#!/usr/bin/env python3
"""Tests für ``Scripts/extract_strings.py`` (unittest, nur Standardbibliothek).

Aufruf (vom Repository-Wurzelverzeichnis)::

    python3 Scripts/tests/test_extract_strings.py
    python3 -m unittest discover -s Scripts/tests -v

Geprüft werden der Swift-Scanner (Kommentare, Escape-Sequenzen, Raw- und Mehrzeilen-Literale,
Interpolation), die dynamischen Quellen (``displayName``, verkettete Literale, SF-Symbol-Filter),
das Lesen/Schreiben von ``.strings``-Dateien, der Vergleich von Formatplatzhaltern, das
Zusammenführen und die Kommandozeile. Ob die Lokalisierung des Repositorys vollständig ist, prüft
``python3 Scripts/extract_strings.py --check --strict`` (``make strings-check``, CI-Schritt
„strings“) – bewusst nicht als Unit-Test, damit neue, noch unübersetzte Texte die Tests nicht
blockieren.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import shutil
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from typing import List, Optional, Sequence

SCRIPTS = Path(__file__).resolve().parent.parent
REPO_ROOT = SCRIPTS.parent
SCRIPT = SCRIPTS / "extract_strings.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("extract_strings", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules["extract_strings"] = module
    spec.loader.exec_module(module)
    return module


es = _load_module()


def scan(source: str, path: str = "Test.swift"):
    """Scannt einen Swift-Quelltext nach tr()-Aufrufen."""
    result = es.ScanResult()
    es.SwiftScanner(source, path).scan_tr_calls(result)
    return result


def keys(source: str) -> List[str]:
    return list(scan(source).keys)


def run_main(argv: Sequence[str]):
    """Führt ``main`` aus und liefert (Exitcode, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = es.main(list(argv))
    return code, out.getvalue(), err.getvalue()


# ------------------------------------------------------------------------------------------------
# Swift-Scanner
# ------------------------------------------------------------------------------------------------


class ScannerTests(unittest.TestCase):
    def test_simple_literal(self):
        self.assertEqual(keys('Text(tr("Drucker hinzufügen"))'), ["Drucker hinzufügen"])

    def test_arguments_mark_key_as_format(self):
        result = scan('let s = tr("Noch %d Etiketten", count)')
        self.assertEqual(list(result.keys), ["Noch %d Etiketten"])
        self.assertTrue(result.keys["Noch %d Etiketten"].has_arguments)
        self.assertEqual(result.literal_calls, 1)

    def test_same_key_with_and_without_arguments(self):
        result = scan('tr("A %@")\ntr("A %@", x)')
        self.assertTrue(result.keys["A %@"].has_arguments)
        self.assertEqual(result.keys["A %@"].line, 1)

    def test_escaped_quotes_and_backslash(self):
        self.assertEqual(keys(r'tr("Er sagte \"Hallo\" \\ ok")'), ['Er sagte "Hallo" \\ ok'])

    def test_escape_sequences(self):
        self.assertEqual(keys(r'tr("Zeile 1\nZeile 2\tTab \u{2026} \u{1F600}")'),
                         ["Zeile 1\nZeile 2\tTab … \U0001F600"])

    def test_unknown_escape_is_reported(self):
        result = scan(r'tr("a\qb")')
        self.assertEqual(list(result.keys), ["aqb"])
        self.assertTrue(any("Escape" in d.message for d in result.diagnostics))

    def test_interpolation_is_an_error_and_not_extracted(self):
        result = scan('tr("Hallo \\(name), du hast \\(count(of: "x")) Aufträge")')
        self.assertEqual(result.keys, {})
        errors = [d for d in result.diagnostics if d.is_error]
        self.assertEqual(len(errors), 1)
        self.assertIn("Interpolation", errors[0].message)

    def test_comments_are_ignored(self):
        source = textwrap.dedent('''
            // tr("Zeilenkommentar")
            /* tr("Block") /* verschachtelt tr("innen") */ tr("immer noch Kommentar") */
            /// tr("Doku")
            let a = tr("Echt")
        ''')
        self.assertEqual(keys(source), ["Echt"])

    def test_tr_inside_other_strings_is_ignored(self):
        source = 'let code = "tr(\\"Nicht\\")"\nlet b = #"tr("Auch nicht")"#\nlet c = tr("Ja")'
        self.assertEqual(keys(source), ["Ja"])

    def test_raw_string_keys(self):
        self.assertEqual(keys('tr(#"Pfad C:\\temp "zitiert""#)'), ['Pfad C:\\temp "zitiert"'])
        self.assertEqual(keys('tr(#"a\\#nb"#)'), ["a\nb"])

    def test_raw_string_interpolation_is_an_error(self):
        result = scan('tr(#"Wert \\#(x)"#)')
        self.assertEqual(result.keys, {})
        self.assertTrue(any(d.is_error and "Interpolation" in d.message for d in result.diagnostics))

    def test_multiline_literal_is_an_error(self):
        source = 'tr("""\n    Zeile\n    """)'
        result = scan(source)
        self.assertEqual(result.keys, {})
        self.assertTrue(any(d.is_error and "Mehrzeilig" in d.message for d in result.diagnostics))

    def test_multiline_string_elsewhere_is_skipped(self):
        source = 'let doc = """\n  tr("drin")\n  """\nlet x = tr("draußen")'
        self.assertEqual(keys(source), ["draußen"])

    def test_concatenation_is_an_error(self):
        result = scan('tr("a" + "b")')
        self.assertEqual(result.keys, {})
        self.assertTrue(any(d.is_error and "kein vollständiges Literal" in d.message for d in result.diagnostics))

    def test_dynamic_calls_are_counted(self):
        result = scan('Text(tr(mode.displayName))\nText(tr(alert.title))')
        self.assertEqual(result.keys, {})
        self.assertEqual(result.dynamic_calls, 2)

    def test_definitions_member_calls_and_other_identifiers_are_ignored(self):
        source = textwrap.dedent('''
            func tr(_ key: String) -> String { key }
            func tr(_ key: String, _ arguments: CVarArg...) -> String { key }
            let a = foo.tr("Methode")
            let b = attr("kein tr")
            let c = `tr`("Backticks")
            let d = tr ( "Leerzeichen erlaubt" )
            let e = tr(
                "Neue Zeile",
                value
            )
        ''')
        self.assertEqual(keys(source), ["Leerzeichen erlaubt", "Neue Zeile"])

    def test_line_numbers(self):
        result = scan('\n\n  // tr("x")\nlet a = 1\nlet b = tr("Zeile fünf")')
        self.assertEqual(result.keys["Zeile fünf"].line, 5)

    def test_empty_key_warning(self):
        result = scan('tr("")')
        self.assertEqual(result.keys, {})
        self.assertTrue(any("Leerer Schlüssel" in d.message for d in result.diagnostics))

    def test_unterminated_string_raises(self):
        with self.assertRaises(es.SwiftSyntaxError):
            scan('let a = tr("offen')

    def test_unterminated_block_comment_raises(self):
        with self.assertRaises(es.SwiftSyntaxError):
            scan('/* offen')


# ------------------------------------------------------------------------------------------------
# Dynamische Quellen
# ------------------------------------------------------------------------------------------------


class DynamicSourceTests(unittest.TestCase):
    ENUM = textwrap.dedent('''
        public enum Mode: String {
            case a, b, c
            /// Kommentar mit "Literal", das nicht zählt
            public var displayName: String {
                switch self {
                case .a: return "Abreißen"
                case .b: return "Spenden " + "(Peel-Off)"
                case .c: return "Wert \\(rawValue)"   // Interpolation → übersprungen
                }
            }
            public var systemImage: String { "scissors" }
        }
    ''')

    def members(self, source: str, members: Sequence[str], skip_symbols: bool = False):
        result = es.ScanResult()
        es.SwiftScanner(source, "Dyn.swift").scan_members(result, members, skip_symbols, "Gruppe")
        return result

    def test_display_name_block(self):
        result = self.members(self.ENUM, ["displayName"])
        self.assertEqual(list(result.keys), ["Abreißen", "Spenden (Peel-Off)"])
        self.assertTrue(all(use.dynamic and use.group == "Gruppe" for use in result.keys.values()))

    def test_other_members_are_not_scanned(self):
        result = self.members(self.ENUM, ["detail"])
        self.assertEqual(result.keys, {})

    def test_function_bodies_and_symbol_filter(self):
        source = textwrap.dedent('''
            static func catalog(_ kind: Kind)
                -> (severity: Int, title: String, recovery: String, systemImage: String) {
                switch kind {
                case .mediaOut:
                    return (2, "Etiketten leer",
                            "Rolle einlegen "
                            + "und kalibrieren.",
                            "tray")
                case .heat:
                    return (2, "Zu heiß", "Abkühlen lassen.", "thermometer.sun.fill")
                }
            }
        ''')
        with_filter = self.members(source, ["catalog"], skip_symbols=True)
        self.assertEqual(list(with_filter.keys),
                         ["Etiketten leer", "Rolle einlegen und kalibrieren.", "Zu heiß", "Abkühlen lassen."])
        without_filter = self.members(source, ["catalog"], skip_symbols=False)
        self.assertIn("tray", without_filter.keys)
        self.assertIn("thermometer.sun.fill", without_filter.keys)

    def test_concatenation_with_variable_is_skipped(self):
        source = 'var displayName: String { "Zebra " + name }'
        self.assertEqual(self.members(source, ["displayName"]).keys, {})

    def test_parse_dynamic_source_spec(self):
        plain = es.parse_dynamic_source("Sources/X.swift")
        self.assertEqual(plain.path, Path("Sources/X.swift"))
        self.assertEqual(plain.members, ("displayName",))
        self.assertFalse(plain.skip_symbols)
        full = es.parse_dynamic_source("Sources/Y.swift:title, recovery:symbols")
        self.assertEqual(full.members, ("title", "recovery"))
        self.assertTrue(full.skip_symbols)

    def test_literal_use_wins_over_dynamic_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / "App"
            app.mkdir()
            (app / "View.swift").write_text('let a = tr("Abreißen")\n', encoding="utf-8")
            core = root / "Enums.swift"
            core.write_text(self.ENUM, encoding="utf-8")
            result = es.scan_sources([app], [es.DynamicSource(core)])
            self.assertFalse(result.keys["Abreißen"].dynamic)
            self.assertIsNone(result.keys["Abreißen"].group)
            self.assertTrue(result.keys["Spenden (Peel-Off)"].dynamic)

    def test_missing_dynamic_source_is_a_warning(self):
        result = es.scan_sources([], [Path("/nicht/vorhanden.swift")])
        self.assertTrue(any("fehlt" in d.message and not d.is_error for d in result.diagnostics))

    def test_default_dynamic_sources_exist(self):
        for source in es.DEFAULT_DYNAMIC_SOURCES:
            if not (REPO_ROOT / "Sources").is_dir():
                self.skipTest("Quelltexte nicht vorhanden")
            self.assertTrue(source.path.is_file(), f"dynamische Quelle fehlt: {source.path}")


# ------------------------------------------------------------------------------------------------
# .strings-Dateien
# ------------------------------------------------------------------------------------------------


class StringsFileTests(unittest.TestCase):
    def test_parse_with_comments_escapes_and_todo(self):
        text = textwrap.dedent('''\
            /* Kopf */
            // Zeilenkommentar
            "a" = "A";
            "b\\"q" = "B \\"zitiert\\"\\nneu"; /* TODO-EN */
            "c" = "\\U00E4\\t"; /* Hinweis */
            unquoted_key = "x";
            "nur" ;
        ''')
        entries = es.parse_strings(text)
        self.assertEqual([e.key for e in entries], ["a", 'b"q', "c", "unquoted_key", "nur"])
        self.assertEqual(entries[1].value, 'B "zitiert"\nneu')
        self.assertTrue(entries[1].todo)
        self.assertFalse(entries[0].todo)
        self.assertFalse(entries[2].todo)
        self.assertEqual(entries[2].value, "ä\t")
        self.assertEqual(entries[4].value, "nur")
        self.assertEqual(entries[1].line, 4)

    def test_bom_is_accepted(self):
        self.assertEqual(es.parse_strings('\ufeff"a" = "b";')[0].value, "b")

    def test_duplicate_key_is_rejected(self):
        with self.assertRaisesRegex(es.StringsSyntaxError, "doppelt"):
            es.parse_strings('"a" = "1";\n"a" = "2";')

    def test_syntax_errors(self):
        for text in ('"a" = "1"', '"a" "1";', '"a = "1";', '/* offen', '"a" = ;'):
            with self.subTest(text=text), self.assertRaises(es.StringsSyntaxError):
                es.parse_strings(text)

    def test_escape_roundtrip(self):
        value = 'Pfad "C:\\x"\nTab\tCR\r\u2028Ende € ä'
        rendered = f'"k" = "{es.escape_strings(value)}";'
        self.assertNotIn("\n", rendered)
        self.assertEqual(es.parse_strings(rendered)[0].value, value)


# ------------------------------------------------------------------------------------------------
# Formatplatzhalter
# ------------------------------------------------------------------------------------------------


class FormatSignatureTests(unittest.TestCase):
    def test_sequential(self):
        self.assertEqual(es.format_signature("%@ hat %d Etiketten (%.1f mm)"),
                         {1: "@", 2: "int", 3: "double"})

    def test_percent_literal_and_length_modifiers(self):
        self.assertEqual(es.format_signature("%ld von %lu – 100 %%"), {1: "longint", 2: "longint"})

    def test_positional_reordering_is_equivalent(self):
        self.assertEqual(es.format_signature("%1$@ von %2$d"), es.format_signature("%2$d: %1$@"))

    def test_type_mismatch_detected(self):
        self.assertNotEqual(es.format_signature("%d Etiketten"), es.format_signature("%@ labels"))

    def test_conflicting_use_returns_none(self):
        self.assertIsNone(es.format_signature("%1$@ und %1$d"))
        self.assertEqual(es.describe_signature(None), "widersprüchlich")
        self.assertEqual(es.describe_signature({}), "keine")


# ------------------------------------------------------------------------------------------------
# Zusammenführen
# ------------------------------------------------------------------------------------------------


class MergeTests(unittest.TestCase):
    def scan_result(self, entries):
        result = es.ScanResult()
        for key, has_args in entries:
            result.add(es.KeyUse(key=key, path="Sources/LabelWerkApp/A.swift", line=1, has_arguments=has_args))
        return result

    def test_preserves_translations_and_marks_new_keys(self):
        result = self.scan_result([("Drucker", False), ("Neu", False)])
        en = [es.StringsEntry("Drucker", "Printer")]
        outcome = es.merge(result, en, [], prune=False)
        self.assertEqual(outcome.missing_en, ["Neu"])
        self.assertEqual(outcome.missing_de, ["Drucker", "Neu"])
        self.assertEqual(outcome.todo, ["Neu"])
        self.assertIn('"Drucker" = "Printer";', outcome.en_text)
        self.assertIn('"Neu" = "Neu"; /* TODO-EN */', outcome.en_text)
        self.assertIn('"Drucker" = "Drucker";', outcome.de_text)
        self.assertIn("/* MARK: A.swift */", outcome.en_text)

    def test_todo_entry_stays_todo_until_translated(self):
        result = self.scan_result([("Neu", False)])
        still_todo = es.merge(result, [es.StringsEntry("Neu", "Neu", todo=True)], [], prune=False)
        self.assertEqual(still_todo.todo, ["Neu"])
        translated = es.merge(result, [es.StringsEntry("Neu", "New", todo=True)], [], prune=False)
        self.assertEqual(translated.todo, [])
        self.assertIn('"Neu" = "New";', translated.en_text)

    def test_obsolete_entries_kept_or_pruned(self):
        result = self.scan_result([("A", False)])
        en = [es.StringsEntry("A", "a"), es.StringsEntry("Alt", "old")]
        kept = es.merge(result, en, [], prune=False)
        self.assertEqual(kept.obsolete_en, ["Alt"])
        self.assertIn(es.OBSOLETE_GROUP, kept.en_text)
        self.assertIn('"Alt" = "old";', kept.en_text)
        pruned = es.merge(result, en, [], prune=True)
        self.assertNotIn('"Alt"', pruned.en_text)

    def test_format_mismatch_is_an_error(self):
        result = self.scan_result([("%d Etiketten", True), ("Ohne Argumente 100 %", False)])
        en = [es.StringsEntry("%d Etiketten", "%@ labels"), es.StringsEntry("Ohne Argumente 100 %", "No args 100 %")]
        outcome = es.merge(result, en, [], prune=False)
        self.assertEqual(len(outcome.format_errors), 1)
        self.assertIn("%d Etiketten", outcome.format_errors[0].message)

    def test_reordered_positional_translation_is_accepted(self):
        result = self.scan_result([("%@ von %d", True)])
        outcome = es.merge(result, [es.StringsEntry("%@ von %d", "%2$d of %1$@")], [], prune=False)
        self.assertEqual(outcome.format_errors, [])

    def test_output_is_parseable_and_stable(self):
        result = self.scan_result([('Mit "Zitat"\nund Umbruch', False), ("B", False)])
        first = es.merge(result, [], [], prune=False)
        parsed = es.parse_strings(first.en_text)
        # Gleiche Datei und Zeile → alphabetisch nach Schlüssel.
        self.assertEqual([e.key for e in parsed], ["B", 'Mit "Zitat"\nund Umbruch'])
        second = es.merge(result, parsed, es.parse_strings(first.de_text), prune=False)
        self.assertEqual(first.en_text, second.en_text)
        self.assertEqual(second.missing_de, [])


# ------------------------------------------------------------------------------------------------
# Kommandozeile
# ------------------------------------------------------------------------------------------------


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-strings-"))
        self.sources = self.tmp / "App"
        self.sources.mkdir()
        self.resources = self.tmp / "Resources"
        self.write_source('Text(tr("Hallo"))\nText(tr("%d Etiketten", n))\n')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_source(self, text: str, name: str = "View.swift"):
        (self.sources / name).write_text(text, encoding="utf-8")

    def main(self, *extra: str, dynamic: Optional[Sequence[str]] = None):
        argv = ["--sources", str(self.sources), "--resources", str(self.resources), "-q"]
        argv += ["--no-dynamic"] if dynamic is None else ["--dynamic-sources", *dynamic]
        return run_main(argv + list(extra))

    def en_path(self) -> Path:
        return self.resources / "en.lproj" / "Localizable.strings"

    def translate(self, mapping):
        text = self.en_path().read_text(encoding="utf-8")
        for key, value in mapping.items():
            text = text.replace(f'"{key}" = "{key}"; /* TODO-EN */', f'"{key}" = "{value}";')
        self.en_path().write_text(text, encoding="utf-8")

    def test_full_workflow(self):
        code, _, _ = self.main("--check")
        self.assertEqual(code, 1, "fehlende Dateien müssen --check scheitern lassen")
        self.assertFalse(self.en_path().exists(), "--check darf nichts schreiben")

        code, _, _ = self.main()
        self.assertEqual(code, 0)
        de = es.read_strings_file(self.resources / "de.lproj" / "Localizable.strings")
        self.assertEqual({e.key: e.value for e in de}, {"Hallo": "Hallo", "%d Etiketten": "%d Etiketten"})
        self.assertEqual(sorted(e.key for e in es.read_strings_file(self.en_path()) if e.todo),
                         ["%d Etiketten", "Hallo"])

        code, _, err = self.main("--check")
        self.assertEqual(code, 0)
        self.assertIn("TODO-EN", err)
        code, _, _ = self.main("--check", "--strict")
        self.assertEqual(code, 1)

        code, out, _ = run_main(["--sources", str(self.sources), "--resources", str(self.resources),
                                 "--no-dynamic", "--list-todo", "--check"])
        self.assertIn("Hallo", out.splitlines())

        self.translate({"Hallo": "Hello", "%d Etiketten": "%d labels"})
        code, _, _ = self.main("--check", "--strict")
        self.assertEqual(code, 0)

        # Neuer Schlüssel im Quelltext → Prüfung schlägt fehl, bis die Dateien aktualisiert sind.
        self.write_source('Text(tr("Neu"))\n', name="Other.swift")
        self.assertEqual(self.main("--check")[0], 1)
        self.assertEqual(self.main()[0], 0)
        self.assertEqual(self.main("--check")[0], 0)
        entries = {e.key: e for e in es.read_strings_file(self.en_path())}
        self.assertEqual(entries["Hallo"].value, "Hello")
        self.assertTrue(entries["Neu"].todo)

    def test_second_run_does_not_rewrite(self):
        self.assertEqual(self.main()[0], 0)
        before = self.en_path().stat().st_mtime_ns
        code, out, _ = run_main(["--sources", str(self.sources), "--resources", str(self.resources), "--no-dynamic"])
        self.assertEqual(code, 0)
        self.assertNotIn("geschrieben", out)
        self.assertEqual(self.en_path().stat().st_mtime_ns, before)

    def test_wrong_placeholder_fails_check(self):
        self.main()
        self.translate({"Hallo": "Hello", "%d Etiketten": "%@ labels"})
        code, _, err = self.main("--check")
        self.assertEqual(code, 1)
        self.assertIn("Platzhalter", err)

    def test_interpolation_fails_check_and_update(self):
        self.write_source('Text(tr("Hallo \\(name)"))\n', name="Bad.swift")
        code, _, err = self.main("--check")
        self.assertEqual(code, 1)
        self.assertIn("Interpolation", err)
        self.assertEqual(self.main()[0], 1)

    def test_obsolete_entries_are_pruned_on_request(self):
        self.main()
        self.write_source('Text(tr("Hallo"))\n')
        self.assertEqual(self.main()[0], 0)
        self.assertIn('"%d Etiketten"', self.en_path().read_text(encoding="utf-8"))
        self.assertEqual(self.main("--prune")[0], 0)
        self.assertNotIn('"%d Etiketten"', self.en_path().read_text(encoding="utf-8"))

    def test_dynamic_sources_on_command_line(self):
        core = self.tmp / "Enums.swift"
        core.write_text('enum M { case a\n var displayName: String { switch self { case .a: return "Spenden" } }\n'
                        ' var detail: String { "Löst das Etikett" } }\n', encoding="utf-8")
        self.assertEqual(self.main(dynamic=[f"{core}:displayName,detail"])[0], 0)
        text = self.en_path().read_text(encoding="utf-8")
        self.assertIn('"Spenden"', text)
        self.assertIn('"Löst das Etikett"', text)
        self.assertIn("MARK: Dynamisch:", text)

    def test_missing_source_directory(self):
        code, _, err = run_main(["--sources", str(self.tmp / "fehlt"), "--resources", str(self.resources)])
        self.assertEqual(code, 2)
        self.assertIn("Quellverzeichnis fehlt", err)

    def test_broken_strings_file(self):
        self.en_path().parent.mkdir(parents=True)
        self.en_path().write_text('"a" = "b"', encoding="utf-8")
        code, _, err = self.main("--check")
        self.assertEqual(code, 1)
        self.assertIn("„;“ erwartet", err)


if __name__ == "__main__":
    unittest.main()
