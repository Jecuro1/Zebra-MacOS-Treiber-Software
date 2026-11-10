#!/usr/bin/env python3
"""Konformitätstest des Druckauftragsformats (unittest, nur Standardbibliothek).

Drei unabhängige Implementierungen von ARCHITECTURE.md §4.1 (Rasterung), §8 (Druckauftrag) und
§9 (Optionen) müssen für dieselben Eingaben byte-genau denselben Druckauftrag erzeugen:

1. Swift: ``LabelWerkImaging.JobEncoder`` über ``lwctl encode <bild…> --no-layout …``,
2. Python: die Referenz ``Driver/filter/tests/reference_encoder.py``,
3. C: der CUPS-Filter ``Driver/filter/build/rastertolabelwerk`` mit CUPS-Raster aus ``mkraster``,
   gleichwertigen Optionen in ``argv[5]`` und einer Test-PPD (``*lwMaxPrintWidthDots``,
   ``*lwDefaultGapDots``).

Pixelgleiche Eingaben: ``mkraster`` erzeugt die Rasterdatei (8 Bit Graustufen, ``L = v``) und legt
dieselben Zeilen zusätzlich als Rohdaten ab. Aus diesen Rohdaten entstehen die PGM- bzw.
PNG-Dateien für ``lwctl`` (8 Bit, ohne Skalierung; ``--no-layout`` übernimmt sie unverändert) und
die Luminanz für die Referenz. Jede geschriebene Bilddatei wird zurückgelesen und verglichen.

Die Matrix deckt alle Rasterverfahren, Schwellen, Z64/ACS/Hex, ZPL/EPL/CPCL, ungerade Breiten
(1…833 Punkte), hohe Seiten, Kopien und Sortierung, Negativ/Spiegeln/180°, Schwärzung,
Geschwindigkeit, Abreißposition, Rückzug (``~JS``), Versatz, Druckverfahren, Medienerkennung,
Druckmodus, Schneiden, Kalibrieren, Speichern, Start-/Endbefehle, leere Seiten, Abschneiden auf
die Druckbreite, Auflösungen und Etikettenlücken ab – dazu die Optionen der Windows-Druckeinstellungen:
Drehung 0/90/180/270°, Markenversatz, Seitenkerben, Linerless-Modi, Bei letztem Element stoppen,
Pausieren, eigene Steuerzeichen, RTC (``^ST`` mit fester Uhr, Schritt je Etikett und Zeitzone:
``lwctl --fixed-time/--time-step/--time-zone`` ↔ Filter ``LW_FIXED_TIME``/``LW_TIME_STEP_SECONDS``/``TZ``
↔ Referenz ``now``/``time_step``), ``~JA``, Etikettenbefehle und ``^MF`` – und „An Etikett anpassen“
(§8 „F“: ``lwctl --label-size/--page-size/--fit-to-label`` ↔ Filter ``lwLabelWidth``/``lwLabelHeight``/
``lwFitToLabel`` mit ``cupsPageSize`` aus ``mkraster pw=/ph=`` ↔ Referenz ``page_sizes``): A4/Letter
mit kleinem Etikett in der Ecke, Letter, leere Seite, passende Größe (byte-gleich zu ohne Anpassung),
Querformat-Inhalt auf Hochformat-Etikett, ``Off``, Drehung, Endlosmaterial und zufällige Kombinationen.
Kennt das gebaute ``lwctl`` eine der neuen Optionen noch nicht, werden genau die Fälle, die sie
brauchen, mit Hinweis übersprungen. Bei einer Abweichung nennt die Meldung die erste abweichende
Befehlszeile (Zeile, Spalte, Auszug) und – bei Grafikdaten – das erste
abweichende Pixel; die Dateien des Falls bleiben erhalten.

Programme (relativ zum Repository, überschreibbar per Umgebung):

* ``LWCTL``: ``lwctl`` (Standard: neuestes ``.build/{debug,release}/lwctl``),
* ``LW_FILTER``: ``rastertolabelwerk`` (Standard: ``Driver/filter/build/rastertolabelwerk``),
* ``LW_MKRASTER``: ``mkraster`` (Standard: ``tests/mkraster`` neben dem Filter).

Fehlen sie, werden die Tests mit Hinweis übersprungen (vorher ``swift build --product lwctl`` und
``make -C Driver/filter tests``); ``LW_REQUIRE_CONFORMANCE=1`` macht daraus einen Fehler.
``LW_KEEP_CONFORMANCE=1`` behält alle Testdateien (bei Abweichungen bleiben sie ohnehin erhalten).

Aufruf (vom Repository-Wurzelverzeichnis)::

    python3 Scripts/tests/test_encoder_conformance.py
    python3 -m unittest discover -s Scripts/tests -t Scripts/tests -k conformance
"""

from __future__ import annotations

import json
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import zlib
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

SCRIPTS = Path(__file__).resolve().parent.parent
REPO_ROOT = SCRIPTS.parent
FILTER_DIR = REPO_ROOT / "Driver" / "filter"
FILTER_TESTS = FILTER_DIR / "tests"
BASE_PPD = FILTER_TESTS / "ppd" / "lwtest.ppd"

try:
    sys.path.insert(0, str(FILTER_TESTS))
    import reference_encoder as ref  # noqa: E402
    REF_ERROR: Optional[str] = None
except ImportError as error:  # pragma: no cover – nur bei unvollständigem Checkout
    ref = None  # type: ignore[assignment]
    REF_ERROR = "Referenz-Encoder fehlt (%s): %s" % (FILTER_TESTS / "reference_encoder.py", error)
finally:
    if sys.path and sys.path[0] == str(FILTER_TESTS):
        sys.path.pop(0)

LANGS = ("ZPL", "EPL", "CPCL")
COMPRESSIONS = ("Z64", "ACS", "Hex")
DITHERS = ("Threshold", "Ordered", "Halftone", "FloydSteinberg", "Atkinson", "Stucki")
PRINT_MODES = ("TearOff", "PeelOff", "Cutter", "DelayedCut", "Rewind", "Applicator", "Kiosk")
LINERLESS_MODES = ("LinerlessPeel", "LinerlessCut", "LinerlessDelayedCut", "LinerlessRewind", "LinerlessTear")
TRACKINGS = ("Gap", "BlackMark", "Continuous", "Auto", "Notch")
RTC_MODES = ("JobStart", "EveryLabel", "EveryMinute")
MEDIA_ACTIONS = ("Feed", "Calibrate", "Length", "NoMotion", "ShortCal")
#: Feste Uhr der RTC-Fälle: 14.11.2023 22:13:20 UTC; Sommerzeit-Fall: 2.7.2024 10:00 UTC.
FIXED_TIME = 1700000000
SUMMER_TIME = 1719914400
MEDIA_TYPES = ("DirectThermal", "ThermalTransfer")
BACKFEEDS = ("After", "Before", "Normal", "Off")
DEFAULT_STOCK = "w4h6in"           # Standard von lwctl ohne --model/--stock
TIMEOUT = 300

SWIFT = "Swift (lwctl)"
C_FILTER = "C (rastertolabelwerk)"
PYTHON = "Python (Referenz)"


# --------------------------------------------------------------------------------------------
# Eingaben
# --------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Page:
    """Eine Seite als mkraster-Muster (8 Bit Graustufen); optional mit Seitengröße in Punkten
    (``cupsPageSize``, sonst ``w · 72 / dpi`` ganzzahlig wie bisher) und Inhaltsrechteck."""

    width: int
    height: int
    pattern: str
    seed: int = 0
    points: Optional[Tuple[float, float]] = None          # mkraster pw=/ph=
    box: Optional[Tuple[int, int, int, int]] = None       # mkraster bx/by/bw/bh

    def spec(self, dpi: int) -> str:
        text = "w=%d,h=%d,pattern=%s,seed=%d,res=%d,cs=SW,bpc=8" % (
            self.width, self.height, self.pattern, self.seed, dpi)
        if self.points is not None:
            text += ",pw=%r,ph=%r" % self.points
        if self.box is not None:
            text += ",bx=%d,by=%d,bw=%d,bh=%d" % self.box
        return text

    @property
    def key(self) -> str:
        key = "%s%d-%dx%d" % (self.pattern, self.seed, self.width, self.height)
        if self.box is not None:
            key += "-box%d_%d_%d_%d" % self.box
        return key


def sized(points: Tuple[float, float], dpi: int, pattern: str, seed: int = 0,
          box: Optional[Tuple[int, int, int, int]] = None) -> Page:
    """Seite mit Seitengröße in Punkten und passender Rastergröße bei ``dpi`` (wie cgpdftoraster)."""
    return Page(int(points[0] * dpi / 72.0 + 0.5), int(points[1] * dpi / 72.0 + 0.5), pattern, seed, points, box)


#: Seitengrößen in Punkten (Programme schicken sie statt der Etikettengröße).
A4 = (595.2756, 841.8898)
LETTER = (612.0, 792.0)
A5 = (419.5276, 595.2756)
A6 = (297.6378, 419.5276)
#: Etikett 104 × 76,2 mm (ZD421 wie mit ZDesigner) als Seite: w295h216.
LABEL_PAGE = (295.0, 216.0)


P_GRAD = Page(203, 96, "gradient")
P_TEXT = Page(203, 96, "text", 3)
P_NOISE = Page(150, 64, "noise", 7)
P_ODD = Page(13, 7, "noise", 2)
P_SMALL = Page(37, 11, "text", 5)
P_BLANK = Page(96, 40, "blank")
P_BLACK = Page(40, 20, "black")
P_WIDE = Page(900, 48, "hgrad")
P_TALL = Page(40, 3000, "text", 11)
P_TALL_GRAD = Page(9, 4000, "vgrad")


