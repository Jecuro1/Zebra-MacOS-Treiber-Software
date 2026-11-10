# -*- coding: utf-8 -*-
"""Tests für den PPD-Generator ``Driver/ppd/generate_ppds.py`` (unittest, nur Standardbibliothek).

Aufruf aus der Repository-Wurzel::

    python3 -m unittest discover -s Driver/ppd/tests -v

Geprüft werden u. a.: eine PPD je Modell × Auflösung (+ generische PPDs), eindeutige
Schlüsselwörter, gültige Standardwerte, Geschwindigkeiten bis zum Modellmaximum, vollständige
deutsche Übersetzungen, der gzip-Modus, ``index.json`` und die exakte Übereinstimmung aller
``lw*``-Optionen mit ARCHITECTURE.md §9. Sind ``cupstestppd`` bzw. ein C-Compiler mit
libcups-Headern vorhanden, werden alle PPDs zusätzlich von CUPS selbst geprüft und geparst
(``tests/ppdcheck.c``: Optionen, Lokalisierung via ``ppdLocalize``, Rasterkopf via
``cupsRasterInterpretPPD``).
"""

from __future__ import annotations

import gzip
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
PPD_DIR = HERE.parent
REPO = PPD_DIR.parent.parent
SCRIPT = PPD_DIR / "generate_ppds.py"
ARCHITECTURE = REPO / "ARCHITECTURE.md"
PRINT_SETTINGS_SWIFT = REPO / "Sources" / "LabelWerkCore" / "Types" / "PrintSettings.swift"
PPDCHECK_SOURCE = HERE / "ppdcheck.c"


def _load_generator():
    spec = importlib.util.spec_from_file_location("generate_ppds", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["generate_ppds"] = module   # für dataclasses mit verzögerten Annotationen
    spec.loader.exec_module(module)
    return module


gen = _load_generator()

# ---------------------------------------------------------------------------------------------
# Einfacher PPD-Parser für die Tests (unabhängig vom Generator)
# ---------------------------------------------------------------------------------------------

LINE_RE = re.compile(
    r'^\*(?P<kw>[^\s:]+)(?:\s+(?P<spec>[^/:]+?))?(?:/(?P<text>[^:]*))?:\s*(?P<value>.*)$')


@dataclass
class ParsedOption:
    keyword: str
    text: str
    ui: str
    group: Optional[str]
    default: Optional[str] = None
    order: Optional[Tuple[int, str]] = None
    choices: Dict[str, str] = field(default_factory=dict)       # Wahl → englischer Text
    codes: Dict[str, str] = field(default_factory=dict)


@dataclass
class ParsedPPD:
    path: Path
    data: bytes
    attrs: Dict[str, List[Tuple[Optional[str], Optional[str], str]]]
    options: Dict[str, ParsedOption]
    groups: Dict[str, str]
    translations: Dict[Tuple[str, str, str], str]               # (Sprache, Schlüssel, Spec) → Text
    choice_lines: List[Tuple[str, str]]                         # (Option, Wahl) in Dateireihenfolge

    def attr(self, name: str) -> Optional[str]:
        values = self.attrs.get(name)
        return values[0][2] if values else None

    def attr_values(self, name: str) -> List[str]:
        return [v for _, _, v in self.attrs.get(name, [])]

    def specs(self, name: str) -> List[str]:
        return [s for s, _, _ in self.attrs.get(name, []) if s is not None]


def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    return value


def parse_ppd(path: Path) -> ParsedPPD:
    data = path.read_bytes()
    if path.suffix == ".gz":
        data = gzip.decompress(data)
    text = data.decode("utf-8")
    attrs: Dict[str, List[Tuple[Optional[str], Optional[str], str]]] = {}
    options: Dict[str, ParsedOption] = {}
    groups: Dict[str, str] = {}
    translations: Dict[Tuple[str, str, str], str] = {}
    choice_lines: List[Tuple[str, str]] = []
    group: Optional[str] = None
    current: Optional[ParsedOption] = None
    for line in text.split("\n"):
        if not line or line.startswith("*%"):
            continue
        if line.startswith("*OpenGroup:"):
            name, _, label = line.split(":", 1)[1].strip().partition("/")
            group = name
            groups[name] = label
            continue
        if line.startswith("*CloseGroup:"):
            group = None
            continue
        if line.startswith("*OpenUI "):
            head, ui = line[len("*OpenUI "):].rsplit(":", 1)
            keyword, _, label = head.strip().lstrip("*").partition("/")
            current = ParsedOption(keyword, label, ui.strip(), group)
            options[keyword] = current
            continue
        if line.startswith("*CloseUI:"):
            current = None
            continue
        match = LINE_RE.match(line)
        if match is None:
            raise AssertionError(f"{path.name}: unlesbare Zeile {line!r}")
        kw, spec, label, value = match.group("kw", "spec", "text", "value")
        if kw == "OrderDependency" and current is not None:
            parts = value.split()
            current.order = (int(parts[0]), parts[1])
            assert parts[2] == "*" + current.keyword, line
            continue
        if re.fullmatch(r"[a-z]{2}(_[A-Z]{2})?\.\S+", kw):
            language, _, key = kw.partition(".")
            translations[(language, key, spec)] = label
            continue
        if current is not None and kw == "Default" + current.keyword:
            current.default = value.strip()
            continue
        if current is not None and kw == current.keyword and spec is not None:
            current.choices[spec] = label or ""
            current.codes[spec] = unquote(value)
            choice_lines.append((kw, spec))
            continue
        attrs.setdefault(kw, []).append((spec, label, unquote(value)))
    return ParsedPPD(path, data, attrs, options, groups, translations, choice_lines)


# ---------------------------------------------------------------------------------------------
# ARCHITECTURE.md §9
# ---------------------------------------------------------------------------------------------


@dataclass
class OptionSpec:
    names: List[str]
    tokens: List[str]                    # aufgezählte Werte (ohne Bereiche)
    int_range: Optional[Tuple[int, int]]
    has_default: bool
    ppd_values: Optional[List[int]]      # exakte PPD-Auswahl (ohne „Default“), falls §9 sie vorgibt
    model_max: bool                      # „PPD: bis Modellmaximum“
    free_form: bool                      # Base64url

    def allows(self, value: str) -> bool:
        if value in self.tokens:
            return True
        if self.int_range and re.fullmatch(r"-?\d+", value):
            return self.int_range[0] <= int(value) <= self.int_range[1]
        return False


def parse_architecture_options() -> Dict[str, OptionSpec]:
    text = ARCHITECTURE.read_text(encoding="utf-8").replace("−", "-")
    section = text.split("## 9.", 1)[1].split("## 10.", 1)[0]
    specs: Dict[str, OptionSpec] = {}
    for line in section.splitlines():
        if not line.startswith("| `lw"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        names = re.findall(r"`(lw\w+)`", cells[0])
        values = cells[1]
        main, _, ppd_part = values.partition("(PPD:")
        range_match = re.search(r"`(-?\d+)`\s*…\s*`(-?\d+)`", main)
        int_range = (int(range_match.group(1)), int(range_match.group(2))) if range_match else None
        tokens = [t for t in re.findall(r"`([^`]+)`", re.sub(r"`-?\d+`\s*…\s*`-?\d+`", "", main))]
        ppd_values: Optional[List[int]] = None
        model_max = False
        if ppd_part:
            ppd_part = ppd_part.rstrip(") ")
            steps = re.search(r"Schritte(?: von)? (\d+)", ppd_part)
            explicit_range = re.search(r"(-?\d+)\s*…\s*(-?\d+)", ppd_part)
            if "Modellmaximum" in ppd_part:
                model_max = True
            elif steps:
                low, high = (int(explicit_range.group(1)), int(explicit_range.group(2))) if explicit_range \
                    else int_range
                ppd_values = list(range(low, high + 1, int(steps.group(1))))
            else:
                ppd_values = [int(v) for v in re.findall(r"-?\d+", ppd_part)]
        spec = OptionSpec(names, tokens, int_range, "Default" in tokens, ppd_values, model_max,
                          free_form="Base64url" in values)
        for name in names:
            specs[name] = spec
    return specs


# ---------------------------------------------------------------------------------------------
# Gemeinsame Testdaten: alle PPDs einmal erzeugen
# ---------------------------------------------------------------------------------------------

CATALOG = gen.load_catalog()
TARGETS = gen.build_targets(CATALOG)
MODELS = {m.id: m for m in CATALOG.models}
_TMP: Optional[tempfile.TemporaryDirectory] = None
OUT: Path = Path()
PPDS: Dict[str, ParsedPPD] = {}
INDEX: List[dict] = []


def setUpModule() -> None:  # noqa: N802 (unittest-Konvention)
    global _TMP, OUT, PPDS, INDEX
    _TMP = tempfile.TemporaryDirectory(prefix="lw-ppd-test-")
    OUT = Path(_TMP.name) / "out"
    rc = gen.main(["--output", str(OUT), "--quiet"])
    if rc != 0:
        raise RuntimeError(f"generate_ppds.py lieferte {rc}")
    PPDS = {p.name[: -len(".ppd")]: parse_ppd(p) for p in sorted(OUT.glob("*.ppd"))}
    INDEX = json.loads((OUT / "index.json").read_text(encoding="utf-8"))


def tearDownModule() -> None:  # noqa: N802
    if _TMP is not None:
        _TMP.cleanup()


def target_for(stem: str):
    return next(t for t in TARGETS if t.stem == stem)


def run_cli(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPT), *args], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, universal_newlines=True, check=False)


