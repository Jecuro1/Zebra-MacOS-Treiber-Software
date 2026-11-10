#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LabelWerk – PPD-Generator.

Erzeugt aus ``Catalog/models.json`` (der einzigen Quelle für Modelle und Etikettenformate)
je Druckermodell und Auflösung eine PPD-Datei ``LabelWerk-<id>-<dpi>dpi.ppd`` (bzw.
``.ppd.gz`` mit ``--gzip``), dazu die generischen PPDs ``LabelWerk-generic-zpl-{203,300,600}dpi``,
``LabelWerk-generic-epl-203dpi`` und ``LabelWerk-generic-cpcl-203dpi`` sowie ein
Verzeichnis ``index.json``.

Verbindliche Grundlage ist ``ARCHITECTURE.md``:

* §9  – Namen und Werte der CUPS-Optionen ``lw*`` (identisch in App, PPD und C-Filter),
* §10 – ``*cupsFilter``/``*cupsCommands``, Farbraum, Installationspfade.

Aufbau der PPD-Dateien:

* PPD 4.3, ``*LanguageEncoding: ISOLatin1``; alle Grundtexte (englisch) sind reines ASCII.
* Deutsche Übersetzungen nach CUPS-Konvention (``*cupsLanguages: "de"``,
  ``*de.Translation <Option>/<Text>: ""`` und ``*de.<Option> <Wahl>/<Text>: ""``).
  CUPS verlangt für Übersetzungszeichenketten UTF-8 – unabhängig von ``*LanguageEncoding``
  (``cupstestppd`` meldet sonst „Bad UTF-8 … translation string“). Da die Grundtexte reines
  ASCII sind, ist die Datei trotzdem konform zu ISOLatin1-Lesern.
* Seitengrößen mit Schlüsselwort ``w<pt>h<pt>`` exakt wie ``LabelStock.ppdKeyword`` in Swift
  (``Int((mm / 25.4 * 72).rounded())`` – kaufmännisch, nicht wie Pythons ``round``).

Aufruf (siehe auch ``--help`` und ``Driver/ppd/README.md``)::

    python3 Driver/ppd/generate_ppds.py                 # alle PPDs nach Driver/ppd/out
    python3 Driver/ppd/generate_ppds.py --gzip --check  # komprimiert + cupstestppd
    python3 Driver/ppd/generate_ppds.py --model zd421t  # nur ein Modell
    python3 Driver/ppd/generate_ppds.py --list          # nur auflisten

Nur Python-3-Standardbibliothek (ab Python 3.7; die macOS Command Line Tools genügen).
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import math
import os
import re
import shutil
import subprocess
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------------------------
# Pfade & feste Werte
# ---------------------------------------------------------------------------------------------

#: Verzeichnis dieses Skripts (``Driver/ppd``).
SCRIPT_DIR = Path(__file__).resolve().parent
#: Wurzel des Repositorys (zwei Ebenen über ``Driver/ppd``).
REPO_ROOT = SCRIPT_DIR.parent.parent
#: Standardpfad des Modellkatalogs.
DEFAULT_CATALOG = REPO_ROOT / "Catalog" / "models.json"
#: Standard-Ausgabeverzeichnis (per ``.gitignore`` ausgeschlossen).
DEFAULT_OUTPUT = SCRIPT_DIR / "out"

#: Treiberversion für ``*FileVersion`` (per ``--file-version`` überschreibbar).
DEFAULT_FILE_VERSION = "1.0.0"
#: ``*cupsVersion`` – Mindestversion der CUPS-Erweiterungen (macOS 14 liefert CUPS 2.3).
CUPS_VERSION = "2.3"
#: Wert der Umgebungsvariablen ``SOFTWARE`` beim Aufruf von libcups-Programmen. Die libcups von
#: macOS beachtet ``LANG`` nur, wenn ``SOFTWARE`` gesetzt ist (wie in der Umgebung, die cupsd
#: seinen Filtern mitgibt); sonst gilt die Sprachwahl des Benutzers (``AppleLanguages``).
CUPS_SOFTWARE = "CUPS/" + CUPS_VERSION
#: Locale-Variablen, die ``LANG`` überstimmen und für libcups-Programme entfernt werden.
LOCALE_OVERRIDE_VARIABLES = ("LC_ALL", "LC_MESSAGES", "LC_CTYPE", "LANGUAGE")
#: Sprache, in der ``cupstestppd`` laufen muss: ``run_cupstestppd`` erkennt ``**FAIL**``, ``WARN``
#: und das Urteil ``PASS`` an den englischen Meldungen – mit deutscher Systemsprache meldet
#: ``cupstestppd`` sonst etwa „BESTANDEN“ und jede Prüfung gälte als fehlgeschlagen.
CUPSTESTPPD_LANGUAGE = "en_US.UTF-8"

FILTER_DIR = "/Library/Printers/LabelWerk/Filter"
#: ``*cupsFilter``-Zeilen exakt nach ARCHITECTURE.md §10.
CUPS_FILTERS = (
    "application/vnd.cups-raster 0 " + FILTER_DIR + "/rastertolabelwerk",
    "application/vnd.cups-command 0 " + FILTER_DIR + "/commandtolabelwerk",
)
#: ``*cupsCommands`` exakt nach ARCHITECTURE.md §10.
CUPS_COMMANDS = "Clean PrintSelfTestPage ReportLevels AutoConfigure Calibrate"
ICON_PATH = "/Library/Printers/LabelWerk/Icons/LabelWerk.icns"
UTILITY_PATH = "/Applications/LabelWerk.app"
#: ``*ColorModel Gray`` – 8-Bit-Graustufen (CUPS_CSPACE_SW = 18), ARCHITECTURE.md §10.
COLOR_MODEL_CODE = (
    "<</cupsColorSpace 18/cupsBitsPerColor 8/cupsColorOrder 0/cupsCompression 0>>setpagedevice"
)
#: Hersteller im ``*1284DeviceID`` (USB-Gerätekennung der Zebra-Drucker).
IEEE1284_MANUFACTURER = "Zebra Technologies"

#: Kleinste eigene Seitengröße (Breite × Höhe) in Punkten: 0,5 × 0,25 Zoll.
CUSTOM_MIN_WIDTH_PT = 36.0
CUSTOM_MIN_HEIGHT_PT = 18.0
#: Toleranz für „passende“ Etikettenbreiten in mm (wie ``ModelCatalog.stocks(fitting:)``).
STOCK_WIDTH_TOLERANCE_MM = 2.0
#: Obergrenze der Geschwindigkeit laut §9 (``lwSpeed`` 1…14) und ``PrintSettings.clamped()``.
MAX_SPEED_IPS = 14
#: Kleinste Geschwindigkeit in der PPD: wie die Windows-Liste ab 51 mm/s (2 Zoll/s); 1 Zoll/s bleibt
#: als Auftragsoption erlaubt (Modelle mit Höchstwert 1 bekommen trotzdem eine Auswahl).
MIN_PPD_SPEED_IPS = 2

#: Generische PPDs: (Sprache, Auflösung).
GENERIC_TARGETS: Tuple[Tuple[str, int], ...] = (
    ("zpl", 203),
    ("zpl", 300),
    ("zpl", 600),
    ("epl", 203),
    ("cpcl", 203),
)
#: Rückfallwerte für generische PPDs, falls der Katalog kein Modell der Sprache enthält.
GENERIC_FALLBACK = {
    "print_width_mm": 104.0,
    "max_label_length_mm": 991.0,
    "max_speed": 6,
}

#: Basis-Ordnungszahl für ``*cupsModelNumber`` der generischen PPDs.
GENERIC_MODEL_NUMBER_BASE = 1000

PPD_MAX_LINE = 255          # PPD-Spezifikation: höchstens 255 Zeichen je Zeile
PPD_MAX_KEYWORD = 40        # PPD_MAX_NAME − 1 in libcups
PPD_MAX_TEXT_BYTES = 80     # PPD_MAX_TEXT − 1 in libcups (gilt auch für UTF-8-Übersetzungen)
SHORT_NICKNAME_MAX = 31     # PPD-Spezifikation / cupstestppd

# ---------------------------------------------------------------------------------------------
# Werte aus den Swift-Typen (LabelWerkCore/Types/Enums.swift) – Rohwert → CUPS-Wert
# ---------------------------------------------------------------------------------------------

LANGUAGE_CUPS = {"zpl": "ZPL", "epl": "EPL", "cpcl": "CPCL"}
#: Reihenfolge wie im Windows-Treiber (Druckmodus: Thermotransfer | Thermo-Direkt).
MEDIA_TYPE_CUPS = {"thermalTransfer": "ThermalTransfer", "directThermal": "DirectThermal"}
TRACKING_CUPS = {"gap": "Gap", "blackMark": "BlackMark", "continuous": "Continuous", "autoDetect": "Auto",
                 "notch": "Notch"}
#: Reihenfolge wie im Windows-Treiber (Bedienermodus → Modus).
PRINT_MODE_CUPS = {
    "tearOff": "TearOff",
    "peelOff": "PeelOff",
    "cutter": "Cutter",
    "delayedCut": "DelayedCut",
    "rewind": "Rewind",
    "linerlessPeel": "LinerlessPeel",
    "linerlessCut": "LinerlessCut",
    "linerlessDelayedCut": "LinerlessDelayedCut",
    "linerlessRewind": "LinerlessRewind",
    "linerlessTear": "LinerlessTear",
    "applicator": "Applicator",
    "kiosk": "Kiosk",
}
#: Linerless-Modi: nur ZPL (SGD ``media.printmode``) und nur für Modelle mit Ausstattung ``linerless``.
LINERLESS_PRINT_MODES = ("linerlessPeel", "linerlessCut", "linerlessDelayedCut", "linerlessRewind",
                         "linerlessTear")
LINERLESS_FEATURE = "linerless"
#: ``CMD:``-Kürzel im IEEE-1284-Geräte-String.
LANGUAGE_IEEE1284 = {"zpl": "ZPL", "epl": "EPL2", "cpcl": "CPCL"}
#: Anzeigenamen der generischen PPDs.
GENERIC_NAMES = {"zpl": "Generic ZPL", "epl": "Generic EPL2", "cpcl": "Generic CPCL"}

# ---------------------------------------------------------------------------------------------
# CUPS-Optionen nach ARCHITECTURE.md §9
# ---------------------------------------------------------------------------------------------

DEFAULT_CHOICE = "Default"

