#!/usr/bin/env python3
"""Pflegt die Lokalisierungsdateien der LabelWerk-App.

Die App übersetzt Texte mit ``tr("Deutscher Text")`` bzw. ``tr("… %@ …", wert)``; der deutsche Text
ist zugleich der Schlüssel (Deutsch ist die Entwicklungssprache). Dieses Skript

* durchsucht ``Sources/LabelWerkApp/**/*.swift`` nach ``tr("…")``-Aufrufen mit Literal-Schlüssel
  (Kommentare und andere Strings werden korrekt übersprungen, Escape-Sequenzen ausgewertet),
* nimmt zusätzlich die ``displayName``-Texte der Kern-Aufzählungen auf, die die App dynamisch über
  ``tr(wert.displayName)`` übersetzt (abschaltbar mit ``--no-dynamic``),
* schreibt ``Installer/Resources/de.lproj/Localizable.strings`` (Identität: Schlüssel = Wert),
* führt ``Installer/Resources/en.lproj/Localizable.strings`` zusammen: vorhandene Übersetzungen
  bleiben erhalten, neue Schlüssel erhalten den deutschen Text und die Markierung ``/* TODO-EN */``,
  nicht mehr verwendete Einträge wandern in einen eigenen Abschnitt (mit ``--prune`` entfernt).

Warnungen: Schlüssel mit String-Interpolation ``\\(…)`` (zur Laufzeit nie übersetzbar – stattdessen
``tr("… %@ …", wert)`` verwenden), zusammengesetzte Schlüssel (``tr("a" + "b")``), mehrzeilige
Literale sowie Übersetzungen, deren Formatplatzhalter (``%@``, ``%d``, ``%1$@`` …) nicht zum
Schlüssel passen (würde zur Laufzeit abstürzen oder Unsinn anzeigen).

Aufruf::

    python3 Scripts/extract_strings.py            # Dateien aktualisieren
    python3 Scripts/extract_strings.py --check    # nur prüfen; Exitcode 1 bei fehlenden Schlüsseln,
                                                  # falschen Platzhaltern oder Interpolation
    python3 Scripts/extract_strings.py --check --strict   # zusätzlich: unübersetzte (TODO-EN) Einträge
    python3 Scripts/extract_strings.py --list-todo        # unübersetzte Schlüssel ausgeben

Nur Python-Standardbibliothek.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCES = [REPO_ROOT / "Sources" / "LabelWerkApp"]
DEFAULT_RESOURCES = REPO_ROOT / "Installer" / "Resources"
# Dateien, deren `displayName`-Texte die App dynamisch mit `tr(x.displayName)` übersetzt.
DEFAULT_DYNAMIC_SOURCES = [
    REPO_ROOT / "Sources" / "LabelWerkCore" / "Types" / "Enums.swift",
    REPO_ROOT / "Sources" / "LabelWerkCore" / "Types" / "LabelStock.swift",
]
TODO_MARKER = "TODO-EN"
DYNAMIC_GROUP = "Dynamische Schlüssel (displayName aus LabelWerkCore)"
OBSOLETE_GROUP = "Nicht mehr verwendet"

IDENT_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")


# --------------------------------------------------------------------------------------------
# Datenmodell
# --------------------------------------------------------------------------------------------


@dataclass
class Diagnostic:
    """Eine Warnung oder ein Fehler mit Fundstelle."""

    path: str
    line: int
    message: str
    is_error: bool = False

    def render(self) -> str:
        kind = "Fehler" if self.is_error else "Warnung"
        return f"{self.path}:{self.line}: {kind}: {self.message}"


@dataclass
class KeyUse:
    """Ein gefundener Schlüssel mit seiner ersten Fundstelle."""

    key: str
    path: str
    line: int
    has_arguments: bool = False
    dynamic: bool = False


@dataclass
class StringsEntry:
    """Ein Eintrag einer .strings-Datei."""

    key: str
    value: str
    todo: bool = False
    line: int = 0


@dataclass
class ScanResult:
    """Ergebnis des Quelltext-Scans."""

    keys: Dict[str, KeyUse] = field(default_factory=dict)
    diagnostics: List[Diagnostic] = field(default_factory=list)
    dynamic_calls: int = 0
    literal_calls: int = 0

    def add(self, use: KeyUse) -> None:
        existing = self.keys.get(use.key)
        if existing is None:
            self.keys[use.key] = use
        elif use.has_arguments:
            existing.has_arguments = True


class SwiftSyntaxError(Exception):
    """Unerwartetes Dateiende o. Ä. beim Scannen."""


# --------------------------------------------------------------------------------------------
# Swift-Scanner
# --------------------------------------------------------------------------------------------


@dataclass
class StringLiteral:
    """Ein gelesenes Swift-Stringliteral."""

    value: str
    start: int
    end: int  # Index direkt hinter dem Literal
    interpolated: bool = False
    multiline: bool = False
    raw: bool = False
    problems: List[str] = field(default_factory=list)


class SwiftScanner:
    """Minimaler Swift-Lexer: erkennt Kommentare, (Raw-/Mehrzeilen-)Strings und Interpolation."""

    def __init__(self, text: str, path: str) -> None:
        self.text = text
        self.path = path
        self._line_starts = [0]
        for index, char in enumerate(text):
            if char == "\n":
                self._line_starts.append(index + 1)

    # -- Hilfen --------------------------------------------------------------------------

    def line_of(self, index: int) -> int:
        lo, hi = 0, len(self._line_starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self._line_starts[mid] <= index:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def _skip_line_comment(self, pos: int) -> int:
        end = self.text.find("\n", pos)
        return len(self.text) if end < 0 else end + 1

    def _skip_block_comment(self, pos: int) -> int:
        # Swift erlaubt verschachtelte Blockkommentare.
        depth = 0
        text = self.text
        while pos < len(text):
            if text.startswith("/*", pos):
                depth += 1
                pos += 2
            elif text.startswith("*/", pos):
                depth -= 1
                pos += 2
                if depth == 0:
                    return pos
            else:
                pos += 1
        raise SwiftSyntaxError("Blockkommentar ohne Ende")

    def skip_trivia(self, pos: int) -> int:
        """Überspringt Leerraum und Kommentare."""
        text = self.text
        while pos < len(text):
            char = text[pos]
            if char in " \t\r\n":
                pos += 1
            elif text.startswith("//", pos):
                pos = self._skip_line_comment(pos)
            elif text.startswith("/*", pos):
                pos = self._skip_block_comment(pos)
            else:
                break
        return pos

    def is_string_start(self, pos: int) -> bool:
        text = self.text
        if pos >= len(text):
            return False
        if text[pos] == '"':
            return True
        if text[pos] == "#":
            hashes = 0
            while pos + hashes < len(text) and text[pos + hashes] == "#":
                hashes += 1
            return pos + hashes < len(text) and text[pos + hashes] == '"'
        return False

    # -- Stringliterale --------------------------------------------------------------------

    def read_string(self, pos: int) -> StringLiteral:
        """Liest ein Stringliteral ab `pos` (``"``, ``#"``, ``\"\"\"`` …) und wertet Escapes aus."""
        text = self.text
        start = pos
        hashes = 0
        while text[pos] == "#":
            hashes += 1
            pos += 1
        multiline = text.startswith('"""', pos)
        pos += 3 if multiline else 1
        closing = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        literal = StringLiteral(value="", start=start, end=start, multiline=multiline, raw=hashes > 0)
        parts: List[str] = []
        while True:
            if pos >= len(text):
                raise SwiftSyntaxError("Stringliteral ohne Ende")
            if text.startswith(closing, pos):
                pos += len(closing)
                break
            char = text[pos]
            if char == "\n" and not multiline:
                raise SwiftSyntaxError("Zeilenumbruch in einzeiligem Stringliteral")
            if text.startswith(escape, pos):
                pos += len(escape)
                if pos >= len(text):
                    raise SwiftSyntaxError("Escape am Dateiende")
                code = text[pos]
                if code == "(":
                    literal.interpolated = True
                    pos = self._skip_interpolation(pos + 1)
                    parts.append("￼")
                    continue
                simple = {"0": "\0", "\\": "\\", "t": "\t", "n": "\n", "r": "\r", '"': '"', "'": "'"}
                if code in simple:
                    parts.append(simple[code])
                    pos += 1
                    continue
                if code == "u" and pos + 1 < len(text) and text[pos + 1] == "{":
                    close = text.find("}", pos + 2)
                    if close < 0:
                        raise SwiftSyntaxError("\\u{…} ohne Ende")
                    digits = text[pos + 2:close]
                    try:
                        parts.append(chr(int(digits, 16)))
                    except ValueError:
                        literal.problems.append(f"ungültige Unicode-Escape-Sequenz \\u{{{digits}}}")
                    pos = close + 1
                    continue
                if multiline and code in "\r\n":
                    # Zeilenfortsetzung in mehrzeiligen Literalen.
                    while pos < len(text) and text[pos] in "\r\n":
                        pos += 1
                    continue
                literal.problems.append(f"unbekannte Escape-Sequenz \\{code}")
                parts.append(code)
                pos += 1
                continue
            parts.append(char)
            pos += 1
        literal.value = "".join(parts)
        literal.end = pos
        if multiline:
            literal.value = _dedent_multiline(literal.value)
        return literal

    def _skip_interpolation(self, pos: int) -> int:
        """Überspringt den Ausdruck einer Interpolation bis zur passenden schließenden Klammer."""
        text = self.text
        depth = 1
        while pos < len(text):
            if self.is_string_start(pos):
                pos = self.read_string(pos).end
                continue
            if text.startswith("//", pos):
                pos = self._skip_line_comment(pos)
                continue
            if text.startswith("/*", pos):
                pos = self._skip_block_comment(pos)
                continue
            char = text[pos]
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    return pos + 1
            pos += 1
        raise SwiftSyntaxError("Interpolation ohne Ende")

    # -- tr()-Aufrufe ----------------------------------------------------------------------

    def _preceded_by(self, pos: int) -> str:
        """Vorhergehendes Wort (für `func tr(`) bzw. Zeichen vor `tr`."""
        back = pos - 1
        while back >= 0 and self.text[back] in " \t":
            back -= 1
        end = back + 1
        while back >= 0 and self.text[back] in IDENT_CHARS:
            back -= 1
        return self.text[back + 1:end]

    def scan_tr_calls(self, result: ScanResult) -> None:
        text = self.text
        pos = 0
        length = len(text)
        while pos < length:
            char = text[pos]
            if text.startswith("//", pos):
                pos = self._skip_line_comment(pos)
                continue
            if text.startswith("/*", pos):
                pos = self._skip_block_comment(pos)
                continue
            if self.is_string_start(pos):
                pos = self.read_string(pos).end
                continue
            if char in IDENT_CHARS:
                end = pos
                while end < length and text[end] in IDENT_CHARS:
                    end += 1
                word = text[pos:end]
                previous = text[pos - 1] if pos > 0 else ""
                if word == "tr" and previous not in IDENT_CHARS and previous != "." and previous != "`":
                    after = self.skip_trivia(end)
                    if after < length and text[after] == "(" and self._preceded_by(pos) != "func":
                        pos = self._handle_call(pos, after + 1, result)
                        continue
                pos = end
                continue
            pos += 1

    def _handle_call(self, call_start: int, arg_start: int, result: ScanResult) -> int:
        line = self.line_of(call_start)
        pos = self.skip_trivia(arg_start)
        if not self.is_string_start(pos):
            # Dynamischer Schlüssel, z. B. tr(mode.displayName) – wird separat abgedeckt.
            result.dynamic_calls += 1
            return pos
        result.literal_calls += 1
        literal = self.read_string(pos)
        after = self.skip_trivia(literal.end)
        follower = self.text[after] if after < len(self.text) else ""
        for problem in literal.problems:
            result.diagnostics.append(Diagnostic(self.path, line, problem))
        if literal.interpolated:
            result.diagnostics.append(Diagnostic(
                self.path, line,
                "String-Interpolation im Schlüssel ist nicht erlaubt (zur Laufzeit nicht übersetzbar) – "
                "tr(\"… %@ …\", wert) verwenden.",
                is_error=True,
            ))
            return literal.end
        if literal.multiline:
            result.diagnostics.append(Diagnostic(
                self.path, line, "Mehrzeiliges Literal als Schlüssel wird nicht unterstützt – "
                "einzeiliges Literal mit \\n verwenden.", is_error=True))
            return literal.end
        if follower in (")", ","):
            if literal.value == "":
                result.diagnostics.append(Diagnostic(self.path, line, "Leerer Schlüssel tr(\"\")."))
                return literal.end
            result.add(KeyUse(key=literal.value, path=self.path, line=line, has_arguments=follower == ","))
            return literal.end
        result.diagnostics.append(Diagnostic(
            self.path, line,
            f"Schlüssel ist kein vollständiges Literal (gefolgt von „{follower or 'Dateiende'}“), "
            "z. B. tr(\"a\" + \"b\") – wird übersprungen.",
            is_error=True,
        ))
        return literal.end

    # -- displayName-Blöcke ----------------------------------------------------------------

    def scan_display_names(self, result: ScanResult) -> None:
        """Nimmt alle interpolationsfreien Literale aus `var displayName: String { … }` auf."""
        pattern = re.compile(r"\bvar\s+displayName\s*:\s*String\s*\{")
        for match in pattern.finditer(self.text):
            if self._in_comment_or_string(match.start()):
                continue
            pos = match.end()
            depth = 1
            while pos < len(self.text) and depth > 0:
                if self.text.startswith("//", pos):
                    pos = self._skip_line_comment(pos)
                    continue
                if self.text.startswith("/*", pos):
                    pos = self._skip_block_comment(pos)
                    continue
                if self.is_string_start(pos):
                    literal = self.read_string(pos)
                    if not literal.interpolated and not literal.multiline and literal.value:
                        result.add(KeyUse(key=literal.value, path=self.path, line=self.line_of(pos), dynamic=True))
                    pos = literal.end
                    continue
                char = self.text[pos]
                if char == "{":
                    depth += 1
                elif char == "}":
                    depth -= 1
                pos += 1

    def _in_comment_or_string(self, target: int) -> bool:
        pos = 0
        text = self.text
        while pos < target:
            if text.startswith("//", pos):
                end = self._skip_line_comment(pos)
                if end > target:
                    return True
                pos = end
                continue
            if text.startswith("/*", pos):
                end = self._skip_block_comment(pos)
                if end > target:
                    return True
                pos = end
                continue
            if self.is_string_start(pos):
                end = self.read_string(pos).end
                if end > target:
                    return True
                pos = end
                continue
            pos += 1
        return False


def _dedent_multiline(value: str) -> str:
    """Grobe Nachbildung der Einrückungsentfernung mehrzeiliger Swift-Literale (nur für Meldungen)."""
    lines = value.split("\n")
    if lines and lines[0].strip() == "":
        lines = lines[1:]
    if lines:
        indent = lines[-1] if lines[-1].strip() == "" else ""
        lines = [line[len(indent):] if line.startswith(indent) else line for line in lines[:-1]]
    return "\n".join(lines)


def swift_files(directories: Sequence[Path]) -> List[Path]:
    files: List[Path] = []
    for directory in directories:
        if directory.is_file() and directory.suffix == ".swift":
            files.append(directory)
            continue
        if not directory.is_dir():
            continue
        for root, dirnames, filenames in os.walk(directory):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            for name in sorted(filenames):
                if name.endswith(".swift"):
                    files.append(Path(root) / name)
    return files


def relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def scan_sources(sources: Sequence[Path], dynamic_sources: Sequence[Path]) -> ScanResult:
    result = ScanResult()
    for path in swift_files(sources):
        text = path.read_text(encoding="utf-8")
        scanner = SwiftScanner(text, relative(path))
        try:
            scanner.scan_tr_calls(result)
        except SwiftSyntaxError as error:
            result.diagnostics.append(Diagnostic(relative(path), 0, f"Datei nicht lesbar: {error}", is_error=True))
    literal_keys = set(result.keys)
    for path in dynamic_sources:
        if not path.is_file():
            result.diagnostics.append(Diagnostic(relative(path), 0, "Quelle für dynamische Schlüssel fehlt."))
            continue
        scanner = SwiftScanner(path.read_text(encoding="utf-8"), relative(path))
        try:
            scanner.scan_display_names(result)
        except SwiftSyntaxError as error:
            result.diagnostics.append(Diagnostic(relative(path), 0, f"Datei nicht lesbar: {error}", is_error=True))
    # Schlüssel, die auch als Literal vorkommen, gelten nicht als dynamisch.
    for key in literal_keys:
        result.keys[key].dynamic = False
    return result


# --------------------------------------------------------------------------------------------
# .strings lesen und schreiben
# --------------------------------------------------------------------------------------------


class StringsSyntaxError(Exception):
    pass


_STRINGS_UNQUOTED = re.compile(r"[A-Za-z0-9_$+/:.\-]+")


def parse_strings(text: str, path: str = "<strings>") -> List[StringsEntry]:
    """Liest eine .strings-Datei (altes Plist-Format: ``"Schlüssel" = "Wert";``)."""
    entries: List[StringsEntry] = []
    pos = 0
    length = len(text)
    if text.startswith("﻿"):
        pos = 1

    def line_at(index: int) -> int:
        return text.count("\n", 0, index) + 1

    def skip(position: int) -> int:
        while position < length:
            if text[position] in " \t\r\n":
                position += 1
            elif text.startswith("//", position):
                end = text.find("\n", position)
                position = length if end < 0 else end + 1
            elif text.startswith("/*", position):
                end = text.find("*/", position + 2)
                if end < 0:
                    raise StringsSyntaxError(f"{path}:{line_at(position)}: Kommentar ohne Ende")
                position = end + 2
            else:
                break
        return position

    def read_token(position: int) -> Tuple[str, int]:
        if position < length and text[position] == '"':
            position += 1
            parts: List[str] = []
            while True:
                if position >= length:
                    raise StringsSyntaxError(f"{path}:{line_at(position)}: String ohne Ende")
                char = text[position]
                if char == '"':
                    return "".join(parts), position + 1
                if char == "\\":
                    position += 1
                    if position >= length:
                        raise StringsSyntaxError(f"{path}:{line_at(position)}: Escape am Dateiende")
                    code = text[position]
                    simple = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'",
                              "a": "\a", "b": "\b", "f": "\f", "v": "\v"}
                    if code in simple:
                        parts.append(simple[code])
                        position += 1
                    elif code in "Uu":
                        digits = text[position + 1:position + 5]
                        if not re.fullmatch(r"[0-9A-Fa-f]{4}", digits):
                            raise StringsSyntaxError(f"{path}:{line_at(position)}: ungültiges \\U-Escape")
                        parts.append(chr(int(digits, 16)))
                        position += 5
                    elif code in "01234567":
                        digits = re.match(r"[0-7]{1,3}", text[position:]).group(0)
                        parts.append(chr(int(digits, 8)))
                        position += len(digits)
                    else:
                        parts.append(code)
                        position += 1
                    continue
                parts.append(char)
                position += 1
        match = _STRINGS_UNQUOTED.match(text, position)
        if not match:
            raise StringsSyntaxError(f"{path}:{line_at(position)}: Zeichenkette erwartet")
        return match.group(0), match.end()

    seen: Dict[str, int] = {}
    while True:
        pos = skip(pos)
        if pos >= length:
            break
        entry_line = line_at(pos)
        key, pos = read_token(pos)
        pos = skip(pos)
        if pos < length and text[pos] == ";":
            value = key
        else:
            if pos >= length or text[pos] != "=":
                raise StringsSyntaxError(f"{path}:{line_at(pos)}: „=“ erwartet")
            pos = skip(pos + 1)
            value, pos = read_token(pos)
            pos = skip(pos)
            if pos >= length or text[pos] != ";":
                raise StringsSyntaxError(f"{path}:{line_at(pos)}: „;“ erwartet")
        pos += 1
        # Markierung /* TODO-EN */ in derselben Zeile hinter dem Eintrag.
        todo = False
        probe = skip_inline_spaces(text, pos)
        if text.startswith("/*", probe):
            end = text.find("*/", probe + 2)
            if end >= 0 and TODO_MARKER in text[probe:end]:
                todo = True
        if key in seen:
            raise StringsSyntaxError(f"{path}:{entry_line}: Schlüssel doppelt (zuerst in Zeile {seen[key]}): {key!r}")
        seen[key] = entry_line
        entries.append(StringsEntry(key=key, value=value, todo=todo, line=entry_line))
    return entries