# ---------------------------------------------------------------------------------------------
# Hilfsfunktionen des Generators
# ---------------------------------------------------------------------------------------------


class HelperTests(unittest.TestCase):
    def test_swift_round_is_half_away_from_zero(self):
        self.assertEqual(gen.swift_round(0.5), 1)
        self.assertEqual(gen.swift_round(1.5), 2)
        self.assertEqual(gen.swift_round(2.5), 3)      # Python round(2.5) == 2
        self.assertEqual(gen.swift_round(2.4999), 2)
        self.assertEqual(gen.swift_round(-2.5), -3)
        self.assertEqual(gen.swift_round(0.0), 0)

    def test_keyword_matches_swift_label_stock(self):
        # Erwartungen aus Tests/LabelWerkCoreTests/ModelCatalogTests.swift
        self.assertEqual(CATALOG.stock("w4h6in").keyword, "w288h432")
        for stock in CATALOG.stocks:
            self.assertRegex(stock.keyword, r"^w\d+h\d+$")
        stock = gen.Stock("x", "x", 100.0, 150.0, 3.0, "gap", "custom")
        self.assertEqual(stock.keyword, "w283h425")

    def test_dots_match_swift_resolution(self):
        self.assertEqual(gen.mm_to_dots(104, 203), 831)
        self.assertEqual(gen.mm_to_dots(104, 300), 1228)
        self.assertEqual(gen.mm_to_dots(3.0, 203), 24)
        self.assertEqual(gen.mm_to_dots(216, 203), 1726)

    def test_select_ieee1284_model(self):
        entries = ["ZDesigner ZD421t", "ZTC ZD421-203dpi ZPL", "ZTC ZD421-300dpi ZPL", "ZTC ZD421t"]
        self.assertEqual(gen.select_ieee1284_model(entries, 203), "ZTC ZD421-203dpi ZPL")
        self.assertEqual(gen.select_ieee1284_model(entries, 300), "ZTC ZD421-300dpi ZPL")
        self.assertEqual(gen.select_ieee1284_model(entries, 600), "ZTC ZD421t")
        self.assertEqual(gen.select_ieee1284_model(["LP 2844", "LP2844"], 203), "LP 2844")
        self.assertEqual(gen.select_ieee1284_model(["ZDesigner X", "Y"], 203), "Y")
        self.assertEqual(gen.select_ieee1284_model(["ZDesigner X"], 203), "ZDesigner X")
        self.assertIsNone(gen.select_ieee1284_model([], 203))

    def test_english_stock_names_are_ascii(self):
        samples = {
            "w4h6in": "4 x 6 in (Shipping)",
            "w2_25h1_25in": "2.25 x 1.25 in",
            "m100x150": "100 x 150 mm (DHL/DPD/GLS)",
            "m89x28": "89 x 28 mm (Small Address)",
            "wb1x11in": "Patient Wristband 1 x 11 in",
            "c80": "Continuous 80 mm (Receipt)",
        }
        for stock_id, expected in samples.items():
            self.assertEqual(gen.english_stock_name(CATALOG.stock(stock_id)), expected)
        for stock in CATALOG.stocks:
            gen.english_stock_name(stock).encode("ascii")
        odd = gen.Stock("o", "Großes Etikett 70 × 40 mm", 70, 40, 3, "gap", "custom")
        self.assertEqual(gen.english_stock_name(odd), "70 x 40 mm")

    def test_sanitize_text(self):
        self.assertEqual(gen.sanitize_text('a: <b> "c"'), "a - (b) 'c'")
        long_text = "ä" * 100
        self.assertLessEqual(len(gen.sanitize_text(long_text).encode("utf-8")), gen.PPD_MAX_TEXT_BYTES)
        with self.assertRaises(gen.GenerationError):
            gen.sanitize_text("   ")
        self.assertEqual(gen.to_ascii("Floyd–Steinberg × Größe"), "Floyd-Steinberg x Groesse")

    def test_check_keyword(self):
        self.assertEqual(gen.check_keyword("w288h432"), "w288h432")
        for bad in ("", "a b", "a/b", "a:b", "x" * 41, "ä"):
            with self.assertRaises(gen.GenerationError):
                gen.check_keyword(bad)

    def test_pc_file_name_format(self):
        name = gen.pc_file_name_candidate("LabelWerk-zd421t-203dpi")
        self.assertRegex(name, r"^LW[0-9A-F]{6}\.PPD$")
        self.assertNotEqual(name, gen.pc_file_name_candidate("LabelWerk-zd421t-203dpi", 1))


