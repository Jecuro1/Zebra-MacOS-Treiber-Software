#!/usr/bin/env python3
"""
run_e2e.py – End-to-End-Tests der LabelWerk-CUPS-Filter.

Ablauf je Testfall:
  1. ``mkraster`` erzeugt eine CUPS-Rasterdatei (beliebige Kopfdaten, Muster) und legt die an
     libcups übergebenen Rohzeilen zusätzlich als Datei ab.
  2. ``rastertolabelwerk`` wird wie von CUPS aufgerufen (argv, Umgebungsvariable PPD, Datei oder
     stdin).
  3. ``reference_encoder.py`` berechnet aus denselben Rohzeilen unabhängig Luminanz, Rasterung
     und Auftragsformat; die Filterausgabe muss byte-genau übereinstimmen. Zusätzlich werden die
     PAGE-Meldungen und – bei ZPL – die dekodierten Grafikdaten geprüft.

Weitere Prüfungen: Fehlerfälle (planar, unbekannte Farbräume, abgeschnittene Daten, falsche
Aufrufe), Seiten der Höhe 0, SIGTERM-Abbruch (auch vor der ersten Seite und vor dem Datenstrom),
eine 2400 × 32000-Seite mit Speichermessung, ``commandtolabelwerk`` und die Test-PPD mit
``cupstestppd``.

Windows-Druckeinstellungen: Drehung 0/90/180/270°, Markenversatz, Seitenkerben, Linerless-Modi,
Bei letztem Element stoppen, Pause, eigene Steuerzeichen, RTC (``^ST``) mit fester bzw.
schrittweiser Uhr (``LW_FIXED_TIME``/``LW_TIME_STEP_SECONDS``, auch mit anderer Zeitzone ``TZ``),
``~JA`` samt Wartezeit (``LW_CANCEL_DELAY_SCALE``; ohne Angabe setzt der Testrahmen 0, damit kein
Fall wirklich wartet – nur die Zeitmessung wartet kurz), Etikettenbefehle und ``^MF``.

An Etikett anpassen (§8 „F“, ``lwFitToLabel``/``lwLabelWidth``/``lwLabelHeight``): A4/Letter-Seiten mit
kleinem Etikett in der Ecke, volle Seiten (verkleinert), leere Seiten, passende Größen (unverändert),
Drehung, Endlosmaterial (nur Breite), ``PageSize`` statt ``cupsPageSize``, PPD-Standard ``Off``.

Aufruf:
    run_e2e.py --bindir build [--quick] [--wrapper "valgrind -q …"] [--only MUSTER] [--keep]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import reference_encoder as ref  # noqa: E402

BASE_PPD = os.path.join(HERE, "ppd", "lwtest.ppd")

# Zwischenprozess für die Speichermessung: fork/exec des Filters, ru_maxrss in Datei argv[1].
MEASURE_RSS = r"""
import os, sys
pid = os.fork()
if pid == 0:
    try:
        os.execv(sys.argv[2], sys.argv[2:])
    finally:
        os._exit(127)
_, status, usage = os.wait4(pid, 0)
with open(sys.argv[1], "w") as f:
    f.write(str(usage.ru_maxrss))