OPT_LANGUAGE = "lwLanguage"
OPT_DARKNESS = "lwDarkness"
OPT_SPEED = "lwSpeed"
OPT_MEDIA_TYPE = "lwMediaType"
OPT_TRACKING = "lwMediaTracking"
OPT_PRINT_MODE = "lwPrintMode"
OPT_LABEL_TOP = "lwLabelTop"
OPT_LABEL_LEFT = "lwLabelLeft"
OPT_TEAR_OFF = "lwTearOff"
OPT_BACKFEED = "lwBackfeed"
OPT_MIRROR = "lwMirror"
OPT_NEGATIVE = "lwNegative"
OPT_ROTATE = "lwRotate180"
OPT_DITHER = "lwDither"
OPT_THRESHOLD = "lwThreshold"
OPT_COMPRESSION = "lwCompression"
OPT_CUT_EVERY = "lwCutEvery"
OPT_CALIBRATE = "lwCalibrate"
OPT_SAVE = "lwSaveSettings"
OPT_SKIP_BLANK = "lwSkipBlank"
OPT_ROTATION = "lwRotation"
OPT_MARK_OFFSET = "lwMarkOffset"
OPT_STOP_AT_LAST = "lwStopAtLast"
OPT_STOP_OFFSET = "lwStopOffset"
OPT_PAUSE_EVERY = "lwPauseEvery"
OPT_CONTROL_CHARS = "lwControlChars"
OPT_RTC = "lwRTC"
OPT_CANCEL_BEFORE = "lwCancelBefore"
OPT_CANCEL_DELAY = "lwCancelDelay"
OPT_POWER_UP = "lwPowerUpAction"
OPT_HEAD_CLOSE = "lwHeadCloseAction"
#: „An Etikett anpassen“ (§8 „F“): Seiten mit abweichender Größe (A4/Letter) auf das Etikett legen.
OPT_FIT_TO_LABEL = "lwFitToLabel"
#: Freie Base64url-Werte – bewusst keine PPD-Optionen (siehe README, Abschnitt „Optionen“).
OPT_START_CMD = "lwStartCmd"
OPT_END_CMD = "lwEndCmd"
OPT_LABEL_START_CMD = "lwLabelStartCmd"
OPT_LABEL_END_CMD = "lwLabelEndCmd"
#: Eigene Steuerzeichen (dezimaler ASCII-Code 33…126) – frei wählbar, daher keine PPD-Optionen.
OPT_FORMAT_PREFIX = "lwFormatPrefix"
OPT_CONTROL_PREFIX = "lwControlPrefix"
OPT_DELIMITER = "lwDelimiter"
#: Etikettengröße der Warteschlange in 1/100 mm (für lwFitToLabel) – frei wählbar, daher keine
#: PPD-Optionen; die App setzt sie aus dem Etikettenformat als Warteschlangen-Standard.
OPT_LABEL_WIDTH = "lwLabelWidth"
OPT_LABEL_HEIGHT = "lwLabelHeight"

#: Optionen aus §9, die bewusst nicht in der PPD stehen: freie Werte (Base64url, ASCII-Codes,
#: Etikettengröße) und das veraltete ``lwRotate180`` (ersetzt durch ``lwRotation``; der Filter wertet
#: es weiter aus).
NON_PPD_OPTIONS = frozenset({OPT_START_CMD, OPT_END_CMD, OPT_LABEL_START_CMD, OPT_LABEL_END_CMD,
                             OPT_FORMAT_PREFIX, OPT_CONTROL_PREFIX, OPT_DELIMITER, OPT_ROTATE,
                             OPT_LABEL_WIDTH, OPT_LABEL_HEIGHT})

#: Feste Auswahllisten aus §9 (PPD-Teilmengen, wo §9 sie vorgibt).
DARKNESS_VALUES = tuple(range(1, 31))            # „Temperatur“ 1…30 wie im Windows-Treiber
LABEL_TOP_VALUES = tuple(range(-120, 121, 10))
LABEL_LEFT_VALUES = tuple(range(-200, 201, 10))
TEAR_OFF_VALUES = tuple(range(-120, 121, 10))
THRESHOLD_VALUES = (64, 96, 128, 160, 192)
CUT_EVERY_VALUES = (0, 1, 2, 5, 10, 25, 50, 100)
PAUSE_EVERY_VALUES = (0, 1, 2, 5, 10, 25, 50, 100)
CANCEL_DELAY_VALUES = (0, 250, 500, 1000, 2000, 3000, 5000, 10000)
#: Markierung Versatz in mm (umgerechnet in Punkte der Auflösung; nur Werte in −80…283 Punkten).
MARK_OFFSET_MM = (-10, -5, -3, -2, -1, 0, 1, 2, 3, 4, 5, 10, 15, 20, 25, 30, 35)
MARK_OFFSET_RANGE = (-80, 283)
#: Stoppversatz in mm (umgerechnet in Punkte der Auflösung).
STOP_OFFSET_MM = (0, 1, 2, 3, 5, 10)
ROTATION_VALUES = ("0", "90", "180", "270")
#: Reihenfolge wie im Windows-Treiber (Seite einrichten → Medientyp).
TRACKING_VALUES = ("Continuous", "Gap", "BlackMark", "Notch", "Auto")
#: Reihenfolge wie im Windows-Treiber (Rückzug: Kein Rückzug | Vor | Nach | Standard).
BACKFEED_VALUES = ("Off", "Before", "After", "Normal")
CONTROL_CHARS_VALUES = ("Standard", "Printer")
RTC_VALUES = ("JobStart", "EveryLabel", "EveryMinute")
MEDIA_ACTION_VALUES = ("Feed", "Calibrate", "Length", "NoMotion", "ShortCal")
DITHER_VALUES = ("Threshold", "Ordered", "Halftone", "FloydSteinberg", "Atkinson", "Stucki")
COMPRESSION_VALUES = ("Z64", "ACS", "Hex")
FIT_TO_LABEL_VALUES = ("Auto", "Off")
PRINT_MODE_VALUES = tuple(PRINT_MODE_CUPS.values())
MEDIA_TYPE_VALUES = tuple(MEDIA_TYPE_CUPS.values())
LANGUAGE_VALUES = tuple(LANGUAGE_CUPS.values())

#: Sprachen, deren Auftragsformat (§8) die Option überhaupt auswertet. Optionen ohne
#: Wirkung werden für Modelle, die keine dieser Sprachen sprechen, weggelassen.
OPTION_LANGUAGES: Dict[str, Tuple[str, ...]] = {
    OPT_LANGUAGE: ("zpl", "epl", "cpcl"),
    OPT_DARKNESS: ("zpl", "epl", "cpcl"),
    OPT_SPEED: ("zpl", "epl", "cpcl"),
    OPT_MEDIA_TYPE: ("zpl", "epl"),
    OPT_TRACKING: ("zpl", "epl", "cpcl"),
    OPT_PRINT_MODE: ("zpl", "epl"),
    OPT_LABEL_TOP: ("zpl",),
    OPT_LABEL_LEFT: ("zpl",),
    OPT_TEAR_OFF: ("zpl",),
    OPT_BACKFEED: ("zpl",),
    OPT_MIRROR: ("zpl", "epl", "cpcl"),
    OPT_NEGATIVE: ("zpl", "epl", "cpcl"),
    OPT_ROTATE: ("zpl", "epl", "cpcl"),
    OPT_DITHER: ("zpl", "epl", "cpcl"),
    OPT_THRESHOLD: ("zpl", "epl", "cpcl"),
    OPT_COMPRESSION: ("zpl",),
    OPT_CUT_EVERY: ("zpl",),
    OPT_CALIBRATE: ("zpl",),
    OPT_SAVE: ("zpl",),
    OPT_SKIP_BLANK: ("zpl", "epl", "cpcl"),
    OPT_ROTATION: ("zpl", "epl", "cpcl"),
    OPT_MARK_OFFSET: ("zpl",),
    OPT_STOP_AT_LAST: ("zpl", "epl", "cpcl"),
    OPT_STOP_OFFSET: ("zpl", "epl", "cpcl"),
    OPT_PAUSE_EVERY: ("zpl",),
    OPT_CONTROL_CHARS: ("zpl",),
    OPT_RTC: ("zpl",),
    OPT_CANCEL_BEFORE: ("zpl", "epl"),
    OPT_CANCEL_DELAY: ("zpl", "epl"),
    OPT_POWER_UP: ("zpl",),
    OPT_HEAD_CLOSE: ("zpl",),
    OPT_FIT_TO_LABEL: ("zpl", "epl", "cpcl"),
}

#: Druckmodi, bei denen ``lwCutEvery`` (``^PQ``-Schnittzähler) sinnvoll ist.
CUTTING_PRINT_MODES = ("cutter", "delayedCut")
#: Druckmodi, die EPL2 abbilden kann (§8: ``O`` + ``C``/``P``; Abreißen = ohne Zusatz).
EPL_PRINT_MODES = ("tearOff", "peelOff", "cutter")

# --- Texte (englische ASCII-Grundtexte, deutsche Übersetzungen) ------------------------------

#: PPD-Gruppen wie die Seitenleiste des Windows-Treibers („Druckeinstellungen für ZD421 …“):
#: (Schlüsselwort, englischer Text, deutscher Text). „Seite einrichten“ enthält zusätzlich die
#: Seitengrößen, „Erweitert“ Auflösung und Farbmodell.
GROUPS: Tuple[Tuple[str, str, str], ...] = (
    ("PageSetup", "Page Setup", "Seite einrichten"),
    ("PrintOptions", "Print Options", "Druckoptionen"),
    ("OperationMode", "Operation Mode", "Bedienermodus"),
    ("Graphics", "Graphics Options", "Grafik Optionen"),
    ("Advanced", "Advanced", "Erweitert"),
)
#: Gruppe der Standardoptionen PageSize/PageRegion (vorn) bzw. Resolution/ColorModel (hinten).
PAGE_GROUP = "PageSetup"
DEVICE_GROUP = "Advanced"

#: Option → (Gruppe, englischer Text, deutscher Text) – deutsche Begriffe wie im Windows-Treiber.
OPTION_TEXTS: Dict[str, Tuple[str, str, str]] = {
    OPT_FIT_TO_LABEL: ("PageSetup", "Fit to Label", "An Etikett anpassen"),
    OPT_TRACKING: ("PageSetup", "Media Type", "Medientyp"),
    OPT_MARK_OFFSET: ("PageSetup", "Mark Offset", "Markierung Versatz"),
    OPT_ROTATION: ("PageSetup", "Rotation", "Drehung"),
    OPT_MIRROR: ("PageSetup", "Mirror Image", "Spiegeln"),
    OPT_NEGATIVE: ("PageSetup", "Inverse", "Invers"),
    OPT_STOP_AT_LAST: ("PageSetup", "Stop at Last Element", "Bei letztem Element stoppen"),
    OPT_STOP_OFFSET: ("PageSetup", "Stop Offset", "Stoppversatz"),
    OPT_SPEED: ("PrintOptions", "Speed", "Geschwindigkeit"),
    OPT_DARKNESS: ("PrintOptions", "Darkness", "Temperatur"),
    OPT_MEDIA_TYPE: ("PrintOptions", "Print Method", "Druckmodus"),
    OPT_LABEL_TOP: ("PrintOptions", "Top Offset", "Versatz oben"),
    OPT_LABEL_LEFT: ("PrintOptions", "Left Offset", "Versatz links"),
    OPT_BACKFEED: ("PrintOptions", "Backfeed", "Rückzug"),
    OPT_PAUSE_EVERY: ("PrintOptions", "Pause", "Pausieren"),
    OPT_CONTROL_CHARS: ("PrintOptions", "Control Characters", "Steuerzeichen"),
    OPT_RTC: ("PrintOptions", "Update RTC", "RTC aktualisieren"),
    OPT_CANCEL_BEFORE: ("PrintOptions", "Cancel Jobs Before Printing", "Aufträge vor dem Drucken abbrechen"),
    OPT_CANCEL_DELAY: ("PrintOptions", "Cancel Delay", "Verzögerung (Abbrechen)"),
    OPT_PRINT_MODE: ("OperationMode", "Mode", "Modus"),
    OPT_TEAR_OFF: ("OperationMode", "Tear-Off Adjust", "Versatz"),
    OPT_CUT_EVERY: ("OperationMode", "Cut Every", "Schneiden alle"),
    OPT_DITHER: ("Graphics", "Dithering", "Rasterung"),
    OPT_THRESHOLD: ("Graphics", "Threshold", "Schwellenwert"),
    OPT_COMPRESSION: ("Graphics", "Graphics Compression", "Grafikkompression"),
    OPT_LANGUAGE: ("Advanced", "Printer Language", "Druckersprache"),
    OPT_CALIBRATE: ("Advanced", "Calibrate Before Job", "Vor dem Auftrag kalibrieren"),
    OPT_SAVE: ("Advanced", "Save Settings to Printer", "Einstellungen im Drucker speichern"),
    OPT_SKIP_BLANK: ("Advanced", "Skip Blank Labels", "Leere Etiketten überspringen"),
    OPT_POWER_UP: ("Advanced", "Power Up Action", "Aktion beim Einschalten"),
    OPT_HEAD_CLOSE: ("Advanced", "Head Close Action", "Aktion beim Schließen des Druckkopfs"),
}