def skip_inline_spaces(text: str, pos: int) -> int:
    while pos < len(text) and text[pos] in " \t":
        pos += 1
    return pos


def escape_strings(value: str) -> str:
    out: List[str] = []
    for char in value:
        if char == "\\":
            out.append("\\\\")
        elif char == '"':
            out.append('\\"')
        elif char == "\n":
            out.append("\\n")
        elif char == "\t":
            out.append("\\t")
        elif char == "\r":
            out.append("\\r")
        elif ord(char) < 0x20 or char in "  ":
            out.append(f"\\U{ord(char):04X}")
        else:
            out.append(char)
    return "".join(out)


# --------------------------------------------------------------------------------------------
# Formatplatzhalter
# --------------------------------------------------------------------------------------------

_FORMAT_PATTERN = re.compile(
    r"%(?:(?P<position>[1-9][0-9]*)\$)?[-+ #0']*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?"
    r"(?P<length>hh|h|ll|l|q|L|z|t|j)?(?P<conversion>[@dDiuUxXoOfFeEgGcCsSpaA%])"
)
_CONVERSION_CLASS = {
    "@": "@", "d": "int", "D": "int", "i": "int", "u": "int", "U": "int", "x": "int", "X": "int",
    "o": "int", "O": "int", "c": "char", "C": "char", "s": "cstring", "S": "cstring", "p": "pointer",
    "f": "double", "F": "double", "e": "double", "E": "double", "g": "double", "G": "double",
    "a": "double", "A": "double",
}
_LENGTH_CLASS = {None: "", "h": "", "hh": "", "l": "long", "ll": "long", "q": "long", "j": "long",
                 "z": "long", "t": "long", "L": "longdouble"}