class CatalogValidationTests(unittest.TestCase):
    def _catalog(self, **model_overrides):
        model = {
            "id": "test1", "name": "Test 1", "family": "T", "category": "desktop",
            "languages": ["zpl"], "defaultLanguage": "zpl", "resolutions": [203],
            "printWidthMM": 104, "maxLabelLengthMM": 991, "maxSpeedIPS": {"203": 6},
            "mediaTypes": ["directThermal"], "printModes": ["tearOff"], "connectivity": ["usb"],
            "features": [], "ieee1284": ["ZTC TEST1-203dpi ZPL"], "defaultStock": "c4in",
        }
        model.update(model_overrides)
        stocks = [
            {"id": "w4h6in", "name": "4 × 6 Zoll", "widthMM": 101.6, "heightMM": 152.4, "gapMM": 3,
             "tracking": "gap", "category": "shipping", "isCustom": False},
            {"id": "c4in", "name": "Endlos 4 Zoll", "widthMM": 101.6, "heightMM": 152.4, "gapMM": 0,
             "tracking": "continuous", "category": "receipt", "isCustom": False},
            {"id": "huge", "name": "Riesig", "widthMM": 300, "heightMM": 100, "gapMM": 3,
             "tracking": "gap", "category": "custom", "isCustom": False},
        ]
        return {"schemaVersion": 1, "models": [model], "stocks": stocks}

    def test_duplicate_keyword_prefers_default_stock(self):
        catalog = gen.parse_catalog(self._catalog())
        target = gen.build_targets(catalog)[0]
        sizes = [p for p in target.page_sizes if p.keyword == "w288h432"]
        self.assertEqual(len(sizes), 1)
        self.assertEqual(sizes[0].stock.id, "c4in")
        self.assertEqual(sizes[0].merged_ids, ("w4h6in",))
        self.assertNotIn("huge", [p.stock.id for p in target.page_sizes])
        self.assertEqual(target.default_gap_dots, 0)

    def test_default_stock_is_always_included(self):
        catalog = gen.parse_catalog(self._catalog(printWidthMM=48, defaultStock="w4h6in"))
        target = gen.build_targets(catalog)[0]
        self.assertIn("w4h6in", [p.stock.id for p in target.page_sizes])
        gen.render_ppd(target)

    def test_invalid_catalogs_are_rejected(self):
        bad_variants = [
            {"languages": ["pcl"]},
            {"defaultLanguage": "epl"},
            {"defaultStock": "missing"},
            {"resolutions": [204]},
            {"maxSpeedIPS": {"203": 0}},
            {"printModes": ["fold"]},
            {"id": "Bad ID"},
            {"id": "generic-zpl"},
        ]
        for overrides in bad_variants:
            with self.subTest(overrides=overrides):
                with self.assertRaises(gen.CatalogError):
                    gen.parse_catalog(self._catalog(**overrides))
        broken = self._catalog()
        del broken["models"][0]["printWidthMM"]
        with self.assertRaises(gen.CatalogError):
            gen.parse_catalog(broken)

    def test_cli_reports_catalog_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "models.json"
            path.write_text("{ kaputt", encoding="utf-8")
            result = run_cli("--catalog", str(path), "--output", str(Path(tmp) / "out"))
            self.assertEqual(result.returncode, 2)
            self.assertIn("JSON", result.stderr)


# ---------------------------------------------------------------------------------------------
# Erzeugte Dateien
# ---------------------------------------------------------------------------------------------