#: Reihenfolge der lw-Optionen in der PPD (innerhalb ihrer Gruppen, wie im Windows-Dialog).
OPTION_ORDER: Tuple[str, ...] = (
    OPT_FIT_TO_LABEL, OPT_TRACKING, OPT_MARK_OFFSET, OPT_ROTATION, OPT_MIRROR, OPT_NEGATIVE, OPT_STOP_AT_LAST,
    OPT_STOP_OFFSET,
    OPT_SPEED, OPT_DARKNESS, OPT_MEDIA_TYPE, OPT_LABEL_TOP, OPT_LABEL_LEFT, OPT_BACKFEED,
    OPT_PAUSE_EVERY, OPT_CONTROL_CHARS, OPT_RTC, OPT_CANCEL_BEFORE, OPT_CANCEL_DELAY,
    OPT_PRINT_MODE, OPT_TEAR_OFF, OPT_CUT_EVERY,
    OPT_DITHER, OPT_THRESHOLD, OPT_COMPRESSION,
    OPT_LANGUAGE, OPT_CALIBRATE, OPT_SAVE, OPT_SKIP_BLANK, OPT_POWER_UP, OPT_HEAD_CLOSE,
)

#: Boolesche Optionen (UI-Typ ``Boolean``, Standard ``False``).
BOOLEAN_OPTIONS = (OPT_MIRROR, OPT_NEGATIVE, OPT_STOP_AT_LAST, OPT_CANCEL_BEFORE, OPT_CALIBRATE, OPT_SAVE,
                   OPT_SKIP_BLANK)

DEFAULT_TEXT = ("Printer Default", "Druckereinstellung")
BOOLEAN_TEXTS = {"True": ("On", "Ein"), "False": ("Off", "Aus")}
#: Abweichende Texte der „Ein“-Wahl (wie die Kontrollkästchen im Windows-Dialog).
BOOLEAN_TRUE_TEXTS = {
    OPT_CANCEL_BEFORE: ("Delete All Current and Pending Jobs", "Alle aktuellen und nächsten Druckjobs löschen"),
}
LANGUAGE_TEXTS = {"ZPL": ("ZPL II", "ZPL II"), "EPL": ("EPL2", "EPL2"), "CPCL": ("CPCL", "CPCL")}
MEDIA_TYPE_TEXTS = {
    "DirectThermal": ("Direct Thermal", "Thermo-Direkt"),
    "ThermalTransfer": ("Thermal Transfer", "Thermotransfer"),
}
TRACKING_TEXTS = {
    "Continuous": ("Continuous Media", "Endlosmaterial"),
    "Gap": ("Labels with Gaps", "Einzeletiketten"),
    "BlackMark": ("Labels with Black Marks", "Etiketten mit schwarzen Markierungen"),
    "Notch": ("Labels with Notches", "Etiketten mit Seitenkerben"),
    "Auto": ("Auto Detect", "Automatisch erkennen"),
}
PRINT_MODE_TEXTS = {
    "TearOff": ("Tear Off", "Abreißen"),
    "PeelOff": ("Peel Off", "Spendemodus"),
    "Cutter": ("Cutter", "Abschneider"),
    "DelayedCut": ("Delayed Cut", "Verzögerter Abschneider"),
    "Rewind": ("Rewind", "Aufwickeln"),
    "LinerlessPeel": ("Linerless Peel", "Linerless ablösen"),
    "LinerlessCut": ("Linerless Cut", "Linerless schneiden"),
    "LinerlessDelayedCut": ("Linerless Delayed Cut", "Linerless verzögert schneiden"),
    "LinerlessRewind": ("Linerless Rewind", "Linerless aufwickeln"),
    "LinerlessTear": ("Linerless Tear", "Linerless-Abriss"),
    "Applicator": ("Applicator", "Applikator"),
    "Kiosk": ("Kiosk", "Kiosk"),
}
BACKFEED_TEXTS = {
    "Off": ("No Backfeed", "Kein Rückzug"),
    "Before": ("Before Printing", "Vor dem Drucken"),
    "After": ("After Printing", "Nach dem Drucken"),
    "Normal": ("Default (90/10)", "Standard"),
}
ROTATION_TEXTS = {
    "0": ("0 degrees - Portrait", "0° – Hochformat"),
    "90": ("90 degrees - Landscape", "90° – Querformat"),
    "180": ("180 degrees - Portrait", "180° – Hochformat"),
    "270": ("270 degrees - Landscape", "270° – Querformat"),
}
CONTROL_CHARS_TEXTS = {
    "Standard": ("Standard", "Standard"),
    "Printer": ("Printer (Internal)", "Intern"),
}
RTC_TEXTS = {
    "JobStart": ("At Job Start", "Druckzeit starten"),
    "EveryLabel": ("Every Label", "Jedes Etikett"),
    "EveryMinute": ("Every Minute", "Jede Minute"),
}
MEDIA_ACTION_TEXTS = {
    "Feed": ("Feed", "Vorschub"),
    "Calibrate": ("Calibrate", "Kalibrieren"),
    "Length": ("Measure Length", "Länge messen"),
    "NoMotion": ("No Motion", "Keine Bewegung"),
    "ShortCal": ("Short Calibration", "Kurzkalibrierung"),
}
DITHER_TEXTS = {
    "Threshold": ("Threshold (Text and Barcodes)", "Schwellenwert (Text & Barcodes)"),
    "Ordered": ("Ordered (Bayer)", "Geordnet (Bayer)"),
    "Halftone": ("Halftone", "Halbton-Raster"),
    "FloydSteinberg": ("Floyd-Steinberg", "Floyd–Steinberg"),
    "Atkinson": ("Atkinson", "Atkinson"),
    "Stucki": ("Stucki", "Stucki"),
}
COMPRESSION_TEXTS = {
    "Z64": ("Z64 (Deflate, recommended)", "Z64 (Deflate, empfohlen)"),
    "ACS": ("ACS (Run Length)", "ACS (Lauflänge)"),
    "Hex": ("Hex (Uncompressed)", "Hex (unkomprimiert)"),
}
THRESHOLD_NOTES = {64: ("lighter", "heller"), 128: ("default", "Standard"), 192: ("darker", "dunkler")}
FIT_TO_LABEL_TEXTS = {
    "Auto": ("Automatic", "Automatisch"),
    "Off": ("Off", "Aus"),
}

#: Übersetzung der Standardoptionen.
STANDARD_TEXTS = {
    "PageSize": ("Media Size", "Etikettenformat"),
    "PageRegion": ("Media Size", "Etikettenformat"),
    "Resolution": ("Resolution", "Auflösung"),
    "ColorModel": ("Color Mode", "Farbmodus"),
}
CUSTOM_SIZE_TEXT = ("Custom Size", "Eigenes Format")
CUSTOM_PARAM_TEXTS = (
    ("Width", 1, "points", "Breite"),
    ("Height", 2, "points", "Höhe"),
    ("WidthOffset", 3, "points", "Breitenversatz"),
    ("HeightOffset", 4, "points", "Höhenversatz"),
    ("Orientation", 5, "int", "Ausrichtung"),
)

#: Deutsche Begriffe in Formatnamen → englische Entsprechung (für ASCII-Grundtexte).
STOCK_PHRASES_EN: Tuple[Tuple[str, str], ...] = (
    ("Adresse klein", "Small Address"),
    ("Adresse", "Address"),
    ("Versand", "Shipping"),
    ("Beleg", "Receipt"),
    ("Schmucketikett", "Jewelry Label"),
    ("Patientenarmband", "Patient Wristband"),
    ("Endlos", "Continuous"),
    ("Zoll", "in"),
)

#: Zeichenersetzungen für ASCII-Texte.
ASCII_REPLACEMENTS = {
    "×": "x",    # ×
    "–": "-",    # –
    "—": "-",    # —
    "−": "-",    # −
    "…": "...",  # …
    "„": '"', "“": '"', "”": '"', "‘": "'", "’": "'",
    "°": " deg",
    "ß": "ss",
}


class CatalogError(Exception):
    """Der Modellkatalog ist unvollständig oder widersprüchlich."""


class GenerationError(Exception):
    """Eine PPD konnte nicht regelkonform erzeugt werden (Programmfehler oder Datenfehler)."""


# ---------------------------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------------------------


def swift_round(value: float) -> int:
    """Rundet wie Swift ``Double.rounded()`` (``.toNearestOrAwayFromZero``).

    Pythons ``round`` rundet „Banker's Rounding“ (2.5 → 2) und darf hier nicht verwendet
    werden, weil Schlüsselwörter und Punktmaße bitgenau zu ``LabelStock.ppdKeyword`` bzw.
    ``Resolution.dots(fromMM:)`` passen müssen.
    """
    if value < 0:
        return -swift_round(-value)
    whole = math.floor(value)
    return int(whole) + (1 if value - whole >= 0.5 else 0)


def ppd_speeds(max_speed: int) -> List[int]:
    """Geschwindigkeiten der PPD in Zoll/s: ``MIN_PPD_SPEED_IPS`` … Modellmaximum (wie Windows ab
    51 mm/s); bei einem Höchstwert darunter nur dieser."""
    return list(range(min(MIN_PPD_SPEED_IPS, max_speed), max_speed + 1))


def mm_to_points(mm: float) -> float:
    """Millimeter → PostScript-Punkte, gleiche Rechenreihenfolge wie ``LabelStock.widthPoints``."""
    return mm / 25.4 * 72.0


def mm_to_dots(mm: float, dpi: int) -> int:
    """Millimeter → Druckerpunkte wie ``Resolution.dots(fromMM:)`` (``mm * (dpi / 25.4)``)."""
    return swift_round(mm * (float(dpi) / 25.4))


def format_number(value: float, decimals: int = 3) -> str:
    """Kompakte Dezimaldarstellung ohne überflüssige Nullen (``288``, ``283.465``)."""
    text = f"{value:.{decimals}f}"
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def format_german_decimal(value: float, decimals: int = 1) -> str:
    """Dezimalzahl mit deutschem Komma (``1,3``)."""
    return f"{value:.{decimals}f}".replace(".", ",")


def to_ascii(text: str) -> str:
    """Wandelt einen Text in reines ASCII (Transliteration, Akzente entfernt).

    Löst ``GenerationError`` aus, wenn danach noch Nicht-ASCII-Zeichen übrig wären.
    """
    out = []
    for ch in text:
        if ch in ASCII_REPLACEMENTS:
            out.append(ASCII_REPLACEMENTS[ch])
            continue
        if ch in "äöüÄÖÜ":
            out.append({"ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue"}[ch])
            continue
        decomposed = unicodedata.normalize("NFKD", ch)
        out.append("".join(c for c in decomposed if not unicodedata.combining(c)))
    result = "".join(out)
    try:
        result.encode("ascii")
    except UnicodeEncodeError as exc:
        raise GenerationError(f"Text lässt sich nicht in ASCII umwandeln: {text!r}") from exc
    return result