def format_signature(text: str) -> Optional[Dict[int, str]]:
    """Platzhalter eines Formatstrings als {Position: Typklasse}; None bei widersprüchlicher Nutzung."""
    signature: Dict[int, str] = {}
    sequential = 0
    for match in _FORMAT_PATTERN.finditer(text):
        conversion = match.group("conversion")
        if conversion == "%":
            continue
        if match.group("position"):
            index = int(match.group("position"))
        else:
            sequential += 1
            index = sequential
        kind = _CONVERSION_CLASS[conversion]
        if kind in ("int", "double"):
            kind = f"{_LENGTH_CLASS[match.group('length')]}{kind}"
        if index in signature and signature[index] != kind:
            return None
        signature[index] = kind
    return signature


def describe_signature(signature: Optional[Dict[int, str]]) -> str:
    if signature is None:
        return "widersprüchlich"
    if not signature:
        return "keine"
    return ", ".join(f"{index}:{kind}" for index, kind in sorted(signature.items()))


# --------------------------------------------------------------------------------------------
# Zusammenführen und Schreiben
# --------------------------------------------------------------------------------------------


@dataclass
class MergeOutcome:
    en_text: str
    de_text: str
    missing_en: List[str]
    missing_de: List[str]
    obsolete_en: List[str]
    todo: List[str]
    format_errors: List[Diagnostic]
    total: int