class GeneratedSetTests(unittest.TestCase):
    def test_one_ppd_per_model_and_resolution(self):
        expected = {f"LabelWerk-{m.id}-{dpi}dpi" for m in CATALOG.models for dpi in m.resolutions}
        expected |= {f"LabelWerk-generic-{lang}-{dpi}dpi" for lang, dpi in gen.GENERIC_TARGETS}
        self.assertEqual(set(PPDS), expected)
        self.assertIn("LabelWerk-generic-zpl-203dpi", PPDS)
        self.assertIn("LabelWerk-generic-zpl-300dpi", PPDS)
        self.assertIn("LabelWerk-generic-zpl-600dpi", PPDS)
        self.assertIn("LabelWerk-generic-epl-203dpi", PPDS)
        self.assertIn("LabelWerk-generic-cpcl-203dpi", PPDS)
        self.assertEqual(sorted(p.name for p in OUT.iterdir()),
                         sorted([s + ".ppd" for s in expected] + ["index.json"]))

    def test_identifying_attributes_are_unique(self):
        for attribute in ("PCFileName", "NickName", "ModelName"):
            values = [p.attr(attribute) for p in PPDS.values()]
            self.assertEqual(len(values), len(set(values)), attribute)
        for ppd in PPDS.values():
            self.assertRegex(ppd.attr("PCFileName"), r"^LW[0-9A-F]{6}\.PPD$")
            self.assertLessEqual(len(ppd.attr("ShortNickName")), 31)
            self.assertRegex(ppd.attr("ModelName"), r"^[A-Za-z0-9 ./+-]+$")

    def test_pc_file_names_do_not_depend_on_model_filter(self):
        targets = gen.build_targets(CATALOG)
        self.assertEqual([t.pc_file_name for t in targets], [t.pc_file_name for t in TARGETS])

    def test_lines_are_ascii_except_utf8_translations(self):
        for stem, ppd in PPDS.items():
            ppd.data.decode("utf-8")
            self.assertTrue(ppd.data.startswith(b'*PPD-Adobe: "4.3"\n'), stem)
            self.assertTrue(ppd.data.endswith(b"\n"))
            self.assertNotIn(b"\r", ppd.data)
            self.assertNotIn(b"\t", ppd.data)
            for line in ppd.data.split(b"\n"):
                self.assertLessEqual(len(line), 255)
                if any(b > 0x7E for b in line):
                    self.assertRegex(line.decode("utf-8"), r"^\*de\.", f"{stem}: {line!r}")

    def test_header_attributes(self):
        for stem, ppd in PPDS.items():
            target = target_for(stem)
            with self.subTest(stem):
                self.assertEqual(ppd.attr("FormatVersion"), "4.3")
                self.assertEqual(ppd.attr("FileVersion"), gen.DEFAULT_FILE_VERSION)
                self.assertEqual(ppd.attr("LanguageVersion"), "English")
                self.assertEqual(ppd.attr("LanguageEncoding"), "ISOLatin1")
                self.assertEqual(ppd.attr("Manufacturer"), "Zebra")
                self.assertEqual(ppd.attr("NickName"), f"Zebra {target.name} ({target.dpi} dpi) - LabelWerk")
                self.assertEqual(ppd.attr("ModelName"), f"Zebra {target.name} {target.dpi} dpi - LabelWerk")
                self.assertEqual(ppd.attr("Product"), f"(Zebra {target.name})")
                for product in ppd.attr_values("Product"):
                    self.assertRegex(product, r"^\([^()]+\)$")
                    self.assertNotIn("ZDesigner", product)
                    other = re.search(r"-(\d+)dpi", product)
                    self.assertTrue(other is None or int(other.group(1)) == target.dpi, product)
                self.assertEqual(len(set(ppd.attr_values("Product"))), len(ppd.attr_values("Product")))
                self.assertEqual(ppd.attr("PSVersion"), "(3010.000) 0")
                self.assertEqual(ppd.attr("LanguageLevel"), "3")
                self.assertEqual(ppd.attr("ColorDevice"), "False")
                self.assertEqual(ppd.attr("DefaultColorSpace"), "Gray")
                self.assertEqual(ppd.attr("TTRasterizer"), "Type42")
                self.assertRegex(ppd.attr("cupsVersion"), r"^2\.\d+$")
                self.assertEqual(ppd.attr("cupsManualCopies"), "False")
                self.assertRegex(ppd.attr("cupsModelNumber"), r"^\d+$")
                self.assertEqual(ppd.attr_values("cupsFilter"), [
                    "application/vnd.cups-raster 0 /Library/Printers/LabelWerk/Filter/rastertolabelwerk",
                    "application/vnd.cups-command 0 /Library/Printers/LabelWerk/Filter/commandtolabelwerk",
                ])
                self.assertEqual(ppd.attr("cupsCommands"),
                                 "Clean PrintSelfTestPage ReportLevels AutoConfigure Calibrate")
                self.assertEqual(ppd.attr("cupsLanguages"), "de")
                self.assertEqual(ppd.attr("APPrinterIconPath"), "/Library/Printers/LabelWerk/Icons/LabelWerk.icns")
                self.assertEqual(ppd.attr("APPrinterUtilityPath"), "/Applications/LabelWerk.app")
                self.assertEqual(ppd.options["ColorModel"].codes, {"Gray": gen.COLOR_MODEL_CODE})
                self.assertEqual(ppd.options["ColorModel"].default, "Gray")
                self.assertEqual(ppd.options["Resolution"].codes,
                                 {f"{target.dpi}dpi": f"<</HWResolution[{target.dpi} {target.dpi}]>>setpagedevice"})

    def test_lw_attributes(self):
        for stem, ppd in PPDS.items():
            target = target_for(stem)
            with self.subTest(stem):
                self.assertEqual(ppd.attr("lwModel"), target.model_id)
                self.assertEqual(ppd.attr("lwMaxPrintWidthDots"), str(gen.mm_to_dots(target.print_width_mm, target.dpi)))
                stock = CATALOG.stock(MODELS[target.model_id].default_stock) if not target.is_generic \
                    else target.default_stock
                self.assertEqual(ppd.attr("lwDefaultGapDots"), str(gen.mm_to_dots(stock.gap_mm, target.dpi)))
        self.assertEqual(PPDS["LabelWerk-zd421t-203dpi"].attr("lwDefaultGapDots"), "24")
        self.assertEqual(PPDS["LabelWerk-zd421t-203dpi"].attr("lwMaxPrintWidthDots"), "831")

    def test_1284_device_id(self):
        for stem, ppd in PPDS.items():
            target = target_for(stem)
            values = ppd.attr_values("1284DeviceID")
            if target.is_generic:
                self.assertEqual(values, [], stem)
                continue
            self.assertEqual(len(values), 1, stem)
            model = MODELS[target.model_id]
            match = re.fullmatch(r"MFG:Zebra Technologies;CMD:([A-Z0-9,]+);MDL:([^;]+);CLS:PRINTER;", values[0])
            self.assertIsNotNone(match, values[0])
            self.assertIn(match.group(2), model.ieee1284)
            self.assertEqual(match.group(1).split(","), [gen.LANGUAGE_IEEE1284[l] for l in model.languages])
            other_dpi = re.search(r"-(\d+)dpi", match.group(2))
            if other_dpi:
                self.assertEqual(int(other_dpi.group(1)), target.dpi, stem)
        self.assertIn("MDL:ZTC ZD421-300dpi ZPL;", PPDS["LabelWerk-zd421t-300dpi"].attr("1284DeviceID"))
        self.assertEqual(PPDS["LabelWerk-zd421t-300dpi"].attr_values("Product"),
                         ["(Zebra ZD421t)", "(ZTC ZD421-300dpi ZPL)", "(ZTC ZD421t)"])
        self.assertEqual(PPDS["LabelWerk-generic-zpl-203dpi"].attr_values("Product"), ["(Zebra Generic ZPL)"])
        self.assertIn("MDL:ZTC ZD421-203dpi ZPL;", PPDS["LabelWerk-zd421t-203dpi"].attr("1284DeviceID"))

    def test_option_keywords_and_choices_unique(self):
        for stem, ppd in PPDS.items():
            seen = set()
            for option, choice in ppd.choice_lines:
                self.assertNotIn((option, choice), seen, f"{stem}: {option} {choice}")
                seen.add((option, choice))
            for option in ppd.options.values():
                self.assertIsNotNone(option.order, option.keyword)
                self.assertEqual(option.order[1], "AnySetup")
                self.assertLessEqual(len(option.keyword), 40)
                for choice in option.choices:
                    self.assertRegex(choice, r"^[!-~]+$")
                    self.assertNotIn("/", choice)
                    self.assertLessEqual(len(choice), 40)

    def test_page_sizes(self):
        for stem, ppd in PPDS.items():
            target = target_for(stem)
            with self.subTest(stem):
                fitting = [s for s in CATALOG.stocks
                           if s.width_mm <= target.print_width_mm + 2 and s.height_mm <= target.max_label_length_mm]
                expected_keywords = []
                for stock in fitting + [target.default_stock]:
                    if stock.keyword not in expected_keywords:
                        expected_keywords.append(stock.keyword)
                page_sizes = ppd.options["PageSize"].choices
                self.assertEqual(sorted(page_sizes), sorted(expected_keywords))
                self.assertEqual(len(set(page_sizes)), len(page_sizes))
                self.assertEqual(list(ppd.options["PageRegion"].choices), list(page_sizes))
                self.assertEqual(ppd.specs("ImageableArea"), list(page_sizes))
                self.assertEqual(ppd.specs("PaperDimension"), list(page_sizes))
                by_keyword = {p.keyword: p.stock for p in target.page_sizes}
                areas = dict(zip(ppd.specs("ImageableArea"), ppd.attr_values("ImageableArea")))
                dims = dict(zip(ppd.specs("PaperDimension"), ppd.attr_values("PaperDimension")))
                for keyword in page_sizes:
                    stock = by_keyword[keyword]
                    self.assertEqual(keyword, stock.keyword)
                    width, height = (float(v) for v in dims[keyword].split())
                    self.assertAlmostEqual(width, stock.width_mm / 25.4 * 72, delta=0.001)
                    self.assertAlmostEqual(height, stock.height_mm / 25.4 * 72, delta=0.001)
                    self.assertEqual(areas[keyword], "0 0 " + dims[keyword])
                    self.assertEqual(ppd.options["PageSize"].codes[keyword],
                                     f"<</PageSize[{dims[keyword]}]/ImagingBBox null>>setpagedevice")
                # Seitengrößen-Text ist der englische Name des gewählten Formats
                for keyword, text in page_sizes.items():
                    self.assertEqual(text, gen.english_stock_name(by_keyword[keyword]))

    def test_custom_page_size(self):
        for stem, ppd in PPDS.items():
            target = target_for(stem)
            with self.subTest(stem):
                self.assertEqual(ppd.attr("VariablePaperSize"), "True")
                self.assertEqual(ppd.attr("HWMargins"), "0 0 0 0")
                self.assertEqual(ppd.specs("CustomPageSize"), ["True"])
                params = dict(zip(ppd.specs("ParamCustomPageSize"), ppd.attr_values("ParamCustomPageSize")))
                self.assertEqual(list(params), ["Width", "Height", "WidthOffset", "HeightOffset", "Orientation"])
                max_w = (target.print_width_mm + 2) / 25.4 * 72
                max_h = target.max_label_length_mm / 25.4 * 72
                self.assertAlmostEqual(float(ppd.attr("MaxMediaWidth")), max_w, delta=0.001)
                self.assertAlmostEqual(float(ppd.attr("MaxMediaHeight")), max_h, delta=0.001)
                self.assertEqual(params["Width"].split()[:3], ["1", "points", "36"])
                self.assertAlmostEqual(float(params["Width"].split()[3]), max_w, delta=0.001)
                self.assertEqual(params["Height"].split()[:3], ["2", "points", "18"])
                self.assertAlmostEqual(float(params["Height"].split()[3]), max_h, delta=0.001)
                self.assertEqual(params["Orientation"], "5 int 0 0")

    def test_defaults_valid(self):
        for stem, ppd in PPDS.items():
            target = target_for(stem)
            with self.subTest(stem):
                for option in ppd.options.values():
                    self.assertIn(option.default, option.choices, option.keyword)
                default_size = target.default_stock.keyword
                if not target.is_generic:
                    self.assertEqual(default_size, CATALOG.stock(MODELS[target.model_id].default_stock).keyword)
                self.assertEqual(ppd.options["PageSize"].default, default_size)
                self.assertEqual(ppd.options["PageRegion"].default, default_size)
                self.assertEqual(ppd.attr("DefaultImageableArea"), default_size)
                self.assertEqual(ppd.attr("DefaultPaperDimension"), default_size)
                self.assertEqual(ppd.options["Resolution"].default, f"{target.dpi}dpi")
                self.assertEqual(list(ppd.options["Resolution"].choices), [f"{target.dpi}dpi"])
                self.assertEqual(ppd.options["lwLanguage"].default, gen.LANGUAGE_CUPS[target.default_language])
                # Standardwerte entsprechen PrintSettings.default (Swift)
                expected = {"lwDither": "Threshold", "lwThreshold": "128", "lwCompression": "Z64",
                            "lwCutEvery": "0", "lwMirror": "False", "lwNegative": "False",
                            "lwRotate180": "False", "lwCalibrate": "False", "lwSaveSettings": "False",
                            "lwSkipBlank": "False"}
                for keyword, value in expected.items():
                    if keyword in ppd.options:
                        self.assertEqual(ppd.options[keyword].default, value, keyword)
                for keyword in ("lwDarkness", "lwSpeed", "lwMediaType", "lwMediaTracking", "lwPrintMode",
                                "lwLabelTop", "lwLabelLeft", "lwTearOff", "lwBackfeed"):
                    if keyword in ppd.options:
                        self.assertEqual(ppd.options[keyword].default, "Default", keyword)

    def test_speeds_within_model_maximum(self):
        for stem, ppd in PPDS.items():
            target = target_for(stem)
            speeds = [int(c) for c in ppd.options["lwSpeed"].choices if c != "Default"]
            if target.is_generic:
                limit = target.max_speed
            else:
                model = MODELS[target.model_id]
                limit = min(model.max_speed_ips.get(str(target.dpi), min(model.max_speed_ips.values())), 14)
            self.assertEqual(speeds, list(range(1, limit + 1)), stem)
            self.assertLessEqual(max(speeds), 14)
        self.assertEqual(len(PPDS["LabelWerk-ze511-203dpi"].options["lwSpeed"].choices), 15)  # 18 ips → 14
        self.assertEqual(max(int(c) for c in PPDS["LabelWerk-zt410-600dpi"].options["lwSpeed"].choices
                             if c != "Default"), 6)

    def test_model_restrictions(self):
        for stem, ppd in PPDS.items():
            target = target_for(stem)
            with self.subTest(stem):
                media = [c for c in ppd.options["lwMediaType"].choices if c != "Default"] \
                    if "lwMediaType" in ppd.options else []
                if "lwMediaType" in ppd.options:
                    self.assertEqual(media, [gen.MEDIA_TYPE_CUPS[m] for m in gen.MEDIA_TYPE_CUPS
                                             if m in target.media_types])
                if "lwPrintMode" in ppd.options:
                    modes = [c for c in ppd.options["lwPrintMode"].choices if c != "Default"]
                    allowed = target.print_modes if "zpl" in target.languages else \
                        [m for m in target.print_modes if m in ("tearOff", "peelOff", "cutter")]
                    self.assertEqual(modes, [gen.PRINT_MODE_CUPS[m] for m in gen.PRINT_MODE_CUPS
                                             if m in allowed])
                languages = list(ppd.options["lwLanguage"].choices)
                self.assertEqual(sorted(languages), sorted(gen.LANGUAGE_CUPS[l] for l in target.languages))
                zpl_only = ("lwLabelTop", "lwLabelLeft", "lwTearOff", "lwBackfeed", "lwCompression",
                            "lwCalibrate", "lwSaveSettings")
                for keyword in zpl_only:
                    self.assertEqual(keyword in ppd.options, "zpl" in target.languages, keyword)
                cutter = any(m in ("cutter", "delayedCut") for m in target.print_modes)
                self.assertEqual("lwCutEvery" in ppd.options, cutter and "zpl" in target.languages)
        self.assertEqual(list(PPDS["LabelWerk-generic-epl-203dpi"].options["lwPrintMode"].choices),
                         ["Default", "TearOff", "PeelOff", "Cutter"])
        self.assertNotIn("lwPrintMode", PPDS["LabelWerk-generic-cpcl-203dpi"].options)
        lp2844 = PPDS["LabelWerk-lp2844-203dpi"].options
        self.assertNotIn("lwCompression", lp2844)
        self.assertEqual(list(lp2844["lwLanguage"].choices), ["EPL"])
        self.assertEqual(list(PPDS["LabelWerk-zd421d-203dpi"].options["lwMediaType"].choices),
                         ["Default", "DirectThermal"])
        self.assertEqual(PPDS["LabelWerk-zq320-203dpi"].options["lwLanguage"].default, "CPCL")

    def test_generic_ppds(self):
        zpl_width = max(m.print_width_mm for m in CATALOG.models if "zpl" in m.languages)
        self.assertEqual(zpl_width, 216)
        for language, dpi in gen.GENERIC_TARGETS:
            ppd = PPDS[f"LabelWerk-generic-{language}-{dpi}dpi"]
            with self.subTest(language=language, dpi=dpi):
                self.assertEqual(list(ppd.options["lwLanguage"].choices), [gen.LANGUAGE_CUPS[language]])
                self.assertEqual(ppd.attr("lwModel"), f"generic-{language}")
                width = max(m.print_width_mm for m in CATALOG.models if language in m.languages)
                self.assertEqual(ppd.attr("lwMaxPrintWidthDots"), str(gen.mm_to_dots(width, dpi)))
                self.assertNotIn("1284DeviceID", ppd.attrs)
        self.assertEqual(PPDS["LabelWerk-generic-zpl-203dpi"].attr("lwMaxPrintWidthDots"), "1726")
        self.assertEqual(PPDS["LabelWerk-generic-cpcl-203dpi"].options["PageSize"].default, "w216h144")