code = os.waitstatus_to_exitcode(status)
sys.exit(code if code >= 0 else 128 - code)
"""
LANGS = ["ZPL", "EPL", "CPCL"]


def b64u(text: str) -> str:
    return ref.base64url_encode(text)


# --------------------------------------------------------------------------------------------
# PPD-Varianten
# --------------------------------------------------------------------------------------------

@dataclass
class PPDInfo:
    path: str
    defaults: Dict[str, str]
    choices: Dict[str, List[str]]
    attrs: Dict[str, str]


def parse_ppd(text: str, path: str) -> PPDInfo:
    defaults = {m[1]: m[2] for m in re.finditer(r"^\*Default(\w+): (\S+)\s*$", text, re.M)}
    choices: Dict[str, List[str]] = {}
    for m in re.finditer(r'^\*(\w+) ([^/:\s]+)(?:/[^:\n]*)?: "', text, re.M):
        choices.setdefault(m[1], []).append(m[2])
    attrs = {m[1]: m[2] for m in re.finditer(r'^\*(lw\w+): "([^"]*)"\s*$', text, re.M)}
    return PPDInfo(path, defaults, choices, attrs)


def make_ppd(directory: str, spec) -> Optional[PPDInfo]:
    """spec: "base" | None | dict(defaults=…, attrs=…, extra=…)."""
    if spec is None or spec == "missing":
        return None
    text = open(BASE_PPD, encoding="ascii").read()
    if isinstance(spec, dict):
        for option, value in spec.get("defaults", {}).items():
            text, n = re.subn(r"^\*Default%s: .*$" % re.escape(option), "*Default%s: %s" % (option, value),
                              text, flags=re.M)
            assert n == 1, option
        for attr, value in spec.get("attrs", {}).items():
            if value is None:
                text = re.sub(r'^\*%s: ".*"\n' % re.escape(attr), "", text, flags=re.M)
            else:
                text, n = re.subn(r'^\*%s: ".*"$' % re.escape(attr), '*%s: "%s"' % (attr, value), text, flags=re.M)
                if n == 0:
                    text = text.replace("*lwModel:", '*%s: "%s"\n*lwModel:' % (attr, value), 1)
        text += spec.get("extra", "")
    path = os.path.join(directory, "test.ppd")
    with open(path, "w", encoding="ascii") as f:
        f.write(text)
    return parse_ppd(text, path)


def simulate_marked(info: Optional[PPDInfo], argv: Dict[str, str]) -> Dict[str, str]:
    """ppdMarkDefaults + cupsMarkOptions: Auswahl aus argv, falls sie eine PPD-Auswahl ist."""
    if info is None:
        return {}
    marked = {k: v for k, v in info.defaults.items() if k in info.choices}
    argv_ci = {k.lower(): v for k, v in argv.items()}
    for option, choices in info.choices.items():
        value = argv_ci.get(option.lower())
        if value is None:
            continue
        for choice in choices:
            if choice.lower() == value.lower():
                marked[option] = choice
    return marked


def ppd_int(info: Optional[PPDInfo], name: str, minimum: int, fallback: int) -> int:
    if info is None or name not in info.attrs or info.attrs[name] == "":
        return fallback
    value = ref._parse_int(info.attrs[name].strip(ref.SPACE))
    if value is ref.INVALID or value is ref.DEFAULT or value < minimum:
        return fallback
    return value


# --------------------------------------------------------------------------------------------
# Testfälle
# --------------------------------------------------------------------------------------------

@dataclass
class Case:
    name: str
    pages: List[str]
    opts: Dict[str, str] = field(default_factory=dict)
    opt_string: Optional[str] = None
    ppd: object = "base"
    copies: object = 1
    mode: str = "native"
    stdin: bool = False
    exit_code: Optional[int] = 0       # None: 1, falls libcups keine Seite liefert, sonst 0
    stderr_has: List[str] = field(default_factory=list)
    stderr_lacks: List[str] = field(default_factory=list)
    compare: bool = True
    quick: bool = False
    expect: Optional[Callable[["Context"], bytes]] = None
    max_rss_mb: Optional[float] = None
    timeout: float = 120.0
    env: Dict[str, str] = field(default_factory=dict)   # z. B. LW_FIXED_TIME, TZ

    def argv_options(self) -> str:
        if self.opt_string is not None:
            return self.opt_string
        return " ".join("%s=%s" % (k, v) for k, v in self.opts.items())


@dataclass
class Context:
    case: Case
    infos: List[dict]
    dump: bytes
    ppd: Optional[PPDInfo]
    argv: Dict[str, str]
    settings: ref.Settings
    collate: bool
    copies: int
    max_width: int
    gap: int
    now: Optional[int] = None
    time_step: int = 0


@contextmanager
def time_zone(tz: Optional[str]):
    """Setzt TZ für die Referenzrechnung (wie in der Umgebung des Filters) und stellt sie wieder her."""
    if tz is None:
        yield
        return
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


class Runner:
    def __init__(self, args):
        self.bindir = os.path.abspath(args.bindir)
        self.filter = os.path.join(self.bindir, "rastertolabelwerk")
        self.command_filter = os.path.join(self.bindir, "commandtolabelwerk")
        self.mkraster = os.path.join(self.bindir, "tests", "mkraster")
        self.wrapper = shlex.split(args.wrapper) if args.wrapper else []
        self.quick = args.quick
        self.only = args.only
        self.keep = args.keep
        self.verbose = args.verbose
        self.tmp = tempfile.mkdtemp(prefix="lw-e2e-")
        self.passed = 0
        self.failed: List[str] = []
        self.checks = 0
        for exe in (self.filter, self.command_filter, self.mkraster):
            if not os.access(exe, os.X_OK):
                sys.exit("Programm fehlt: %s (vorher 'make tests' ausführen)" % exe)

    # --- Hilfen ---------------------------------------------------------------------------
    def check(self, cond: bool, message: str, errors: List[str]):
        self.checks += 1
        if not cond:
            errors.append(message)

    def case_dir(self, name: str) -> str:
        d = os.path.join(self.tmp, re.sub(r"[^A-Za-z0-9_.-]+", "_", name))
        os.makedirs(d, exist_ok=True)
        return d

    def run_mkraster(self, directory: str, pages: Sequence[str], mode: str):
        raster = os.path.join(directory, "in.ras")
        dump = os.path.join(directory, "in.raw")
        cmd = [self.mkraster, "-o", raster, "-m", mode, "-d", dump] + list(pages)
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError("mkraster fehlgeschlagen: %s" % result.stderr.strip())
        records = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        infos = [rec for rec in records if "page" in rec]
        summary = next(rec for rec in records if "readable_pages" in rec)
        readable = summary["readable_pages"]
        sizes = summary.get("page_sizes", [])
        for index, info in enumerate(infos):
            info["readable"] = index < readable   # liefert libcups diese Seite vollständig?
            # Seitengröße in Punkten, wie der Filter sie liest (cupsPageSize bzw. PageSize)
            info["page_size"] = tuple(sizes[index]) if index < len(sizes) else None
        with open(dump, "rb") as f:
            return raster, infos, f.read()

    def run_filter(self, exe: str, argv: List[str], env: Dict[str, str], stdin_path: Optional[str],
                   directory: str, timeout: float, measure_rss: bool = False):
        """Startet einen Filter; liefert (Exitcode, stdout, stderr, Spitzen-RSS in MB oder None).

        Der Spitzenspeicher eines Kindprozesses enthält unter Linux beim exec den Speicher des
        aufrufenden Prozesses (ru_maxrss). Für eine aussagekräftige Messung startet ein kleiner
        Zwischenprozess den Filter per fork/exec und meldet dessen ru_maxrss."""
        out_path = os.path.join(directory, "out.bin")
        rss_path = os.path.join(directory, "rss.txt")
        command = self.wrapper + [exe] + argv
        if measure_rss:
            command = [sys.executable, "-c", MEASURE_RSS, rss_path] + command
        with open(out_path, "wb") as out, open(os.path.join(directory, "err.txt"), "wb") as err:
            stdin = open(stdin_path, "rb") if stdin_path else subprocess.DEVNULL
            try:
                proc = subprocess.Popen(command, stdout=out, stderr=err, stdin=stdin, env=env)
                deadline = time.time() + timeout
                while True:
                    pid, status, usage = os.wait4(proc.pid, os.WNOHANG)
                    if pid != 0:
                        break
                    if time.time() > deadline:
                        proc.kill()
                        pid, status, usage = os.wait4(proc.pid, 0)
                        break
                    time.sleep(0.005)
                proc.returncode = os.waitstatus_to_exitcode(status)
            finally:
                if stdin_path:
                    stdin.close()
        rss = None
        if measure_rss and os.path.exists(rss_path):
            with open(rss_path) as f:
                rss = int(f.read().strip()) / (1024.0 * 1024.0 if sys.platform == "darwin" else 1024.0)
        with open(out_path, "rb") as f:
            output = f.read()
        with open(os.path.join(directory, "err.txt"), "rb") as f:
            stderr = f.read().decode("utf-8", "replace")
        return proc.returncode, output, stderr, rss

    def report(self, name: str, errors: List[str], seconds: float):
        if errors:
            self.failed.append(name)
            print("FEHLER  %-58s (%.2fs)" % (name, seconds))
            for e in errors:
                print("        - " + e)
        else:
            self.passed += 1
            if self.verbose:
                print("ok      %-58s (%.2fs)" % (name, seconds))

    def selected(self, case_name: str, quick: bool) -> bool:
        if self.only and not any(o in case_name for o in self.only):
            return False
        if self.quick and not quick:
            return False
        return True

    # --- Rasterfilter ---------------------------------------------------------------------
    def run_case(self, case: Case):
        if not self.selected(case.name, case.quick):
            return
        start = time.time()
        errors: List[str] = []
        directory = self.case_dir(case.name)
        try:
            raster, infos, dump = self.run_mkraster(directory, case.pages, case.mode)
            ppd = make_ppd(directory, case.ppd)
            env = dict(os.environ)
            env.pop("PPD", None)
            env.setdefault("LW_CANCEL_DELAY_SCALE", "0")   # ~JA-Wartezeit in Tests nicht abwarten
            env.update(case.env)
            if case.ppd == "missing":
                env["PPD"] = os.path.join(directory, "gibt-es-nicht.ppd")
            elif ppd is not None:
                env["PPD"] = ppd.path
            argv_text = case.argv_options()
            argv = ["42", "tester", "Testauftrag", str(case.copies), argv_text]
            if not case.stdin:
                argv.append(raster)
            code, output, stderr, rss = self.run_filter(self.filter, argv, env, raster if case.stdin else None,
                                                        directory, case.timeout,
                                                        measure_rss=case.max_rss_mb is not None and not self.wrapper)
            exit_code = case.exit_code
            if exit_code is None:
                exit_code = 0 if any(info["readable"] for info in infos) else 1
            self.check(code == exit_code, "Exitcode %d, erwartet %d; stderr: %s" % (
                code, exit_code, stderr.strip().splitlines()[-3:]), errors)
            for needle in case.stderr_has:
                self.check(needle in stderr, "stderr enthält nicht %r" % needle, errors)
            for needle in case.stderr_lacks:
                self.check(needle not in stderr, "stderr enthält unerwartet %r" % needle, errors)
            if rss is not None and case.max_rss_mb is not None:
                self.check(rss <= case.max_rss_mb, "Speicherbedarf %.1f MB > %.1f MB" % (rss, case.max_rss_mb), errors)
            if case.compare and not errors and code == 0:
                ctx = self.context(case, infos, dump, ppd, argv_text)
                with time_zone(case.env.get("TZ")):
                    expected = case.expect(ctx) if case.expect else self.expected(ctx)
                if output != expected:
                    pos = next((i for i, (a, b) in enumerate(zip(output, expected)) if a != b),
                               min(len(output), len(expected)))
                    with open(os.path.join(directory, "expected.bin"), "wb") as f:
                        f.write(expected)
                    errors.append("Ausgabe weicht ab (Länge %d, erwartet %d, erste Abweichung bei %d): ist %r, erwartet %r"
                                  % (len(output), len(expected), pos, output[max(0, pos - 20):pos + 30],
                                     expected[max(0, pos - 20):pos + 30]))
                    self.checks += 1
                else:
                    self.checks += 1
                    if case.expect is None:
                        self.verify_page_messages(ctx, stderr, errors)
                        if ctx.settings.language == "ZPL":
                            self.verify_zpl_graphics(ctx, output, errors)
        except Exception as exc:  # noqa: BLE001 – Testrahmen meldet jeden Fehler
            errors.append("Ausnahme: %r" % (exc,))
        self.report(case.name, errors, time.time() - start)

    def context(self, case: Case, infos, dump, ppd: Optional[PPDInfo], argv_text: str) -> Context:
        argv = ref.parse_cups_options(argv_text)
        marked = simulate_marked(ppd, argv)
        defaults = ppd.defaults if ppd else {}
        settings = ref.resolve_settings(argv, marked, defaults)
        fixed = case.env.get("LW_FIXED_TIME")
        step = case.env.get("LW_TIME_STEP_SECONDS") if fixed is not None else None
        if settings.rtc and settings.language == "ZPL" and fixed is None:
            raise AssertionError("RTC-Fall ohne LW_FIXED_TIME ist nicht reproduzierbar")
        return Context(case=case, infos=infos, dump=dump, ppd=ppd, argv=argv, settings=settings,
                       collate=ref.resolve_collate(argv, marked), copies=ref.parse_copies(str(case.copies)),
                       max_width=ppd_int(ppd, "lwMaxPrintWidthDots", 1, 0),
                       gap=ppd_int(ppd, "lwDefaultGapDots", 0, ref.DEFAULT_GAP_DOTS),
                       now=int(fixed) if fixed is not None else None, time_step=int(step) if step else 0)

    @staticmethod
    def readable_infos(ctx: Context):
        """Seiten, die libcups dem Filter liefert (Gegenprobe von mkraster); Seiten ohne Fläche
        überspringt der Filter."""
        result = []
        for info in ctx.infos:
            if not info["readable"]:
                break   # abgeschnittene Seite bzw. von libcups abgelehnter Kopf beendet den Strom
            if info["w"] == 0 or info["h"] == 0:
                continue
            result.append(info)
        return result

    @classmethod
    def images(cls, ctx: Context):
        """Luminanzbilder der gelieferten Seiten."""
        result = []
        for info in cls.readable_infos(ctx):
            raw = ctx.dump[info["dump_offset"]:info["dump_offset"] + info["dump_size"]]
            result.append((info["w"], info["h"], ref.luminance_from_samples(raw, info)))
        return result

    @classmethod
    def page_sizes(cls, ctx: Context):
        """Seitengröße (Punkte) und Auflösung je gelieferter Seite – für §8 „F“."""
        sizes = []
        for info in cls.readable_infos(ctx):
            size = info.get("page_size")
            valid = size is not None and size[0] > 0 and size[1] > 0
            sizes.append((size[0], size[1], info["xres"], info["yres"]) if valid else None)
        return sizes

    def expected(self, ctx: Context) -> bytes:
        res = ctx.infos[0]["xres"] if ctx.infos else 203
        return ref.encode_job_from_luminance(self.images(ctx), ctx.settings, page_sizes=self.page_sizes(ctx),
                                             resolution_dpi=res, max_width=ctx.max_width, gap_dots=ctx.gap,
                                             copies=ctx.copies, collate=ctx.collate,
                                             now=ctx.now, time_step=ctx.time_step)

    def processed_pages(self, ctx: Context):
        s = ctx.settings
        pages = []
        images = ref.fit_images(self.images(ctx), s, self.page_sizes(ctx))
        for index, (w, h, lum) in enumerate(images):
            bm = ref.preprocess(ref.dither(lum, w, h, s.dither, s.threshold), s, ctx.max_width)
            if bm is not None:
                pages.append((index + 1, bm))
        return pages

    def verify_page_messages(self, ctx: Context, stderr: str, errors: List[str]):
        pages = self.processed_pages(ctx)
        seq = ref.label_sequence(len(pages), ctx.copies, ctx.collate)
        expected = [(pages[i][0], q) for i, q in seq]
        actual = [(int(a), int(b)) for a, b in re.findall(r"^PAGE: (\d+) (\d+)$", stderr, re.M)]
        if any(",h=0" in page or page.startswith("h=0") for page in ctx.case.pages):
            # Seiten mit Höhe 0: Ob libcups sie liefert (macOS) oder vorher abbricht/überspringt
            # (Linux, CUPS 2.3/2.4), ist versionsabhängig. Liefert sie libcups, zählt der Filter sie
            # in der Rasterseitennummer mit (z. B. 1, 3). Geprüft werden daher Mengen und die
            # streng steigende Reihenfolge, nicht die absolute Nummer.
            numbers = [n for n, _ in actual]
            self.check([q for _, q in actual] == [q for _, q in expected]
                       and all(a < b for a, b in zip(numbers, numbers[1:])),
                       "PAGE-Meldungen %r, erwartet Mengen %r" % (actual[:8], [q for _, q in expected][:8]), errors)
            return
        self.check(actual == expected, "PAGE-Meldungen %r, erwartet %r" % (actual[:8], expected[:8]), errors)

    def verify_zpl_graphics(self, ctx: Context, output: bytes, errors: List[str]):
        """Unabhängig vom Bytevergleich: Grafikfelder dekodieren und mit den Seiten vergleichen."""
        pages = self.processed_pages(ctx)
        seq = ref.label_sequence(len(pages), ctx.copies, ctx.collate)
        f, _, d = (bytes([c]) for c in (ctx.settings.control_chars or ref.STANDARD_CONTROL_CHARS))
        n = rb"(\d+)"
        pattern = re.escape(f) + b"GFA" + re.escape(d) + n + re.escape(d) + n + re.escape(d) + n + re.escape(d) \
            + rb"(.*?)" + re.escape(f) + b"FS"
        fields = re.findall(pattern, output, re.S)
        self.check(len(fields) == len(seq), "Anzahl Grafikfelder %d, erwartet %d" % (len(fields), len(seq)), errors)
        for (total, total2, bpr, data), (index, _) in zip(fields, seq):
            bm = pages[index][1]
            total, bpr = int(total), int(bpr)
            if data.startswith(b":Z64:"):
                raw = ref.z64_decode(data)
            else:
                raw = ref.acs_decode(data, bpr, total)   # Hex ist eine Teilmenge von ACS
            ok = total == len(bm.data) and int(total2) == total and bpr == bm.bpr and raw == bytes(bm.data)
            self.check(ok, "dekodierte Grafik von Seite %d stimmt nicht" % pages[index][0], errors)
            if not ok:
                break

    # --- Sonderfälle ----------------------------------------------------------------------
    def run_custom(self, name: str, quick: bool, fn: Callable[[str, List[str]], None]):
        if not self.selected(name, quick):
            return
        start = time.time()
        errors: List[str] = []
        try:
            fn(self.case_dir(name), errors)
        except Exception as exc:  # noqa: BLE001
            errors.append("Ausnahme: %r" % (exc,))
        self.report(name, errors, time.time() - start)

    def cleanup(self):
        if self.keep or self.failed:
            print("Testdateien: %s" % self.tmp)
        else:
            shutil.rmtree(self.tmp, ignore_errors=True)


# --------------------------------------------------------------------------------------------
# Falldefinitionen
# --------------------------------------------------------------------------------------------

P_GRAD = "w=203,h=96,pattern=gradient"
P_TEXT = "w=203,h=96,pattern=text,seed=3"
P_NOISE = "w=150,h=64,pattern=noise,seed=7"
P_BLANK = "w=96,h=40,pattern=blank"
P_BLACK = "w=40,h=20,pattern=black"
P_WIDE = "w=900,h=48,pattern=hgrad"
P_ODD = "w=13,h=7,pattern=noise,seed=2"
P_SMALL = "w=37,h=11,pattern=text,seed=5"


def raster_cases() -> List[Case]:
    cases: List[Case] = []
    add = cases.append

    # 1. Sprache × Kompression
    for lang in LANGS:
        for comp in ("Z64", "ACS", "Hex"):
            add(Case("sprache-%s-%s" % (lang, comp), [P_GRAD, P_TEXT],
                     {"lwLanguage": lang, "lwCompression": comp}, quick=(comp == "Z64")))

    # 2. Alle Rasterverfahren × Sprachen
    for lang in LANGS:
        for dither in ref.DITHERS:
            add(Case("raster-%s-%s" % (lang, dither), [P_GRAD, P_NOISE],
                     {"lwLanguage": lang, "lwDither": dither, "lwCompression": "ACS"},
                     quick=(lang == "ZPL" and dither in ("Stucki", "Halftone"))))
    for dither in ref.DITHERS:
        for t in ("1", "64", "200", "254"):
            add(Case("schwelle-%s-%s" % (dither, t), [P_GRAD], {"lwDither": dither, "lwThreshold": t,
                                                                 "lwCompression": "Hex"}))
    add(Case("schwelle-begrenzt-0", [P_GRAD], {"lwThreshold": "0", "lwDither": "Ordered"}))
    add(Case("schwelle-begrenzt-999", [P_GRAD], {"lwThreshold": "999", "lwDither": "Atkinson"}))

    # 3. Bildoperationen je Sprache
    for lang in LANGS:
        for flags in ({"lwNegative": "True"}, {"lwMirror": "True"}, {"lwRotate180": "True"},
                      {"lwMirror": "True", "lwRotate180": "True", "lwNegative": "True"}):
            name = "bild-%s-%s" % (lang, "-".join(k[2:] for k in flags))
            add(Case(name, [P_TEXT, P_ODD], dict(flags, lwLanguage=lang, lwCompression="ACS"),
                     quick=(len(flags) == 3 and lang == "CPCL")))

    # 4. Leere Seiten
    for lang in LANGS:
        add(Case("leer-ueberspringen-%s" % lang, [P_TEXT, P_BLANK, P_GRAD],
                 {"lwLanguage": lang, "lwSkipBlank": "True"}, copies=2))
        add(Case("leer-behalten-%s" % lang, [P_TEXT, P_BLANK], {"lwLanguage": lang, "lwSkipBlank": "False"}))
    add(Case("leer-alles-uebersprungen", [P_BLANK, P_BLANK], {"lwSkipBlank": "True", "lwDarkness": "10",
                                                               "lwEndCmd": b64u("~JR")},
             stderr_has=["übersprungen"]))
    add(Case("leer-negativ-schwarz", [P_BLACK, P_TEXT], {"lwSkipBlank": "True", "lwNegative": "True"}))

    # 5. Abschneiden auf *lwMaxPrintWidthDots (Rasterung vor dem Abschneiden)
    for lang in LANGS:
        for dither in ("Threshold", "FloydSteinberg", "Stucki"):
            add(Case("abschneiden-%s-%s" % (lang, dither), [P_WIDE, P_GRAD],
                     {"lwLanguage": lang, "lwDither": dither, "lwMirror": "True"},
                     stderr_has=["abgeschnitten"], quick=(lang == "EPL" and dither == "Stucki")))
    add(Case("abschneiden-ungerade-breite", ["w=845,h=10,pattern=noise"], {"lwCompression": "Hex"},
             ppd={"attrs": {"lwMaxPrintWidthDots": "837"}}))
    add(Case("abschneiden-ohne-ppd-keine-grenze", [P_WIDE], {"lwCompression": "ACS"}, ppd=None))
    # ACS-Läufe > 419 Nibbles (Gruppenteilung) in Rumpf und Abschluss
    add(Case("acs-lange-laeufe", ["w=3400,h=6,pattern=hgrad", "w=3400,h=4,pattern=bars"],
             {"lwCompression": "ACS"}, ppd=None))
    add(Case("acs-lange-laeufe-negativ", ["w=3400,h=6,pattern=hgrad"], {"lwCompression": "ACS",
                                                                         "lwNegative": "True"}, ppd=None))

    # 6. Kopien und Sortierung
    three = [P_TEXT, P_GRAD, P_ODD]
    add(Case("kopien-eine-seite", [P_TEXT], copies=3, quick=True))
    add(Case("kopien-sortiert", three, copies=2, quick=True))
    add(Case("kopien-nicht-sortiert", three, {"collate": "false"}, copies=2))
    add(Case("kopien-noCollate", three, opt_string="noCollate lwCompression=Hex", copies=2))
    add(Case("kopien-mdh-uncollated", three, {"multiple-document-handling": "separate-documents-uncollated-copies"},
             copies=3))
    add(Case("kopien-mdh-collated", three, {"multiple-document-handling": "separate-documents-collated-copies"},
             copies=2))
    add(Case("kopien-collate-ungueltig", three, {"collate": "vielleicht"}, copies=2,
             stderr_has=["collate"]))
    add(Case("kopien-ppd-collate-false", three, copies=2,
             ppd={"extra": "\n*OpenUI *Collate/Collate: Boolean\n*OrderDependency: 30 AnySetup *Collate\n"
                           "*DefaultCollate: False\n*Collate True/On: \"\"\n*Collate False/Off: \"\"\n"
                           "*CloseUI: *Collate\n"}))
    for lang in ("EPL", "CPCL"):
        add(Case("kopien-sortiert-%s" % lang, three, {"lwLanguage": lang}, copies=3))
        add(Case("kopien-nicht-sortiert-%s" % lang, three, {"lwLanguage": lang, "Collate": "False"}, copies=2))
    add(Case("kopien-ungueltig", [P_TEXT], copies="viele", stderr_has=["Kopienzahl"]))
    add(Case("kopien-null", [P_TEXT], copies=0))
    add(Case("kopien-gross", [P_TEXT], copies=123456789, stderr_has=["begrenzt"]))
    add(Case("kopien-schnitt", three, {"lwCutEvery": "5", "lwSaveSettings": "True"}, copies=4))

    # 7. Auftrags- und Etiketteneinstellungen
    for lang in LANGS:
        base = {"lwLanguage": lang, "lwCompression": "Hex"}
        add(Case("einstellungen-alle-%s" % lang, [P_TEXT],
                 dict(base, lwDarkness="17", lwSpeed="9", lwMediaType="ThermalTransfer", lwMediaTracking="Gap",
                      lwPrintMode="Rewind", lwLabelTop="37", lwLabelLeft="-33", lwTearOff="7",
                      lwBackfeed="Normal", lwCalibrate="True", lwSaveSettings="True", lwCutEvery="25"),
                 quick=(lang == "ZPL")))
        for darkness in ("0", "1", "8", "15", "16", "29", "30", "45"):
            add(Case("schwaerzung-%s-%s" % (lang, darkness), [P_ODD], dict(base, lwDarkness=darkness)))
        for speed in ("1", "5", "6", "7", "14", "20"):
            add(Case("geschwindigkeit-%s-%s" % (lang, speed), [P_ODD], dict(base, lwSpeed=speed)))
        for tracking in ("Gap", "BlackMark", "Continuous", "Auto", "Default"):
            add(Case("erkennung-%s-%s" % (lang, tracking), [P_ODD], dict(base, lwMediaTracking=tracking)))
        for mode in ("TearOff", "PeelOff", "Cutter", "DelayedCut", "Rewind", "Applicator", "Kiosk"):
            for media in ("DirectThermal", "ThermalTransfer", "Default"):
                if lang != "EPL" and media != "DirectThermal":
                    continue
                add(Case("modus-%s-%s-%s" % (lang, mode, media), [P_ODD],
                         dict(base, lwPrintMode=mode, lwMediaType=media)))
        add(Case("nur-medium-%s" % lang, [P_ODD], dict(base, lwMediaType="DirectThermal")))
    for backfeed in ("After", "Before", "Normal", "Off"):
        add(Case("rueckzug-%s" % backfeed, [P_ODD], {"lwBackfeed": backfeed}))
    for top, left, tear in (("-120", "-9999", "-120"), ("120", "9999", "120"), ("-500", "20000", "500"),
                            ("0", "0", "0"), ("-5", "3", "-9"), ("Custom.37", "Custom.-41", "Custom.12")):
        add(Case("position-%s-%s-%s" % (top, left, tear), [P_ODD],
                 {"lwLabelTop": top, "lwLabelLeft": left, "lwTearOff": tear}))
    for cut in ("1", "100", "12345"):
        add(Case("schnitt-%s" % cut, [P_ODD, P_ODD], {"lwCutEvery": cut}, copies=3))

    # 8. Start-/Endbefehle
    start = "^XA^FXStart äöü\n^XZ"
    end = "^XA^FX€ Ende^XZ"
    for lang in LANGS:
        add(Case("befehle-%s" % lang, [P_ODD], {"lwLanguage": lang, "lwStartCmd": b64u(start),
                                                "lwEndCmd": b64u(end)}, copies=2, quick=(lang == "EPL")))
    sample = b64u("^XA^FX LabelWerk^XZ")
    add(Case("befehle-ppd-standard", [P_ODD], ppd={"defaults": {"lwStartCmd": sample, "lwEndCmd": sample}}))
    add(Case("befehle-ungueltig-faellt-auf-ppd", [P_ODD], {"lwStartCmd": "@@@", "lwEndCmd": "_w"},
             ppd={"defaults": {"lwStartCmd": sample}}, stderr_has=["lwStartCmd", "lwEndCmd"]))
    add(Case("befehle-none", [P_ODD], {"lwStartCmd": "None"}, ppd={"defaults": {"lwStartCmd": sample}}))
    add(Case("befehle-mit-padding", [P_ODD], {"lwStartCmd": ref.base64.urlsafe_b64encode(b"~JA").decode()}))

    # 9. Vorrang argv > markierte Auswahl > PPD-Standard > eingebauter Standard
    ppd_defaults = {"defaults": {"lwLanguage": "EPL", "lwDither": "Atkinson", "lwDarkness": "15",
                                 "lwThreshold": "160", "lwMediaTracking": "BlackMark", "lwMirror": "True",
                                 "lwCompression": "ACS", "lwSpeed": "4"}}
    add(Case("vorrang-ppd-standard", [P_GRAD], ppd=ppd_defaults, quick=True))
    add(Case("vorrang-argv-schlaegt-ppd", [P_GRAD], {"lwLanguage": "ZPL", "lwDither": "Ordered",
                                                    "lwDarkness": "3", "lwThreshold": "96", "lwMirror": "False"},
             ppd=ppd_defaults))
    add(Case("vorrang-argv-ausserhalb-ppd", [P_GRAD], {"lwDarkness": "23", "lwThreshold": "111",
                                                      "lwLabelTop": "37", "lwCutEvery": "7"},
             ppd=ppd_defaults))
    add(Case("vorrang-ungueltig-faellt-durch", [P_GRAD], {"lwDither": "Bogus", "lwLanguage": "PCL",
                                                         "lwDarkness": "dunkel", "lwMirror": "vielleicht"},
             ppd=ppd_defaults, stderr_has=["Bogus", "PCL", "dunkel", "vielleicht"]))
    add(Case("vorrang-default-schlaegt-ppd", [P_GRAD], {"lwDarkness": "Default", "lwSpeed": "Default",
                                                       "lwMediaTracking": "Default"}, ppd=ppd_defaults))
    add(Case("vorrang-begrenzung", [P_GRAD], {"lwDarkness": "45", "lwSpeed": "99", "lwThreshold": "-3"},
             ppd=ppd_defaults))
    add(Case("vorrang-gross-klein", [P_GRAD], opt_string="LWDITHER=stucki lwlanguage=cpcl LWMIRROR=yes",
             ppd=ppd_defaults))
    add(Case("vorrang-leerraum", [P_GRAD], opt_string="lwDarkness='  12 ' lwDither=\" Halftone\""))
    add(Case("vorrang-ohne-ppd", [P_GRAD, P_TEXT], {"lwSpeed": "3"}, ppd=None, quick=True))
    add(Case("vorrang-ppd-fehlt", [P_GRAD], {"lwDither": "Ordered"}, ppd="missing",
             stderr_has=["PPD-Datei"]))
    add(Case("vorrang-ppd-default-ungueltig", [P_GRAD], ppd={"defaults": {"lwDither": "Kaputt", "lwDarkness": "x"}},
             stderr_has=["Kaputt"]))
    add(Case("attribut-luecke-epl", [P_ODD], {"lwLanguage": "EPL", "lwMediaTracking": "BlackMark"},
             ppd={"attrs": {"lwDefaultGapDots": "40"}}))
    add(Case("attribut-luecke-ungueltig", [P_ODD], {"lwLanguage": "EPL"},
             ppd={"attrs": {"lwDefaultGapDots": "-4"}}, stderr_has=["lwDefaultGapDots"]))
    add(Case("attribut-breite-ungueltig", [P_WIDE], ppd={"attrs": {"lwMaxPrintWidthDots": "breit"}},
             stderr_has=["lwMaxPrintWidthDots"]))
    add(Case("attribut-fehlen", [P_WIDE], {"lwLanguage": "EPL"},
             ppd={"attrs": {"lwMaxPrintWidthDots": None, "lwDefaultGapDots": None, "lwModel": None}}))

    # 10. Rasterformate (Floyd–Steinberg reagiert auf jede Luminanzabweichung)
    formats = [
        ("1bit-K", "cs=K,bpc=1"), ("1bit-W", "cs=W,bpc=1"), ("1bit-SW", "cs=SW,bpc=1"),
        ("2bit-W", "cs=W,bpc=2"), ("2bit-K", "cs=K,bpc=2"), ("4bit-SW", "cs=SW,bpc=4"), ("4bit-K", "cs=K,bpc=4"),
        ("8bit-W", "cs=W,bpc=8"), ("8bit-SW", "cs=SW,bpc=8"), ("8bit-K", "cs=K,bpc=8"),
        ("16bit-SW", "cs=SW,bpc=16"), ("16bit-K", "cs=K,bpc=16"), ("16bit-W", "cs=W,bpc=16"),
        ("RGB-8", "cs=RGB,bpc=8"), ("SRGB-8", "cs=SRGB,bpc=8"), ("ADOBERGB-8", "cs=ADOBERGB,bpc=8"),
        ("SRGB-16", "cs=SRGB,bpc=16"), ("RGB-1", "cs=RGB,bpc=1"), ("RGB-2", "cs=RGB,bpc=2"),
        ("RGB-4", "cs=RGB,bpc=4"), ("RGB-banded-8", "cs=RGB,bpc=8,order=banded"),
        ("RGB-banded-1", "cs=RGB,bpc=1,order=banded"), ("RGBA-8", "cs=RGBA,bpc=8"),
        ("CMY-8", "cs=CMY,bpc=8"), ("YMC-4", "cs=YMC,bpc=4"), ("CMYK-8", "cs=CMYK,bpc=8"),
        ("CMYK-16", "cs=CMYK,bpc=16"), ("CMYK-1", "cs=CMYK,bpc=1"), ("YMCK-8", "cs=YMCK,bpc=8"),
        ("KCMY-8", "cs=KCMY,bpc=8"), ("CMYK-banded", "cs=CMYK,bpc=8,order=banded"),
        ("SW-planar", "cs=SW,bpc=8,order=planar"), ("RGB-1-3bit", "cs=RGB,bpc=1,bpp=3"),
        ("CMY-2", "cs=CMY,bpc=2"), ("RGBA-16", "cs=RGBA,bpc=16"), ("KCMY-4", "cs=KCMY,bpc=4"),
    ]
    for label, fmt in formats:
        for pattern in ("gradient", "text"):
            add(Case("format-%s-%s" % (label, pattern), ["w=61,h=37,pattern=%s,%s" % (pattern, fmt)],
                     {"lwDither": "FloydSteinberg", "lwCompression": "Hex"},
                     quick=(label in ("RGB-1", "16bit-K") and pattern == "text")))
    for width in (1, 2, 7, 8, 9, 15, 16, 17, 833):
        add(Case("breite-%d" % width, ["w=%d,h=11,pattern=noise,seed=%d" % (width, width)],
                 {"lwCompression": "ACS", "lwDither": "Atkinson"}, ppd=None))
    add(Case("gemischte-formate", ["w=50,h=20,cs=K,bpc=1,pattern=checker", "w=70,h=30,cs=RGB,bpc=8",
                                   "w=33,h=9,cs=SW,bpc=16", "w=41,h=13,cs=CMYK,bpc=8"],
             {"lwDither": "Stucki", "lwLanguage": "EPL"}, copies=2))
    for mode in ("compressed", "pwg"):
        add(Case("modus-%s-SW" % mode, [P_TEXT, "w=77,h=21,cs=SW,bpc=16,pattern=gradient"],
                 {"lwDither": "FloydSteinberg"}, mode=mode, quick=(mode == "pwg")))
        add(Case("modus-%s-SRGB" % mode, ["w=64,h=30,cs=SRGB,bpc=8,pattern=gradient"], mode=mode))
    add(Case("modus-pwg-K1", ["w=64,h=30,cs=K,bpc=1,pattern=checker"], mode="pwg"))
    add(Case("cpcl-300dpi", ["w=100,h=50,res=300,pattern=text"], {"lwLanguage": "CPCL"}))
    add(Case("cpcl-600dpi-gemischt", ["w=100,h=50,xres=600,yres=300,pattern=text"], {"lwLanguage": "CPCL"}))
    add(Case("stdin-eingabe", [P_TEXT, P_GRAD], {"lwLanguage": "EPL"}, stdin=True, copies=2, quick=True))
    add(Case("stdin-komprimiert", [P_TEXT], stdin=True, mode="compressed"))

    # 11. Fehlerfälle
    add(Case("fehler-planar-rgb", ["w=20,h=5,cs=RGB,bpc=8,order=planar"], exit_code=1,
             stderr_has=["ERROR:", "Planare"], compare=False, quick=True))
    add(Case("fehler-planar-nach-guter-seite", [P_ODD, "w=20,h=5,cs=CMYK,bpc=8,order=planar"], exit_code=1,
             stderr_has=["Planare"], compare=False))
    add(Case("fehler-cielab", ["w=20,h=5,cs=CIELAB,bpc=8"], exit_code=1, stderr_has=["CIELab"], compare=False))
    add(Case("fehler-icc", ["w=20,h=5,cs=ICC3,bpc=8"], exit_code=1, stderr_has=["ICC3"], compare=False))
    # Köpfe, die libcups selbst ablehnt (Bittiefe 3, Zeilenlänge ≠ Breite × Bit/Pixel): der Filter
    # meldet sauber einen Fehler (die Prüfungen in lw_raster decken die Unit-Tests ab).
    add(Case("fehler-bittiefe", ["w=20,h=5,cs=SW,bpc=3,raw=1"], exit_code=1, stderr_has=["ERROR:"], compare=False))
    add(Case("fehler-zeile-zu-kurz", ["w=20,h=5,cs=SW,bpc=8,bpl=10,raw=1"], exit_code=1, stderr_has=["ERROR:"],
             compare=False))
    add(Case("fehler-zeile-zu-lang", [P_ODD, "w=20,h=5,cs=SW,bpc=8,bpl=64,raw=1", P_GRAD]))
    add(Case("fehler-abgeschnitten", [P_ODD, "w=40,h=30,pattern=text,truncate=12"], exit_code=1,
             stderr_has=["unvollständig"], compare=False, quick=True))
    add(Case("hoehe-null-nach-seite", [P_TEXT, "w=40,h=0,raw=1", P_GRAD], quick=True))
    # Ob libcups an einem Kopf mit Höhe 0 abbricht (2.3/2.4) oder ihn liefert, ist versionsabhängig;
    # der Filter überspringt solche Seiten bzw. meldet „keine Seiten“, wenn gar nichts ankommt.
    add(Case("hoehe-null-zuerst", ["w=40,h=0,raw=1", P_GRAD], exit_code=None))
    cases += windows_cases()
    return cases


# Feste Uhr für RTC-Fälle: 14.11.2023 22:13:20 UTC
FIXED = {"LW_FIXED_TIME": "1700000000", "TZ": "UTC0"}
TZ_BERLIN = "CET-1CEST,M3.5.0,M10.5.0/3"   # POSIX-Zeitzone (ohne tzdata), Sommerzeit am 2.7.2024


def windows_cases() -> List[Case]:
    """Optionen der Windows-Druckeinstellungen (ZDesigner „Druckeinstellungen für ZD421“)."""
    cases: List[Case] = []
    add = cases.append
    P_TALLNOISE = "w=60,h=900,pattern=noise,seed=4"

    # Drehung (lwRotation) – Software-Drehung vor dem Abschneiden, 180° wie bisher
    for lang in LANGS:
        for rotation in ("0", "90", "180", "270"):
            add(Case("drehung-%s-%s" % (lang, rotation), [P_TEXT, P_ODD],
                     {"lwLanguage": lang, "lwRotation": rotation, "lwCompression": "ACS"},
                     quick=(rotation == "90" and lang == "ZPL")))
        add(Case("drehung-%s-90-mit-alt-180" % lang, [P_ODD], {"lwLanguage": lang, "lwRotation": "90",
                                                              "lwRotate180": "True"}))
        add(Case("drehung-%s-270-abschneiden-spiegeln-negativ" % lang, [P_TALLNOISE, P_TEXT],
                 {"lwLanguage": lang, "lwRotation": "270", "lwMirror": "True", "lwNegative": "True",
                  "lwDither": "FloydSteinberg"}, stderr_has=["abgeschnitten"]))
    add(Case("drehung-90-abschneiden", [P_TALLNOISE], {"lwRotation": "90", "lwCompression": "Hex"},
             stderr_has=["abgeschnitten"]))
    add(Case("drehung-ppd-standard", [P_TEXT], ppd={"defaults": {"lwRotation": "270"}}))
    add(Case("drehung-ungueltig-faellt-auf-ppd", [P_TEXT], {"lwRotation": "45"},
             ppd={"defaults": {"lwRotation": "90"}}, stderr_has=["lwRotation"]))
    add(Case("drehung-default", [P_TEXT], {"lwRotation": "Default", "lwRotate180": "True"},
             ppd={"defaults": {"lwRotation": "90"}}))
    add(Case("drehung-kopien-sortiert", [P_TEXT, P_ODD, P_GRAD], {"lwRotation": "90"}, copies=2))

    # Medientyp: Seitenkerben, Markenversatz
    for lang in LANGS:
        add(Case("kerben-%s" % lang, [P_ODD, P_SMALL], {"lwLanguage": lang, "lwMediaTracking": "Notch"}))
    for offset in ("-200", "-80", "0", "37", "283", "999", "Default", "Custom.-12"):
        add(Case("markenversatz-%s" % offset, [P_ODD], {"lwMediaTracking": "BlackMark", "lwMarkOffset": offset}))
    add(Case("markenversatz-nur-schwarze-marke", [P_ODD], {"lwMediaTracking": "Gap", "lwMarkOffset": "40"}))
    add(Case("markenversatz-ohne-erkennung", [P_ODD], {"lwMarkOffset": "40"}))
    add(Case("markenversatz-EPL-ignoriert", [P_ODD], {"lwLanguage": "EPL", "lwMediaTracking": "BlackMark",
                                                      "lwMarkOffset": "40"}))
    add(Case("markenversatz-ppd", [P_ODD], {"lwMediaTracking": "BlackMark"},
             ppd={"defaults": {"lwMarkOffset": "40"}}))

    # Linerless-Modi (SGD media.printmode, kein ^MM)
    for mode in ("LinerlessPeel", "LinerlessCut", "LinerlessDelayedCut", "LinerlessRewind", "LinerlessTear"):
        for lang in LANGS:
            add(Case("linerless-%s-%s" % (lang, mode), [P_ODD, P_SMALL],
                     {"lwLanguage": lang, "lwPrintMode": mode, "lwMediaType": "DirectThermal"},
                     copies=2, quick=(mode == "LinerlessCut" and lang == "ZPL")))

    # Bei letztem Element stoppen (nur Endlosmaterial, alle Sprachen)
    P_TOP = "w=96,h=120,pattern=dots,seed=9"
    for lang in LANGS:
        for offset in ("0", "24", "5000"):
            add(Case("stoppen-%s-%s" % (lang, offset), [P_TEXT, P_GRAD, P_TOP],
                     {"lwLanguage": lang, "lwMediaTracking": "Continuous", "lwStopAtLast": "True",
                      "lwStopOffset": offset}))
    add(Case("stoppen-leer", [P_BLANK, P_TEXT], {"lwMediaTracking": "Continuous", "lwStopAtLast": "True"}))
    add(Case("stoppen-leer-ueberspringen", [P_BLANK, P_TEXT], {"lwMediaTracking": "Continuous",
                                                              "lwStopAtLast": "True", "lwSkipBlank": "True"}))
    add(Case("stoppen-negativ", [P_TEXT], {"lwMediaTracking": "Continuous", "lwStopAtLast": "True",
                                          "lwStopOffset": "16", "lwNegative": "True"}))
    add(Case("stoppen-nur-endlos", [P_TEXT], {"lwMediaTracking": "Gap", "lwStopAtLast": "True",
                                             "lwStopOffset": "16"}))
    add(Case("stoppen-begrenzt", [P_ODD], {"lwMediaTracking": "Continuous", "lwStopAtLast": "True",
                                          "lwStopOffset": "99999"}))
    add(Case("stoppen-gedreht", [P_TALLNOISE], {"lwMediaTracking": "Continuous", "lwStopAtLast": "True",
                                               "lwRotation": "90"}))

    # Pausieren (Vorrang vor Schneiden)
    for pause in ("1", "5", "9999", "20000"):
        add(Case("pause-%s" % pause, [P_ODD, P_SMALL], {"lwPauseEvery": pause}, copies=3))
    add(Case("pause-vor-schneiden", [P_ODD], {"lwPauseEvery": "4", "lwCutEvery": "2"}, copies=8))
    add(Case("pause-null-schneiden", [P_ODD], {"lwPauseEvery": "0", "lwCutEvery": "2"}, copies=8))
    add(Case("pause-EPL-ignoriert", [P_ODD], {"lwLanguage": "EPL", "lwPauseEvery": "3"}, copies=2))

    # Steuerzeichen („Intern“ = Zeichen des Druckers)
    every = {"lwDarkness": "12", "lwTearOff": "-10", "lwBackfeed": "After", "lwCalibrate": "True",
             "lwCancelBefore": "True", "lwPowerUpAction": "Feed", "lwHeadCloseAction": "Length",
             "lwRTC": "EveryLabel", "lwMediaTracking": "BlackMark", "lwMarkOffset": "-20", "lwSpeed": "5",
             "lwLabelTop": "8", "lwLabelLeft": "-4", "lwPauseEvery": "2", "lwSaveSettings": "True",
             "lwStartCmd": b64u("^XA^FX,~^XZ"), "lwLabelStartCmd": b64u("^FO1,1^FD~,^FS"),
             "lwLabelEndCmd": b64u("^FX,"), "lwEndCmd": b64u("~JR")}
    for label, chars in (("raute", ("35", "64", "59")), ("vertauscht", ("126", "94", "44")),
                         ("nur-trenner", ("94", "126", "124")), ("ungueltig", ("200", "32", "59"))):
        for comp in ("Z64", "ACS", "Hex"):
            opts = dict(every, lwControlChars="Printer", lwFormatPrefix=chars[0], lwControlPrefix=chars[1],
                        lwDelimiter=chars[2], lwCompression=comp)
            add(Case("steuerzeichen-%s-%s" % (label, comp), [P_TEXT, P_ODD], opts, copies=2, env=FIXED,
                     stderr_has=["lwFormatPrefix"] if label == "ungueltig" else [],
                     quick=(label == "raute" and comp == "ACS")))
    add(Case("steuerzeichen-standard-ignoriert-praefixe", [P_ODD],
             dict(every, lwControlChars="Standard", lwFormatPrefix="35"), env=FIXED))
    add(Case("steuerzeichen-ppd-standard", [P_ODD], {"lwDarkness": "3"},
             ppd={"defaults": {"lwControlChars": "Printer", "lwFormatPrefix": "35", "lwDelimiter": "59"}}))
    add(Case("steuerzeichen-EPL-ignoriert", [P_ODD], {"lwLanguage": "EPL", "lwControlChars": "Printer",
                                                      "lwFormatPrefix": "35", "lwCancelBefore": "True"}))

    # Echtzeituhr (^ST)
    for mode in ("JobStart", "EveryLabel", "EveryMinute"):
        for step in ("0", "25", "61"):
            add(Case("rtc-%s-%s" % (mode, step), [P_ODD, P_SMALL, P_TEXT], {"lwRTC": mode}, copies=3,
                     env=dict(FIXED, LW_TIME_STEP_SECONDS=step), quick=(mode == "EveryMinute" and step == "25")))
        add(Case("rtc-%s-einzeln" % mode, [P_ODD, P_SMALL], {"lwRTC": mode, "collate": "false"}, copies=4,
                 env=dict(FIXED, LW_TIME_STEP_SECONDS="30")))
    add(Case("rtc-sommerzeit-berlin", [P_ODD], {"lwRTC": "EveryLabel"}, copies=2,
             env={"LW_FIXED_TIME": "1719914400", "LW_TIME_STEP_SECONDS": "3600", "TZ": TZ_BERLIN}))
    add(Case("rtc-jahreswechsel", [P_ODD, P_SMALL], {"lwRTC": "EveryMinute"}, copies=2,
             env={"LW_FIXED_TIME": "1704067170", "LW_TIME_STEP_SECONDS": "45", "TZ": "UTC0"}))
    add(Case("rtc-leer-alles-uebersprungen", [P_BLANK], {"lwRTC": "EveryLabel", "lwSkipBlank": "True"},
             env=FIXED))
    add(Case("rtc-ppd-standard", [P_ODD], ppd={"defaults": {"lwRTC": "JobStart"}}, env=FIXED))
    for lang in ("EPL", "CPCL"):
        add(Case("rtc-%s-ignoriert" % lang, [P_ODD], {"lwLanguage": lang, "lwRTC": "EveryLabel"}, copies=2))
    add(Case("rtc-ungueltige-uhr", [P_ODD], {"lwRTC": "JobStart"}, compare=False,
             env={"LW_FIXED_TIME": "gestern"}, stderr_has=["LW_FIXED_TIME"]))

    # Aufträge vor dem Drucken abbrechen (~JA)
    for lang in LANGS:
        add(Case("abbrechen-%s" % lang, [P_ODD], {"lwLanguage": lang, "lwCancelBefore": "True",
                                                  "lwStartCmd": b64u("~JR"), "lwEndCmd": b64u("END")}))
    add(Case("abbrechen-ohne-seiten", [P_BLANK], {"lwCancelBefore": "True", "lwSkipBlank": "True"}))
    cases += fit_cases()

    # Etikettenbefehle (Anfang/Ende jedes Etiketts)
    start, end = "^FO10,10^A0N,20,20^FDÄnfang €^FS", "^FX Ende,~"
    for lang in LANGS:
        add(Case("etikettenbefehle-%s" % lang, [P_ODD, P_SMALL], {"lwLanguage": lang,
                                                                  "lwLabelStartCmd": b64u(start),
                                                                  "lwLabelEndCmd": b64u(end)}, copies=2))
    add(Case("etikettenbefehle-ppd", [P_ODD], ppd={"defaults": {"lwLabelStartCmd": "XkZYTGFiZWxTdGFydA",
                                                                "lwLabelEndCmd": "XkZYTGFiZWxFbmRl"}}))
    add(Case("etikettenbefehle-ungueltig", [P_ODD], {"lwLabelStartCmd": "@@@", "lwLabelEndCmd": "None"},
             ppd={"defaults": {"lwLabelEndCmd": "XkZYTGFiZWxFbmRl"}}, stderr_has=["lwLabelStartCmd"]))

    # ^MF (nur wenn beide Aktionen gesetzt sind)
    for power, head in (("Feed", "Calibrate"), ("Length", "NoMotion"), ("ShortCal", "Default"),
                        ("Default", "Feed")):
        add(Case("medienaktion-%s-%s" % (power, head), [P_ODD], {"lwPowerUpAction": power,
                                                                 "lwHeadCloseAction": head}))
    add(Case("medienaktion-EPL-ignoriert", [P_ODD], {"lwLanguage": "EPL", "lwPowerUpAction": "Feed",
                                                     "lwHeadCloseAction": "Feed"}))

    # Alles zusammen je Sprache
    for lang in LANGS:
        opts = dict(every, lwLanguage=lang, lwRotation="90", lwMediaTracking="Continuous", lwStopAtLast="True",
                    lwStopOffset="12", lwPrintMode="LinerlessRewind", lwControlChars="Printer",
                    lwFormatPrefix="36", lwRTC="EveryMinute", lwCompression="ACS")
        add(Case("windows-alle-%s" % lang, [P_TEXT, P_TOP, P_ODD], opts, copies=2,
                 env=dict(FIXED, LW_TIME_STEP_SECONDS="40"), quick=True))
    return cases


def sized_page(width_pt: float, height_pt: float, dpi: int = 203, extra: str = "pattern=blank") -> str:
    """mkraster-Seite mit Seitengröße in Punkten (cupsPageSize) und passender Rastergröße."""
    width = int(width_pt * dpi / 72.0 + 0.5)
    height = int(height_pt * dpi / 72.0 + 0.5)
    return "w=%d,h=%d,res=%d,pw=%r,ph=%r,%s" % (width, height, dpi, width_pt, height_pt, extra)


def unfitted(ctx: Context) -> bytes:
    """Erwartung ohne Schritt F (Seiten unverändert) – Gegenprobe für „passt“ und „Off“."""
    res = ctx.infos[0]["xres"] if ctx.infos else 203
    return ref.encode_job_from_luminance(Runner.images(ctx), ctx.settings, resolution_dpi=res,
                                         max_width=ctx.max_width, gap_dots=ctx.gap, copies=ctx.copies,
                                         collate=ctx.collate, now=ctx.now, time_step=ctx.time_step)


def fit_cases() -> List[Case]:
    """An Etikett anpassen (§8 „F“): Etikett 104 × 76,2 mm wie beim ZD421 mit ZDesigner."""
    cases: List[Case] = []
    add = cases.append
    label = {"lwLabelWidth": "10400", "lwLabelHeight": "7620"}
    a4, letter = (595.2756, 841.8898), (612.0, 792.0)
    corner = "pattern=text,seed=4,bx=40,by=50,bw=600,bh=420"           # Etikett-PDF bei 100 % in der Ecke
    note = ["automatisch auf das Etikett"]

    for lang in LANGS:
        add(Case("anpassen-a4-etikett-ecke-%s" % lang, [sized_page(*a4, extra=corner)],
                 dict(label, lwLanguage=lang), stderr_has=note, quick=(lang == "ZPL")))
    add(Case("anpassen-a4-voll-verkleinert", [sized_page(*a4, extra="pattern=gradient")],
             dict(label, lwDither="FloydSteinberg")))
    add(Case("anpassen-letter-breit-verkleinert", [sized_page(*letter, extra="pattern=text,seed=2,bx=10,by=300,"
                                                                             "bw=1600,bh=700")],
             dict(label, lwCompression="ACS")))
    add(Case("anpassen-a4-quer", [sized_page(a4[1], a4[0], extra="pattern=dots,bx=900,by=600,bw=700,bh=500")],
             label))
    add(Case("anpassen-a4-leer", [sized_page(*a4)], dict(label, lwCompression="Hex"), stderr_has=note))
    add(Case("anpassen-a4-leer-ueberspringen", [sized_page(*a4), sized_page(*a4, extra=corner)],
             dict(label, lwSkipBlank="True"), copies=2))
    add(Case("anpassen-gemischt-sortiert", [sized_page(294.8, 216.0, extra="pattern=text,seed=6"),
                                            sized_page(*a4, extra=corner)], label, copies=2))
    add(Case("anpassen-drehung-90", [sized_page(*a4, extra=corner)], dict(label, lwRotation="90")))
    add(Case("anpassen-drehung-270-passt", [sized_page(216.0, 294.8, extra="pattern=text,seed=8")],
             dict(label, lwRotation="270"), expect=unfitted, stderr_lacks=note))
    add(Case("anpassen-endlos-nur-breite", [sized_page(*a4, extra="pattern=bars,bx=30,by=100,bw=1500,bh=900")],
             {"lwLabelWidth": "8000", "lwLabelHeight": "15000", "lwMediaTracking": "Continuous",
              "lwStopAtLast": "True"}))
    add(Case("anpassen-hoehe-null", [sized_page(*a4, extra=corner)], {"lwLabelWidth": "5000"}))
    add(Case("anpassen-pagesize-statt-cupspagesize", [sized_page(*letter, extra=corner + ",cps=0")], label))
    add(Case("anpassen-pwg", [sized_page(*letter, extra=corner)], label, mode="pwg"))
    add(Case("anpassen-300dpi", [sized_page(*letter, dpi=300, extra="pattern=checker,bx=100,by=80,bw=300,bh=200")],
             dict(label, lwLanguage="CPCL")))
    add(Case("anpassen-negativ-spiegeln-180", [sized_page(*a4, extra=corner)],
             dict(label, lwNegative="True", lwMirror="True", lwRotation="180", lwLanguage="EPL")))
    # Drehen, Vergrößern, Rand (Fall aus der Meldung: halb so großes Etikett, von macOS gegen den
    # Uhrzeigersinn gedreht, mitten auf A4 hoch → aufrecht und formatfüllend abzüglich 1,5 mm)
    cw_note, ccw_note = ["im Uhrzeigersinn gedreht"], ["gegen den Uhrzeigersinn gedreht"]
    add(Case("anpassen-a4-halb-gedreht-meldung", [sized_page(*a4, extra="pattern=text,seed=5,bx=686,by=979,"
                                                                       "bw=305,bh=416")],
             dict(label, lwCompression="Z64"), stderr_has=note + cw_note, quick=True))
    add(Case("anpassen-a4-halb-gedreht-EPL", [sized_page(*a4, extra="pattern=bars,bx=686,by=979,bw=305,bh=416")],
             dict(label, lwLanguage="EPL", lwDither="Stucki"), stderr_has=cw_note))
    add(Case("anpassen-4x6-quer-inhalt", [sized_page(*letter, extra="pattern=text,seed=3,bx=100,by=200,"
                                                                    "bw=1000,bh=600")],
             {"lwLabelWidth": "10160", "lwLabelHeight": "15240"}, stderr_has=ccw_note))
    add(Case("anpassen-a4-klein-vergroessert", [sized_page(*a4, extra="pattern=checker,bx=40,by=50,bw=200,bh=150")],
             dict(label, lwDither="Ordered"), stderr_lacks=cw_note + ccw_note))
    add(Case("anpassen-600dpi-gedreht", [sized_page(200.0, 150.0, dpi=600, extra="pattern=text,seed=9,bx=300,"
                                                                                  "by=200,bw=500,bh=800")],
             {"lwLabelWidth": "5000", "lwLabelHeight": "3000", "lwCompression": "ACS"}, stderr_has=cw_note))
    add(Case("anpassen-endlos-vergroessert", [sized_page(*a4, extra="pattern=bars,bx=30,by=100,bw=300,bh=400")],
             {"lwLabelWidth": "8000", "lwMediaTracking": "Continuous", "lwRotation": "90"},
             stderr_lacks=cw_note + ccw_note))
    # Unverändert: passende Seite (± 2 mm), Off, kein Etikett, PPD-Standard Off
    add(Case("anpassen-passend-unveraendert", [sized_page(296.0, 218.0, extra="pattern=text,seed=6")], label,
             expect=unfitted, stderr_lacks=note, quick=True))
    add(Case("anpassen-aus", [sized_page(*a4, extra=corner)], dict(label, lwFitToLabel="Off"), expect=unfitted,
             stderr_lacks=note))
    add(Case("anpassen-ohne-etikett", [sized_page(*a4, extra=corner)], {"lwFitToLabel": "Auto"},
             expect=unfitted, stderr_lacks=note))
    add(Case("anpassen-ppd-aus", [sized_page(*a4, extra=corner)], label, ppd={"defaults": {"lwFitToLabel": "Off"}},
             expect=unfitted, stderr_lacks=note))
    add(Case("anpassen-ungueltig-faellt-auf-ppd", [sized_page(*a4, extra=corner)],
             dict(label, lwFitToLabel="Vielleicht"), ppd={"defaults": {"lwFitToLabel": "Off"}}, expect=unfitted,
             stderr_has=["lwFitToLabel"]))
    return cases


# --------------------------------------------------------------------------------------------
# Sonderprüfungen
# --------------------------------------------------------------------------------------------

def special_tests(r: Runner):
    filt = r.filter

    def plain_env(ppd: Optional[str] = None):
        env = dict(os.environ)
        env.pop("PPD", None)
        if ppd:
            env["PPD"] = ppd
        return env

    def bad_invocations(directory: str, errors: List[str]):
        for argv in ([], ["1", "u", "t", "1"], ["1", "u", "t", "1", "", "a", "b"]):
            code, out, err, _ = r.run_filter(filt, argv, plain_env(), None, directory, 30)
            r.check(code == 1 and b"" == out and "Usage:" in err, "falscher Aufruf %r: %d %r" % (argv, code, err), errors)
        code, out, err, _ = r.run_filter(filt, ["1", "u", "t", "1", "", os.path.join(directory, "fehlt.ras")],
                                         plain_env(), None, directory, 30)
        r.check(code == 1 and "kann nicht geöffnet werden" in err, "fehlende Datei: %d %r" % (code, err), errors)
        empty = os.path.join(directory, "leer.ras")
        open(empty, "wb").close()
        code, out, err, _ = r.run_filter(filt, ["1", "u", "t", "1", "", empty], plain_env(), None, directory, 30)
        r.check(code == 1 and out == b"" and "ERROR:" in err, "leere Datei: %d %r" % (code, err), errors)
        junk = os.path.join(directory, "muell.ras")
        with open(junk, "wb") as f:
            f.write(bytes(range(256)) * 20)
        code, out, err, _ = r.run_filter(filt, ["1", "u", "t", "1", "", junk], plain_env(), None, directory, 30)
        r.check(code == 1 and out == b"" and "ERROR:" in err, "Datenmüll: %d %r" % (code, err), errors)

    def sigterm(directory: str, errors: List[str]):
        raster, infos, dump = r.run_mkraster(directory, [P_TEXT, "w=203,h=400,pattern=gradient", P_GRAD], "native")
        data = open(raster, "rb").read()
        first_page_end = 4 + 1796 + infos[0]["dump_size"]
        proc = subprocess.Popen(r.wrapper + [filt, "1", "u", "t", "3", "lwCompression=Hex"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=plain_env())
        # stderr in einem eigenen Faden mitlesen, um den Fortschritt zu erkennen.
        lines: List[str] = []
        second_page = threading.Event()

        def read_stderr():
            for raw_line in proc.stderr:
                line = raw_line.decode("utf-8", "replace")
                lines.append(line)
                if "Seite 2 wird verarbeitet" in line:
                    second_page.set()

        reader = threading.Thread(target=read_stderr, daemon=True)
        reader.start()
        # Erste Seite vollständig + Kopf der zweiten Seite + einige Zeilen senden.
        proc.stdin.write(data[:first_page_end + 1796 + 203 * 10])
        proc.stdin.flush()
        r.check(second_page.wait(60), "Filter hat Seite 2 nicht begonnen", errors)
        proc.send_signal(signal.SIGTERM)
        time.sleep(0.2 if not r.wrapper else 1.0)
        try:
            proc.stdin.close()
        except BrokenPipeError:
            pass
        out = proc.stdout.read()
        proc.wait(timeout=60)
        reader.join(timeout=10)
        err = "".join(lines)
        r.check(proc.returncode == 0, "Exitcode nach SIGTERM %d: %s" % (proc.returncode, err[-300:]), errors)
        # Erwartet: Seite 1 mit Kopien=3 (bei Abbruch einmal ausgeben → Menge 1), keine Seite 2.
        lum = ref.luminance_from_samples(dump[:infos[0]["dump_size"]], infos[0])
        settings = ref.Settings(compression="Hex")
        expected = ref.encode_job_from_luminance([(infos[0]["w"], infos[0]["h"], lum)], settings, copies=1)
        r.check(out == expected, "Ausgabe nach SIGTERM weicht ab (%d Bytes, erwartet %d)" % (len(out), len(expected)),
                errors)
        r.check("abgebrochen" in err, "keine Abbruchmeldung: %r" % err[-300:], errors)

    def cancel_run(directory: str, opts: str, prefix: bytes) -> Tuple[int, bytes, str]:
        """Startet den Filter an einer Pipe, schickt `prefix`, bricht per SIGTERM ab und schließt
        dann die Pipe (wie CUPS, das auch den vorgelagerten Filter beendet)."""
        out_path = os.path.join(directory, "out.bin")
        with open(out_path, "wb") as out:
            proc = subprocess.Popen(r.wrapper + [filt, "1", "u", "t", "3", opts], stdin=subprocess.PIPE,
                                    stdout=out, stderr=subprocess.PIPE, env=plain_env())
        lines: List[str] = []
        ready = threading.Event()

        def read_stderr():
            for raw_line in proc.stderr:
                line = raw_line.decode("utf-8", "replace")
                lines.append(line)
                if "Modell=" in line:   # erst nach dem Einrichten des SIGTERM-Handlers gemeldet
                    ready.set()

        reader = threading.Thread(target=read_stderr, daemon=True)
        reader.start()
        if prefix:
            proc.stdin.write(prefix)
            proc.stdin.flush()
        if not ready.wait(60):
            proc.kill()
            proc.wait()
            reader.join(timeout=10)
            return -999, b"", "Filter ist nicht gestartet: " + "".join(lines)
        time.sleep(0.1 if not r.wrapper else 1.0)   # Präfix lesen lassen; Filter wartet dann an der Pipe
        proc.send_signal(signal.SIGTERM)
        time.sleep(0.2 if not r.wrapper else 1.0)
        try:
            proc.stdin.close()
        except BrokenPipeError:
            pass
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        reader.join(timeout=10)
        with open(out_path, "rb") as f:
            return proc.returncode, f.read(), "".join(lines)

    def sigterm_before_first_page(directory: str, errors: List[str]):
        """Regression: Abbruch, bevor eine Seite vollständig angekommen ist. Der Filter darf weder
        den Auftragskopf (Startbefehle, ~SD, ~TA und ~JC – eine Kalibrierung mit Vorschub) noch
        Endbefehle senden und endet mit Exitcode 0 und INFO-Meldung – auch, wenn der Abbruch vor
        dem Synchronisationswort kommt und cupsRasterOpen deshalb scheitert."""
        raster, _, _ = r.run_mkraster(directory, [P_TEXT], "native")
        with open(raster, "rb") as f:
            data = f.read()
        prefixes = (("ohne Daten", b""), ("nur Sync-Wort", data[:4]), ("halber Seitenkopf", data[:4 + 900]))
        variants = (("ZPL", "lwCalibrate=True lwDarkness=10 lwTearOff=10 lwStartCmd=%s lwEndCmd=%s"
                     % (b64u("^XA^FXstart^XZ"), b64u("~JR"))),
                    ("EPL", "lwLanguage=EPL lwDarkness=10 lwStartCmd=%s lwEndCmd=%s" % (b64u("OD"), b64u("ENDE"))))
        for lang, opts in variants:
            for label, prefix in prefixes:
                code, out, err = cancel_run(directory, opts, prefix)
                what = "%s, %s" % (lang, label)
                tail = err.strip().splitlines()[-2:]
                r.check(code == 0, "%s: Exitcode %d nach SIGTERM: %r" % (what, code, tail), errors)
                r.check(out == b"", "%s: Ausgabe nach Abbruch vor der ersten Seite: %r" % (what, out[:120]), errors)
                r.check("INFO: Auftrag abgebrochen – 0 Etikett(en)" in err,
                        "%s: keine Abbruchmeldung: %r" % (what, tail), errors)
                r.check("ERROR:" not in err, "%s: unerwartete Fehlermeldung: %r" % (what, tail), errors)
                r.check("PAGE:" not in err, "%s: unerwartete PAGE-Meldung" % what, errors)

    def big_page(directory: str, errors: List[str]):
        for comp, limit in (("Z64", 64.0), ("Hex", 80.0)):
            raster, infos, dump = r.run_mkraster(directory, ["w=2400,h=32000,pattern=text,seed=5"], "native")
            code, out, err, rss = r.run_filter(filt, ["1", "u", "t", "1", "lwCompression=%s" % comp, raster],
                                               plain_env(), None, directory, 300, measure_rss=not r.wrapper)
            r.check(code == 0, "Exitcode %d: %s" % (code, err[-300:]), errors)
            if rss is not None:
                r.check(rss < limit, "Speicherbedarf %.1f MB ≥ %.1f MB (%s)" % (rss, limit, comp), errors)
                print("        Spitzenspeicher 2400 × 32000, %s: %.1f MB" % (comp, rss))
            lum = ref.luminance_from_samples(dump, infos[0])
            expected = ref.encode_job_from_luminance([(2400, 32000, lum)], ref.Settings(compression=comp))
            r.check(out == expected, "große Seite (%s) weicht ab: %d vs. %d Bytes" % (comp, len(out), len(expected)),
                    errors)
            del dump, lum, expected
        # Längenwarnung jenseits von 32000 Punkten (ZPL ^LL)
        raster, infos, dump = r.run_mkraster(directory, ["w=16,h=32001,pattern=blank"], "native")
        code, out, err, _ = r.run_filter(filt, ["1", "u", "t", "1", "", raster], plain_env(), None, directory, 120)
        r.check(code == 0 and "32000" in err, "Längenwarnung fehlt: %r" % err[-300:], errors)

    def cupstestppd(directory: str, errors: List[str]):
        tool = shutil.which("cupstestppd")
        if tool is None:
            print("        (cupstestppd nicht installiert – übersprungen)")
            return
        result = subprocess.run([tool, "-I", "filters", BASE_PPD], capture_output=True, text=True)
        r.check(result.returncode == 0, "cupstestppd: %s" % result.stdout.strip()[-400:], errors)

    def cancel_delay(directory: str, errors: List[str]):
        """Wartezeit nach ~JA: wirklich gewartet (300 ms), mit Faktor 0 nicht; SIGTERM beendet sie."""
        raster, _, _ = r.run_mkraster(directory, [P_ODD], "native")

        def timed(opts: str, scale: Optional[str]):
            env = plain_env()
            env.pop("LW_CANCEL_DELAY_SCALE", None)
            if scale is not None:
                env["LW_CANCEL_DELAY_SCALE"] = scale
            start = time.time()
            code, out, err, _ = r.run_filter(filt, ["1", "u", "t", "1", opts, raster], env, None, directory, 60)
            return time.time() - start, code, out, err

        elapsed, code, out, err = timed("lwCancelBefore=True lwCancelDelay=300", None)
        r.check(code == 0 and out.startswith(b"~JA\n^XA\n"), "Wartezeit: %d %r" % (code, out[:20]), errors)
        r.check(elapsed >= 0.3, "nicht gewartet: %.3f s" % elapsed, errors)
        r.check("Warte 300 ms" in err, "keine Wartemeldung: %r" % err[-300:], errors)
        elapsed, code, out, err = timed("lwCancelBefore=True lwCancelDelay=3000", "0.1")
        r.check(code == 0 and 0.3 <= elapsed < 2.5, "Faktor 0,1: %.3f s" % elapsed, errors)
        elapsed, code, out, err = timed("lwCancelBefore=True lwCancelDelay=10000", "0")
        r.check(code == 0 and elapsed < 2.5 and "Warte" not in err, "Faktor 0: %.3f s" % elapsed, errors)
        elapsed, code, out, err = timed("lwCancelBefore=False lwCancelDelay=10000", None)
        r.check(code == 0 and elapsed < 2.5 and b"~JA" not in out, "ohne ~JA: %.3f s" % elapsed, errors)
        elapsed, code, out, err = timed("lwCancelBefore=True lwCancelDelay=100", "x")
        r.check(code == 0 and "LW_CANCEL_DELAY_SCALE" in err, "ungültiger Faktor: %r" % err[-200:], errors)
        # SIGTERM während der Wartezeit: Filter endet sofort regulär
        proc = subprocess.Popen(r.wrapper + [filt, "1", "u", "t", "1", "lwCancelBefore=True lwCancelDelay=10000",
                                             raster], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=dict(plain_env(), LW_CANCEL_DELAY_SCALE="1"))
        time.sleep(0.4 if not r.wrapper else 2.0)
        start = time.time()
        proc.send_signal(signal.SIGTERM)
        out, err = proc.communicate(timeout=60)
        r.check(proc.returncode == 0 and time.time() - start < 3.0 and out.startswith(b"~JA\n"),
                "SIGTERM in der Wartezeit: %d %r" % (proc.returncode, err[-300:]), errors)

    r.run_custom("abbrechen-wartezeit", True, cancel_delay)
    r.run_custom("aufruf-fehler", True, bad_invocations)
    r.run_custom("sigterm-abbruch", True, sigterm)
    r.run_custom("sigterm-vor-erster-seite", True, sigterm_before_first_page)
    r.run_custom("grosse-seite-2400x32000", False, big_page)
    r.run_custom("cupstestppd-test-ppd", False, cupstestppd)


def command_tests(r: Runner):
    exe = r.command_filter

    def run(directory: str, content: Optional[bytes], opts: str = "", ppd_spec="base", stdin: bool = False):
        ppd = make_ppd(directory, ppd_spec)
        env = dict(os.environ)
        env.pop("PPD", None)
        if ppd is not None:
            env["PPD"] = ppd.path
        path = os.path.join(directory, "befehle.txt")
        if content is not None:
            with open(path, "wb") as f:
                f.write(content)
        argv = ["7", "tester", "Befehl", "1", opts] + ([] if stdin else [path])
        return r.run_filter(exe, argv, env, path if stdin else None, directory, 30)

    def cpcl_selftest(width: int, height: int, model: str, dpi: int = 203) -> bytes:
        res = 200 if dpi == 203 else dpi
        lines = ["! 0 %d %d %d 1" % (res, res, height), "PAGE-WIDTH %d" % width,
                 "BOX 0 0 %d %d 2" % (width - 1, height - 1), "TEXT 4 0 16 12 LabelWerk Selbsttest",
                 "TEXT 7 0 16 70 Modell: %s" % model, "TEXT 7 0 16 96 Aufloesung: %d dpi" % dpi,
                 "TEXT 7 0 16 122 Druckbreite: %d Punkte" % width, "TEXT 7 0 16 148 Druckkopf-Test:",
                 "LINE 0 176 %d 176 24" % (width - 1)]
        step = max(1, width // 8)
        for i in range(8):
            x0, x1 = i * step, (width if i == 7 else (i + 1) * step) - 1
            if x1 > x0:
                y = 208 + (i % 2) * 12
                lines.append("LINE %d %d %d %d 12" % (x0, y, x1, y))
        lines += ["FORM", "PRINT"]
        return ("\r\n".join(lines) + "\r\n").encode("ascii")

    expectations = [
        # (Name, Inhalt, Optionen, PPD, erwartete Ausgabe, Exitcode, stderr-Text)
        ("zpl-selbsttest", b"#CUPS-COMMAND\nPrintSelfTestPage\n", "", "base", b"~WC\n", 0, "Selbsttest"),
        ("epl-selbsttest", b"#CUPS-COMMAND\nPrintSelfTestPage\n", "lwLanguage=EPL", "base", b"\nU\n", 0, None),
        ("cpcl-selbsttest", b"#CUPS-COMMAND\nPrintSelfTestPage\n", "lwLanguage=CPCL", "base",
         cpcl_selftest(832, 1218, "zd421t"), 0, None),
        ("cpcl-selbsttest-ohne-ppd", b"#CUPS-COMMAND\nPrintSelfTestPage\n", "lwLanguage=CPCL", None,
         cpcl_selftest(384, 400, "Zebra"), 0, None),
        ("zpl-kalibrieren", b"#CUPS-COMMAND\nCalibrate\n", "", "base", b"~JC\n", 0, "kalibrierung"),
        ("epl-kalibrieren", b"#CUPS-COMMAND\nCalibrate\n", "", {"defaults": {"lwLanguage": "EPL"}}, b"\nxa\n", 0,
         None),
        ("cpcl-kalibrieren", b"#CUPS-COMMAND\nCalibrate\n", "lwLanguage=CPCL", "base",
         b'! U1 do "ezpl.manual_calibration" ""\r\n', 0, None),
        ("reinigen", b"#CUPS-COMMAND\nClean\n", "", "base", b"", 0, "Reinigungsstift"),
        ("autokonfiguration", b"#CUPS-COMMAND\nAutoConfigure\n", "", "base", b"", 0, "INFO:"),
        ("fuellstaende", b"#CUPS-COMMAND\nReportLevels\n", "", "base", b"", 0, "Füllstände"),
        ("unbekannt", b"#CUPS-COMMAND\nFrobnicate now\n", "", "base", b"", 0, "Unbekannter Befehl"),
        ("mehrere", b"#CUPS-COMMAND\r\n# Kommentar\n\n  calibrate  \nPrintSelfTestPage\nClean\n", "", "base",
         b"~JC\n~WC\n", 0, None),
        ("ohne-kopf", b"PrintSelfTestPage\n", "", "base", b"", 1, "#CUPS-COMMAND"),
        ("leer", b"", "", "base", b"", 1, "ERROR:"),
        ("fehlende-datei", None, "", "base", b"", 1, "kann nicht geöffnet werden"),
        ("lange-zeile", b"#CUPS-COMMAND\n" + b"X" * 5000 + b"\nCalibrate\n", "", "base", b"~JC\n", 0, None),
        ("steuerzeichen-drucker", b"#CUPS-COMMAND\nPrintSelfTestPage\nCalibrate\n",
         "lwControlChars=Printer lwControlPrefix=64", "base", b"@WC\n@JC\n", 0, None),
        ("steuerzeichen-ppd", b"#CUPS-COMMAND\nCalibrate\n", "",
         {"defaults": {"lwControlChars": "Printer", "lwControlPrefix": "64"}}, b"@JC\n", 0, None),
        ("steuerzeichen-standard", b"#CUPS-COMMAND\nCalibrate\n", "lwControlChars=Standard lwControlPrefix=64",
         "base", b"~JC\n", 0, None),
        ("steuerzeichen-epl", b"#CUPS-COMMAND\nCalibrate\n", "lwLanguage=EPL lwControlChars=Printer "
         "lwControlPrefix=64", "base", b"\nxa\n", 0, None),
    ]
    for name, content, opts, ppd_spec, expected, code_expected, needle in expectations:
        def test(directory, errors, content=content, opts=opts, ppd_spec=ppd_spec, expected=expected,
                 code_expected=code_expected, needle=needle):
            code, out, err, _ = run(directory, content, opts, ppd_spec)
            r.check(code == code_expected, "Exitcode %d, erwartet %d: %r" % (code, code_expected, err[-300:]), errors)
            r.check(out == expected, "Ausgabe %r, erwartet %r" % (out[:200], expected[:200]), errors)
            if needle:
                r.check(needle in err, "stderr enthält nicht %r: %r" % (needle, err[-300:]), errors)
        r.run_custom("befehl-" + name, name in ("zpl-selbsttest", "cpcl-selbsttest", "ohne-kopf"), test)

    def stdin_test(directory, errors):
        code, out, err, _ = run(directory, b"#CUPS-COMMAND\nCalibrate\n", "lwLanguage=EPL", "base", stdin=True)
        r.check(code == 0 and out == b"\nxa\n", "stdin: %d %r %r" % (code, out, err[-200:]), errors)
    r.run_custom("befehl-stdin", True, stdin_test)

    def bad_args(directory, errors):
        code, out, err, _ = r.run_filter(exe, ["1"], dict(os.environ), None, directory, 30)
        r.check(code == 1 and "Usage:" in err, "falscher Aufruf: %d %r" % (code, err), errors)
    r.run_custom("befehl-aufruf-fehler", False, bad_args)


# --------------------------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="End-to-End-Tests der LabelWerk-CUPS-Filter")
    parser.add_argument("--bindir", default=os.path.join(HERE, "..", "build"), help="Verzeichnis mit den Programmen")
    parser.add_argument("--quick", action="store_true", help="nur eine repräsentative Auswahl (z. B. für Valgrind)")
    parser.add_argument("--wrapper", default="", help="Präfix für Filteraufrufe, z. B. 'valgrind -q'")
    parser.add_argument("--only", action="append", help="nur Fälle, deren Name den Text enthält")
    parser.add_argument("--keep", action="store_true", help="Testdateien behalten")
    parser.add_argument("-v", "--verbose", action="store_true", help="auch erfolgreiche Fälle anzeigen")
    args = parser.parse_args()

    ref.selftest()   # die Referenz selbst muss stimmen, bevor sie als Orakel dient
    r = Runner(args)
    start = time.time()
    cases = raster_cases()
    names = [c.name for c in cases]
    assert len(names) == len(set(names)), "doppelte Testnamen"
    for case in cases:
        r.run_case(case)
    special_tests(r)
    command_tests(r)
    r.cleanup()
    total = r.passed + len(r.failed)
    print("\nEnd-to-End: %d Fälle, %d bestanden, %d fehlgeschlagen, %d Prüfungen (%.1fs)"
          % (total, r.passed, len(r.failed), r.checks, time.time() - start))
    if r.failed:
        print("Fehlgeschlagen: " + ", ".join(r.failed))
    return 0 if not r.failed and total > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