HEADER_EN = """/* LabelWerk – englische Übersetzungen (en.lproj/Localizable.strings)
 *
 * Gepflegt mit Scripts/extract_strings.py – Schlüssel = deutscher Quelltext aus tr("…").
 * Neue Einträge enthalten zunächst den deutschen Text und die Markierung TODO-EN: Übersetzung
 * eintragen und die Markierung entfernen. Formatplatzhalter (%@, %d, %.1f, %1$@ …) müssen in
 * Anzahl und Typ erhalten bleiben; die Reihenfolge lässt sich mit %1$@, %2$@ … ändern.
 */"""

HEADER_DE = """/* LabelWerk – deutsche Texte (de.lproj/Localizable.strings)
 *
 * Deutsch ist die Entwicklungssprache: Schlüssel = Wert. Automatisch erzeugt von
 * Scripts/extract_strings.py – nicht von Hand bearbeiten.
 */"""


def _group_title(use: KeyUse) -> str:
    if use.dynamic:
        return DYNAMIC_GROUP
    path = use.path
    prefix = "Sources/LabelWerkApp/"
    return path[len(prefix):] if path.startswith(prefix) else path


def _ordered_groups(keys: Dict[str, KeyUse]) -> List[Tuple[str, List[KeyUse]]]:
    groups: Dict[str, List[KeyUse]] = {}
    for use in keys.values():
        groups.setdefault(_group_title(use), []).append(use)
    titles = sorted(t for t in groups if t != DYNAMIC_GROUP)
    if DYNAMIC_GROUP in groups:
        titles.append(DYNAMIC_GROUP)
    ordered = []
    for title in titles:
        uses = sorted(groups[title], key=lambda u: (u.path, u.line, u.key))
        ordered.append((title, uses))
    return ordered


