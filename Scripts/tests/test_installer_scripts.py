#!/usr/bin/env python3
"""Tests für die Build-, Paket- und Installationsskripte (unittest, nur Standardbibliothek).

Aufruf (vom Repository-Wurzelverzeichnis)::

    python3 Scripts/tests/test_installer_scripts.py
    python3 -m unittest discover -s Scripts/tests -v

Geprüft werden – auf jedem System, also auch unter Linux in der CI –

* ``Installer/lib/common.sh``: Lesen von ``config.env`` (Vorrang der Umgebung, Validierung) und
  das wörtliche Ersetzen von Platzhaltern,
* die Skripte ``build_driver.sh``, ``build_app.sh``, ``make_pkg.sh``, ``notarize.sh`` im Probelauf
  bzw. ihr Abbruch mit verständlicher Meldung außerhalb von macOS,
* ``build_driver.sh --host``: vollständiger Treiberbaum nach ARCHITECTURE.md §10 (sofern Compiler,
  libcups und zlib vorhanden sind),
* ``uninstall.sh`` gegen ein Testwurzelverzeichnis (``--root``),
* die Installer-Skripte (preinstall, postinstall) gegen ein Testvolume,
* Info.plist, Berechtigungen, InfoPlist.strings, distribution.xml, Installer-Texte und Symbole,
* ShellCheck für alle Skripte (falls installiert).
"""

from __future__ import annotations

import gzip
import json
import os
import platform
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path
from typing import Dict, List, Optional, Sequence

SCRIPTS = Path(__file__).resolve().parent.parent
REPO_ROOT = SCRIPTS.parent
INSTALLER = REPO_ROOT / "Installer"
COMMON = INSTALLER / "lib" / "common.sh"
IS_MACOS = platform.system() == "Darwin"
IS_ROOT = hasattr(os, "geteuid") and os.geteuid() == 0

SHELL_SCRIPTS = [
    SCRIPTS / "build_app.sh",
    SCRIPTS / "build_driver.sh",
    SCRIPTS / "make_pkg.sh",
    SCRIPTS / "notarize.sh",
    SCRIPTS / "uninstall.sh",
    SCRIPTS / "ci_linux.sh",
    SCRIPTS / "ci_macos.sh",
    COMMON,
    INSTALLER / "pkg" / "scripts" / "driver" / "preinstall",
    INSTALLER / "pkg" / "scripts" / "driver" / "postinstall",
    INSTALLER / "pkg" / "scripts" / "cli" / "postinstall",
]


def clean_env(**extra: str) -> Dict[str, str]:
    """Umgebung ohne Konfigurationswerte des Aufrufers (damit config.env gilt)."""
    env = {key: value for key, value in os.environ.items()
           if key not in ("APP_NAME", "BUNDLE_ID", "VERSION", "BUILD", "COPYRIGHT_YEAR", "TEAM_ID",
                          "DEVELOPER_ID_APP", "DEVELOPER_ID_INSTALLER", "LW_CONFIG_FILE", "LW_DRY_RUN",
                          "NOTARY_KEYCHAIN_PROFILE", "NOTARY_API_KEY_PATH", "NOTARY_API_KEY_ID",
                          "NOTARY_APPLE_ID", "NOTARY_PASSWORD")}
    env["NO_COLOR"] = "1"
    # UTF-8-Gebietsschema für die deutschen Meldungen (macOS kennt kein „C.UTF-8“).
    env["LC_ALL"] = "en_US.UTF-8" if IS_MACOS else "C.UTF-8"
    env.update(extra)
    return env


def run(argv: Sequence[str], env: Optional[Dict[str, str]] = None, cwd: Optional[Path] = None,
        timeout: int = 600, stdin: Optional[str] = None) -> subprocess.CompletedProcess:
    return subprocess.run(list(argv), cwd=str(cwd or REPO_ROOT), env=env or clean_env(),
                          input=stdin if stdin is not None else "", capture_output=True, text=True,
                          timeout=timeout)


def bash(script: str, env: Optional[Dict[str, str]] = None) -> subprocess.CompletedProcess:
    """Führt Bash-Code mit eingebundenem common.sh aus."""
    prelude = f'set -euo pipefail\nsource "{COMMON}"\n'
    return run(["bash", "-c", prelude + script], env=env)


def write_config(directory: Path, **values: str) -> Path:
    config = {
        "APP_NAME": "LabelWerk", "BUNDLE_ID": "com.labelwerk.app", "VERSION": "1.0.0", "BUILD": "1",
        "COPYRIGHT_YEAR": "2026", "TEAM_ID": "", "DEVELOPER_ID_APP": "", "DEVELOPER_ID_INSTALLER": "",
    }
    config.update(values)
    path = directory / "config.env"
    path.write_text("# Test\n\n" + "\n".join(f"{k}={v}" for k, v in config.items()) + "\n", encoding="utf-8")
    return path


def mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def have_filter_toolchain() -> bool:
    """Compiler, make und libcups/zlib-Header für den Testaufbau der Filter vorhanden?"""
    if not shutil.which("make") or not (shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")):
        return False
    if IS_MACOS:
        return True
    return Path("/usr/include/cups/raster.h").exists() and Path("/usr/include/zlib.h").exists()


# ------------------------------------------------------------------------------------------------
# common.sh
# ------------------------------------------------------------------------------------------------


class CommonLibraryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-common-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def load(self, config: Path, **env: str) -> subprocess.CompletedProcess:
        return bash('lw_load_config\nfor k in APP_NAME BUNDLE_ID VERSION BUILD COPYRIGHT_YEAR DEVELOPER_ID_APP '
                    'LW_PKG_ID_APP LW_PKG_ID_DRIVER LW_PKG_ID_CLI; do printf "%s=%s\\n" "$k" "${!k}"; done',
                    env=clean_env(LW_CONFIG_FILE=str(config), **env))

    @staticmethod
    def values(output: str) -> Dict[str, str]:
        return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)

    def test_repository_config_has_required_defaults(self):
        result = self.load(INSTALLER / "config.env")
        self.assertEqual(result.returncode, 0, result.stderr)
        values = self.values(result.stdout)
        self.assertEqual(values["APP_NAME"], "LabelWerk")
        self.assertEqual(values["BUNDLE_ID"], "com.labelwerk.app")
        self.assertRegex(values["VERSION"], r"^\d+\.\d+(\.\d+)?$")
        self.assertRegex(values["BUILD"], r"^\d+$")
        self.assertEqual(values["DEVELOPER_ID_APP"], "")
        self.assertEqual(values["LW_PKG_ID_DRIVER"], "com.labelwerk.app.driver")
        text = (INSTALLER / "config.env").read_text(encoding="utf-8")
        for key in ("TEAM_ID=", "DEVELOPER_ID_APP=", "DEVELOPER_ID_INSTALLER="):
            self.assertRegex(text, rf"(?m)^{key}$", f"{key} muss im Repository leer sein")

    def test_environment_overrides_config(self):
        config = write_config(self.tmp)
        result = self.load(config, VERSION="2.3.4", DEVELOPER_ID_APP="Developer ID Application: X (ABCDE12345)")
        self.assertEqual(result.returncode, 0, result.stderr)
        values = self.values(result.stdout)
        self.assertEqual(values["VERSION"], "2.3.4")
        self.assertEqual(values["DEVELOPER_ID_APP"], "Developer ID Application: X (ABCDE12345)")
        self.assertEqual(values["BUILD"], "1")

    def test_quoted_values_and_crlf(self):
        config = self.tmp / "config.env"
        config.write_bytes(b'APP_NAME="Label Werk"\r\nBUNDLE_ID=\'com.example.app\'\r\nVERSION=1.2\r\nBUILD=7\r\n')
        result = self.load(config)
        self.assertEqual(result.returncode, 0, result.stderr)
        values = self.values(result.stdout)
        self.assertEqual(values["APP_NAME"], "Label Werk")
        self.assertEqual(values["BUNDLE_ID"], "com.example.app")
        self.assertRegex(values["COPYRIGHT_YEAR"], r"^\d{4}$")

    def test_config_is_not_executed(self):
        marker = self.tmp / "pwned"
        config = write_config(self.tmp, APP_NAME=f"$(touch {marker})")
        result = self.load(config)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())

    def test_invalid_values_are_rejected(self):
        cases = {
            "VERSION": ("1.0.0-beta", "VERSION"),
            "BUILD": ("x", "BUILD"),
            "BUNDLE_ID": ("labelwerk", "BUNDLE_ID"),
            "COPYRIGHT_YEAR": ("26", "COPYRIGHT_YEAR"),
        }
        for key, (value, message) in cases.items():
            with self.subTest(key=key):
                result = self.load(write_config(self.tmp, **{key: value}))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_invalid_line_is_rejected(self):
        config = self.tmp / "config.env"
        config.write_text("APP_NAME = LabelWerk\n", encoding="utf-8")
        result = self.load(config)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ungültige Zeile", result.stderr)

    def test_missing_config(self):
        result = self.load(self.tmp / "fehlt.env")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Konfigurationsdatei fehlt", result.stderr)

    def test_render_template_replaces_literally(self):
        template = self.tmp / "in.txt"
        template.write_text("@APP_NAME@ @VERSION@ (@BUILD@) @BUNDLE_ID@ @LW_PKG_ID_CLI@ © @COPYRIGHT_YEAR@\n"
                            "@APP_NAME@@APP_NAME@\n", encoding="utf-8")
        config = write_config(self.tmp, APP_NAME='"A&B \\\\1 Werk"')
        result = bash(f'lw_load_config\nlw_render_template "{template}" "{self.tmp / "out.txt"}"',
                      env=clean_env(LW_CONFIG_FILE=str(config), APP_NAME="A.B_Werk-1"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.tmp / "out.txt").read_text(encoding="utf-8"),
                         "A.B_Werk-1 1.0.0 (1) com.labelwerk.app com.labelwerk.app.cli © 2026\n"
                         "A.B_Werk-1A.B_Werk-1\n")

    def test_render_template_rejects_unknown_placeholder(self):
        template = self.tmp / "in.txt"
        template.write_text("@UNKNOWN_KEY@\n", encoding="utf-8")
        result = bash(f'lw_load_config\nlw_render_template "{template}" "{self.tmp / "out.txt"}"',
                      env=clean_env(LW_CONFIG_FILE=str(write_config(self.tmp))))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("@UNKNOWN_KEY@", result.stderr)

    def test_dry_run_helpers(self):
        never = self.tmp / "never"
        result = bash(f'LW_DRY_RUN=1\nlw_run touch "{never}"\nlw_require_tool definitely-missing-tool\n'
                      'lw_require_file /definitely/missing "Datei"\necho fertig', env=clean_env())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fertig", result.stdout)
        self.assertIn("touch", result.stderr)
        self.assertFalse(never.exists())
        result = bash("lw_require_tool definitely-missing-tool 'Hinweis XY'")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Hinweis XY", result.stderr)

    def test_app_identity(self):
        result = bash("lw_app_identity", env=clean_env())
        self.assertEqual(result.stdout, "-")
        result = bash("lw_app_identity", env=clean_env(DEVELOPER_ID_APP="Developer ID Application: Y"))
        self.assertEqual(result.stdout, "Developer ID Application: Y")