@dataclass
class Case:
    name: str
    pages: Tuple[Page, ...]
    settings: Dict[str, object]             # Felder von reference_encoder.Settings
    copies: int = 1
    collate: bool = True
    dpi: int = 203
    max_width: Optional[int] = None          # *lwMaxPrintWidthDots bzw. --max-width
    stock: Optional[str] = None              # --stock (EPL-Lücke); None = Standard von lwctl
    formats: Tuple[str, ...] = ()            # Bildformat je Seite für lwctl; leer = abwechselnd
    fixed_time: Optional[int] = None         # Uhr für ^ST (lwRTC): --fixed-time / LW_FIXED_TIME / now
    time_step: int = 0                       # Sekunden je Etikett (--time-step / LW_TIME_STEP_SECONDS)
    time_zone: str = "UTC"                   # --time-zone / TZ
    same_as_unfitted: bool = False           # §8 „F“ darf hier nichts ändern (passende Größe, Off)

    def image_format(self, index: int) -> str:
        if self.formats:
            return self.formats[index % len(self.formats)]
        return ("pgm", "png")[(index + len(self.name)) % 2]


def build_cases() -> List[Case]:
    cases: List[Case] = []

    def add(name: str, pages: Sequence[Page], copies: int = 1, collate: bool = True, dpi: int = 203,
            max_width: Optional[int] = None, stock: Optional[str] = None, formats: Tuple[str, ...] = (),
            fixed_time: Optional[int] = None, time_step: int = 0, time_zone: str = "UTC",
            same_as_unfitted: bool = False, **settings) -> None:
        if settings.get("rtc") and fixed_time is None:
            fixed_time = FIXED_TIME            # ^ST nur mit fester Uhr reproduzierbar
        cases.append(Case(name, tuple(pages), dict(settings), copies, collate, dpi, max_width, stock, formats,
                          fixed_time, time_step, time_zone, same_as_unfitted))

    # 1. Sprache × Kompression × Rasterverfahren
    for lang in LANGS:
        for comp in (COMPRESSIONS if lang == "ZPL" else ("Z64",)):
            for dither in DITHERS:
                add("sprache_%s_%s_%s" % (lang, comp, dither), [P_GRAD, P_TEXT, P_ODD],
                    language=lang, compression=comp, dither=dither)

    # 2. Schwellen je Rasterverfahren (auch Verschiebung der Matrizen)
    for i, dither in enumerate(DITHERS):
        for j, threshold in enumerate((1, 2, 64, 127, 128, 129, 200, 253, 254)):
            add("schwelle_%s_%d" % (dither, threshold), [P_GRAD, P_NOISE],
                language=LANGS[(i + j) % 3], compression=COMPRESSIONS[j % 3], dither=dither, threshold=threshold)

    # 3. Ungerade Breiten 1…833 (Füllbits, ACS-Zeilenenden, EPL/CPCL-Bytes je Zeile)
    widths = (1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 33, 63, 64, 65, 127, 129, 203, 255, 401, 511, 777, 831, 832, 833)
    for i, width in enumerate(widths):
        page = Page(width, 3 + width % 7, ("noise", "text", "gradient", "checker")[i % 4], width)
        add("breite_%d" % width, [page, Page(width, 5, "hgrad")], language=LANGS[i % 3],
            compression=COMPRESSIONS[(i // 3) % 3], dither=DITHERS[i % 6], negative=(i % 5 == 4),
            mirror=(i % 4 == 1), rotate180=(i % 4 == 2))
    for i, width in enumerate((833, 845, 1000)):
        add("breite_abgeschnitten_%d" % width, [Page(width, 9, "noise", width)], max_width=832 + i * 5,
            language=LANGS[i], compression="Hex", dither=DITHERS[3 + i])

    # 4. Hohe Seiten
    add("hoch_ZPL_Z64_Atkinson", [P_TALL], language="ZPL", compression="Z64", dither="Atkinson")
    add("hoch_ZPL_ACS_Ordered", [P_TALL_GRAD], language="ZPL", compression="ACS", dither="Ordered")
    add("hoch_EPL_FloydSteinberg_Spiegeln", [P_TALL], language="EPL", dither="FloydSteinberg", mirror=True)
    add("hoch_CPCL_Stucki_180", [P_TALL, P_TALL_GRAD], language="CPCL", dither="Stucki", rotate180=True)
    # länger als ^LL erlaubt (32000): der C-Filter warnt nur, kodiert wird unverändert
    add("hoch_ZPL_ueber_32000", [Page(9, 32001, "vgrad")], language="ZPL", compression="Hex", dither="Ordered")

    # 5. Bildoperationen (Reihenfolge: abschneiden, negativ, leer, spiegeln, drehen)
    for lang in LANGS:
        for flags in range(8):
            negative, mirror, rotate = bool(flags & 1), bool(flags & 2), bool(flags & 4)
            label = "".join(c for c, on in (("N", negative), ("M", mirror), ("R", rotate)) if on) or "keine"
            add("bild_%s_%s" % (lang, label), [P_TEXT, P_ODD], language=lang, compression="ACS",
                dither=DITHERS[flags % 6], negative=negative, mirror=mirror, rotate180=rotate)
        add("bild_%s_abgeschnitten_NMR" % lang, [P_WIDE, P_ODD], max_width=832, language=lang,
            compression="Z64", dither="Halftone", negative=True, mirror=True, rotate180=True)

    # 6. Kopien und Sortierung
    three = [P_TEXT, P_GRAD, P_ODD]
    for lang in LANGS:
        for copies in (1, 2, 3):
            for collate in (True, False):
                add("kopien_%s_%d_%s" % (lang, copies, "sortiert" if collate else "einzeln"), three,
                    copies=copies, collate=collate, language=lang, compression="Hex")
        add("kopien_%s_eine_seite_4" % lang, [P_SMALL], copies=4, language=lang)
        add("kopien_%s_eine_seite_einzeln_4" % lang, [P_SMALL], copies=4, collate=False, language=lang)
    add("kopien_ZPL_99999", [P_SMALL], copies=99999, language="ZPL")
    add("kopien_ZPL_sortiert_schneiden_speichern", three, copies=3, language="ZPL", cut_every=2, save_settings=True)

    # 7. Leere Seiten
    for lang in LANGS:
        add("leer_ueberspringen_%s" % lang, [P_TEXT, P_BLANK, P_GRAD], copies=2, language=lang, skip_blank=True)
        add("leer_behalten_%s" % lang, [P_TEXT, P_BLANK], copies=2, language=lang, skip_blank=False)
        add("leer_alle_%s" % lang, [P_BLANK, P_BLANK], copies=3, language=lang, skip_blank=True, darkness=10,
            start_commands=b"~JR", end_commands=b"^XA^XZ")
        add("leer_negativ_schwarz_%s" % lang, [P_BLACK, P_TEXT], copies=2, language=lang, skip_blank=True,
            negative=True)
        add("leer_eine_uebrig_%s" % lang, [P_BLANK, P_SMALL, P_BLANK], copies=3, language=lang, skip_blank=True)

    # 8. Abschneiden auf die Druckbreite (gerastert wird über die volle Breite)
    for lang in LANGS:
        for dither in ("Threshold", "FloydSteinberg", "Stucki"):
            add("abschneiden_%s_%s" % (lang, dither), [P_WIDE, P_GRAD], max_width=832, language=lang,
                dither=dither, mirror=True, compression="ACS")
    add("abschneiden_ungerade_837", [Page(845, 10, "noise")], max_width=837, compression="Hex")
    add("abschneiden_auf_1", [P_TEXT], max_width=1, language="ZPL", compression="Hex")

    # 9. Auftrags- und Etiketteneinstellungen
    everything = dict(darkness=17, speed=9, tear_off=-10, backfeed="After", label_top=37, label_left=-15,
                      media_type="ThermalTransfer", tracking="BlackMark", print_mode="Cutter", cut_every=3,
                      calibrate=True, save_settings=True, start_commands=b"~JR\n^XA^PON^XZ",
                      end_commands=b"^XA^IDR:*.GRF^FS^XZ")
    for lang in LANGS:
        add("einstellungen_alle_%s" % lang, [P_TEXT, P_SMALL], copies=2, language=lang, compression="Hex",
            **everything)
        add("einstellungen_alle_%s_einzeln" % lang, [P_TEXT, P_SMALL], copies=2, collate=False, language=lang,
            **dict(everything, media_type="DirectThermal", print_mode="PeelOff", tracking="Continuous"))
    for lang in LANGS:
        for darkness in (0, 1, 2, 3, 8, 14, 15, 16, 29, 30):
            add("schwaerzung_%s_%d" % (lang, darkness), [P_ODD], language=lang, darkness=darkness)
        for speed in (1, 2, 5, 6, 7, 14):
            add("geschwindigkeit_%s_%d" % (lang, speed), [P_ODD], language=lang, speed=speed)
    for tear_off in (-120, -100, -10, -9, -5, -1, 0, 5, 10, 99, 100, 120):
        add("abreissen_ZPL_%s" % str(tear_off).replace("-", "m"), [P_ODD], language="ZPL", tear_off=tear_off)
    for lang in ("EPL", "CPCL"):
        add("abreissen_%s_ignoriert" % lang, [P_ODD], language=lang, tear_off=-10)
    for backfeed in BACKFEEDS:
        add("rueckzug_ZPL_%s" % backfeed, [P_ODD], language="ZPL", backfeed=backfeed)
        add("rueckzug_ZPL_%s_mit_kopf" % backfeed, [P_ODD], language="ZPL", backfeed=backfeed, darkness=5,
            tear_off=15, calibrate=True, start_commands=b"^XA^MNY^XZ")
    for lang in ("EPL", "CPCL"):
        add("rueckzug_%s_ignoriert" % lang, [P_ODD], language=lang, backfeed="Before")
    for top in (-120, -1, 0, 37, 120):
        add("versatz_oben_%s" % str(top).replace("-", "m"), [P_ODD], language="ZPL", label_top=top)
    for left in (-9999, -200, 0, 15, 9999):
        add("versatz_links_%s" % str(left).replace("-", "m"), [P_ODD], language="ZPL", label_left=left)
    add("versatz_EPL_CPCL_ignoriert_EPL", [P_ODD], language="EPL", label_top=20, label_left=-30)
    add("versatz_EPL_CPCL_ignoriert_CPCL", [P_ODD], language="CPCL", label_top=20, label_left=-30)
    for lang in ("ZPL", "EPL"):
        for media in (None,) + MEDIA_TYPES:
            for mode in (None,) + PRINT_MODES:
                if lang == "ZPL" and media is not None and mode not in (None, "Kiosk"):
                    continue
                add("medien_%s_%s_%s" % (lang, media or "ohne", mode or "ohne"), [P_ODD], language=lang,
                    media_type=media, print_mode=mode)
    add("medien_CPCL_ignoriert", [P_ODD], language="CPCL", media_type="DirectThermal", print_mode="Cutter")
    for lang in LANGS:
        for tracking in TRACKINGS:
            add("erkennung_%s_%s" % (lang, tracking), [P_SMALL, P_ODD], language=lang, tracking=tracking)
    for cut in (1, 5, 9999):
        for collate in (True, False):
            add("schneiden_ZPL_%d_%s" % (cut, "sortiert" if collate else "einzeln"), [P_SMALL, P_ODD], copies=3,
                collate=collate, language="ZPL", cut_every=cut)
    for lang in ("EPL", "CPCL"):
        add("schneiden_%s_ignoriert" % lang, [P_SMALL, P_ODD], copies=2, language=lang, cut_every=2)
    add("kalibrieren_ZPL", [P_SMALL, P_ODD], copies=2, language="ZPL", calibrate=True)
    add("speichern_ZPL", [P_SMALL, P_ODD], copies=2, language="ZPL", save_settings=True)
    add("speichern_ZPL_einzeln", [P_SMALL, P_ODD], copies=2, collate=False, language="ZPL", save_settings=True)
    add("kalibrieren_speichern_EPL_CPCL_ignoriert", [P_ODD], language="EPL", calibrate=True, save_settings=True)
    commands = (
        ("einfach", b"~JR", b"~JA"),
        ("mehrzeilig", b"^XA\n^MMT\n^XZ", b"^XA\r\n^JUS\r\n^XZ"),
        ("sonderzeichen", "^FH\\^FDGrüße – 50 % ≥ 3 · \"x\" 'y' {z} & <a>".encode("utf-8"), b"a=b c,d;e#f$g\tTab"),
        ("nur_start", b"^XA^LRN^XZ", b""),
        ("nur_ende", b"", b"~PS"),
    )
    for lang in LANGS:
        for label, start, end in commands:
            add("befehle_%s_%s" % (lang, label), [P_SMALL], copies=2, language=lang,
                start_commands=start, end_commands=end)

    # 10. Auflösungen (CPCL-Kopf, EPL-Lücke) und Etikettenformate (EPL-Lücke)
    for dpi in (152, 300, 600):
        for lang in LANGS:
            add("aufloesung_%d_%s" % (dpi, lang), [P_SMALL, P_ODD], dpi=dpi, language=lang, darkness=12, speed=3,
                tracking="BlackMark" if lang == "EPL" else None)
    for stock in ("wb1x11in", "c80", "w2h1in"):
        for tracking in (None, "BlackMark", "Continuous"):
            add("etikett_EPL_%s_%s" % (stock, tracking or "ohne"), [P_ODD], stock=stock, language="EPL",
                tracking=tracking)
        add("etikett_EPL_%s_300dpi" % stock, [P_ODD], stock=stock, dpi=300, language="EPL")

    # 11. Muster für ACS (Wiederholungszeilen ':', lange Läufe > 419 Nibbles, Zeilenenden ',' und '!')
    for i, pattern in enumerate(("checker", "dots", "bars", "vgrad", "hgrad", "blank", "black")):
        for negative in (False, True):
            add("muster_%s%s" % (pattern, "_negativ" if negative else ""), [Page(130 + i, 50, pattern, i)],
                language="ZPL", compression="ACS", dither=DITHERS[i % 6], negative=negative)
    add("acs_lange_laeufe", [Page(3400, 6, "hgrad"), Page(3400, 4, "bars")], language="ZPL", compression="ACS")
    add("acs_lange_laeufe_negativ", [Page(3400, 6, "hgrad")], language="ZPL", compression="ACS", negative=True)

    # 12. Bildformate: nur PGM bzw. nur PNG
    for fmt in ("pgm", "png"):
        add("format_%s" % fmt, [P_TEXT, P_NOISE, P_ODD], formats=(fmt,), language="ZPL", compression="Hex",
            dither="Stucki")

    # 13. Zufällige (fest gesäte) Kombinationen aller Einstellungen – Wechselwirkungen
    rng = random.Random(20261110)
    patterns = ("gradient", "hgrad", "vgrad", "text", "checker", "noise", "blank", "black", "bars", "dots")
    raw_commands = (b"", b"~JR", b"^XA^MMT^XZ", "^FDÄÖÜ ß €".encode("utf-8"), b"line1\nline2")

    def maybe(values, chance=0.5):
        return rng.choice(values) if rng.random() < chance else None

    for index in range(100):
        pages = [Page(rng.choice((rng.randint(1, 64), rng.randint(1, 833))), rng.randint(1, 160),
                      rng.choice(patterns), rng.randint(0, 999)) for _ in range(rng.choice((1, 1, 2, 3, 4)))]
        add("zufall_%03d" % index, pages, copies=rng.choice((1, 1, 2, 3, 7)), collate=rng.random() < 0.6,
            dpi=rng.choice((152, 203, 203, 300, 600)), max_width=maybe(range(1, 900), 0.3),
            stock=maybe(("w4h6in", "w2h1in", "wb1x11in", "c80"), 0.3),
            language=rng.choice(LANGS), compression=rng.choice(COMPRESSIONS), dither=rng.choice(DITHERS),
            threshold=rng.choice((128, rng.randint(1, 254))), darkness=maybe(range(0, 31)),
            speed=maybe(range(1, 15)), media_type=maybe(MEDIA_TYPES), tracking=maybe(TRACKINGS),
            print_mode=maybe(PRINT_MODES), label_top=maybe(range(-120, 121)), label_left=maybe(range(-9999, 10000)),
            tear_off=maybe(range(-120, 121)), backfeed=maybe(BACKFEEDS), mirror=rng.random() < 0.3,
            negative=rng.random() < 0.3, rotate180=rng.random() < 0.3,
            cut_every=rng.choice((0, 0, 0, rng.randint(1, 9999))), calibrate=rng.random() < 0.2,
            save_settings=rng.random() < 0.2, skip_blank=rng.random() < 0.4,
            start_commands=rng.choice(raw_commands), end_commands=rng.choice(raw_commands))

    windows_cases(add)
    fit_cases(add)

    names = [case.name for case in cases]
    assert len(names) == len(set(names)), "doppelte Fallnamen"
    return cases


def windows_cases(add) -> None:
    """14. Optionen der Windows-Druckeinstellungen (ZDesigner „Druckeinstellungen für ZD421 …“)."""
    p_tall_noise = Page(60, 900, "noise", 4)
    p_top = Page(96, 120, "dots", 9)

    # Drehung: 90/270 in Software vor dem Abschneiden, 180 wie bisher (auch als lwRotate180-Ersatz)
    for lang in LANGS:
        for rotation in (90, 180, 270):
            add("drehung_%s_%d" % (lang, rotation), [P_TEXT, P_ODD], language=lang, compression="ACS",
                dither=DITHERS[rotation // 90], rotation=rotation)
        add("drehung_%s_90_mit_alt_180" % lang, [P_SMALL], language=lang, rotation=90, rotate180=True)
        add("drehung_%s_270_abschneiden_NM" % lang, [p_tall_noise, P_SMALL], max_width=832, language=lang,
            rotation=270, mirror=True, negative=True, dither="FloydSteinberg")
    add("drehung_ZPL_90_kopien_sortiert", [P_TEXT, P_ODD, P_GRAD], copies=2, rotation=90, compression="Hex")

    # Medientyp: Seitenkerben, Markierung Versatz
    for lang in LANGS:
        add("kerben_%s" % lang, [P_SMALL, P_ODD], language=lang, tracking="Notch")
    for offset in (-80, -1, 0, 37, 283):
        add("markenversatz_%s" % str(offset).replace("-", "m"), [P_ODD], tracking="BlackMark", mark_offset=offset)
    add("markenversatz_nur_schwarze_marke", [P_ODD], tracking="Gap", mark_offset=40)
    add("markenversatz_EPL_ignoriert", [P_ODD], language="EPL", tracking="BlackMark", mark_offset=40)

    # Linerless-Modi: SGD media.printmode im Kopf, kein ^MM
    for mode in LINERLESS_MODES:
        for lang in LANGS:
            add("linerless_%s_%s" % (lang, mode), [P_SMALL, P_ODD], copies=2, language=lang, print_mode=mode,
                media_type="DirectThermal")

    # Bei letztem Element stoppen (nur Endlosmaterial; alle Sprachen)
    for lang in LANGS:
        for offset in (0, 24, 5000):
            add("stoppen_%s_%d" % (lang, offset), [P_TEXT, P_GRAD, p_top], language=lang, tracking="Continuous",
                stop_at_last=True, stop_offset=offset)
    add("stoppen_leer_ueberspringen", [P_BLANK, P_TEXT], tracking="Continuous", stop_at_last=True,
        skip_blank=True)
    add("stoppen_leer_eine_zeile", [P_BLANK], tracking="Continuous", stop_at_last=True, compression="Hex")
    add("stoppen_nur_endlos", [P_TEXT], tracking="Gap", stop_at_last=True, stop_offset=16)
    add("stoppen_negativ_gedreht", [p_tall_noise], tracking="Continuous", stop_at_last=True, stop_offset=8,
        negative=True, rotation=90, max_width=832)

    # Pausieren (Vorrang vor Schneiden)
    for pause in (1, 5, 9999):
        for collate in (True, False):
            add("pause_%d_%s" % (pause, "sortiert" if collate else "einzeln"), [P_SMALL, P_ODD], copies=3,
                collate=collate, pause_every=pause)
    add("pause_vor_schneiden", [P_ODD], copies=8, pause_every=4, cut_every=2)
    add("pause_EPL_CPCL_ignoriert_EPL", [P_ODD], copies=2, language="EPL", pause_every=3)

    # Eigene Steuerzeichen („Intern“)
    everything = dict(darkness=12, tear_off=-10, backfeed="After", calibrate=True, cancel_before=True,
                      power_up_action="Feed", head_close_action="Length", rtc="EveryLabel", tracking="BlackMark",
                      mark_offset=-20, speed=5, label_top=8, label_left=-4, pause_every=2, save_settings=True,
                      start_commands=b"^XA^FX,~^XZ", label_start_commands=b"^FO1,1^FD~,^FS",
                      label_end_commands=b"^FX,", end_commands=b"~JR")
    for label, chars in (("raute", (35, 64, 59)), ("vertauscht", (126, 94, 44)), ("nur_trenner", (94, 126, 124))):
        for comp in COMPRESSIONS:
            add("steuerzeichen_%s_%s" % (label, comp), [P_TEXT, P_ODD], copies=2, compression=comp,
                control_chars=chars, **everything)
    add("steuerzeichen_EPL_ignoriert", [P_ODD], language="EPL", control_chars=(35, 64, 59), cancel_before=True)

    # Echtzeituhr (^ST): feste Uhr, Schritt je Etikett, Zeitzone
    for mode in RTC_MODES:
        for step in (0, 25, 61):
            add("rtc_%s_%d" % (mode, step), [P_ODD, P_SMALL, P_TEXT], copies=3, rtc=mode, time_step=step)
        add("rtc_%s_einzeln" % mode, [P_ODD, P_SMALL], copies=4, collate=False, rtc=mode, time_step=30)
    add("rtc_sommerzeit_berlin", [P_ODD], copies=2, rtc="EveryLabel", fixed_time=SUMMER_TIME, time_step=3600,
        time_zone="Europe/Berlin")
    add("rtc_ohne_etiketten", [P_BLANK], rtc="JobStart", skip_blank=True)
    for lang in ("EPL", "CPCL"):
        add("rtc_%s_ignoriert" % lang, [P_ODD], copies=2, language=lang, rtc="EveryLabel", time_step=60)

    # Aufträge vor dem Drucken abbrechen (~JA; Wartezeit nur beim Drucken)
    for lang in LANGS:
        add("abbrechen_%s" % lang, [P_ODD], language=lang, cancel_before=True, cancel_delay=250,
            start_commands=b"~JR", end_commands=b"END")

    # Etikettenbefehle
    for lang in LANGS:
        for collate in (True, False):
            add("etikettenbefehle_%s_%s" % (lang, "sortiert" if collate else "einzeln"), [P_SMALL, P_ODD], copies=2,
                collate=collate, language=lang, label_start_commands="^FO10,10^A0N,20,20^FDÄnfang €^FS".encode("utf-8"),
                label_end_commands=b"^FX Ende\nzweite Zeile")

    # ^MF nur mit beiden Aktionen
    for power, head in (("Feed", "Calibrate"), ("Length", "NoMotion"), ("ShortCal", None), (None, "Feed")):
        add("medienaktion_%s_%s" % (power or "ohne", head or "ohne"), [P_ODD], power_up_action=power,
            head_close_action=head)
    add("medienaktion_EPL_ignoriert", [P_ODD], language="EPL", power_up_action="Feed", head_close_action="Feed")

    # Alles zusammen
    for lang in LANGS:
        add("windows_alle_%s" % lang, [P_TEXT, p_top, P_ODD], copies=2, language=lang, compression="ACS",
            time_step=40, **dict(everything, rotation=90, tracking="Continuous", stop_at_last=True, stop_offset=12,
                                 print_mode="LinerlessRewind", control_chars=(36, 126, 44), rtc="EveryMinute"))

    # Zufällige Kombinationen der neuen Optionen (eigener Zufallsgenerator – Abschnitt 13 bleibt gleich)
    rng = random.Random(20261111)

    def maybe(values, chance=0.5):
        return rng.choice(values) if rng.random() < chance else None

    patterns = ("gradient", "hgrad", "vgrad", "text", "checker", "noise", "blank", "black", "bars", "dots")
    for index in range(40):
        pages = [Page(rng.randint(1, 300), rng.randint(1, 200), rng.choice(patterns), rng.randint(0, 999))
                 for _ in range(rng.choice((1, 2, 3)))]
        chars = maybe(((35, 64, 59), (126, 94, 44), (36, 126, 124)), 0.3)
        add("zufall_windows_%03d" % index, pages, copies=rng.choice((1, 2, 3)), collate=rng.random() < 0.6,
            dpi=rng.choice((203, 300)), max_width=maybe(range(1, 400), 0.3), time_step=rng.choice((0, 20, 70)),
            language=rng.choice(LANGS), compression=rng.choice(COMPRESSIONS), dither=rng.choice(DITHERS),
            rotation=rng.choice((0, 0, 90, 180, 270)), rotate180=rng.random() < 0.2,
            tracking=maybe(TRACKINGS, 0.7), mark_offset=maybe(range(-80, 284)), stop_at_last=rng.random() < 0.5,
            stop_offset=rng.choice((0, 0, rng.randint(0, 200))), pause_every=rng.choice((0, 0, rng.randint(1, 9))),
            cut_every=rng.choice((0, rng.randint(1, 9))), control_chars=chars, rtc=maybe(RTC_MODES),
            cancel_before=rng.random() < 0.3, print_mode=maybe(PRINT_MODES + LINERLESS_MODES),
            power_up_action=maybe(MEDIA_ACTIONS), head_close_action=maybe(MEDIA_ACTIONS),
            label_start_commands=rng.choice((b"", b"^FX start", b"A10,10,0,1,1,1,N,\"x\"")),
            label_end_commands=rng.choice((b"", b"^FX ende,~")), negative=rng.random() < 0.3,
            mirror=rng.random() < 0.3, skip_blank=rng.random() < 0.3, darkness=maybe(range(0, 31)))


def fit_cases(add) -> None:
    """15. An Etikett anpassen (§8 „F“): Seitengröße ≠ Etikett der Warteschlange."""
    label = dict(label_width=10400, label_height=7620)                  # 104 × 76,2 mm (ZD421)
    corner = (40, 50, 600, 420)                                         # Etikett-PDF bei 100 % oben links
    for lang in LANGS:
        add("anpassen_a4_ecke_%s" % lang, [sized(A4, 203, "text", 4, corner)], max_width=832, language=lang,
            compression="ACS" if lang == "ZPL" else "Z64", **label)
    add("anpassen_letter_ecke", [sized(LETTER, 203, "dots", 3, (10, 10, 500, 300))], max_width=832,
        dither="Ordered", **label)
    add("anpassen_a4_voll_verkleinert", [sized(A4, 203, "gradient")], max_width=832, dither="FloydSteinberg",
        compression="Hex", **label)
    add("anpassen_quer_inhalt_hochformat_etikett", [sized(A4, 203, "text", 9, (20, 400, 1600, 600))],
        max_width=832, dither="Atkinson", **label)
    add("anpassen_hoch_inhalt_querformat_etikett", [sized(LETTER, 203, "bars", 1, (100, 50, 400, 1500))],
        max_width=832, **label)
    add("anpassen_a4_leer", [sized(A4, 203, "blank")], max_width=832, compression="Hex", **label)
    add("anpassen_a4_leer_ueberspringen", [sized(A4, 203, "blank"), sized(A6, 203, "text", 2, (5, 5, 300, 200))],
        copies=2, max_width=832, skip_blank=True, **label)
    add("anpassen_passende_groesse", [sized(LABEL_PAGE, 203, "text", 6)], max_width=832, same_as_unfitted=True,
        **label)
    add("anpassen_fast_passend_2mm", [sized((300.0, 220.0), 203, "noise", 5)], max_width=832,
        same_as_unfitted=True, **label)
    add("anpassen_aus", [sized(A4, 203, "text", 4, corner)], max_width=832, fit_to_label="Off",
        same_as_unfitted=True, **label)
    add("anpassen_ohne_etikett", [sized(A4, 203, "text", 4, corner)], max_width=832, same_as_unfitted=True)
    add("anpassen_gemischt_sortiert", [sized(LABEL_PAGE, 203, "text", 7), sized(A4, 203, "text", 4, corner),
                                       sized(LETTER, 203, "checker", 0, (300, 200, 900, 900))],
        copies=2, max_width=832, compression="Z64", **label)
    for rotation in (90, 270):
        add("anpassen_drehung_%d" % rotation, [sized(A4, 203, "text", 4, corner)], max_width=832,
            rotation=rotation, **label)
    add("anpassen_drehung_90_passend", [sized((LABEL_PAGE[1], LABEL_PAGE[0]), 203, "text", 8)], max_width=832,
        rotation=90, same_as_unfitted=True, **label)
    add("anpassen_endlos_nur_breite", [sized(A4, 203, "bars", 2, (30, 100, 1500, 900))], max_width=640,
        tracking="Continuous", stop_at_last=True, label_width=8000, label_height=15000)
    add("anpassen_hoehe_frei", [sized(A5, 203, "text", 3, (10, 20, 1100, 300))], max_width=832,
        label_width=5000, label_height=0)
    for lang in ("EPL", "CPCL"):
        add("anpassen_300dpi_%s" % lang, [sized(LETTER, 300, "checker", 0, (100, 80, 900, 500))], dpi=300,
            max_width=1248, language=lang, **label)
    add("anpassen_152dpi_negativ_spiegeln", [sized(A6, 152, "text", 1, (5, 5, 400, 500))], dpi=152,
        negative=True, mirror=True, label_width=5000, label_height=3000)

    # Zufällige Kombinationen (eigener Zufallsgenerator – die übrigen Abschnitte bleiben gleich)
    rng = random.Random(20261112)
    page_sizes = (A4, LETTER, A5, A6, LABEL_PAGE, (288.0, 432.0), (162.0, 90.0), (300.0, 219.0))
    labels = ((10400, 7620), (10160, 15240), (5700, 3200), (5000, 0), (8000, 20000), (2540, 1270))
    patterns = ("gradient", "text", "checker", "noise", "bars", "dots", "blank", "black", "vgrad")
    for index in range(24):
        dpi = rng.choice((152, 203, 203))
        pages = []
        for _ in range(rng.choice((1, 1, 2))):
            points = rng.choice(page_sizes)
            page = sized(points, dpi, rng.choice(patterns), rng.randint(0, 99))
            if rng.random() < 0.6 and page.width > 4 and page.height > 4:
                bw, bh = rng.randint(1, page.width - 2), rng.randint(1, page.height - 2)
                page = sized(points, dpi, page.pattern, page.seed,
                             (rng.randint(0, page.width - bw), rng.randint(0, page.height - bh), bw, bh))
            pages.append(page)
        width, height = rng.choice(labels)
        add("anpassen_zufall_%02d" % index, pages, copies=rng.choice((1, 2)), collate=rng.random() < 0.5, dpi=dpi,
            max_width=rng.choice((None, 832, 640)), language=rng.choice(LANGS), compression=rng.choice(COMPRESSIONS),
            dither=rng.choice(DITHERS), rotation=rng.choice((0, 0, 90, 180, 270)),
            tracking=rng.choice((None, None, "Gap", "Continuous")), negative=rng.random() < 0.2,
            skip_blank=rng.random() < 0.3, fit_to_label=rng.choice(("Auto", "Auto", "Auto", "Off")),
            label_width=width, label_height=height)


CASES = build_cases()


# --------------------------------------------------------------------------------------------
# Bilddateien (unabhängig von LabelWerkImaging geschrieben und zurückgelesen)
# --------------------------------------------------------------------------------------------

def write_pgm(path: Path, width: int, height: int, lum: bytes) -> None:
    path.write_bytes(b"P5\n%d %d\n255\n" % (width, height) + lum)


def read_pgm(data: bytes) -> Tuple[int, int, bytes]:
    match = re.match(rb"P5\s+(\d+)\s+(\d+)\s+255\s", data)
    assert match, "kein PGM (P5, 8 Bit)"
    width, height = int(match[1]), int(match[2])
    return width, height, data[match.end():match.end() + width * height]


def _png_chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


def write_png(path: Path, width: int, height: int, lum: bytes) -> None:
    """8-Bit-Graustufen-PNG (Farbtyp 0, Filter 0 je Zeile, ohne gAMA/tRNS)."""
    raw = b"".join(b"\x00" + lum[y * width:(y + 1) * width] for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n"
                     + _png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
                     + _png_chunk(b"IDAT", zlib.compress(raw, 9))
                     + _png_chunk(b"IEND", b""))


def read_png(data: bytes) -> Tuple[int, int, bytes]:
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "kein PNG"
    pos, width, height, idat = 8, 0, 0, b""
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        payload = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color = struct.unpack(">IIBB", payload[:10])
            assert depth == 8 and color == 0, "nur 8-Bit-Graustufen"
        elif kind == b"IDAT":
            idat += payload
        pos += 12 + length
    raw = zlib.decompress(idat)
    rows = [raw[y * (width + 1):(y + 1) * (width + 1)] for y in range(height)]
    assert all(row[0] == 0 for row in rows), "nur Filter 0"
    return width, height, b"".join(row[1:] for row in rows)


# --------------------------------------------------------------------------------------------
# Programme
# --------------------------------------------------------------------------------------------

@dataclass
class Tools:
    lwctl: Path
    filter: Path
    mkraster: Path
    stock_gaps_mm: Dict[str, float] = field(default_factory=dict)
    help_text: str = ""

    def missing_flags(self, flags: Sequence[str]) -> List[str]:
        return [flag for flag in flags if flag not in self.help_text]


def _executable(path: Path) -> bool:
    return path.is_file() and os.access(path, os.X_OK)


def _from_env(name: str) -> Optional[Path]:
    value = os.environ.get(name, "").strip()
    if not value:
        return None
    if os.sep not in value:
        found = shutil.which(value)
        if found:
            return Path(found)
    return Path(value).expanduser().resolve()


def _unavailable(message: str) -> Exception:
    """Fehlendes Werkzeug: Test überspringen – mit ``LW_REQUIRE_CONFORMANCE=1`` ein Fehler."""
    if os.environ.get("LW_REQUIRE_CONFORMANCE", "") not in ("", "0"):
        return RuntimeError(message + " (LW_REQUIRE_CONFORMANCE ist gesetzt)")
    return unittest.SkipTest(message)


def find_tools() -> Tools:
    """Sucht die drei Programme; überspringt mit Hinweis, wenn eines fehlt oder veraltet ist."""
    if REF_ERROR:
        raise _unavailable(REF_ERROR)

    lwctl = _from_env("LWCTL")
    if lwctl is None:
        build = REPO_ROOT / ".build"
        candidates = [build / "debug" / "lwctl", build / "release" / "lwctl"]
        for pattern in ("*/debug/lwctl", "*/release/lwctl", "out/Products/*/lwctl"):
            candidates += sorted(build.glob(pattern))
        existing = [path for path in candidates if _executable(path)]
        if not existing:
            hint = "„swift build --product lwctl“ ausführen" if shutil.which("swift") else \
                "Swift-Toolchain fehlt – lwctl auf einem System mit Swift bauen"
            raise _unavailable("lwctl nicht gefunden (%s/{debug,release}/lwctl) – %s oder LWCTL setzen" % (build, hint))
        lwctl = max(existing, key=lambda path: path.stat().st_mtime)
    elif not _executable(lwctl):
        raise _unavailable("LWCTL=%s ist kein ausführbares Programm" % lwctl)

    filter_path = _from_env("LW_FILTER") or FILTER_DIR / "build" / "rastertolabelwerk"
    if not _executable(filter_path):
        raise _unavailable("CUPS-Filter nicht gefunden (%s) – vorher „make -C Driver/filter tests“ "
                           "ausführen oder LW_FILTER setzen" % filter_path)
    mkraster = _from_env("LW_MKRASTER")
    if mkraster is None:
        mkraster = filter_path.parent / "tests" / "mkraster"
        if not _executable(mkraster):
            mkraster = FILTER_DIR / "build" / "tests" / "mkraster"
    if not _executable(mkraster):
        raise _unavailable("mkraster nicht gefunden (%s) – vorher „make -C Driver/filter tests“ "
                           "ausführen oder LW_MKRASTER setzen" % mkraster)
    if not BASE_PPD.is_file():
        raise _unavailable("Test-PPD fehlt: %s" % BASE_PPD)

    try:
        help_text = subprocess.run([str(lwctl), "help", "encode"], capture_output=True, text=True,
                                   timeout=60).stdout
        stocks = subprocess.run([str(lwctl), "stocks", "--json"], capture_output=True, timeout=60)
        gaps = {entry["id"]: float(entry.get("gapMM", 3.0)) for entry in json.loads(stocks.stdout)}
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
        raise _unavailable("lwctl (%s) lässt sich nicht verwenden: %s" % (lwctl, error))
    missing = [flag for flag in ("--no-layout", "--max-width", "--no-collate", "--backfeed", "--start-commands")
               if flag not in help_text]
    if missing:
        raise _unavailable("lwctl (%s) ist veraltet (es fehlen %s) – „swift build --product lwctl“ "
                           "ausführen" % (lwctl, ", ".join(missing)))
    return Tools(lwctl=lwctl, filter=filter_path, mkraster=mkraster, stock_gaps_mm=gaps, help_text=help_text)


def gap_dots(gap_mm: float, dpi: int) -> int:
    """Wie ``Resolution.dots(fromMM:)``: mm · (dpi / 25,4), kaufmännisch gerundet."""
    value = gap_mm * (dpi / 25.4)
    return int(value + 0.5) if value >= 0 else -int(-value + 0.5)


# --------------------------------------------------------------------------------------------
# Optionen je Implementierung
# --------------------------------------------------------------------------------------------

def cups_options(s, collate: bool) -> str:
    """Vollständige ``argv[5]``-Optionen (§9) – jede Option explizit, damit keine PPD-Standardwerte greifen."""
    def opt(value) -> str:
        return "Default" if value is None else str(value)

    def flag(value: bool) -> str:
        return "True" if value else "False"

    def commands(raw: bytes) -> str:
        return ref.base64url_encode(raw.decode("utf-8")) if raw else "None"

    pairs = [
        ("lwLanguage", s.language), ("lwDarkness", opt(s.darkness)), ("lwSpeed", opt(s.speed)),
        ("lwMediaType", opt(s.media_type)), ("lwMediaTracking", opt(s.tracking)),
        ("lwPrintMode", opt(s.print_mode)), ("lwLabelTop", opt(s.label_top)), ("lwLabelLeft", opt(s.label_left)),
        ("lwTearOff", opt(s.tear_off)), ("lwBackfeed", opt(s.backfeed)), ("lwMirror", flag(s.mirror)),
        ("lwNegative", flag(s.negative)), ("lwRotate180", flag(s.rotate180)), ("lwDither", s.dither),
        ("lwThreshold", str(s.threshold)), ("lwCompression", s.compression), ("lwCutEvery", str(s.cut_every)),
        ("lwCalibrate", flag(s.calibrate)), ("lwSaveSettings", flag(s.save_settings)),
        ("lwSkipBlank", flag(s.skip_blank)), ("lwStartCmd", commands(s.start_commands)),
        ("lwEndCmd", commands(s.end_commands)), ("collate", "true" if collate else "false"),
        ("lwRotation", str(s.rotation)), ("lwMarkOffset", opt(s.mark_offset)), ("lwStopAtLast", flag(s.stop_at_last)),
        ("lwStopOffset", str(s.stop_offset)), ("lwPauseEvery", str(s.pause_every)),
        ("lwControlChars", "Standard" if s.control_chars is None else "Printer"),
        ("lwRTC", opt(s.rtc)), ("lwCancelBefore", flag(s.cancel_before)), ("lwCancelDelay", str(s.cancel_delay)),
        ("lwLabelStartCmd", commands(s.label_start_commands)), ("lwLabelEndCmd", commands(s.label_end_commands)),
        ("lwPowerUpAction", opt(s.power_up_action)), ("lwHeadCloseAction", opt(s.head_close_action)),
        ("lwFitToLabel", s.fit_to_label), ("lwLabelWidth", str(s.label_width)),
        ("lwLabelHeight", str(s.label_height)),
    ]
    chars = s.control_chars or ref.STANDARD_CONTROL_CHARS
    pairs += [("lwFormatPrefix", str(chars[0])), ("lwControlPrefix", str(chars[1])), ("lwDelimiter", str(chars[2]))]
    return " ".join("%s=%s" % pair for pair in pairs)


#: lwctl-Optionen der Windows-Druckeinstellungen (werden je Fall geprüft, siehe ``needed_flags``).
NEW_FLAGS = ("--rotation", "--mark-offset", "--stop-at-last", "--stop-offset", "--pause-every", "--control-chars",
             "--format-prefix", "--control-prefix", "--delimiter", "--rtc", "--fixed-time", "--cancel-before",
             "--cancel-delay", "--label-start-commands", "--label-end-commands", "--power-up-action",
             "--head-close-action")


def needed_flags(case: Case, s) -> List[str]:
    """Neue lwctl-Optionen, die ein Fall braucht (für das Überspringen mit älterem lwctl)."""
    flags = []
    if s.rotation:
        flags.append("--rotation")
    if s.mark_offset is not None:
        flags.append("--mark-offset")
    if s.stop_at_last:
        flags.append("--stop-at-last")
    if s.stop_offset:
        flags.append("--stop-offset")
    if s.pause_every:
        flags.append("--pause-every")
    if s.control_chars is not None:
        flags += ["--control-chars", "--format-prefix", "--control-prefix", "--delimiter"]
    if s.rtc:
        flags += ["--rtc", "--fixed-time", "--time-zone"] + (["--time-step"] if case.time_step else [])
    if s.cancel_before:
        flags.append("--cancel-before")
    if s.cancel_delay != 1000:
        flags.append("--cancel-delay")
    if s.label_start_commands:
        flags.append("--label-start-commands")
    if s.label_end_commands:
        flags.append("--label-end-commands")
    if s.power_up_action:
        flags.append("--power-up-action")
    if s.head_close_action:
        flags.append("--head-close-action")
    if s.tracking == "Notch" or (s.print_mode or "").startswith("Linerless"):
        flags.append("--rotation")   # Stellvertreter: lwctl ohne neue Optionen kennt auch Notch/Linerless nicht
    if s.label_width or s.label_height or s.fit_to_label != "Auto":
        flags += ["--label-size", "--page-size", "--fit-to-label"]
    return flags


def lwctl_arguments(case: Case, s, files: Sequence[Path], output: Path,
                    page_sizes: Sequence[Tuple[float, float]] = ()) -> List[str]:
    """``lwctl encode``-Aufruf mit denselben Einstellungen (Bilder unverändert, ohne Skalierung).

    ``page_sizes``: Seitengröße je Bild in Punkten, wie der Filter sie aus dem Rasterkopf liest
    (exakt, ``repr``) – nur für Fälle mit Etikettengröße, sonst bleibt der Aufruf wie bisher."""
    args = ["--language", s.language.lower(), "encode", *[str(f) for f in files], "--no-layout",
            "--dpi", str(case.dpi), "--dither", s.dither, "--threshold", str(s.threshold),
            "--compression", s.compression.lower(), "--copies", str(case.copies), "-o", str(output)]
    if not case.collate:
        args.append("--no-collate")
    if case.max_width is not None:
        args += ["--max-width", str(case.max_width)]
    if case.stock is not None:
        args += ["--stock", case.stock]
    for option, value in (("--darkness", s.darkness), ("--speed", s.speed), ("--tear-off", s.tear_off),
                          ("--label-top", s.label_top), ("--label-left", s.label_left),
                          ("--media-type", s.media_type), ("--tracking", s.tracking),
                          ("--print-mode", s.print_mode), ("--backfeed", s.backfeed)):
        if value is not None:
            args += [option, str(value)]
    if s.cut_every:
        args += ["--cut-every", str(s.cut_every)]
    for option, on in (("--negative", s.negative), ("--mirror", s.mirror), ("--rotate180", s.rotate180),
                       ("--calibrate", s.calibrate), ("--save-settings", s.save_settings),
                       ("--skip-blank", s.skip_blank)):
        if on:
            args.append(option)
    if s.start_commands:
        args += ["--start-commands", s.start_commands.decode("utf-8")]
    if s.end_commands:
        args += ["--end-commands", s.end_commands.decode("utf-8")]
    if s.rotation:
        args += ["--rotation", str(s.rotation)]
    if s.mark_offset is not None:
        args += ["--mark-offset", str(s.mark_offset)]
    if s.stop_at_last:
        args.append("--stop-at-last")
    if s.stop_offset:
        args += ["--stop-offset", str(s.stop_offset)]
    if s.pause_every:
        args += ["--pause-every", str(s.pause_every)]
    if s.control_chars is not None:
        args += ["--control-chars", "printer", "--format-prefix", str(s.control_chars[0]),
                 "--control-prefix", str(s.control_chars[1]), "--delimiter", str(s.control_chars[2])]
    if s.rtc:
        args += ["--rtc", s.rtc]
    if s.cancel_before:
        args.append("--cancel-before")
    if s.cancel_delay != 1000:
        args += ["--cancel-delay", str(s.cancel_delay)]
    if s.label_start_commands:
        args += ["--label-start-commands", s.label_start_commands.decode("utf-8")]
    if s.label_end_commands:
        args += ["--label-end-commands", s.label_end_commands.decode("utf-8")]
    if s.power_up_action:
        args += ["--power-up-action", s.power_up_action]
    if s.head_close_action:
        args += ["--head-close-action", s.head_close_action]
    if case.fixed_time is not None:
        args += ["--fixed-time", str(case.fixed_time), "--time-zone", case.time_zone]
        if case.time_step:
            args += ["--time-step", str(case.time_step)]
    if s.label_width or s.label_height:
        args += ["--label-size", "%d.%02dx%d.%02dmm" % (s.label_width // 100, s.label_width % 100,
                                                        s.label_height // 100, s.label_height % 100)]
        args += ["--page-size", ",".join("%rx%r" % size for size in page_sizes)]
    if s.fit_to_label != "Auto":
        args += ["--fit-to-label", s.fit_to_label.lower()]
    return args


@contextmanager
def time_zone(tz: str):
    """TZ für die Referenzrechnung (``time.localtime``) setzen und wiederherstellen."""
    old = os.environ.get("TZ")
    os.environ["TZ"] = tz
    time.tzset()
    try:
        yield
    finally:
        if old is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = old
        time.tzset()


def write_ppd(path: Path, max_width: Optional[int], gap: int) -> None:
    text = BASE_PPD.read_text(encoding="ascii")
    if max_width is None:
        text, count = re.subn(r'^\*lwMaxPrintWidthDots: ".*"\n', "", text, flags=re.M)
    else:
        text, count = re.subn(r'^\*lwMaxPrintWidthDots: ".*"$', '*lwMaxPrintWidthDots: "%d"' % max_width,
                              text, flags=re.M)
    assert count == 1, "Test-PPD ohne *lwMaxPrintWidthDots"
    text, count = re.subn(r'^\*lwDefaultGapDots: ".*"$', '*lwDefaultGapDots: "%d"' % gap, text, flags=re.M)
    assert count == 1, "Test-PPD ohne *lwDefaultGapDots"
    path.write_text(text, encoding="ascii")


# --------------------------------------------------------------------------------------------
# Abweichungen beschreiben
# --------------------------------------------------------------------------------------------

GFA = re.compile(rb"\^GFA,(\d+),(\d+),(\d+),")
CPCL_LABEL = re.compile(rb"(?:^|(?<=\r\n))! 0 \d+ \d+ \d+ \d+\r\nPAGE-WIDTH ")


def label_starts(data: bytes, language: str, control_chars=None) -> List[int]:
    """Anfang jedes Etiketts: ZPL das ``^XA`` vor dem Grafikfeld (auch mit eigenen Steuerzeichen
    und Etikettenbefehlen dazwischen), EPL das ``N`` vor ``GW``, CPCL die Kopfzeile."""
    if language == "CPCL":
        return [m.start() for m in CPCL_LABEL.finditer(data)]
    if language == "EPL":
        anchor, start = re.compile(rb"GW0,0,\d+,\d+,"), b"\nN\n"
    else:
        f, _, d = (bytes([c]) for c in (control_chars or (0x5E, 0x7E, 0x2C)))
        anchor = re.compile(re.escape(f + b"FO0" + d + b"0" + f + b"GFA" + d))
        start = f + b"XA\n"
    return [max(0, data.rfind(start, 0, m.start())) for m in anchor.finditer(data)]
BINARY_GRAPHICS = (re.compile(rb"GW0,0,(\d+),(\d+),"), re.compile(rb"CG (\d+) (\d+) 0 0 "))


def _is_text(data: bytes) -> bool:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return not any(ord(ch) < 32 and ch not in "\t\r\n" for ch in text)


def _excerpt(data: bytes, column: int) -> str:
    """Auszug um die Abweichung: Text als repr, Binärdaten als Hex mit [markiertem] Byte."""
    if _is_text(data[max(0, column - 40):column + 40]):
        start = max(0, column - 40)
        return ("…" if start else "") + repr(data[start:column + 40]) + ("…" if column + 40 < len(data) else "")
    start = max(0, column - 10)
    cells = ["[%02x]" % byte if start + i == column else "%02x" % byte
             for i, byte in enumerate(data[start:column + 10])]
    if column >= len(data):
        cells.append("[Ende]")
    return ("… " if start else "") + " ".join(cells) + (" …" if column + 10 < len(data) else "")


def _binary_graphic(data: bytes, pos: int):
    """EPL ``GW``/CPCL ``CG``: Kopf und Lage im Bild, falls ``pos`` in Grafikdaten liegt."""
    for pattern in BINARY_GRAPHICS:
        last = None
        for match in pattern.finditer(data, 0, pos + 1):
            if match.end() <= pos:
                last = match
        if last is not None:
            bpr, height = int(last[1]), int(last[2])
            offset = pos - last.end()
            if bpr > 0 and offset < bpr * height:
                return last, bpr, offset
    return None


def _first_pixel(a: bytes, b: bytes, bpr: int) -> Optional[Tuple[int, int]]:
    for index, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return (index % bpr) * 8 + 8 - (x ^ y).bit_length(), index // bpr
    return None


def _zpl_graphic(line: bytes) -> Optional[Tuple[int, bytes]]:
    match = GFA.search(line)
    if match is None:
        return None
    total, bpr = int(match[1]), int(match[3])
    body = line[match.end():]
    end = body.find(b"^FS")
    body = body[:end] if end >= 0 else body
    try:
        data = ref.z64_decode(body) if body.startswith(b":Z64:") else ref.acs_decode(body, bpr, total)
    except Exception:  # noqa: BLE001 – nur Diagnose
        return None
    return bpr, data


def _graphic_hint(a: bytes, b: bytes, pos: int, line_a: bytes, line_b: bytes) -> Optional[str]:
    """Erstes abweichendes Pixel, falls die Abweichung in Grafikdaten liegt."""
    zpl_a, zpl_b = _zpl_graphic(line_a), _zpl_graphic(line_b)
    if zpl_a and zpl_b:
        if zpl_a[0] != zpl_b[0]:
            return "Grafik: %d bzw. %d Bytes je Zeile" % (zpl_a[0], zpl_b[0])
        pixel = _first_pixel(zpl_a[1], zpl_b[1], zpl_a[0])
        if pixel is not None:
            return "Grafik (dekodiert): erstes abweichendes Pixel x=%d, y=%d" % pixel
        if zpl_a[1] == zpl_b[1]:
            return ("Grafik: dekodiert identisch (%d Bytes) – nur die Kodierung weicht ab "
                    "(bei Z64: verschiedene zlib-Versionen?)" % len(zpl_a[1]))
        return "Grafik: dekodiert %d bzw. %d Bytes" % (len(zpl_a[1]), len(zpl_b[1]))
    found = _binary_graphic(a, pos)
    if found is not None and pos < min(len(a), len(b)):
        _, bpr, offset = found
        return "Grafik: erstes abweichendes Pixel x=%d, y=%d" % (
            (offset % bpr) * 8 + 8 - (a[pos] ^ b[pos]).bit_length(), offset // bpr)
    return None


def describe_mismatch(name_a: str, a: bytes, name_b: str, b: bytes, language: str, control_chars=None) -> str:
    """Erste abweichende Befehlszeile zweier Aufträge: Lage, Befehl, Auszüge und ggf. Pixel."""
    pos = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
    line_start = a.rfind(b"\n", 0, pos) + 1
    end_a, end_b = a.find(b"\n", pos), b.find(b"\n", pos)
    line_a = a[line_start:end_a if end_a >= 0 else len(a)]
    line_b = b[line_start:end_b if end_b >= 0 else len(b)]
    column = pos - line_start
    graphic = _binary_graphic(a, pos)
    if graphic is not None:
        head = graphic[0][0]
    else:
        match = GFA.search(line_a) or GFA.search(line_b)
        head = (line_a if GFA.search(line_a) else line_b)[:match.end()] if match else line_a[:60]
    starts = label_starts(a, language, control_chars)
    label = sum(1 for start in starts if start <= pos)
    where = "Etikett %d von %d" % (label, len(starts)) if label else "Auftragskopf"
    lines = [
        "%s ≠ %s: erste Abweichung bei Byte %d (Zeile %d, Spalte %d, %s); Länge %d bzw. %d Bytes" % (
            name_a, name_b, pos, a.count(b"\n", 0, pos) + 1, column + 1, where, len(a), len(b)),
        "    Befehl: %s" % repr(head)[2:-1],
        "    %-22s %s" % (name_a + ":", _excerpt(line_a, column)),
        "    %-22s %s" % (name_b + ":", _excerpt(line_b, column)),
    ]
    hint = _graphic_hint(a, b, pos, line_a, line_b)
    if hint:
        lines.append("    " + hint)
    return "\n".join(lines)


# --------------------------------------------------------------------------------------------
# Test
# --------------------------------------------------------------------------------------------

@dataclass
class PreparedInput:
    raster: Path
    images: List[Tuple[int, int, bytes]]
    #: Seitengröße je Seite in Punkten, wie libcups sie dem Filter liefert (cupsPageSize bzw. PageSize).
    page_sizes: List[Tuple[float, float]] = field(default_factory=list)


class EncoderConformanceTest(unittest.TestCase):
    """Swift ``JobEncoder`` (lwctl), C-Filter und Python-Referenz: byte-gleiche Druckaufträge."""

    tools: Tools
    workdir: Path
    keep: bool
    failures_seen: bool

    @classmethod
    def setUpClass(cls):
        cls.tools = find_tools()
        cls.workdir = Path(tempfile.mkdtemp(prefix="lw-conformance-"))
        cls.keep = os.environ.get("LW_KEEP_CONFORMANCE", "") not in ("", "0")
        cls.failures_seen = False
        cls._rasters: Dict[Tuple[Tuple[str, ...], int], PreparedInput] = {}
        cls._luminance: Dict[str, bytes] = {}
        cls._images: Dict[Tuple[str, str], Path] = {}
        cls._ppds: Dict[Tuple[Optional[int], int], Path] = {}

    @classmethod
    def tearDownClass(cls):
        if cls.keep or cls.failures_seen:
            sys.stderr.write("\nKonformitätstest: Testdateien in %s\n" % cls.workdir)
        else:
            shutil.rmtree(cls.workdir, ignore_errors=True)

    # --- Eingaben -------------------------------------------------------------------------
    def raster_for(self, pages: Sequence[Page], dpi: int) -> PreparedInput:
        key = (tuple(page.key for page in pages), dpi)
        if key in self._rasters:
            return self._rasters[key]
        directory = self.workdir / "raster" / ("r%d-%d" % (len(self._rasters), dpi))
        directory.mkdir(parents=True)
        raster, dump = directory / "in.ras", directory / "in.raw"
        result = subprocess.run([str(self.tools.mkraster), "-o", str(raster), "-m", "native", "-d", str(dump)]
                                + [page.spec(dpi) for page in pages], capture_output=True, text=True,
                                timeout=TIMEOUT)
        self.assertEqual(result.returncode, 0, "mkraster: %s" % result.stderr.strip())
        records = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        infos = [record for record in records if "page" in record]
        summary = next(record for record in records if "readable_pages" in record)
        readable = summary["readable_pages"]
        self.assertEqual(readable, len(pages), "libcups liest nicht alle Seiten der Testeingabe")
        page_sizes = [tuple(size) for size in summary.get("page_sizes", [])]
        self.assertEqual(len(page_sizes), len(pages),
                         "mkraster ohne Seitengrößen – „make -C Driver/filter tests“ ausführen")
        raw = dump.read_bytes()
        images = []
        for page, info in zip(pages, infos):
            self.assertEqual((info["w"], info["h"], info["bpc"], info["rows"]),
                             (page.width, page.height, 8, page.height), "mkraster-Seitenkopf")
            lum = ref.luminance_from_samples(raw[info["dump_offset"]:info["dump_offset"] + info["dump_size"]], info)
            self.assertEqual(len(lum), page.width * page.height)
            # Dasselbe Muster muss in jeder Rasterdatei dieselbe Luminanz haben (die Bilddatei
            # für lwctl wird nur einmal je Muster geschrieben).
            known = self._luminance.setdefault(page.key, lum)
            self.assertEqual(known, lum, "mkraster-Muster %s ist nicht deterministisch" % page.key)
            images.append((page.width, page.height, lum))
        prepared = PreparedInput(raster, images, page_sizes)
        self._rasters[key] = prepared
        return prepared

    def image_file(self, page: Page, fmt: str) -> Path:
        key = (page.key, fmt)
        if key in self._images:
            return self._images[key]
        directory = self.workdir / "bilder"
        directory.mkdir(exist_ok=True)
        path = directory / ("%s.%s" % (page.key, fmt))
        lum = self._luminance[page.key]
        (write_pgm if fmt == "pgm" else write_png)(path, page.width, page.height, lum)
        decoded = (read_pgm if fmt == "pgm" else read_png)(path.read_bytes())
        self.assertEqual(decoded, (page.width, page.height, lum), "Bilddatei %s ist nicht pixelgleich" % path)
        self._images[key] = path
        return path

    def ppd_for(self, max_width: Optional[int], gap: int) -> Path:
        key = (max_width, gap)
        if key not in self._ppds:
            directory = self.workdir / "ppd"
            directory.mkdir(exist_ok=True)
            path = directory / ("test-%s-%d.ppd" % (max_width or "frei", gap))
            write_ppd(path, max_width, gap)
            self._ppds[key] = path
        return self._ppds[key]

    # --- Ein Fall -------------------------------------------------------------------------
    def run_case(self, case: Case) -> None:
        s = ref.Settings(**case.settings)
        stock = case.stock or DEFAULT_STOCK
        self.assertIn(stock, self.tools.stock_gaps_mm, "Etikettenformat %s fehlt in „lwctl stocks“" % stock)
        gap = gap_dots(self.tools.stock_gaps_mm[stock], case.dpi)
        prepared = self.raster_for(case.pages, case.dpi)
        files = [self.image_file(page, case.image_format(i)) for i, page in enumerate(case.pages)]
        directory = self.workdir / "faelle" / case.name
        directory.mkdir(parents=True, exist_ok=True)

        missing = self.tools.missing_flags(needed_flags(case, s))
        if missing:
            self.skipTest("lwctl (%s) kennt %s noch nicht – „swift build --product lwctl“ ausführen"
                          % (self.tools.lwctl, ", ".join(sorted(set(missing)))))

        # Testrahmen: Die CUPS-Optionen müssen genau diese Einstellungen ergeben (§9).
        options = cups_options(s, case.collate)
        argv = ref.parse_cups_options(options)
        self.assertEqual(ref.resolve_settings(argv, {}, {}), s.clamped(), "CUPS-Optionen: %s" % options)
        self.assertEqual(ref.resolve_collate(argv, {}), case.collate)

        # (1) Swift
        swift_out = directory / "swift.out"
        args = lwctl_arguments(case, s, files, swift_out, prepared.page_sizes)
        result = subprocess.run([str(self.tools.lwctl)] + args, capture_output=True, timeout=TIMEOUT)
        self.assertEqual(result.returncode, 0, "lwctl %s\n%s" % (" ".join(args), result.stderr.decode("utf-8", "replace")))
        swift = swift_out.read_bytes()

        # (2) C-Filter (Wartezeit nach ~JA abgeschaltet, Uhr und Zeitzone wie bei lwctl)
        env = dict(os.environ, PPD=str(self.ppd_for(case.max_width, gap)), LW_CANCEL_DELAY_SCALE="0",
                   TZ=case.time_zone)
        for name in ("LW_FIXED_TIME", "LW_TIME_STEP_SECONDS"):
            env.pop(name, None)
        if case.fixed_time is not None:
            env["LW_FIXED_TIME"] = str(case.fixed_time)
            env["LW_TIME_STEP_SECONDS"] = str(case.time_step)
        result = subprocess.run([str(self.tools.filter), "1", "konformitaet", case.name, str(case.copies), options,
                                 str(prepared.raster)], capture_output=True, env=env, timeout=TIMEOUT)
        stderr = result.stderr.decode("utf-8", "replace")
        self.assertEqual(result.returncode, 0, "rastertolabelwerk: %s" % stderr.strip()[-2000:])
        c_output = result.stdout
        (directory / "c.out").write_bytes(c_output)

        # (3) Python-Referenz
        with time_zone(case.time_zone):
            python = ref.encode_job_from_luminance(prepared.images, s, page_sizes=prepared.page_sizes,
                                                   resolution_dpi=case.dpi, max_width=case.max_width or 0,
                                                   gap_dots=gap, copies=case.copies, collate=case.collate,
                                                   now=case.fixed_time, time_step=case.time_step)
            if case.same_as_unfitted:
                # §8 „F“: passende Größe bzw. Off – byte-gleich zur Ausgabe ohne Seitengrößen.
                plain = ref.encode_job_from_luminance(prepared.images, s, resolution_dpi=case.dpi,
                                                      max_width=case.max_width or 0, gap_dots=gap,
                                                      copies=case.copies, collate=case.collate,
                                                      now=case.fixed_time, time_step=case.time_step)
                self.assertEqual(python, plain, "%s: Anpassung hat die Ausgabe verändert" % case.name)
        (directory / "python.out").write_bytes(python)

        # Gegen triviale Übereinstimmung (z. B. alle leer): Die Referenz muss genau die erwarteten
        # Etiketten enthalten (Seiten nach Vorverarbeitung × Kopienregel).
        fitted = ref.fit_images(prepared.images, s, prepared.page_sizes, case.dpi)
        processed = [bm for bm in (ref.preprocess(ref.dither(lum, w, h, s.dither, s.threshold), s.clamped(),
                                                  case.max_width or 0)
                                   for w, h, lum in fitted) if bm is not None]
        labels = len(ref.label_sequence(len(processed), case.copies, case.collate))
        self.assertEqual(len(label_starts(python, s.language, s.clamped().control_chars)), labels,
                         "Referenz: Anzahl Etiketten in %s" % case.name)

        outputs = {SWIFT: swift, C_FILTER: c_output, PYTHON: python}
        if swift == python and c_output == python:
            if not self.keep:
                shutil.rmtree(directory, ignore_errors=True)
            return
        type(self).failures_seen = True
        reports = []
        chars = s.clamped().control_chars
        if swift != python:
            reports.append(describe_mismatch(SWIFT, swift, PYTHON, python, s.language, chars))
        if c_output != python:
            reports.append(describe_mismatch(C_FILTER, c_output, PYTHON, python, s.language, chars))
        if swift != python and c_output != python and swift != c_output:
            reports.append(describe_mismatch(SWIFT, swift, C_FILTER, c_output, s.language, chars))
        agreeing = [name for name in outputs if sum(outputs[name] == other for other in outputs.values()) >= 2]
        summary = "Fall %s: Druckaufträge weichen ab%s" % (
            case.name, " (übereinstimmend: %s)" % ", ".join(agreeing) if agreeing else "")
        self.fail("\n".join([summary] + reports + [
            "    Einstellungen: %s%s" % (options, "" if case.fixed_time is None else
                                        "  (LW_FIXED_TIME=%d LW_TIME_STEP_SECONDS=%d TZ=%s)"
                                        % (case.fixed_time, case.time_step, case.time_zone)),
            "    lwctl %s" % " ".join(args),
            "    Dateien: %s" % directory]))

    def test_matrix_covers_spec(self):
        """Die Matrix enthält jede Ausprägung von §8/§9 mindestens einmal."""
        def values(key):
            return {case.settings.get(key) for case in CASES}
        self.assertTrue(set(LANGS) <= values("language"))
        self.assertTrue(set(DITHERS) <= values("dither"))
        self.assertTrue(set(COMPRESSIONS) <= values("compression") | {None})
        self.assertTrue(set(PRINT_MODES) | set(LINERLESS_MODES) <= values("print_mode"))
        self.assertTrue({90, 180, 270} <= values("rotation"))
        self.assertTrue(set(RTC_MODES) <= values("rtc"))
        self.assertTrue(set(MEDIA_ACTIONS) <= values("power_up_action") | values("head_close_action"))
        self.assertTrue({-80, 0, 283} <= values("mark_offset"))
        for key in ("stop_at_last", "cancel_before"):
            self.assertIn(True, values(key), key)
        for key in ("stop_offset", "pause_every", "label_start_commands", "label_end_commands"):
            self.assertGreater(len(values(key) - {None, 0, b""}), 1, key)
        self.assertTrue(len(values("control_chars") - {None}) >= 3)
        for lang in LANGS:   # jede neue Option auch in EPL und CPCL (dort teils ohne Wirkung)
            for key in ("rotation", "stop_at_last", "rtc", "cancel_before", "label_start_commands", "control_chars"):
                self.assertTrue(any(case.settings.get(key) and case.settings.get("language", "ZPL") == lang
                                    for case in CASES), (lang, key))
        self.assertTrue(any(case.time_step for case in CASES if case.settings.get("rtc") == "EveryMinute"))
        self.assertTrue(any(case.time_zone != "UTC" for case in CASES))
        self.assertTrue(set(TRACKINGS) <= values("tracking"))
        self.assertTrue(set(MEDIA_TYPES) <= values("media_type"))
        self.assertTrue(set(BACKFEEDS) <= values("backfeed"))
        for key in ("negative", "mirror", "rotate180", "calibrate", "save_settings", "skip_blank"):
            self.assertIn(True, values(key), key)
        for key in ("darkness", "speed", "tear_off", "label_top", "label_left", "cut_every", "start_commands",
                    "end_commands"):
            self.assertGreater(len(values(key) - {None, 0, b""}), 1, key)
        self.assertTrue({1, 833} <= {page.width for case in CASES for page in case.pages})
        self.assertTrue(any(page.height >= 3000 for case in CASES for page in case.pages))
        self.assertTrue(any(not case.collate and case.copies > 1 for case in CASES))
        self.assertTrue({152, 203, 300, 600} <= {case.dpi for case in CASES})
        # §8 „F“: Etikettengrößen, Off, freie Länge, Drehung, passende Größe, A4/Letter
        fit = [case for case in CASES if case.settings.get("label_width")]
        self.assertGreaterEqual(len(fit), 40)
        self.assertIn("Off", values("fit_to_label"))
        self.assertTrue(any(case.settings.get("label_height") == 0 for case in fit))
        self.assertTrue(any(case.settings.get("tracking") == "Continuous" for case in fit))
        self.assertTrue({90, 270} <= {case.settings.get("rotation") for case in fit})
        self.assertTrue(any(case.same_as_unfitted for case in fit))
        self.assertTrue({A4, LETTER, LABEL_PAGE} <= {page.points for case in fit for page in case.pages})
        self.assertTrue(set(LANGS) <= {case.settings.get("language", "ZPL") for case in fit})


def _make_test(case: Case):
    def test(self):
        self.run_case(case)
    test.__doc__ = "Konformität: %s" % case.name
    return test


for _case in CASES:
    setattr(EncoderConformanceTest, "test_" + re.sub(r"\W", "_", _case.name), _make_test(_case))
del _case


if __name__ == "__main__":
    unittest.main()