def _render_entry(key: str, value: str, todo: bool) -> str:
    line = f"\"{escape_strings(key)}\" = \"{escape_strings(value)}\";"
    if todo:
        line += f" /* {TODO_MARKER} */"
    return line


def merge(scan: ScanResult, en_entries: List[StringsEntry], de_entries: List[StringsEntry],
          prune: bool) -> MergeOutcome:
    existing_en = {entry.key: entry for entry in en_entries}
    existing_de = {entry.key for entry in de_entries}
    current = scan.keys

    en_lines: List[str] = [HEADER_EN]
    de_lines: List[str] = [HEADER_DE]
    todo: List[str] = []
    format_errors: List[Diagnostic] = []
    for title, uses in _ordered_groups(current):
        en_lines.append(f"\n/* MARK: {title} */")
        de_lines.append(f"\n/* MARK: {title} */")
        for use in uses:
            key = use.key
            previous = existing_en.get(key)
            if previous is None:
                value, is_todo = key, True
            elif previous.todo and previous.value == key:
                value, is_todo = key, True
            else:
                value, is_todo = previous.value, False
            if is_todo:
                todo.append(key)
            en_lines.append(_render_entry(key, value, is_todo))
            de_lines.append(_render_entry(key, key, False))
            if use.has_arguments and not is_todo:
                expected = format_signature(key)
                actual = format_signature(value)
                if expected is None or actual is None or expected != actual:
                    format_errors.append(Diagnostic(
                        use.path, use.line,
                        f"Platzhalter der Übersetzung passen nicht zum Schlüssel {key!r}: "
                        f"erwartet {describe_signature(expected)}, gefunden {describe_signature(actual)} "
                        f"in {value!r}.",
                        is_error=True,
                    ))

    obsolete = [entry for entry in en_entries if entry.key not in current]
    if obsolete and not prune:
        en_lines.append(f"\n/* MARK: {OBSOLETE_GROUP} – wird mit --prune entfernt */")
        for entry in obsolete:
            en_lines.append(_render_entry(entry.key, entry.value, entry.todo and entry.value == entry.key))

    return MergeOutcome(
        en_text="\n".join(en_lines) + "\n",
        de_text="\n".join(de_lines) + "\n",
        missing_en=[key for key in current if key not in existing_en],
        missing_de=[key for key in current if key not in existing_de],
        obsolete_en=[entry.key for entry in obsolete],
        todo=todo,
        format_errors=format_errors,
        total=len(current),
    )