class TranslationTests(unittest.TestCase):
    def test_german_translations_present_for_every_option_and_choice(self):
        for stem, ppd in PPDS.items():
            with self.subTest(stem):
                for keyword, option in ppd.options.items():
                    self.assertIn(("de", "Translation", keyword), ppd.translations, keyword)
                    for choice in option.choices:
                        self.assertIn(("de", keyword, choice), ppd.translations, f"{keyword} {choice}")
                for group in ppd.groups:
                    self.assertIn(("de", "Translation", group), ppd.translations, group)
                self.assertIn(("de", "CustomPageSize", "True"), ppd.translations)
                for param in ("Width", "Height", "WidthOffset", "HeightOffset", "Orientation"):
                    self.assertIn(("de", "ParamCustomPageSize", param), ppd.translations)
                # keine verwaisten Übersetzungen
                for (language, key, spec), text in ppd.translations.items():
                    self.assertEqual(language, "de")
                    self.assertTrue(text, (key, spec))
                    self.assertLessEqual(len(text.encode("utf-8")), 80)
                    if key == "Translation":
                        self.assertTrue(spec in ppd.options or spec in ppd.groups, spec)
                    elif key not in ("CustomPageSize", "ParamCustomPageSize"):
                        self.assertIn(spec, ppd.options[key].choices, (key, spec))

    def test_translations_are_german(self):
        ppd = PPDS["LabelWerk-zd421t-203dpi"]
        t = ppd.translations
        self.assertEqual(t[("de", "Translation", "lwDarkness")], "Schwärzung")
        self.assertEqual(t[("de", "Translation", "lwBackfeed")], "Rückzug")
        self.assertEqual(t[("de", "Translation", "lwRotate180")], "Um 180° drehen")
        self.assertEqual(t[("de", "lwPrintMode", "TearOff")], "Abreißen")
        self.assertEqual(t[("de", "lwDarkness", "Default")], "Druckereinstellung")
        self.assertEqual(t[("de", "lwDither", "FloydSteinberg")], "Floyd–Steinberg")
        self.assertEqual(t[("de", "PageSize", "w288h432")], "4 × 6 Zoll (Versand)")
        self.assertEqual(t[("de", "Translation", "PrinterSettings")], "Druckereinstellungen")
        self.assertEqual(t[("de", "lwSpeed", "4")], "4 Zoll/s (102 mm/s)")
        self.assertEqual(t[("de", "lwLabelTop", "-120")], "-120 Punkte (-15,0 mm)")
        self.assertEqual(ppd.options["lwLabelTop"].choices["10"], "+10 dots (+1.3 mm)")
        # Jede lw-Option hat einen vom Englischen abweichenden deutschen Namen
        for keyword, option in ppd.options.items():
            if keyword.startswith("lw") and keyword != "lwThreshold":
                self.assertNotEqual(t[("de", "Translation", keyword)], option.text, keyword)

    def test_page_size_translations_use_catalog_names(self):
        for stem, ppd in PPDS.items():
            target = target_for(stem)
            for size in target.page_sizes:
                self.assertEqual(ppd.translations[("de", "PageSize", size.keyword)], size.stock.name)
                self.assertEqual(ppd.translations[("de", "PageRegion", size.keyword)], size.stock.name)