# ------------------------------------------------------------------------------------------------
# Build-Skripte (Probelauf / Plattformprüfung)
# ------------------------------------------------------------------------------------------------


class BuildScriptTests(unittest.TestCase):
    SCRIPTS = ["build_driver.sh", "build_app.sh", "make_pkg.sh", "notarize.sh", "uninstall.sh"]

    def test_help_and_unknown_options(self):
        for name in self.SCRIPTS:
            with self.subTest(script=name):
                result = run([str(SCRIPTS / name), "--help"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Aufruf:", result.stdout)
                result = run([str(SCRIPTS / name), "--gibt-es-nicht"])
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn("Unbekannte Option", result.stderr)

    def test_scripts_are_executable_bash_with_strict_mode(self):
        for path in SHELL_SCRIPTS:
            if path == COMMON:
                continue
            with self.subTest(script=path.name):
                self.assertTrue(os.access(path, os.X_OK), f"{path} ist nicht ausführbar")
                text = path.read_text(encoding="utf-8")
                self.assertTrue(text.startswith("#!/bin/bash") or text.startswith("#!/usr/bin/env bash"))
                self.assertIn("set -euo pipefail", text)

    def test_bash_syntax(self):
        for path in SHELL_SCRIPTS:
            with self.subTest(script=path.name):
                result = run(["bash", "-n", str(path)])
                self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which("shellcheck"), "shellcheck nicht installiert")
    def test_shellcheck(self):
        result = run(["shellcheck", "-x", *[str(p) for p in SHELL_SCRIPTS]])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipIf(IS_MACOS, "prüft das Verhalten außerhalb von macOS")
    def test_macos_only_scripts_refuse_without_dry_run(self):
        for name in ("build_app.sh", "make_pkg.sh", "notarize.sh"):
            with self.subTest(script=name):
                result = run([str(SCRIPTS / name)])
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("erfordert macOS", result.stderr)
                self.assertIn("--dry-run", result.stderr)
        result = run([str(SCRIPTS / "build_driver.sh")])
        self.assertEqual(result.returncode, 2)
        self.assertIn("--host", result.stderr)

    def test_dry_runs_change_nothing(self):
        with tempfile.TemporaryDirectory(prefix="lw-dry-") as tmp:
            out = Path(tmp) / "out"
            cases = [
                ([str(SCRIPTS / "build_driver.sh"), "--dry-run", "--output", str(out / "driver")],
                 ["make -C", "generate_ppds.py", "--gzip", "codesign"]),
                ([str(SCRIPTS / "build_app.sh"), "--dry-run", "--skip-driver", "--output", str(out)],
                 ["--arch arm64 --arch x86_64 --product LabelWerk", "--product lwctl", "Contents/Helpers/lwctl",
                  "--entitlements", "codesign --verify --deep --strict"]),
                ([str(SCRIPTS / "make_pkg.sh"), "--dry-run", "--skip-build", "--output", str(out)],
                 ["pkgbuild", "--install-location /Applications", "com.labelwerk.app.driver", "productbuild",
                  "LabelWerk-"]),
                ([str(SCRIPTS / "notarize.sh"), "--dry-run", str(out / "LabelWerk-1.0.0.pkg")],
                 ["notarytool submit", "--wait"]),
            ]
            for argv, expected in cases:
                with self.subTest(script=Path(argv[0]).name):
                    result = run(argv)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    for fragment in expected:
                        self.assertIn(fragment, result.stderr)
                    self.assertIn("Probelauf", result.stderr)
            self.assertFalse(out.exists(), "Probelauf darf nichts anlegen")

    def test_notarize_hides_password(self):
        result = run([str(SCRIPTS / "notarize.sh"), "--dry-run", "x.pkg"],
                     env=clean_env(NOTARY_APPLE_ID="dev@example.com", NOTARY_PASSWORD="geheim-123",
                                   TEAM_ID="ABCDE12345"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("geheim-123", result.stdout + result.stderr)
        self.assertIn("--password VERBORGEN", result.stderr)

    def test_notarize_rejects_unknown_file_type(self):
        result = run([str(SCRIPTS / "notarize.sh"), "--dry-run", "datei.txt"])
        self.assertEqual(result.returncode, 64)
        self.assertIn("Nicht unterstützter Dateityp", result.stderr)

    def test_build_driver_refuses_system_directories(self):
        for target in ("/", "/Library", "/usr/local"):
            with self.subTest(target=target):
                result = run([str(SCRIPTS / "build_driver.sh"), "--dry-run", "--output", target])
                self.assertEqual(result.returncode, 64)
                self.assertIn("Ungeeignetes Zielverzeichnis", result.stderr)


# ------------------------------------------------------------------------------------------------
# Treiberbaum (build_driver.sh --host)
# ------------------------------------------------------------------------------------------------


@unittest.skipUnless(have_filter_toolchain(), "Compiler, libcups oder zlib fehlen")
@unittest.skipUnless((REPO_ROOT / "Driver" / "filter" / "Makefile").exists(), "Driver/filter fehlt")
class DriverTreeTests(unittest.TestCase):
    tmp: Path
    root: Path
    result: subprocess.CompletedProcess

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="lw-driver-"))
        cls.root = cls.tmp / "driver-root"
        cls.result = run([str(SCRIPTS / "build_driver.sh"), "--host", "--no-sign", "--output", str(cls.root)],
                         env=clean_env(VERSION="9.8.7"), timeout=900)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_build_succeeds(self):
        self.assertEqual(self.result.returncode, 0, self.result.stderr[-4000:])

    def test_layout_matches_architecture(self):
        self.assertEqual(self.result.returncode, 0)
        driver = self.root / "Library" / "Printers" / "LabelWerk"
        for name in ("rastertolabelwerk", "commandtolabelwerk"):
            path = driver / "Filter" / name
            self.assertTrue(path.is_file(), path)
            self.assertEqual(mode(path), 0o755)
        self.assertEqual((driver / "VERSION").read_text(encoding="utf-8"), "9.8.7\n")
        self.assertEqual(mode(driver / "VERSION"), 0o644)
        self.assertEqual((driver / "Icons" / "LabelWerk.icns").read_bytes()[:4], b"icns")
        self.assertEqual(mode(driver / "uninstall.sh"), 0o755)
        self.assertEqual(mode(driver), 0o755)
        self.assertEqual(mode(self.root / "Library" / "Printers"), 0o775)

    def test_ppds_are_gzipped_and_reference_filter(self):
        self.assertEqual(self.result.returncode, 0)
        ppd_dir = self.root / "Library" / "Printers" / "PPDs" / "Contents" / "Resources"
        ppds = sorted(ppd_dir.glob("LabelWerk-*.ppd.gz"))
        self.assertGreater(len(ppds), 10)
        self.assertEqual(sorted(p for p in ppd_dir.iterdir() if p not in ppds), [])
        for ppd in ppds:
            self.assertRegex(ppd.name, r"^LabelWerk-[a-z0-9-]+-\d{3}dpi\.ppd\.gz$")
            self.assertEqual(mode(ppd), 0o644)
        text = gzip.decompress(ppds[0].read_bytes()).decode("utf-8", errors="replace")
        self.assertIn('*cupsFilter: "application/vnd.cups-raster 0 /Library/Printers/LabelWerk/Filter/rastertolabelwerk"',
                      text)
        self.assertIn('*FileVersion: "9.8.7"', text)
        index = json.loads((self.root / "Library" / "Printers" / "LabelWerk" / "ppd-index.json").read_text(encoding="utf-8"))
        self.assertTrue(index)

    def test_uninstaller_defaults_follow_config(self):
        self.assertEqual(self.result.returncode, 0)
        text = (self.root / "Library" / "Printers" / "LabelWerk" / "uninstall.sh").read_text(encoding="utf-8")
        self.assertIn('DEFAULT_APP_NAME="LabelWerk"', text)
        self.assertIn('DEFAULT_BUNDLE_ID="com.labelwerk.app"', text)

    def test_no_build_artifacts_left_next_to_output(self):
        self.assertEqual(self.result.returncode, 0)
        self.assertFalse((self.tmp / "driver-root.ppd-tmp").exists())


# ------------------------------------------------------------------------------------------------
# Deinstallation
# ------------------------------------------------------------------------------------------------


PPD_SNIPPET = '*PPD-Adobe: "4.3"\n*lwModel: "zd421t"\n*cupsFilter: "application/vnd.cups-raster 0 ' \
              '/Library/Printers/LabelWerk/Filter/rastertolabelwerk"\n'


class UninstallTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="lw-uninstall-"))
        driver = self.root / "Library" / "Printers" / "LabelWerk"
        (driver / "Filter").mkdir(parents=True)
        (driver / "Filter" / "rastertolabelwerk").write_text("x", encoding="utf-8")
        (driver / "VERSION").write_text("1.0.0\n", encoding="utf-8")
        self.ppds = self.root / "Library" / "Printers" / "PPDs" / "Contents" / "Resources"
        self.ppds.mkdir(parents=True)
        for name in ("LabelWerk-zd421t-203dpi.ppd.gz", "LabelWerk-zt411-300dpi.ppd.gz", "Fremd.ppd.gz"):
            (self.ppds / name).write_bytes(b"x")
        app = self.root / "Applications" / "LabelWerk.app" / "Contents" / "Helpers"
        app.mkdir(parents=True)
        (app / "lwctl").write_text("x", encoding="utf-8")
        bin_dir = self.root / "usr" / "local" / "bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "lwctl").symlink_to("/Applications/LabelWerk.app/Contents/Helpers/lwctl")
        (bin_dir / "fremd").symlink_to("/opt/fremd/bin/fremd")
        cups = self.root / "etc" / "cups" / "ppd"
        cups.mkdir(parents=True)
        (cups / "Versand.ppd").write_text(PPD_SNIPPET, encoding="utf-8")
        (cups / "Laser.ppd").write_text('*PPD-Adobe: "4.3"\n*cupsFilter: "x 0 foo"\n', encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def uninstall(self, *args: str, stdin: str = "") -> subprocess.CompletedProcess:
        return run([str(SCRIPTS / "uninstall.sh"), "--root", str(self.root), *args], stdin=stdin)

    def test_dry_run_lists_and_changes_nothing(self):
        result = self.uninstall("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("installierte Treiberversion: 1.0.0", result.stdout)
        self.assertIn("2 PPD-Dateien", result.stdout)
        self.assertIn("Versand", result.stderr)
        self.assertNotIn("Laser", result.stderr + result.stdout)
        self.assertTrue((self.root / "Library" / "Printers" / "LabelWerk").exists())

    def test_requires_confirmation_without_terminal(self):
        result = self.uninstall()
        self.assertEqual(result.returncode, 1)
        self.assertIn("--yes", result.stderr)
        self.assertTrue((self.root / "Library" / "Printers" / "LabelWerk").exists())

    def test_removes_only_labelwerk_files(self):
        result = self.uninstall("--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "Library" / "Printers" / "LabelWerk").exists())
        self.assertEqual(sorted(p.name for p in self.ppds.iterdir()), ["Fremd.ppd.gz"])
        self.assertFalse((self.root / "Applications" / "LabelWerk.app").exists())
        self.assertFalse((self.root / "usr" / "local" / "bin" / "lwctl").is_symlink())
        self.assertTrue((self.root / "usr" / "local" / "bin" / "fremd").is_symlink())
        # Ohne --remove-queues bleiben die Warteschlangen bestehen (mit Warnung).
        self.assertTrue((self.root / "etc" / "cups" / "ppd" / "Versand.ppd").exists())
        self.assertIn("--remove-queues", result.stderr)

    def test_remove_queues_and_keep_app(self):
        result = self.uninstall("--yes", "--remove-queues", "--keep-app")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "etc" / "cups" / "ppd" / "Versand.ppd").exists())
        self.assertTrue((self.root / "etc" / "cups" / "ppd" / "Laser.ppd").exists())
        self.assertTrue((self.root / "Applications" / "LabelWerk.app").exists())

    def test_nothing_installed(self):
        empty = Path(tempfile.mkdtemp(prefix="lw-empty-"))
        try:
            result = run([str(SCRIPTS / "uninstall.sh"), "--root", str(empty), "--yes"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("nichts von LabelWerk installiert", result.stdout)
        finally:
            shutil.rmtree(empty, ignore_errors=True)

    def test_missing_root(self):
        result = run([str(SCRIPTS / "uninstall.sh"), "--root", str(self.root / "fehlt"), "--yes"])
        self.assertEqual(result.returncode, 64)

    @unittest.skipIf(IS_MACOS, "prüft das Verhalten außerhalb von macOS")
    def test_system_uninstall_refused_outside_macos(self):
        result = run([str(SCRIPTS / "uninstall.sh"), "--yes"])
        self.assertEqual(result.returncode, 2)
        self.assertIn("nur auf macOS", result.stderr)


# ------------------------------------------------------------------------------------------------
# Installer-Skripte (preinstall / postinstall)
# ------------------------------------------------------------------------------------------------


class PackageScriptTests(unittest.TestCase):
    def setUp(self):
        self.volume = Path(tempfile.mkdtemp(prefix="lw-volume-"))
        self.driver = self.volume / "Library" / "Printers" / "LabelWerk"
        self.ppds = self.volume / "Library" / "Printers" / "PPDs" / "Contents" / "Resources"

    def tearDown(self):
        shutil.rmtree(self.volume, ignore_errors=True)

    def script(self, component: str, name: str) -> Path:
        return INSTALLER / "pkg" / "scripts" / component / name

    def test_preinstall_removes_old_driver_only(self):
        (self.driver / "Filter").mkdir(parents=True)
        (self.driver / "VERSION").write_text("0.9.0\n", encoding="utf-8")
        self.ppds.mkdir(parents=True)
        for name in ("LabelWerk-alt-203dpi.ppd.gz", "LabelWerk-alt-300dpi.ppd", "Andere.ppd.gz"):
            (self.ppds / name).write_bytes(b"x")
        result = run([str(self.script("driver", "preinstall")), "pkg", "/", str(self.volume)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.driver.exists())
        self.assertEqual([p.name for p in self.ppds.iterdir()], ["Andere.ppd.gz"])
        self.assertIn("0.9.0", result.stdout)
        self.assertIn("2 alte PPD-Dateien", result.stdout)

    def test_preinstall_removes_symlink_without_following(self):
        target = self.volume / "repo-driver"
        (target / "Filter").mkdir(parents=True)
        self.driver.parent.mkdir(parents=True)
        self.driver.symlink_to(target)
        result = run([str(self.script("driver", "preinstall")), "pkg", "/", str(self.volume)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.driver.is_symlink())
        self.assertTrue((target / "Filter").is_dir(), "das Ziel des Links darf nicht gelöscht werden")

    def test_preinstall_on_fresh_volume(self):
        result = run([str(self.script("driver", "preinstall")), "pkg", "/", str(self.volume)])
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(IS_ROOT, "postinstall setzt Besitzer root:wheel (nur als root testbar)")
    def test_postinstall_fixes_permissions_on_other_volume(self):
        (self.driver / "Filter").mkdir(parents=True)
        for name in ("rastertolabelwerk", "commandtolabelwerk"):
            (self.driver / "Filter" / name).write_text("#!/bin/sh\n", encoding="utf-8")
            os.chmod(self.driver / "Filter" / name, 0o777)
        (self.driver / "uninstall.sh").write_text("#!/bin/bash\n", encoding="utf-8")
        (self.driver / "VERSION").write_text("1.0.0\n", encoding="utf-8")
        os.chmod(self.driver / "VERSION", 0o666)
        self.ppds.mkdir(parents=True)
        (self.ppds / "LabelWerk-zd421t-203dpi.ppd.gz").write_bytes(b"x")
        os.chmod(self.ppds / "LabelWerk-zd421t-203dpi.ppd.gz", 0o600)
        result = run([str(self.script("driver", "postinstall")), "pkg", "/", str(self.volume)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(mode(self.driver / "Filter" / "rastertolabelwerk"), 0o755)
        self.assertEqual(mode(self.driver / "uninstall.sh"), 0o755)
        self.assertEqual(mode(self.driver / "VERSION"), 0o644)
        self.assertEqual(mode(self.ppds / "LabelWerk-zd421t-203dpi.ppd.gz"), 0o644)
        self.assertEqual((self.driver / "Filter" / "rastertolabelwerk").stat().st_uid, 0)
        self.assertIn("nicht das Startvolume", result.stdout)

    def test_postinstall_fails_without_filters(self):
        result = run([str(self.script("driver", "postinstall")), "pkg", "/", str(self.volume)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("Filterordner fehlt", result.stdout)

    def render_cli_postinstall(self) -> Path:
        rendered = self.volume / "cli-postinstall"
        result = bash(f'lw_load_config\nlw_render_template "{self.script("cli", "postinstall")}" "{rendered}"\n'
                      f'chmod 755 "{rendered}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        return rendered

    def test_cli_postinstall_creates_link(self):
        script = self.render_cli_postinstall()
        self.assertNotIn("@APP_NAME@", script.read_text(encoding="utf-8"))
        helper = self.volume / "Applications" / "LabelWerk.app" / "Contents" / "Helpers" / "lwctl"
        helper.parent.mkdir(parents=True)
        helper.write_text("#!/bin/sh\n", encoding="utf-8")
        os.chmod(helper, 0o755)
        result = run([str(script), "pkg", "/", str(self.volume)])
        self.assertEqual(result.returncode, 0, result.stderr)
        link = self.volume / "usr" / "local" / "bin" / "lwctl"
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), "/Applications/LabelWerk.app/Contents/Helpers/lwctl")
        # Erneuter Lauf (Update) ersetzt den eigenen Link.
        result = run([str(script), "pkg", "/", str(self.volume)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(link.is_symlink())

    def test_cli_postinstall_keeps_foreign_file(self):
        script = self.render_cli_postinstall()
        helper = self.volume / "Applications" / "LabelWerk.app" / "Contents" / "Helpers" / "lwctl"
        helper.parent.mkdir(parents=True)
        helper.write_text("#!/bin/sh\n", encoding="utf-8")
        os.chmod(helper, 0o755)
        link = self.volume / "usr" / "local" / "bin" / "lwctl"
        link.parent.mkdir(parents=True)
        link.write_text("eigene Version", encoding="utf-8")
        result = run([str(script), "pkg", "/", str(self.volume)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(link.read_text(encoding="utf-8"), "eigene Version")
        self.assertIn("unverändert", result.stdout)

    def test_cli_postinstall_without_app(self):
        script = self.render_cli_postinstall()
        result = run([str(script), "pkg", "/", str(self.volume)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.volume / "usr" / "local" / "bin" / "lwctl").exists())


# ------------------------------------------------------------------------------------------------
# Installer-Ressourcen
# ------------------------------------------------------------------------------------------------


def parse_strings(path: Path) -> Dict[str, str]:
    """Liest eine .strings-Datei mit dem Parser aus extract_strings.py."""
    sys.path.insert(0, str(SCRIPTS))
    try:
        import extract_strings  # noqa: PLC0415 – bewusst lokal (Pfad wird erst hier gesetzt)
    finally:
        sys.path.pop(0)
    return {e.key: e.value for e in extract_strings.read_strings_file(path)}


class _TagBalanceChecker(HTMLParser):
    """Findet nicht geschlossene bzw. falsch verschachtelte HTML-Elemente."""

    VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}

    def __init__(self) -> None:
        super().__init__()
        self.stack: List[str] = []
        self.problems: List[str] = []

    def handle_starttag(self, tag, attrs):
        if tag not in self.VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag in self.VOID:
            return
        if not self.stack or self.stack[-1] != tag:
            self.problems.append(f"</{tag}> passt nicht zu {self.stack[-1:] or 'nichts'} (Zeile {self.getpos()[0]})")
            return
        self.stack.pop()


def unbalanced_html_tags(html: str) -> List[str]:
    checker = _TagBalanceChecker()
    checker.feed(html)
    checker.close()
    return checker.problems + [f"<{tag}> nicht geschlossen" for tag in checker.stack]


def png_size(data: bytes):
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "kein PNG"
    return struct.unpack(">II", data[16:24])


class ResourceTests(unittest.TestCase):
    def info_plist(self) -> dict:
        return plistlib.loads((INSTALLER / "Info.plist").read_bytes())

    def test_info_plist_contract(self):
        info = self.info_plist()
        expected = {
            "CFBundleExecutable": "LabelWerk",
            "CFBundleIdentifier": "@BUNDLE_ID@",
            "CFBundleShortVersionString": "@VERSION@",
            "CFBundleVersion": "@BUILD@",
            "LSMinimumSystemVersion": "14.0",
            "CFBundleDevelopmentRegion": "de",
            "CFBundleLocalizations": ["de", "en"],
            "LSApplicationCategoryType": "public.app-category.utilities",
            "CFBundleIconFile": "AppIcon",
            "NSPrincipalClass": "NSApplication",
            "NSSupportsAutomaticTermination": False,
            "CFBundlePackageType": "APPL",
        }
        for key, value in expected.items():
            self.assertEqual(info.get(key), value, key)
        self.assertEqual(sorted(info["NSBonjourServices"]), ["_ipp._tcp", "_pdl-datastream._tcp", "_printer._tcp"])
        for key in ("NSBluetoothAlwaysUsageDescription", "NSLocalNetworkUsageDescription", "NSHumanReadableCopyright"):
            self.assertTrue(info.get(key), key)
        self.assertIn("Bluetooth", info["NSBluetoothAlwaysUsageDescription"])

    def test_entitlements(self):
        entitlements = plistlib.loads((INSTALLER / "LabelWerk.entitlements").read_bytes())
        self.assertIs(entitlements.get("com.apple.security.app-sandbox"), False)
        for key in ("com.apple.security.device.usb", "com.apple.security.device.bluetooth",
                    "com.apple.security.network.client", "com.apple.security.network.server"):
            self.assertIs(entitlements.get(key), True, key)
        for forbidden in ("com.apple.security.cs.allow-jit", "com.apple.security.cs.disable-library-validation",
                          "com.apple.security.get-task-allow"):
            self.assertNotIn(forbidden, entitlements)

    def test_info_plist_strings_match_in_all_languages(self):
        info = self.info_plist()
        tables = {lang: parse_strings(INSTALLER / "Resources" / f"{lang}.lproj" / "InfoPlist.strings")
                  for lang in ("de", "en")}
        self.assertEqual(set(tables["de"]), set(tables["en"]))
        for key in tables["de"]:
            self.assertIn(key, info, f"{key} fehlt in Info.plist")
        self.assertEqual(tables["de"]["NSBluetoothAlwaysUsageDescription"], info["NSBluetoothAlwaysUsageDescription"])
        self.assertEqual(tables["de"]["NSLocalNetworkUsageDescription"], info["NSLocalNetworkUsageDescription"])
        self.assertNotEqual(tables["en"]["NSLocalNetworkUsageDescription"], info["NSLocalNetworkUsageDescription"])

    def test_localizable_strings_exist(self):
        for lang in ("de", "en"):
            self.assertTrue(parse_strings(INSTALLER / "Resources" / f"{lang}.lproj" / "Localizable.strings"))

    def test_distribution_and_installer_texts(self):
        text = (INSTALLER / "pkg" / "distribution.xml").read_text(encoding="utf-8")
        placeholders = set(re.findall(r"@([A-Z_]+)@", text))
        self.assertLessEqual(placeholders, {"APP_NAME", "BUNDLE_ID", "VERSION", "BUILD",
                                            "LW_PKG_ID_APP", "LW_PKG_ID_DRIVER", "LW_PKG_ID_CLI"})
        root = ET.fromstring(re.sub(r"@[A-Z_]+@", "x", text))
        self.assertEqual(root.tag, "installer-gui-script")
        self.assertEqual(root.find("volume-check/allowed-os-versions/os-version").get("min"), "14.0")
        files = [element.get("file") for element in root if element.get("file")]
        resources = INSTALLER / "pkg" / "Resources"
        titles = {element.get(attr) for element in root.iter("choice") for attr in ("title", "description")}
        titles.add(root.findtext("title"))
        for lang in ("de", "en"):
            lproj = resources / f"{lang}.lproj"
            strings = parse_strings(lproj / "Localizable.strings")
            self.assertLessEqual(titles, set(strings), f"Texte fehlen in {lang}.lproj")
            for name in files:
                if name.endswith(".png"):
                    self.assertEqual((resources / name).read_bytes()[:4], b"\x89PNG")
                    continue
                html = (lproj / name).read_text(encoding="utf-8")
                self.assertIn(f'<html lang="{lang}">', html, f"{lang}/{name}")
                self.assertEqual(unbalanced_html_tags(html), [], f"{lang}/{name}")

    def test_pkg_scripts_reference_architecture_paths(self):
        postinstall = (INSTALLER / "pkg" / "scripts" / "driver" / "postinstall").read_text(encoding="utf-8")
        self.assertIn("launchctl kickstart -k system/org.cups.cupsd", postinstall)
        self.assertIn("/Library/Printers/LabelWerk", postinstall)
        self.assertIn("chown -R 0:0", postinstall)

    def test_icons(self):
        expected = {b"ic07": 128, b"ic08": 256, b"ic09": 512, b"ic10": 1024,
                    b"ic11": 32, b"ic12": 64, b"ic13": 256, b"ic14": 512}
        for name in ("AppIcon.icns", "LabelWerk.icns"):
            with self.subTest(icon=name):
                data = (INSTALLER / "Resources" / name).read_bytes()
                self.assertEqual(data[:4], b"icns")
                self.assertEqual(struct.unpack(">I", data[4:8])[0], len(data))
                entries = {}
                position = 8
                while position < len(data):
                    kind, length = data[position:position + 4], struct.unpack(">I", data[position + 4:position + 8])[0]
                    self.assertGreaterEqual(length, 8)
                    entries[kind] = data[position + 8:position + length]
                    position += length
                self.assertEqual(position, len(data))
                for kind, size in expected.items():
                    self.assertIn(kind, entries, kind)
                    self.assertEqual(png_size(entries[kind]), (size, size), kind)
        previews = INSTALLER / "Resources" / "icon-preview"
        for size in (16, 32, 64, 128, 256, 512, 1024):
            self.assertEqual(png_size((previews / f"AppIcon-{size}.png").read_bytes()), (size, size))


if __name__ == "__main__":
    unittest.main()