def read_strings_file(path: Path) -> List[StringsEntry]:
    if not path.exists():
        return []
    return parse_strings(path.read_text(encoding="utf-8"), relative(path))


# --------------------------------------------------------------------------------------------
# Kommandozeile
# --------------------------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Extrahiert tr(\"…\")-Schlüssel der App und pflegt de/en Localizable.strings.")
    parser.add_argument("--check", action="store_true",
                        help="nur prüfen, nichts schreiben (Exitcode 1 bei Fehlern)")
    parser.add_argument("--strict", action="store_true",
                        help="mit --check: auch unübersetzte (TODO-EN) Einträge als Fehler werten")
    parser.add_argument("--prune", action="store_true",
                        help="nicht mehr verwendete Übersetzungen entfernen statt aufzubewahren")
    parser.add_argument("--no-dynamic", action="store_true",
                        help="displayName-Texte aus LabelWerkCore nicht aufnehmen")
    parser.add_argument("--list-todo", action="store_true", help="unübersetzte Schlüssel ausgeben")
    parser.add_argument("--sources", nargs="+", type=Path, default=None,
                        help="zu durchsuchende Verzeichnisse/Dateien (Standard: Sources/LabelWerkApp)")
    parser.add_argument("--dynamic-sources", nargs="*", type=Path, default=None,
                        help="Swift-Dateien mit displayName-Texten (Standard: LabelWerkCore/Types/…)")
    parser.add_argument("--resources", type=Path, default=DEFAULT_RESOURCES,
                        help="Verzeichnis mit de.lproj/ und en.lproj/ (Standard: Installer/Resources)")
    parser.add_argument("-q", "--quiet", action="store_true", help="nur Warnungen und Fehler ausgeben")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    sources = args.sources if args.sources is not None else DEFAULT_SOURCES
    dynamic = [] if args.no_dynamic else (
        args.dynamic_sources if args.dynamic_sources is not None else DEFAULT_DYNAMIC_SOURCES)
    for source in sources:
        if not source.exists():
            print(f"Fehler: Quellverzeichnis fehlt: {source}", file=sys.stderr)
            return 2

    scan = scan_sources(sources, dynamic)
    en_path = args.resources / "en.lproj" / "Localizable.strings"
    de_path = args.resources / "de.lproj" / "Localizable.strings"
    try:
        en_entries = read_strings_file(en_path)
        de_entries = read_strings_file(de_path)
    except StringsSyntaxError as error:
        print(f"Fehler: {error}", file=sys.stderr)
        return 1

    outcome = merge(scan, en_entries, de_entries, prune=args.prune)
    diagnostics = scan.diagnostics + outcome.format_errors
    for diagnostic in diagnostics:
        print(diagnostic.render(), file=sys.stderr)

    if args.list_todo:
        for key in outcome.todo:
            print(key)

    translated = outcome.total - len(outcome.todo)
    summary = (f"{outcome.total} Schlüssel ({scan.literal_calls} Literal-Aufrufe, {scan.dynamic_calls} "
               f"dynamische Aufrufe) · Englisch: {translated} übersetzt, {len(outcome.todo)} offen (TODO-EN)")

    if args.check:
        errors = [d for d in diagnostics if d.is_error]
        failed = bool(errors)
        if outcome.missing_en:
            failed = True
            print(f"Fehler: {len(outcome.missing_en)} Schlüssel fehlen in {relative(en_path)}, z. B. "
                  f"{outcome.missing_en[0]!r} – Scripts/extract_strings.py ausführen.", file=sys.stderr)
        if outcome.missing_de:
            failed = True
            print(f"Fehler: {len(outcome.missing_de)} Schlüssel fehlen in {relative(de_path)} – "
                  f"Scripts/extract_strings.py ausführen.", file=sys.stderr)
        if outcome.obsolete_en:
            print(f"Hinweis: {len(outcome.obsolete_en)} Übersetzungen werden nicht mehr verwendet "
                  f"(entfernen mit --prune).", file=sys.stderr)
        if outcome.todo:
            message = f"{len(outcome.todo)} Schlüssel sind noch nicht ins Englische übersetzt (TODO-EN)."
            if args.strict:
                failed = True
                print(f"Fehler: {message}", file=sys.stderr)
            else:
                print(f"Warnung: {message}", file=sys.stderr)
        if not args.quiet:
            print(summary)
        if failed:
            print("Lokalisierung: Prüfung fehlgeschlagen.", file=sys.stderr)
            return 1
        if not args.quiet:
            print("Lokalisierung: in Ordnung.")
        return 0

    for path, content in ((en_path, outcome.en_text), (de_path, outcome.de_text)):
        path.parent.mkdir(parents=True, exist_ok=True)
        old = path.read_text(encoding="utf-8") if path.exists() else None
        if old != content:
            path.write_text(content, encoding="utf-8")
            if not args.quiet:
                print(f"geschrieben: {relative(path)}")
    if not args.quiet:
        print(summary)
        if outcome.missing_en:
            print(f"neu: {len(outcome.missing_en)} Schlüssel (mit TODO-EN markiert)")
        if outcome.obsolete_en:
            verb = "entfernt" if args.prune else "aufbewahrt (Abschnitt „Nicht mehr verwendet“)"
            print(f"nicht mehr verwendet: {len(outcome.obsolete_en)} Einträge {verb}")
    return 1 if any(d.is_error for d in diagnostics) else 0


if __name__ == "__main__":
    sys.exit(main())