class ArchitectureContractTests(unittest.TestCase):
    """Alle ``lw*``-Optionen und -Werte exakt nach ARCHITECTURE.md §9."""

    @classmethod
    def setUpClass(cls):
        cls.spec = parse_architecture_options()

    def test_architecture_table_parsed(self):
        self.assertEqual(len(self.spec), 22)
        self.assertEqual(self.spec["lwThreshold"].ppd_values, [64, 96, 128, 160, 192])
        self.assertEqual(self.spec["lwCutEvery"].ppd_values, [0, 1, 2, 5, 10, 25, 50, 100])
        self.assertEqual(self.spec["lwLabelLeft"].ppd_values, list(range(-200, 201, 10)))
        self.assertEqual(self.spec["lwLabelTop"].ppd_values, list(range(-120, 121, 10)))
        self.assertTrue(self.spec["lwSpeed"].model_max)
        self.assertTrue(self.spec["lwStartCmd"].free_form)

    @unittest.skipUnless(PRINT_SETTINGS_SWIFT.exists(), "PrintSettings.swift fehlt")
    def test_option_names_match_swift_cups_option_name(self):
        source = PRINT_SETTINGS_SWIFT.read_text(encoding="utf-8")
        block = source.split("public enum CUPSOptionName", 1)[1].split("public static let defaultValue", 1)[0]
        swift_names = set(re.findall(r'static let \w+ = "(lw\w+)"', block))
        self.assertEqual(swift_names, set(self.spec))
        generator_names = set(gen.OPTION_TEXTS) | {gen.OPT_START_CMD, gen.OPT_END_CMD}
        self.assertEqual(generator_names, set(self.spec))

    def test_all_lw_options_match_section_9(self):
        present = set()
        for stem, ppd in PPDS.items():
            target = target_for(stem)
            for keyword, option in ppd.options.items():
                if not keyword.startswith("lw"):
                    continue
                present.add(keyword)
                spec = self.spec.get(keyword)
                self.assertIsNotNone(spec, f"{stem}: {keyword} fehlt in §9")
                self.assertFalse(spec.free_form, keyword)
                choices = list(option.choices)
                for choice in choices:
                    self.assertTrue(spec.allows(choice), f"{stem}: {keyword}={choice} nicht in §9")
                self.assertEqual("Default" in choices, spec.has_default, f"{stem}: {keyword} Default")
                values = [c for c in choices if c != "Default"]
                if spec.ppd_values is not None:
                    self.assertEqual([int(v) for v in values], spec.ppd_values, f"{stem}: {keyword}")
                if spec.model_max:
                    self.assertEqual([int(v) for v in values], list(range(1, target.max_speed + 1)))
                if set(spec.tokens) == {"False", "True"}:
                    self.assertEqual(option.ui, "Boolean", keyword)
                    self.assertEqual(sorted(choices), ["False", "True"])
                else:
                    self.assertEqual(option.ui, "PickOne", keyword)
                for code in option.codes.values():
                    self.assertEqual(code, "", f"{keyword}: PostScript-Code muss leer sein")
        expected = {k for k, s in self.spec.items() if not s.free_form}
        self.assertEqual(present, expected)
        # Generische ZPL-PPD enthält alle Optionen außer den freien Base64url-Werten
        generic = set(k for k in PPDS["LabelWerk-generic-zpl-203dpi"].options if k.startswith("lw"))
        self.assertEqual(generic, expected)

    def test_full_value_lists_for_enumerations(self):
        ppd = PPDS["LabelWerk-zt410-203dpi"].options
        self.assertEqual(list(ppd["lwDarkness"].choices), ["Default"] + [str(i) for i in range(31)])
        self.assertEqual(list(ppd["lwMediaTracking"].choices), ["Default", "Gap", "BlackMark", "Continuous", "Auto"])
        self.assertEqual(list(ppd["lwBackfeed"].choices), ["Default", "After", "Before", "Normal", "Off"])
        self.assertEqual(list(ppd["lwDither"].choices),
                         ["Threshold", "Ordered", "Halftone", "FloydSteinberg", "Atkinson", "Stucki"])
        self.assertEqual(list(ppd["lwCompression"].choices), ["Z64", "ACS", "Hex"])
        self.assertEqual(list(ppd["lwPrintMode"].choices),
                         ["Default", "TearOff", "PeelOff", "Cutter", "DelayedCut", "Rewind", "Applicator"])
        self.assertEqual(list(ppd["lwMediaType"].choices), ["Default", "DirectThermal", "ThermalTransfer"])

    def test_free_form_options_are_not_ppd_options(self):
        for ppd in PPDS.values():
            self.assertNotIn("lwStartCmd", ppd.options)
            self.assertNotIn("lwEndCmd", ppd.options)

    def test_groups(self):
        for stem, ppd in PPDS.items():
            self.assertEqual(ppd.options["PageSize"].group, "General")
            for keyword, option in ppd.options.items():
                if keyword.startswith("lw"):
                    self.assertEqual(option.group, gen.OPTION_TEXTS[keyword][0], keyword)
            self.assertTrue(set(ppd.groups) <= {"General", "PrinterSettings", "Media", "Position", "Image",
                                                "Advanced"}, stem)


class IndexTests(unittest.TestCase):
    def test_index_json_consistent(self):
        self.assertEqual(len(INDEX), len(PPDS))
        self.assertEqual([e["file"] for e in INDEX], [t.stem + ".ppd" for t in TARGETS])
        for entry in INDEX:
            with self.subTest(entry["file"]):
                self.assertEqual(list(entry), ["file", "modelId", "name", "dpi", "languages", "nickName", "ieee1284"])
                ppd = PPDS[entry["file"][: -len(".ppd")]]
                self.assertTrue((OUT / entry["file"]).exists())
                self.assertEqual(entry["modelId"], ppd.attr("lwModel"))
                self.assertEqual(entry["nickName"], ppd.attr("NickName"))
                self.assertEqual(entry["ieee1284"], ppd.attr("1284DeviceID"))
                self.assertEqual(f'{entry["dpi"]}dpi', ppd.options["Resolution"].default)
                self.assertEqual(sorted(gen.LANGUAGE_CUPS[l] for l in entry["languages"]),
                                 sorted(ppd.options["lwLanguage"].choices))
                if not entry["modelId"].startswith("generic-"):
                    model = MODELS[entry["modelId"]]
                    self.assertEqual(entry["name"], model.name)
                    self.assertEqual(entry["languages"], list(model.languages))
                    self.assertIn(entry["dpi"], model.resolutions)


# ---------------------------------------------------------------------------------------------
# Kommandozeile
# ---------------------------------------------------------------------------------------------