def sanitize_text(text: str) -> str:
    """Bereinigt einen Übersetzungs-/Anzeigetext für PPD-Zeilen.

    Verboten sind ``:`` (Trenner), ``<``/``>`` (Hex-Teilzeichenketten), ``"`` und
    Steuerzeichen. Mehrfache Leerzeichen werden zusammengefasst; die Länge wird auf
    ``PPD_MAX_TEXT_BYTES`` UTF-8-Bytes gekürzt (an Zeichengrenzen).
    """
    text = text.replace(":", " -").replace("<", "(").replace(">", ")").replace('"', "'")
    text = "".join(ch if ch >= " " and ch != "\x7f" else " " for ch in text)
    text = re.sub(r"\s+", " ", text).strip()
    while len(text.encode("utf-8")) > PPD_MAX_TEXT_BYTES:
        text = text[:-1].rstrip()
    if not text:
        raise GenerationError("Leerer PPD-Text")
    return text


def ascii_text(text: str) -> str:
    """Bereinigter ASCII-Grundtext (englische PPD-Texte, Kommentare, Attributwerte)."""
    return sanitize_text(to_ascii(text))


def check_attribute_value(keyword: str, value: str) -> str:
    """Prüft den Wert eines Hauptschlüsselworts ``*keyword: "value"``: reines ASCII, ohne
    Anführungszeichen und Zeilenumbrüche. Liefert den Wert unverändert zurück."""
    if '"' in value or "\n" in value or "\r" in value:
        raise GenerationError(f"Ungültiges Zeichen im Wert von *{keyword}: {value!r}")
    try:
        value.encode("ascii")
    except UnicodeEncodeError as exc:
        raise GenerationError(f"Nicht-ASCII im Wert von *{keyword}: {value!r}") from exc
    return value


def check_keyword(keyword: str) -> str:
    """Prüft ein PPD-Options- oder Auswahl-Schlüsselwort (ASCII 33–126 ohne ``:`` und ``/``)."""
    if not keyword or len(keyword) > PPD_MAX_KEYWORD:
        raise GenerationError(f"Ungültige Länge des PPD-Schlüsselworts: {keyword!r}")
    for ch in keyword:
        if not (33 <= ord(ch) <= 126) or ch in ":/":
            raise GenerationError(f"Ungültiges Zeichen im PPD-Schlüsselwort: {keyword!r}")
    return keyword


def pc_file_name_candidate(stem: str, salt: int = 0) -> str:
    """8.3-Dateiname (Großbuchstaben) aus einem Hash des Dateinamens, z. B. ``LW1A2B3C.PPD``."""
    data = stem if salt == 0 else f"{stem}#{salt}"
    digest = hashlib.sha1(data.encode("utf-8")).hexdigest().upper()
    return f"LW{digest[:6]}.PPD"


# ---------------------------------------------------------------------------------------------
# Katalog
# ---------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Stock:
    """Etikettenformat aus dem Katalog (entspricht ``LabelStock`` in Swift)."""

    id: str
    name: str
    width_mm: float
    height_mm: float
    gap_mm: float
    tracking: str
    category: str

    @property
    def width_points(self) -> float:
        return mm_to_points(self.width_mm)

    @property
    def height_points(self) -> float:
        return mm_to_points(self.height_mm)

    @property
    def keyword(self) -> str:
        """``w<pt>h<pt>`` exakt wie ``LabelStock.ppdKeyword``."""
        return f"w{swift_round(self.width_points)}h{swift_round(self.height_points)}"

    def gap_dots(self, dpi: int) -> int:
        return mm_to_dots(self.gap_mm, dpi)

    def fits(self, print_width_mm: float, max_label_length_mm: float) -> bool:
        """Regel aus ``ModelCatalog.stocks(fitting:)``."""
        return (self.width_mm <= print_width_mm + STOCK_WIDTH_TOLERANCE_MM
                and self.height_mm <= max_label_length_mm)


@dataclass(frozen=True)
class Model:
    """Druckermodell aus dem Katalog (entspricht ``PrinterModel`` in Swift)."""

    id: str
    name: str
    family: str
    category: str
    languages: Tuple[str, ...]
    default_language: str
    resolutions: Tuple[int, ...]
    print_width_mm: float
    max_label_length_mm: float
    max_speed_ips: Dict[str, int]
    media_types: Tuple[str, ...]
    print_modes: Tuple[str, ...]
    ieee1284: Tuple[str, ...]
    default_stock: str
    features: Tuple[str, ...] = ()

    def max_speed(self, dpi: int) -> int:
        """Höchstgeschwindigkeit wie ``PrinterModel.maxSpeed(_:)`` (Fallback: kleinster Wert, sonst 4)."""
        if str(dpi) in self.max_speed_ips:
            return self.max_speed_ips[str(dpi)]
        if self.max_speed_ips:
            return min(self.max_speed_ips.values())
        return 4


@dataclass(frozen=True)
class Catalog:
    schema_version: int
    models: Tuple[Model, ...]
    stocks: Tuple[Stock, ...]

    def stock(self, stock_id: str) -> Optional[Stock]:
        for stock in self.stocks:
            if stock.id == stock_id:
                return stock
        return None


def _require(obj: dict, key: str, kind: type, where: str):
    if key not in obj:
        raise CatalogError(f"{where}: Feld „{key}“ fehlt")
    value = obj[key]
    if kind is float:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise CatalogError(f"{where}: Feld „{key}“ muss eine Zahl sein")
        return float(value)
    if not isinstance(value, kind) or (kind is int and isinstance(value, bool)):
        raise CatalogError(f"{where}: Feld „{key}“ hat den falschen Typ")
    return value


def _require_values(values: Sequence, allowed: Iterable[str], where: str, key: str) -> Tuple[str, ...]:
    allowed = set(allowed)
    for value in values:
        if value not in allowed:
            raise CatalogError(f"{where}: unbekannter Wert „{value}“ in „{key}“")
    return tuple(values)


def parse_catalog(data: dict) -> Catalog:
    """Prüft und übernimmt den Inhalt von ``models.json``."""
    if not isinstance(data, dict):
        raise CatalogError("Katalog: Wurzel muss ein Objekt sein")
    schema = _require(data, "schemaVersion", int, "Katalog")
    stocks: List[Stock] = []
    seen_stock_ids = set()
    for index, raw in enumerate(_require(data, "stocks", list, "Katalog")):
        where = f"stocks[{index}]"
        if not isinstance(raw, dict):
            raise CatalogError(f"{where}: muss ein Objekt sein")
        stock = Stock(
            id=_require(raw, "id", str, where),
            name=_require(raw, "name", str, where),
            width_mm=_require(raw, "widthMM", float, where),
            height_mm=_require(raw, "heightMM", float, where),
            gap_mm=float(raw.get("gapMM", 3.0)),
            tracking=str(raw.get("tracking", "gap")),
            category=str(raw.get("category", "custom")),
        )
        if stock.id in seen_stock_ids:
            raise CatalogError(f"{where}: doppelte Kennung „{stock.id}“")
        if stock.width_mm <= 0 or stock.height_mm <= 0 or stock.gap_mm < 0:
            raise CatalogError(f"{where}: ungültige Abmessungen")
        _require_values([stock.tracking], TRACKING_CUPS, where, "tracking")
        seen_stock_ids.add(stock.id)
        stocks.append(stock)

    models: List[Model] = []
    seen_model_ids = set()
    for index, raw in enumerate(_require(data, "models", list, "Katalog")):
        where = f"models[{index}]"
        if not isinstance(raw, dict):
            raise CatalogError(f"{where}: muss ein Objekt sein")
        model_id = _require(raw, "id", str, where)
        where = f"Modell „{model_id}“"
        if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", model_id):
            raise CatalogError(f"{where}: Kennung muss aus Kleinbuchstaben/Ziffern bestehen")
        if model_id in seen_model_ids or model_id.startswith("generic"):
            raise CatalogError(f"{where}: doppelte oder reservierte Kennung")
        languages = _require_values(_require(raw, "languages", list, where), LANGUAGE_CUPS, where, "languages")
        resolutions = tuple(_require(raw, "resolutions", list, where))
        if not languages or not resolutions:
            raise CatalogError(f"{where}: Sprachen und Auflösungen dürfen nicht leer sein")
        for dpi in resolutions:
            if isinstance(dpi, bool) or not isinstance(dpi, int) or dpi not in (152, 203, 300, 600):
                raise CatalogError(f"{where}: ungültige Auflösung {dpi!r}")
        default_language = _require(raw, "defaultLanguage", str, where)
        if default_language not in languages:
            raise CatalogError(f"{where}: Standardsprache „{default_language}“ fehlt in „languages“")
        speeds_raw = _require(raw, "maxSpeedIPS", dict, where)
        speeds: Dict[str, int] = {}
        for key, value in speeds_raw.items():
            if isinstance(value, bool) or not isinstance(value, int) or value < 1:
                raise CatalogError(f"{where}: ungültige Geschwindigkeit {key}={value!r}")
            speeds[str(key)] = value
        model = Model(
            id=model_id,
            name=_require(raw, "name", str, where),
            family=str(raw.get("family", "")),
            category=str(raw.get("category", "")),
            languages=languages,
            default_language=default_language,
            resolutions=resolutions,
            print_width_mm=_require(raw, "printWidthMM", float, where),
            max_label_length_mm=_require(raw, "maxLabelLengthMM", float, where),
            max_speed_ips=speeds,
            media_types=_require_values(_require(raw, "mediaTypes", list, where), MEDIA_TYPE_CUPS, where, "mediaTypes"),
            print_modes=_require_values(_require(raw, "printModes", list, where), PRINT_MODE_CUPS, where,
                                        "printModes"),
            ieee1284=tuple(str(v) for v in raw.get("ieee1284", [])),
            default_stock=_require(raw, "defaultStock", str, where),
            features=tuple(str(v) for v in raw.get("features", [])),
        )
        if model.print_width_mm <= 0 or model.max_label_length_mm <= 0:
            raise CatalogError(f"{where}: ungültige Druckbreite oder Etikettenlänge")
        if model.default_stock not in seen_stock_ids:
            raise CatalogError(f"{where}: Standardformat „{model.default_stock}“ fehlt im Katalog")
        seen_model_ids.add(model_id)
        models.append(model)
    return Catalog(schema_version=schema, models=tuple(models), stocks=tuple(stocks))