class CommandLineTests(unittest.TestCase):
    def test_gzip_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            first, second = Path(tmp) / "a", Path(tmp) / "b"
            for out in (first, second):
                result = run_cli("--gzip", "--quiet", "--output", str(out))
                self.assertEqual(result.returncode, 0, result.stderr)
            files = sorted(p.name for p in first.glob("*.ppd.gz"))
            self.assertEqual(len(files), len(PPDS))
            self.assertEqual(list(first.glob("*.ppd")), [])
            for name in files:
                data = (first / name).read_bytes()
                self.assertEqual(data[:2], b"\x1f\x8b")
                self.assertEqual(data, (second / name).read_bytes(), f"{name} nicht reproduzierbar")
                self.assertEqual(gzip.decompress(data), PPDS[name[: -len(".ppd.gz")]].data)
            index = json.loads((first / "index.json").read_text(encoding="utf-8"))
            self.assertEqual([e["file"] for e in index], [t.stem + ".ppd.gz" for t in TARGETS])
            # Wechsel zurück auf .ppd entfernt die .gz-Dateien
            result = run_cli("--quiet", "--output", str(first))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(list(first.glob("*.ppd.gz")), [])

    def test_model_filter_and_index_merge(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            result = run_cli("--model", "ZD421t", "--quiet", "--output", str(out))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(sorted(p.name for p in out.iterdir()),
                             ["LabelWerk-zd421t-203dpi.ppd", "LabelWerk-zd421t-300dpi.ppd", "index.json"])
            index = json.loads((out / "index.json").read_text(encoding="utf-8"))
            self.assertEqual([e["file"] for e in index],
                             ["LabelWerk-zd421t-203dpi.ppd", "LabelWerk-zd421t-300dpi.ppd"])
            self.assertEqual((out / "LabelWerk-zd421t-203dpi.ppd").read_bytes(),
                             PPDS["LabelWerk-zd421t-203dpi"].data)
            # Vollständiger Lauf, danach Teil-Lauf: index.json bleibt vollständig
            self.assertEqual(run_cli("--quiet", "--output", str(out)).returncode, 0)
            self.assertEqual(run_cli("--model", "generic-epl", "--gzip", "--quiet", "--output", str(out)).returncode, 0)
            index = json.loads((out / "index.json").read_text(encoding="utf-8"))
            self.assertEqual(len(index), len(PPDS))
            self.assertIn("LabelWerk-generic-epl-203dpi.ppd.gz", [e["file"] for e in index])
            self.assertFalse((out / "LabelWerk-generic-epl-203dpi.ppd").exists())
            for entry in index:
                self.assertTrue((out / entry["file"]).exists(), entry["file"])

    def test_full_run_removes_stale_files_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            (out / "LabelWerk-old-203dpi.ppd").write_text("alt")
            (out / "LabelWerk-old-203dpi.ppd.gz").write_bytes(b"alt")
            (out / "notiz.txt").write_text("bleibt")
            self.assertEqual(run_cli("--quiet", "--output", str(out)).returncode, 0)
            self.assertFalse((out / "LabelWerk-old-203dpi.ppd").exists())
            self.assertFalse((out / "LabelWerk-old-203dpi.ppd.gz").exists())
            self.assertTrue((out / "notiz.txt").exists())

    def test_unknown_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_cli("--model", "zx9000", "--output", tmp)
            self.assertEqual(result.returncode, 2)
            self.assertIn("zx9000", result.stderr)
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "nicht-anlegen"
            result = run_cli("--list", "--output", str(out))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(out.exists())
            for target in TARGETS:
                self.assertIn(target.stem, result.stdout)
            self.assertIn(f"{len(TARGETS)} PPD-Dateien", result.stdout)
            single = run_cli("--list", "--model", "zt410")
            self.assertEqual(single.stdout.count("LabelWerk-zt410-"), 3)

    def test_file_version_option(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_cli("--model", "gk420d", "--file-version", "2.1.0", "--quiet", "--output", tmp)
            self.assertEqual(result.returncode, 0, result.stderr)
            ppd = parse_ppd(Path(tmp) / "LabelWerk-gk420d-203dpi.ppd")
            self.assertEqual(ppd.attr("FileVersion"), "2.1.0")
            bad = run_cli("--model", "gk420d", "--file-version", 'x"y', "--quiet", "--output", tmp)
            self.assertEqual(bad.returncode, 2)

    def test_check_option(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_cli("--model", "zd421t", "--check", "--output", tmp)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            if shutil.which("cupstestppd"):
                self.assertIn("2 von 2 bestanden", result.stdout)
            else:
                self.assertIn("cupstestppd nicht gefunden", result.stderr)


# ---------------------------------------------------------------------------------------------
# Prüfung mit CUPS selbst
# ---------------------------------------------------------------------------------------------

SIZE_WARNING = re.compile(r'^WARN\s+Size "w\d+h\d+" should be the Adobe standard name ".+"\.$')


@unittest.skipUnless(shutil.which("cupstestppd"), "cupstestppd nicht installiert")
class CupsTestPPDTests(unittest.TestCase):
    def test_all_ppds_pass_cupstestppd(self):
        results = gen.run_cupstestppd(sorted(OUT.glob("*.ppd")))
        self.assertEqual(len(results), len(PPDS))
        for result in results:
            with self.subTest(result.path.name):
                self.assertTrue(result.passed, "\n".join(result.errors))
                for warning in result.warnings:
                    self.assertRegex(warning, SIZE_WARNING)

    def test_gzip_ppds_pass_cupstestppd(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(run_cli("--gzip", "--quiet", "--model", "zt610", "--output", tmp).returncode, 0)
            results = gen.run_cupstestppd(sorted(Path(tmp).glob("*.ppd.gz")))
            self.assertEqual(len(results), 3)
            self.assertTrue(all(r.passed for r in results), [r.errors for r in results])

    def test_strict_with_installed_filter_layout(self):
        """Ohne ``-I filters``: Filter und Symbol liegen in einem nachgebildeten Wurzelverzeichnis."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "root"
            filter_dir = root / "Library/Printers/LabelWerk/Filter"
            icon_dir = root / "Library/Printers/LabelWerk/Icons"
            app_dir = root / "Applications/LabelWerk.app"
            for directory in (filter_dir, icon_dir, app_dir):
                directory.mkdir(parents=True)
            for path in [root] + [p for d in (filter_dir, icon_dir, app_dir) for p in [d, *d.parents]
                                  if root in p.parents or p == root]:
                path.chmod(0o755)
            for name in ("rastertolabelwerk", "commandtolabelwerk"):
                program = filter_dir / name
                program.write_text("#!/bin/sh\nexit 0\n")
                program.chmod(0o755)
            (icon_dir / "LabelWerk.icns").write_bytes(b"icns")
            (icon_dir / "LabelWerk.icns").chmod(0o644)
            sample = [OUT / f"{stem}.ppd" for stem in ("LabelWerk-zd421t-203dpi", "LabelWerk-lp2844-203dpi",
                                                        "LabelWerk-generic-cpcl-203dpi")]
            results = gen.run_cupstestppd(sample, extra_args=("-R", str(root)))
            for result in results:
                self.assertTrue(result.passed, f"{result.path.name}: {result.errors}")
            # Gegenprobe: ohne Filter schlägt die strenge Prüfung fehl
            (filter_dir / "rastertolabelwerk").unlink()
            results = gen.run_cupstestppd(sample[:1], extra_args=("-R", str(root)))
            self.assertFalse(results[0].passed)

    def test_verbose_output_lists_all_options(self):
        stem = "LabelWerk-zd421t-203dpi"
        proc = subprocess.run(["cupstestppd", "-I", "filters", "-vv", str(OUT / f"{stem}.ppd")],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        text = proc.stdout.decode("utf-8", "replace")
        self.assertEqual(proc.returncode, 0, text)
        for keyword, option in PPDS[stem].options.items():
            self.assertRegex(text, re.escape(keyword) + r" \(" + re.escape(option.text) + r"\)", keyword)
            for choice in option.choices:
                self.assertIn(choice, text)

    def test_broken_ppd_is_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = PPDS["LabelWerk-zd421t-203dpi"].data.decode("utf-8")
            broken = Path(tmp) / "LabelWerk-broken-203dpi.ppd"
            broken.write_text(source.replace('*de.lwSpeed 1/1 Zoll/s (25 mm/s): ""\n', ""), encoding="utf-8")
            result = gen.run_cupstestppd([broken])[0]
            self.assertFalse(result.passed)
            self.assertTrue(any("translation" in e for e in result.errors), result.errors)


def _compile_ppdcheck(directory: Path) -> Optional[Path]:
    compiler = shutil.which(os.environ.get("CC", "cc")) or shutil.which("gcc") or shutil.which("clang")
    if compiler is None:
        return None
    binary = directory / "ppdcheck"
    flags = ["-std=c99", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations"]
    libs = ["-lcups"]
    if shutil.which("pkg-config"):
        cflags = subprocess.run(["pkg-config", "--cflags", "cups"], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, universal_newlines=True)
        lflags = subprocess.run(["pkg-config", "--libs", "cups"], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, universal_newlines=True)
        if cflags.returncode == 0 and lflags.returncode == 0 and lflags.stdout.strip():
            flags += cflags.stdout.split()
            libs = lflags.stdout.split()
    proc = subprocess.run([compiler, *flags, str(PPDCHECK_SOURCE), "-o", str(binary), *libs],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    if proc.returncode != 0:
        if "cups/ppd.h" in proc.stdout or "-lcups" in proc.stdout or "cannot find" in proc.stdout:
            return None      # libcups-Entwicklungsdateien fehlen
        raise AssertionError("ppdcheck.c lässt sich nicht übersetzen:\n" + proc.stdout)
    return binary


class LibCupsParseTests(unittest.TestCase):
    """Parst jede PPD mit libcups (ppdOpenFile, ppdLocalize, cupsRasterInterpretPPD)."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory(prefix="lw-ppdcheck-")
        cls.binary = _compile_ppdcheck(Path(cls._tmp.name))
        if cls.binary is None:
            cls._tmp.cleanup()
            raise unittest.SkipTest("kein C-Compiler oder keine libcups-Entwicklungsdateien")
        cls.reports = {}
        env = {k: v for k, v in os.environ.items() if k not in ("LC_ALL", "LC_MESSAGES", "LANGUAGE")}
        env["LANG"] = "de_DE.UTF-8"
        for stem in PPDS:
            proc = subprocess.run([str(cls.binary), str(OUT / f"{stem}.ppd"), "Custom.50x30mm"],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
            cls.reports[stem] = (proc.returncode, proc.stdout.decode("utf-8"))

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    @staticmethod
    def records(text: str, tag: str) -> List[List[str]]:
        return [line.split("\t")[1:] for line in text.splitlines() if line.split("\t", 1)[0] == tag]

    def test_libcups_opens_every_ppd_without_conflicts(self):
        for stem, (rc, text) in self.reports.items():
            with self.subTest(stem):
                self.assertEqual(rc, 0, text[-2000:])
                self.assertEqual(self.records(text, "ERROR"), [])
                self.assertEqual(self.records(text, "CONFLICTS"), [["0"]])

    def test_libcups_sees_same_options_choices_and_defaults(self):
        for stem, (_, text) in self.reports.items():
            ppd = PPDS[stem]
            with self.subTest(stem):
                options = {r[0]: r for r in self.records(text, "OPTION")}
                self.assertEqual(set(options), set(ppd.options))
                for keyword, (key, ui, default, group, label) in options.items():
                    option = ppd.options[keyword]
                    self.assertEqual(ui, option.ui)
                    self.assertEqual(default, option.default)
                    self.assertEqual(group, option.group)
                    self.assertEqual(label, option.text)
                choices: Dict[str, List[str]] = {}
                for keyword, choice, _ in self.records(text, "CHOICE"):
                    choices.setdefault(keyword, []).append(choice)
                for keyword, option in ppd.options.items():
                    expected = list(option.choices)
                    if keyword in ("PageSize", "PageRegion"):
                        expected.append("Custom")     # von CUPS für *CustomPageSize ergänzt
                    self.assertEqual(choices[keyword], expected, keyword)
                attrs = {(r[0], r[1]): r[2] for r in self.records(text, "ATTR")}
                for name in ("lwModel", "lwMaxPrintWidthDots", "lwDefaultGapDots", "NickName", "cupsLanguages"):
                    self.assertEqual(attrs[(name, "")], ppd.attr(name), name)

    def test_ppd_localize_uses_german_translations(self):
        for stem, (_, text) in self.reports.items():
            ppd = PPDS[stem]
            with self.subTest(stem):
                locale = self.records(text, "LOCALE")
                self.assertTrue(locale and locale[0][0].startswith("de"), locale)
                for keyword, label in self.records(text, "LOPTION"):
                    self.assertEqual(label, ppd.translations[("de", "Translation", keyword)])
                for keyword, choice, label in self.records(text, "LCHOICE"):
                    if choice == "Custom" and keyword == "PageRegion":
                        # Von CUPS selbst ergänzte Wahl der (nie angezeigten) Option PageRegion;
                        # libcups verwirft *de.PageRegion Custom, Text bleibt der Grundtext.
                        self.assertEqual(label, gen.CUSTOM_SIZE_TEXT[0])
                    elif choice == "Custom":
                        self.assertEqual(label, "Eigenes Format", keyword)
                        self.assertEqual(label, ppd.translations[("de", "CustomPageSize", "True")])
                    else:
                        self.assertEqual(label, ppd.translations[("de", keyword, choice)])
                for group, label in self.records(text, "LGROUP"):
                    self.assertEqual(label, ppd.translations[("de", "Translation", group)])
                params = {r[1]: r[2] for r in self.records(text, "LPARAM")}
                self.assertEqual(params["Width"], "Breite")
                self.assertEqual(params["Height"], "Höhe")

    def test_raster_header_matches_label_dots(self):
        """``cupsRasterInterpretPPD`` liefert je Format Auflösung, 8-Bit-Graustufen (cupsColorSpace 18)
        und genau die Punktmaße, die ``LabelStock.widthDots/heightDots`` in Swift berechnen."""
        for stem, (_, text) in self.reports.items():
            target = target_for(stem)
            stocks = {p.keyword: p.stock for p in target.page_sizes}
            rasters = self.records(text, "RASTER")
            with self.subTest(stem):
                self.assertEqual(sorted(r[0] for r in rasters), sorted(stocks))
                for name, hx, hy, width, height, space, bits, bpl in rasters:
                    stock = stocks[name]
                    self.assertEqual((int(hx), int(hy)), (target.dpi, target.dpi))
                    self.assertEqual(int(space), 18)
                    self.assertEqual(int(bits), 8)
                    self.assertEqual(int(width), gen.mm_to_dots(stock.width_mm, target.dpi), name)
                    self.assertEqual(int(height), gen.mm_to_dots(stock.height_mm, target.dpi), name)
                    self.assertEqual(int(bpl), int(width))
                custom = self.records(text, "CUSTOM")
                self.assertEqual(len(custom), 1)
                _, w_pt, h_pt, width, height = custom[0]
                self.assertAlmostEqual(float(w_pt), 50 / 25.4 * 72, delta=0.01)
                self.assertAlmostEqual(float(h_pt), 30 / 25.4 * 72, delta=0.01)
                self.assertEqual(int(width), gen.mm_to_dots(50, target.dpi))
                self.assertEqual(int(height), gen.mm_to_dots(30, target.dpi))

    def test_custom_size_limits(self):
        for stem, (_, text) in self.reports.items():
            target = target_for(stem)
            params = {r[1]: r for r in self.records(text, "CPARAM")}
            self.assertEqual(params["Width"][2], "points")
            self.assertAlmostEqual(float(params["Width"][3]), 36.0, delta=0.001)
            self.assertAlmostEqual(float(params["Width"][4]), (target.print_width_mm + 2) / 25.4 * 72, delta=0.01)
            self.assertAlmostEqual(float(params["Height"][4]), target.max_label_length_mm / 25.4 * 72, delta=0.01)


if __name__ == "__main__":
    unittest.main()