def load_catalog(path: Path = DEFAULT_CATALOG) -> Catalog:
    """Liest ``models.json``."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as exc:
        raise CatalogError(f"Katalog kann nicht gelesen werden: {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise CatalogError(f"Katalog ist kein gültiges JSON: {path}: {exc}") from exc
    return parse_catalog(data)


# ---------------------------------------------------------------------------------------------
# Ziele (eine PPD je Modell × Auflösung + generische PPDs)
# ---------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class PageSize:
    """Eine Seitengröße der PPD (Katalogformat oder zusammengeführte Duplikate)."""

    keyword: str
    stock: Stock
    merged_ids: Tuple[str, ...]      # weitere Formate mit identischem Schlüsselwort

    @property
    def text_en(self) -> str:
        return english_stock_name(self.stock)

    @property
    def text_de(self) -> str:
        return sanitize_text(self.stock.name)


@dataclass
class Target:
    """Beschreibung einer zu erzeugenden PPD."""

    model_id: str                    # Katalog-ID bzw. ``generic-zpl``
    name: str                        # Anzeigename ohne Hersteller, z. B. ``ZD421t``
    dpi: int
    languages: Tuple[str, ...]       # Rohwerte (``zpl``, ``epl``, ``cpcl``)
    default_language: str
    print_width_mm: float
    max_label_length_mm: float
    max_speed: int                   # bereits auf 1…14 begrenzt
    media_types: Tuple[str, ...]     # Rohwerte
    print_modes: Tuple[str, ...]     # Rohwerte
    default_stock: Stock
    page_sizes: Tuple[PageSize, ...]
    ieee1284_model: Optional[str]    # ``MDL:``-Wert oder ``None``
    ieee1284_names: Tuple[str, ...]  # alle IEEE-1284-Namen des Modells (für ``*Product``)
    model_number: int
    is_generic: bool
    pc_file_name: str = ""
    linerless: bool = False          # Ausstattung „linerless“ (Linerless-Modi in ZPL)

    @property
    def stem(self) -> str:
        return f"LabelWerk-{self.model_id}-{self.dpi}dpi"

    @property
    def display_name(self) -> str:
        return ascii_text(f"Zebra {self.name}")

    @property
    def nick_name(self) -> str:
        """``Zebra <Name> (<dpi> dpi) - LabelWerk`` (ASCII-Fassung von §10)."""
        return ascii_text(f"Zebra {self.name} ({self.dpi} dpi) - LabelWerk")

    @property
    def model_name(self) -> str:
        """``*ModelName`` – wie NickName, aber ohne Klammern (cupstestppd erlaubt dort nur
        Buchstaben, Ziffern, Leerzeichen und ``./-+``)."""
        text = to_ascii(f"Zebra {self.name} {self.dpi} dpi - LabelWerk")
        text = re.sub(r"[^A-Za-z0-9 ./+-]", " ", text)
        return re.sub(r"\s+", " ", text).strip()

    @property
    def short_nick_name(self) -> str:
        """Höchstens 31 Zeichen: ``Zebra <Name> (<dpi> dpi)``, sonst kürzere Varianten."""
        for candidate in (f"Zebra {self.name} ({self.dpi} dpi)", f"Zebra {self.name} {self.dpi}dpi",
                          f"{self.name} {self.dpi}dpi"):
            text = ascii_text(candidate)
            if len(text) <= SHORT_NICKNAME_MAX:
                return text
        return ascii_text(f"{self.name} {self.dpi}dpi")[:SHORT_NICKNAME_MAX].rstrip()

    @property
    def device_id(self) -> Optional[str]:
        """``*1284DeviceID`` oder ``None`` (generische PPDs)."""
        if not self.ieee1284_model:
            return None
        commands = ",".join(LANGUAGE_IEEE1284[lang] for lang in self.languages)
        return (f"MFG:{IEEE1284_MANUFACTURER};CMD:{commands};"
                f"MDL:{self.ieee1284_model};CLS:PRINTER;")

    @property
    def products(self) -> List[str]:
        """``*Product``-Werte: ``(Zebra <Name>)`` und die IEEE-1284-Namen dieser Auflösung.

        macOS ordnet Bonjour-/IPP-Drucker über den ``product``-Eintrag (z. B.
        ``(ZTC ZD421-203dpi ZPL)``) einer PPD zu; ``ZDesigner …`` (Windows-Treibernamen) und
        Namen mit fremder Auflösung werden ausgelassen.
        """
        values = [f"({self.display_name})"]
        for entry in self.ieee1284_names:
            match = re.search(r"-(\d+)dpi\b", entry, re.IGNORECASE)
            if entry.lower().startswith("zdesigner") or (match and int(match.group(1)) != self.dpi):
                continue
            text = re.sub(r"[()\"]", "", to_ascii(entry)).strip()
            if text and f"({text})" not in values:
                values.append(f"({text})")
        return values

    @property
    def max_print_width_dots(self) -> int:
        return mm_to_dots(self.print_width_mm, self.dpi)

    @property
    def default_gap_dots(self) -> int:
        return self.default_stock.gap_dots(self.dpi)

    @property
    def effective_print_modes(self) -> Tuple[str, ...]:
        """Druckmodi, die der Filter in einer Sprache des Modells ausdrücken kann.

        ZPL kennt alle Modi (``^MM``) und – bei Modellen mit Linerless-Ausstattung – die fünf
        Linerless-Modi (SGD ``media.printmode``); ohne ZPL bleiben nur die EPL2-Modi übrig.
        Reihenfolge wie ``PRINT_MODE_CUPS`` (Windows-Dialog).
        """
        if "zpl" in self.languages:
            modes = set(self.print_modes) | (set(LINERLESS_PRINT_MODES) if self.linerless else set())
        else:
            modes = {m for m in self.print_modes if m in EPL_PRINT_MODES}
        return tuple(m for m in PRINT_MODE_CUPS if m in modes)

    def supports_option(self, option: str) -> bool:
        """Wird die Option von mindestens einer Sprache des Modells ausgewertet?"""
        if not set(OPTION_LANGUAGES[option]) & set(self.languages):
            return False
        if option == OPT_CUT_EVERY:
            return any(mode in CUTTING_PRINT_MODES for mode in self.print_modes)
        if option == OPT_PRINT_MODE:
            return bool(self.effective_print_modes)
        return True

    def validate(self) -> None:
        """Prüft alle aus dem Katalog abgeleiteten Texte dieser PPD, bevor etwas ausgegeben wird.

        ``build_targets`` ruft das für jedes Ziel auf. Datenfehler – etwa ein Modellname, der
        sich nicht in ASCII umwandeln lässt (``Zebra 斑马``), ein IEEE-1284-Name mit
        Anführungszeichen oder ein Format ohne Namen – führen so in jedem Modus (auch
        ``--list``) früh und einheitlich zu einem ``CatalogError`` (Exit-Status 2) statt erst
        beim Schreiben oder als Traceback.
        """
        try:
            check_attribute_value("NickName", self.nick_name)
            check_attribute_value("ShortNickName", self.short_nick_name)
            check_attribute_value("ModelName", self.model_name)
            for product in self.products:            # enthält ``(<display_name>)``
                check_attribute_value("Product", product)
            if self.device_id is not None:
                check_attribute_value("1284DeviceID", self.device_id)
        except GenerationError as exc:
            raise CatalogError(f"{self.stem}: {exc}") from exc
        for page in self.page_sizes:
            try:
                _ = (page.text_en, page.text_de)
            except GenerationError as exc:
                raise CatalogError(f"{self.stem}: Format „{page.stock.id}“: {exc}") from exc


def select_ieee1284_model(entries: Sequence[str], dpi: int) -> Optional[str]:
    """Wählt den ``MDL:``-Wert für eine Auflösung.

    Reihenfolge: (1) ``ZTC …``-Eintrag mit passender Auflösung (``-203dpi``), (2) erster
    ``ZTC …``-Eintrag ohne Auflösungsangabe, (3) erster sonstige Eintrag ohne fremde Auflösung
    (``ZDesigner …`` sind Windows-Treibernamen und werden übersprungen), (4) erster Eintrag.
    Damit ordnet macOS einen „ZTC ZD421-300dpi ZPL“ automatisch der 300-dpi-PPD zu.
    """
    if not entries:
        return None
    dpi_pattern = re.compile(r"-(\d+)dpi\b", re.IGNORECASE)

    def resolution_of(entry: str) -> Optional[int]:
        match = dpi_pattern.search(entry)
        return int(match.group(1)) if match else None

    ztc = [e for e in entries if e.upper().startswith("ZTC ")]
    for entry in ztc:
        if resolution_of(entry) == dpi:
            return entry
    for entry in ztc:
        if resolution_of(entry) is None:
            return entry
    for entry in entries:
        if not entry.lower().startswith("zdesigner") and resolution_of(entry) in (None, dpi):
            return entry
    return entries[0]


def english_stock_name(stock: Stock) -> str:
    """Englischer ASCII-Anzeigename eines Formats, abgeleitet aus dem deutschen Namen.

    ``4 × 6 Zoll (Versand)`` → ``4 x 6 in (Shipping)``; ``2,25 × 1,25 Zoll`` → ``2.25 x 1.25 in``.
    Bleiben Zeichen außerhalb von ASCII übrig, wird ``<Breite> x <Höhe> mm`` verwendet.
    """
    text = re.sub(r"(\d),(\d)", r"\1.\2", stock.name)
    for german, english in STOCK_PHRASES_EN:
        text = re.sub(r"\b" + re.escape(german) + r"\b", english, text)
    text = text.replace("×", "x")
    try:
        text.encode("ascii")
    except UnicodeEncodeError:
        text = f"{format_number(stock.width_mm, 1)} x {format_number(stock.height_mm, 1)} mm"
    return sanitize_text(text)


def page_sizes_for(catalog: Catalog, print_width_mm: float, max_label_length_mm: float,
                   default_stock: Stock) -> Tuple[PageSize, ...]:
    """Alle passenden Katalogformate (plus immer das Standardformat) in Katalogreihenfolge.

    Formate mit gleichem Schlüsselwort ``w<pt>h<pt>`` (gleiche Größe auf 1 pt genau) werden
    zusammengeführt; das Standardformat gewinnt, sonst das erste im Katalog.
    """
    order: List[str] = []
    chosen: Dict[str, Stock] = {}
    merged: Dict[str, List[str]] = {}
    for stock in catalog.stocks:
        if stock.id != default_stock.id and not stock.fits(print_width_mm, max_label_length_mm):
            continue
        keyword = check_keyword(stock.keyword)
        if keyword not in chosen:
            order.append(keyword)
            chosen[keyword] = stock
            merged[keyword] = []
        elif stock.id == default_stock.id:
            merged[keyword].append(chosen[keyword].id)
            chosen[keyword] = stock
        else:
            merged[keyword].append(stock.id)
    return tuple(PageSize(keyword=k, stock=chosen[k], merged_ids=tuple(merged[k])) for k in order)


def build_targets(catalog: Catalog) -> List[Target]:
    """Alle PPD-Ziele in kanonischer Reihenfolge (Katalogreihenfolge, dann generisch).

    Jedes Ziel wird mit ``Target.validate`` geprüft; Datenfehler lösen ``CatalogError`` aus.
    """
    targets: List[Target] = []
    for index, model in enumerate(catalog.models):
        default_stock = catalog.stock(model.default_stock)
        assert default_stock is not None  # von parse_catalog geprüft
        for dpi in sorted(set(model.resolutions)):
            targets.append(Target(
                model_id=model.id,
                name=model.name,
                dpi=dpi,
                languages=model.languages,
                default_language=model.default_language,
                print_width_mm=model.print_width_mm,
                max_label_length_mm=model.max_label_length_mm,
                max_speed=max(1, min(model.max_speed(dpi), MAX_SPEED_IPS)),
                media_types=model.media_types,
                print_modes=model.print_modes,
                default_stock=default_stock,
                page_sizes=page_sizes_for(catalog, model.print_width_mm, model.max_label_length_mm, default_stock),
                ieee1284_model=select_ieee1284_model(model.ieee1284, dpi),
                ieee1284_names=model.ieee1284,
                model_number=index + 1,
                is_generic=False,
                linerless=LINERLESS_FEATURE in model.features,
            ))
    for index, (language, dpi) in enumerate(GENERIC_TARGETS):
        targets.append(build_generic_target(catalog, language, dpi, GENERIC_MODEL_NUMBER_BASE + index + 1))
    for target in targets:
        target.validate()
    assign_pc_file_names(targets)
    return targets


def build_generic_target(catalog: Catalog, language: str, dpi: int, model_number: int) -> Target:
    """Generische PPD: Vereinigung der Fähigkeiten aller Katalogmodelle der Sprache.

    Druckbreite und Etikettenlänge sind das Maximum aller Modelle der Sprache (ZPL: 216 mm,
    sodass jeder Drucker passt); Geschwindigkeit, Medientypen und Druckmodi stammen von den
    Modellen mit Sprache *und* Auflösung (sonst von allen Modellen der Sprache).
    """
    with_language = [m for m in catalog.models if language in m.languages]
    with_dpi = [m for m in with_language if dpi in m.resolutions] or with_language
    if with_language:
        width = max(m.print_width_mm for m in with_language)
        length = max(m.max_label_length_mm for m in with_language)
        speed = max(m.max_speed(dpi) for m in with_dpi)
    else:
        width = GENERIC_FALLBACK["print_width_mm"]
        length = GENERIC_FALLBACK["max_label_length_mm"]
        speed = GENERIC_FALLBACK["max_speed"]
    media = tuple(v for v in MEDIA_TYPE_CUPS if any(v in m.media_types for m in with_dpi)) or tuple(MEDIA_TYPE_CUPS)
    modes = tuple(v for v in PRINT_MODE_CUPS if any(v in m.print_modes for m in with_dpi)) or ("tearOff",)
    linerless = any(LINERLESS_FEATURE in m.features for m in with_dpi)

    # Standardformat: häufigstes Standardformat der Modelle (Gleichstand: Katalogreihenfolge),
    # ohne Modelle der Sprache 4 × 6 Zoll bzw. das erste passende Format.
    if not catalog.stocks:
        raise CatalogError("Katalog enthält keine Etikettenformate")
    counts: Dict[str, int] = {}
    for model in with_language:
        counts[model.default_stock] = counts.get(model.default_stock, 0) + 1
    if counts:
        position = {s.id: i for i, s in enumerate(catalog.stocks)}
        best = max(counts, key=lambda stock_id: (counts[stock_id], -position[stock_id]))
        default_stock = catalog.stock(best)
    else:
        fitting = [s for s in catalog.stocks if s.fits(width, length)]
        preferred = catalog.stock("w4h6in")
        default_stock = preferred if preferred in fitting else (fitting or list(catalog.stocks))[0]
    assert default_stock is not None

    return Target(
        model_id=f"generic-{language}",
        name=GENERIC_NAMES[language],
        dpi=dpi,
        languages=(language,),
        default_language=language,
        print_width_mm=width,
        max_label_length_mm=length,
        max_speed=max(1, min(speed, MAX_SPEED_IPS)),
        media_types=media,
        print_modes=modes,
        default_stock=default_stock,
        page_sizes=page_sizes_for(catalog, width, length, default_stock),
        ieee1284_model=None,
        ieee1284_names=(),
        model_number=model_number,
        is_generic=True,
        linerless=linerless,
    )


def assign_pc_file_names(targets: List[Target]) -> None:
    """Vergibt eindeutige 8.3-Namen (``*PCFileName``) – stabil, unabhängig von ``--model``."""
    used: Dict[str, str] = {}
    for target in sorted(targets, key=lambda t: t.stem):
        salt = 0
        while True:
            name = pc_file_name_candidate(target.stem, salt)
            if name not in used:
                break
            salt += 1
        used[name] = target.stem
        target.pc_file_name = name


# ---------------------------------------------------------------------------------------------
# Optionen
# ---------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Choice:
    key: str
    text_en: str
    text_de: str
    code: str = ""


@dataclass
class UIOption:
    keyword: str
    text_en: str
    text_de: str
    ui: str                          # PickOne | Boolean
    default: str
    choices: List[Choice] = field(default_factory=list)
    order: int = 20
    section: str = "AnySetup"


def _signed(value: int) -> str:
    return f"+{value}" if value > 0 else str(value)


def _offset_choices(values: Iterable[int], dpi: int) -> List[Choice]:
    """Versatz-Auswahl in Punkten, angezeigt in Millimetern (wie der Windows-Treiber) mit Punkten."""
    choices = [Choice(DEFAULT_CHOICE, *DEFAULT_TEXT)]
    for value in values:
        if value == 0:
            choices.append(Choice("0", "0 mm (no offset)", "0 mm (kein Versatz)"))
            continue
        mm = value * 25.4 / dpi
        choices.append(Choice(
            str(value),
            f"{'+' if mm > 0 else ''}{mm:.1f} mm ({_signed(value)} dots)",
            f"{'+' if mm > 0 else ''}{format_german_decimal(mm)} mm ({_signed(value)} Punkte)",
        ))
    return choices


def mm_choice_dots(values_mm: Iterable[int], dpi: int, low: int, high: int) -> List[Tuple[int, int]]:
    """(mm, Punkte) je mm-Wert für die Auflösung; Punkte außerhalb von ``low…high`` und doppelte
    Punktwerte entfallen (Reihenfolge der mm-Werte)."""
    result: List[Tuple[int, int]] = []
    seen = set()
    for mm in values_mm:
        dots = mm_to_dots(float(mm), dpi)
        if low <= dots <= high and dots not in seen:
            seen.add(dots)
            result.append((mm, dots))
    return result


def _mm_dot_choices(values_mm: Iterable[int], dpi: int, low: int, high: int, zero_text: Tuple[str, str],
                    signed: bool) -> List[Choice]:
    """Auswahl in Punkten, beschriftet mit Millimetern (``+5 mm (40 Punkte)`` bzw. ``5 mm (40 Punkte)``)."""
    choices = []
    for mm, dots in mm_choice_dots(values_mm, dpi, low, high):
        if dots == 0:
            choices.append(Choice("0", *zero_text))
            continue
        label = _signed(mm) if signed else str(mm)
        choices.append(Choice(str(dots), f"{label} mm ({dots} dots)", f"{label} mm ({dots} Punkte)"))
    return choices


def _mapped_choices(values: Iterable[str], texts: Dict[str, Tuple[str, str]], with_default: bool) -> List[Choice]:
    choices = [Choice(DEFAULT_CHOICE, *DEFAULT_TEXT)] if with_default else []
    for value in values:
        choices.append(Choice(value, *texts[value]))
    return choices


def build_options(target: Target) -> List[UIOption]:
    """Alle ``lw*``-Optionen der PPD (nach §9, auf das Modell eingeschränkt)."""
    options: Dict[str, UIOption] = {}

    def add(keyword: str, choices: List[Choice], default: str, ui: str = "PickOne") -> None:
        if not target.supports_option(keyword):
            return
        _, text_en, text_de = OPTION_TEXTS[keyword]
        options[keyword] = UIOption(keyword, text_en, text_de, ui, default, choices)

    languages = [LANGUAGE_CUPS[lang] for lang in LANGUAGE_CUPS if lang in target.languages]
    add(OPT_LANGUAGE, _mapped_choices(languages, LANGUAGE_TEXTS, False), LANGUAGE_CUPS[target.default_language])

    darkness = [Choice(DEFAULT_CHOICE, *DEFAULT_TEXT)]
    for value in DARKNESS_VALUES:
        note = {1: (" (lightest)", " (am hellsten)"), 30: (" (darkest)", " (am dunkelsten)")}.get(value, ("", ""))
        darkness.append(Choice(str(value), f"{value}{note[0]}", f"{value}{note[1]}"))
    add(OPT_DARKNESS, darkness, DEFAULT_CHOICE)

    # Geschwindigkeit wie im Windows-Treiber in mm/s (51, 76, 102 … = 2, 3, 4 … Zoll/s).
    speeds = [Choice(DEFAULT_CHOICE, *DEFAULT_TEXT)]
    for value in ppd_speeds(target.max_speed):
        mm_s = swift_round(value * 25.4)
        speeds.append(Choice(str(value), f"{mm_s} mm/s ({value} ips)", f"{mm_s} mm/s ({value} Zoll/s)"))
    add(OPT_SPEED, speeds, DEFAULT_CHOICE)

    modes = [PRINT_MODE_CUPS[m] for m in PRINT_MODE_CUPS if m in target.effective_print_modes]
    add(OPT_PRINT_MODE, _mapped_choices(modes, PRINT_MODE_TEXTS, True), DEFAULT_CHOICE)

    cut = []
    for value in CUT_EVERY_VALUES:
        if value == 0:
            cut.append(Choice("0", "End of Job Only", "Nur am Auftragsende"))
        elif value == 1:
            cut.append(Choice("1", "1 Label", "1 Etikett"))
        else:
            cut.append(Choice(str(value), f"{value} Labels", f"{value} Etiketten"))
    add(OPT_CUT_EVERY, cut, "0")

    pause = []
    for value in PAUSE_EVERY_VALUES:
        if value == 0:
            pause.append(Choice("0", "No Pause", "Keine Pause"))
        elif value == 1:
            pause.append(Choice("1", "After Every Label", "Nach jedem Etikett"))
        else:
            pause.append(Choice(str(value), f"After Every {value} Labels", f"Nach je {value} Etiketten"))
    add(OPT_PAUSE_EVERY, pause, "0")

    add(OPT_BACKFEED, _mapped_choices(BACKFEED_VALUES, BACKFEED_TEXTS, True), DEFAULT_CHOICE)

    media = [MEDIA_TYPE_CUPS[m] for m in MEDIA_TYPE_CUPS if m in target.media_types]
    add(OPT_MEDIA_TYPE, _mapped_choices(media, MEDIA_TYPE_TEXTS, True), DEFAULT_CHOICE)
    add(OPT_TRACKING, _mapped_choices(TRACKING_VALUES, TRACKING_TEXTS, True), DEFAULT_CHOICE)
    add(OPT_MARK_OFFSET, [Choice(DEFAULT_CHOICE, *DEFAULT_TEXT)]
        + _mm_dot_choices(MARK_OFFSET_MM, target.dpi, *MARK_OFFSET_RANGE, ("0 mm", "0 mm"), signed=True),
        DEFAULT_CHOICE)
    add(OPT_ROTATION, _mapped_choices(ROTATION_VALUES, ROTATION_TEXTS, False), "0")
    add(OPT_STOP_OFFSET, _mm_dot_choices(STOP_OFFSET_MM, target.dpi, 0, 32000,
                                         ("0 mm (no offset)", "0 mm (kein Versatz)"), signed=False), "0")

    add(OPT_LABEL_TOP, _offset_choices(LABEL_TOP_VALUES, target.dpi), DEFAULT_CHOICE)
    add(OPT_LABEL_LEFT, _offset_choices(LABEL_LEFT_VALUES, target.dpi), DEFAULT_CHOICE)
    add(OPT_TEAR_OFF, _offset_choices(TEAR_OFF_VALUES, target.dpi), DEFAULT_CHOICE)

    add(OPT_CONTROL_CHARS, _mapped_choices(CONTROL_CHARS_VALUES, CONTROL_CHARS_TEXTS, False), "Standard")
    add(OPT_RTC, _mapped_choices(RTC_VALUES, RTC_TEXTS, True), DEFAULT_CHOICE)
    delays = []
    for value in CANCEL_DELAY_VALUES:
        note = (" (default)", " (Standard)") if value == 1000 else ("", "")
        delays.append(Choice(str(value), f"{value} ms{note[0]}", f"{value} ms{note[1]}"))
    add(OPT_CANCEL_DELAY, delays, "1000")
    for keyword in (OPT_POWER_UP, OPT_HEAD_CLOSE):
        add(keyword, _mapped_choices(MEDIA_ACTION_VALUES, MEDIA_ACTION_TEXTS, True), DEFAULT_CHOICE)

    for keyword in BOOLEAN_OPTIONS:
        on = BOOLEAN_TRUE_TEXTS.get(keyword, BOOLEAN_TEXTS["True"])
        add(keyword, [Choice("False", *BOOLEAN_TEXTS["False"]), Choice("True", *on)], "False", ui="Boolean")

    add(OPT_DITHER, _mapped_choices(DITHER_VALUES, DITHER_TEXTS, False), "Threshold")
    threshold = []
    for value in THRESHOLD_VALUES:
        note = THRESHOLD_NOTES.get(value)
        threshold.append(Choice(str(value), f"{value} ({note[0]})" if note else str(value),
                                f"{value} ({note[1]})" if note else str(value)))
    add(OPT_THRESHOLD, threshold, "128")
    add(OPT_COMPRESSION, _mapped_choices(COMPRESSION_VALUES, COMPRESSION_TEXTS, False), "Z64")
    add(OPT_FIT_TO_LABEL, _mapped_choices(FIT_TO_LABEL_VALUES, FIT_TO_LABEL_TEXTS, False), "Auto")

    ordered = [options[k] for k in OPTION_ORDER if k in options]
    for index, option in enumerate(ordered):
        option.order = 20 + index
    return ordered


# ---------------------------------------------------------------------------------------------
# PPD-Ausgabe
# ---------------------------------------------------------------------------------------------


class PPDWriter:
    """Sammelt PPD-Zeilen und prüft Zeilenlänge und Kodierung."""

    def __init__(self) -> None:
        self._lines: List[str] = []

    def raw(self, line: str) -> None:
        self._lines.append(line)

    def blank(self) -> None:
        if self._lines and self._lines[-1] != "":
            self._lines.append("")

    def comment(self, text: str = "") -> None:
        """``*% Kommentar`` (ASCII, eine Zeile)."""
        if not text:
            self._lines.append("*%")
            return
        text = to_ascii(text)
        if "\n" in text or "\r" in text or len(text) > PPD_MAX_LINE - 3:
            raise GenerationError(f"Ungültiger Kommentar: {text!r}")
        self._lines.append("*% " + text)

    def attr(self, keyword: str, value: str) -> None:
        """``*keyword: "value"`` (Wert ASCII, ohne Anführungszeichen)."""
        self._lines.append(f'*{keyword}: "{check_attribute_value(keyword, value)}"')

    def translation(self, language: str, keyword: str, spec: str, text: str) -> None:
        """``*ll.keyword spec/Text: ""`` – Übersetzung in UTF-8."""
        self._lines.append(f'*{language}.{keyword} {check_keyword(spec)}/{sanitize_text(text)}: ""')

    def render(self) -> bytes:
        text = "\n".join(self._lines).rstrip("\n") + "\n"
        data = text.encode("utf-8")
        for number, line in enumerate(data.split(b"\n"), start=1):
            if len(line) > PPD_MAX_LINE:
                raise GenerationError(f"Zeile {number} ist länger als {PPD_MAX_LINE} Bytes")
            if not line.startswith(b"*") and line.strip():
                raise GenerationError(f"Zeile {number} beginnt nicht mit „*“")
            # Nur Übersetzungszeilen (*ll.…) dürfen Nicht-ASCII enthalten.
            if any(b > 0x7E for b in line) and not re.match(rb"^\*[a-z]{2}(_[A-Z]{2})?\.", line):
                raise GenerationError(f"Zeile {number}: Nicht-ASCII außerhalb einer Übersetzung")
        return data


def _emit_option(w: PPDWriter, option: UIOption) -> None:
    keyword = check_keyword(option.keyword)
    w.raw(f"*OpenUI *{keyword}/{ascii_text(option.text_en)}: {option.ui}")
    w.raw(f"*OrderDependency: {option.order} {option.section} *{keyword}")
    if option.default not in {c.key for c in option.choices}:
        raise GenerationError(f"Standardwert {option.default} fehlt in {keyword}")
    w.raw(f"*Default{keyword}: {option.default}")
    seen = set()
    for choice in option.choices:
        key = check_keyword(choice.key)
        if key in seen:
            raise GenerationError(f"Doppelte Auswahl {key} in {keyword}")
        seen.add(key)
        w.raw(f'*{keyword} {key}/{ascii_text(choice.text_en)}: "{choice.code}"')
    w.raw(f"*CloseUI: *{keyword}")
    w.translation("de", "Translation", keyword, option.text_de)
    for choice in option.choices:
        w.translation("de", keyword, choice.key, choice.text_de)


def throughput(target: Target) -> int:
    """Etiketten pro Minute mit Höchstgeschwindigkeit und Standardformat (``*Throughput``)."""
    stock = target.default_stock
    length_mm = stock.height_mm + stock.gap_mm
    return max(1, int(target.max_speed * 25.4 * 60.0 / length_mm))


def render_ppd(target: Target, file_version: str = DEFAULT_FILE_VERSION) -> bytes:
    """Erzeugt den vollständigen PPD-Inhalt (ASCII + UTF-8-Übersetzungen)."""
    if not re.fullmatch(r"[0-9A-Za-z.+-]+", file_version):
        raise GenerationError(f"Ungültige Dateiversion: {file_version!r}")
    w = PPDWriter()
    w.raw('*PPD-Adobe: "4.3"')
    w.comment("=" * 72)
    w.comment(f"LabelWerk - PPD fuer {target.display_name} ({target.dpi} dpi)")
    w.comment("Automatisch erzeugt von Driver/ppd/generate_ppds.py aus Catalog/models.json.")
    w.comment("Nicht von Hand bearbeiten - Aenderungen gehen beim naechsten Erzeugen verloren.")
    w.comment("Filter: rastertolabelwerk (CUPS-Raster, 8 Bit Graustufen) -> ZPL II / EPL2 / CPCL.")
    w.comment("Optionen und Werte: ARCHITECTURE.md Abschnitt 9. Gruppen wie der Windows-Treiber.")
    w.comment("Freie Werte (lwStartCmd, lwEndCmd, lwLabelStartCmd, lwLabelEndCmd, lwFormatPrefix,")
    w.comment("lwControlPrefix, lwDelimiter, lwLabelWidth, lwLabelHeight) setzt die App je Warteschlange")
    w.comment("per 'lpadmin -o name-default=...'.")
    w.comment("Zebra ist eine Marke der Zebra Technologies Corp.; LabelWerk ist unabhaengig.")
    w.comment("=" * 72)
    w.attr("FormatVersion", "4.3")
    w.attr("FileVersion", file_version)
    w.raw("*LanguageVersion: English")
    w.raw("*LanguageEncoding: ISOLatin1")
    w.attr("PCFileName", target.pc_file_name)
    for product in target.products:
        w.attr("Product", product)
    w.attr("Manufacturer", "Zebra")
    w.attr("ModelName", target.model_name)
    w.attr("ShortNickName", target.short_nick_name)
    w.attr("NickName", target.nick_name)
    w.attr("PSVersion", "(3010.000) 0")
    w.attr("LanguageLevel", "3")
    w.raw("*ColorDevice: False")
    w.raw("*DefaultColorSpace: Gray")
    w.raw("*FileSystem: False")
    w.attr("Throughput", str(throughput(target)))
    w.raw("*LandscapeOrientation: Plus90")
    w.raw("*TTRasterizer: Type42")
    if target.device_id:
        w.attr("1284DeviceID", target.device_id)
    w.blank()
    w.comment("CUPS")
    w.raw(f"*cupsVersion: {CUPS_VERSION}")
    w.raw(f"*cupsModelNumber: {target.model_number}")
    w.raw("*cupsManualCopies: False")
    for line in CUPS_FILTERS:
        w.attr("cupsFilter", line)
    w.attr("cupsCommands", CUPS_COMMANDS)
    w.raw("*cupsSNMPSupplies: False")
    w.attr("cupsLanguages", "de")
    w.attr("APPrinterIconPath", ICON_PATH)
    w.attr("APPrinterUtilityPath", UTILITY_PATH)
    w.blank()
    w.comment("LabelWerk-Attribute fuer den Filter (ARCHITECTURE.md Abschnitt 9)")
    w.attr("lwModel", target.model_id)
    w.attr("lwMaxPrintWidthDots", str(target.max_print_width_dots))
    w.attr("lwDefaultGapDots", str(target.default_gap_dots))

    options = build_options(target)
    for group, text_en, text_de in GROUPS:
        members = [o for o in options if OPTION_TEXTS[o.keyword][0] == group]
        if not members and group not in (PAGE_GROUP, DEVICE_GROUP):
            continue
        w.blank()
        w.raw(f"*OpenGroup: {group}/{text_en}")
        if group == PAGE_GROUP:
            _emit_page_sizes(w, target)
        for option in members:
            w.blank()
            _emit_option(w, option)
        if group == DEVICE_GROUP:
            _emit_device_options(w, target)
        w.blank()
        w.raw(f"*CloseGroup: {group}")
        w.translation("de", "Translation", group, text_de)

    w.blank()
    w.comment("Ende der PPD")
    return w.render()


def _emit_page_sizes(w: PPDWriter, target: Target) -> None:
    """Seitengrößen und eigene Größe (Gruppe „Seite einrichten“)."""
    default_keyword = next(p.keyword for p in target.page_sizes if p.stock.id == target.default_stock.id)

    def page_code(size: PageSize) -> str:
        return (f"<</PageSize[{format_number(size.stock.width_points)} "
                f"{format_number(size.stock.height_points)}]/ImagingBBox null>>setpagedevice")

    for keyword in ("PageSize", "PageRegion"):
        text_en, text_de = STANDARD_TEXTS[keyword]
        w.blank()
        w.raw(f"*OpenUI *{keyword}/{text_en}: PickOne")
        w.raw(f"*OrderDependency: 10 AnySetup *{keyword}")
        w.raw(f"*Default{keyword}: {default_keyword}")
        for size in target.page_sizes:
            w.raw(f'*{keyword} {size.keyword}/{size.text_en}: "{page_code(size)}"')
        w.raw(f"*CloseUI: *{keyword}")
        w.translation("de", "Translation", keyword, text_de)
        for size in target.page_sizes:
            w.translation("de", keyword, size.keyword, size.text_de)

    w.blank()
    w.raw(f"*DefaultImageableArea: {default_keyword}")
    for size in target.page_sizes:
        w.raw(f'*ImageableArea {size.keyword}/{size.text_en}: "0 0 '
              f'{format_number(size.stock.width_points)} {format_number(size.stock.height_points)}"')
    w.raw(f"*DefaultPaperDimension: {default_keyword}")
    for size in target.page_sizes:
        w.raw(f'*PaperDimension {size.keyword}/{size.text_en}: '
              f'"{format_number(size.stock.width_points)} {format_number(size.stock.height_points)}"')

    max_width = mm_to_points(target.print_width_mm + STOCK_WIDTH_TOLERANCE_MM)
    max_height = mm_to_points(target.max_label_length_mm)
    w.blank()
    w.raw("*VariablePaperSize: True")
    w.attr("MaxMediaWidth", format_number(max_width))
    w.attr("MaxMediaHeight", format_number(max_height))
    w.raw("*HWMargins: 0 0 0 0")
    w.raw(f'*CustomPageSize True/{CUSTOM_SIZE_TEXT[0]}: '
          f'"pop pop pop <</PageSize[5 -2 roll]/ImagingBBox null>>setpagedevice"')
    w.translation("de", "CustomPageSize", "True", CUSTOM_SIZE_TEXT[1])
    limits = {
        "Width": (CUSTOM_MIN_WIDTH_PT, max_width),
        "Height": (CUSTOM_MIN_HEIGHT_PT, max_height),
        "WidthOffset": (0.0, 0.0),
        "HeightOffset": (0.0, 0.0),
        "Orientation": (0.0, 0.0),
    }
    for name, order, kind, _ in CUSTOM_PARAM_TEXTS:
        low, high = limits[name]
        w.raw(f"*ParamCustomPageSize {name}: {order} {kind} {format_number(low)} {format_number(high)}")
    for name, _, _, text_de in CUSTOM_PARAM_TEXTS:
        w.translation("de", "ParamCustomPageSize", name, text_de)


def _emit_device_options(w: PPDWriter, target: Target) -> None:
    """Auflösung und Farbmodell (Gruppe „Erweitert“; je eine feste Wahl)."""
    dpmm = {152: 6, 203: 8, 300: 12, 600: 24}.get(target.dpi, mm_to_dots(1.0, target.dpi))
    text_en, text_de = STANDARD_TEXTS["Resolution"]
    w.blank()
    w.raw(f"*OpenUI *Resolution/{text_en}: PickOne")
    w.raw("*OrderDependency: 10 AnySetup *Resolution")
    w.raw(f"*DefaultResolution: {target.dpi}dpi")
    w.raw(f'*Resolution {target.dpi}dpi/{target.dpi} dpi ({dpmm} dots/mm): '
          f'"<</HWResolution[{target.dpi} {target.dpi}]>>setpagedevice"')
    w.raw("*CloseUI: *Resolution")
    w.translation("de", "Translation", "Resolution", text_de)
    w.translation("de", "Resolution", f"{target.dpi}dpi", f"{target.dpi} dpi ({dpmm} Punkte/mm)")

    text_en, text_de = STANDARD_TEXTS["ColorModel"]
    w.blank()
    w.raw(f"*OpenUI *ColorModel/{text_en}: PickOne")
    w.raw("*OrderDependency: 10 AnySetup *ColorModel")
    w.raw("*DefaultColorModel: Gray")
    w.raw(f'*ColorModel Gray/Grayscale: "{COLOR_MODEL_CODE}"')
    w.raw("*CloseUI: *ColorModel")
    w.translation("de", "Translation", "ColorModel", text_de)
    w.translation("de", "ColorModel", "Gray", "Graustufen")


# ---------------------------------------------------------------------------------------------
# Dateien schreiben, Index, Prüfung
# ---------------------------------------------------------------------------------------------


def gzip_bytes(data: bytes) -> bytes:
    """Reproduzierbares gzip (ohne Zeitstempel und Dateinamen)."""
    buffer = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buffer, compresslevel=9, mtime=0) as handle:
        handle.write(data)
    return buffer.getvalue()


def index_entry(target: Target, file_name: str) -> dict:
    return {
        "file": file_name,
        "modelId": target.model_id,
        "name": target.name,
        "dpi": target.dpi,
        "languages": list(target.languages),
        "nickName": target.nick_name,
        "ieee1284": target.device_id,
    }


PPD_FILE_PATTERN = re.compile(r"^LabelWerk-.+-\d+dpi\.ppd(\.gz)?$")


def write_outputs(targets: Sequence[Target], output: Path, use_gzip: bool, file_version: str,
                  full_run: bool) -> List[Path]:
    """Schreibt PPDs und ``index.json``; liefert die geschriebenen PPD-Pfade.

    Bei einem vollständigen Lauf werden veraltete ``LabelWerk-*.ppd[.gz]`` im Ausgabeordner
    entfernt. Mit ``--model`` bleiben andere Dateien erhalten und ``index.json`` wird ergänzt.
    """
    rendered = [(target, render_ppd(target, file_version)) for target in targets]
    output.mkdir(parents=True, exist_ok=True)
    extension = ".ppd.gz" if use_gzip else ".ppd"
    written: List[Path] = []
    entries: List[dict] = []
    for target, data in rendered:
        name = target.stem + extension
        path = output / name
        tmp = output / (name + ".tmp")
        tmp.write_bytes(gzip_bytes(data) if use_gzip else data)
        os.replace(tmp, path)
        other = output / (target.stem + (".ppd" if use_gzip else ".ppd.gz"))
        if other.exists():
            other.unlink()
        written.append(path)
        entries.append(index_entry(target, name))

    index_path = output / "index.json"
    if full_run:
        keep = {p.name for p in written}
        for existing in output.iterdir():
            if PPD_FILE_PATTERN.match(existing.name) and existing.name not in keep:
                existing.unlink()
    else:
        entries = _merge_index(index_path, entries, output)
    tmp = output / "index.json.tmp"
    tmp.write_text(json.dumps(entries, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, index_path)
    return written


def _merge_index(index_path: Path, new_entries: List[dict], output: Path) -> List[dict]:
    """Ergänzt ein vorhandenes ``index.json`` um neu erzeugte Einträge (Teil-Lauf)."""
    old: List[dict] = []
    if index_path.exists():
        try:
            loaded = json.loads(index_path.read_text(encoding="utf-8"))
            if isinstance(loaded, list):
                old = [e for e in loaded if isinstance(e, dict) and isinstance(e.get("file"), str)]
        except (OSError, json.JSONDecodeError):
            old = []
    replaced = {(e["modelId"], e["dpi"]): e for e in new_entries}
    merged: List[dict] = []
    for entry in old:
        key = (entry.get("modelId"), entry.get("dpi"))
        if key in replaced:
            merged.append(replaced.pop(key))
        elif (output / entry["file"]).exists():
            merged.append(entry)
    merged.extend(e for e in new_entries if (e["modelId"], e["dpi"]) in replaced)
    return merged


@dataclass
class CheckResult:
    path: Path
    passed: bool
    errors: List[str]
    warnings: List[str]


def find_cupstestppd() -> Optional[str]:
    return shutil.which("cupstestppd")


def cups_environment(language: str, base: Optional[Mapping[str, str]] = None) -> Dict[str, str]:
    """Umgebung, in der libcups-Programme Meldungen und PPD-Übersetzungen in ``language`` liefern.

    Ausgehend von ``base`` (Standard: ``os.environ``) werden die Variablen entfernt, die ``LANG``
    überstimmen (``LOCALE_OVERRIDE_VARIABLES``), ``LANG`` wird gesetzt und zusätzlich
    ``SOFTWARE``: Die libcups von macOS (``cupsLangGet``/``appleLangDefault`` in
    ``cups/language.c``) liest ``LANG`` nur bei gesetztem ``SOFTWARE`` und nimmt sonst die
    Systemsprache des Benutzers. Unter Linux wertet libcups ``LANG`` direkt aus; ``SOFTWARE``
    ist dort wirkungslos.
    """
    source = os.environ if base is None else base
    env = {k: v for k, v in source.items() if k not in LOCALE_OVERRIDE_VARIABLES}
    env["LANG"] = language
    env["SOFTWARE"] = CUPS_SOFTWARE
    return env


def run_cupstestppd(paths: Sequence[Path], executable: Optional[str] = None,
                    extra_args: Sequence[str] = ("-I", "filters")) -> List[CheckResult]:
    """Prüft PPDs mit ``cupstestppd`` (Standard: ``-I filters``, weil die Filterprogramme unter
    ``/Library/Printers/LabelWerk`` auf dem Build-Rechner fehlen). Jede andere Beanstandung
    zählt als Fehler; Warnungen werden mitgeliefert.

    ``cupstestppd`` läuft unabhängig von der Systemsprache englisch (``CUPSTESTPPD_LANGUAGE``),
    weil Fehler, Warnungen und das Urteil an den englischen Meldungen erkannt werden.
    """
    env = cups_environment(CUPSTESTPPD_LANGUAGE)
    executable = executable or find_cupstestppd()
    if executable is None:
        raise FileNotFoundError("cupstestppd")
    results: List[CheckResult] = []
    for path in paths:
        proc = subprocess.run([executable, *extra_args, str(path)], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, env=env, check=False)
        output = proc.stdout.decode("utf-8", "replace")
        lines = output.splitlines()
        errors = [line.strip() for line in lines if "**FAIL**" in line]
        warnings = [line.strip() for line in lines if line.strip().startswith("WARN")]
        verdict = [line for line in lines if line.startswith(f"{path}: ")]
        passed = (proc.returncode == 0 and not errors and len(verdict) == 1
                  and verdict[0].rstrip().endswith(": PASS"))
        if not passed and not errors:
            errors = [line.strip() for line in lines if line.strip()] or [f"Exit-Status {proc.returncode}"]
        results.append(CheckResult(path, passed, errors, warnings))
    return results


def print_target_list(targets: Sequence[Target], stream=sys.stdout) -> None:
    """Tabelle für ``--list``."""
    rows = [("Datei", "Modell", "dpi", "Sprachen", "NickName")]
    for t in targets:
        rows.append((t.stem, t.model_id, str(t.dpi), ",".join(t.languages), t.nick_name))
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]) - 1)]
    for row in rows:
        cells = [row[i].ljust(widths[i]) for i in range(len(widths))] + [row[-1]]
        print("  ".join(cells).rstrip(), file=stream)
    print(f"\n{len(targets)} PPD-Dateien", file=stream)


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="generate_ppds.py",
        description="Erzeugt die LabelWerk-PPD-Dateien aus Catalog/models.json.",
    )
    parser.add_argument("--output", "-o", type=Path, default=DEFAULT_OUTPUT,
                        help="Ausgabeordner (Standard: Driver/ppd/out)")
    parser.add_argument("--gzip", action="store_true", help="PPDs als .ppd.gz schreiben")
    parser.add_argument("--check", action="store_true",
                        help="erzeugte PPDs mit cupstestppd prüfen (falls vorhanden)")
    parser.add_argument("--model", metavar="ID",
                        help="nur dieses Modell (Katalog-ID oder generic-zpl/-epl/-cpcl)")
    parser.add_argument("--list", action="store_true", help="Ziele nur auflisten, nichts schreiben")
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG,
                        help="Pfad zu models.json (Standard: Catalog/models.json)")
    parser.add_argument("--file-version", default=DEFAULT_FILE_VERSION,
                        help=f"Wert für *FileVersion (Standard: {DEFAULT_FILE_VERSION})")
    parser.add_argument("--quiet", "-q", action="store_true", help="nur Fehler ausgeben")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    try:
        catalog = load_catalog(args.catalog)
        targets = build_targets(catalog)
    except (CatalogError, GenerationError) as exc:
        print(f"Fehler: {exc}", file=sys.stderr)
        return 2

    if args.model:
        wanted = args.model.strip().lower()
        selected = [t for t in targets if t.model_id == wanted]
        if not selected:
            known = ", ".join(sorted({t.model_id for t in targets}))
            print(f"Fehler: unbekanntes Modell „{args.model}“. Bekannt: {known}", file=sys.stderr)
            return 2
    else:
        selected = targets

    if args.list:
        try:
            print_target_list(selected)
        except (CatalogError, GenerationError) as exc:   # von build_targets bereits geprüft
            print(f"Fehler: {exc}", file=sys.stderr)
            return 2
        return 0

    try:
        written = write_outputs(selected, args.output, args.gzip, args.file_version,
                                full_run=not args.model)
    except (GenerationError, OSError) as exc:
        print(f"Fehler: {exc}", file=sys.stderr)
        return 2
    if not args.quiet:
        print(f"{len(written)} PPD-Dateien nach {args.output} geschrieben (+ index.json).")

    if args.check:
        executable = find_cupstestppd()
        if executable is None:
            print("Hinweis: cupstestppd nicht gefunden – Prüfung übersprungen.", file=sys.stderr)
            return 0
        results = run_cupstestppd(written, executable)
        failed = [r for r in results if not r.passed]
        warnings = sum(len(r.warnings) for r in results)
        for result in failed:
            print(f"FEHLER {result.path.name}:", file=sys.stderr)
            for line in result.errors:
                print(f"    {line}", file=sys.stderr)
        if not args.quiet:
            print(f"cupstestppd: {len(results) - len(failed)} von {len(results)} bestanden, "
                  f"{warnings} Warnungen (erwartet: Hinweise auf Adobe-Standardnamen).")
        if failed:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
