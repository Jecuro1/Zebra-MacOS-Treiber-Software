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
* ``build_driver.sh``: das Zielverzeichnis wird nur gelöscht, wenn es neu, leer oder ein früherer
  Treiberbaum ist,
* ``uninstall.sh`` gegen ein Testwurzelverzeichnis (``--root``),
* die Installer-Skripte (preinstall, postinstall) gegen ein Testvolume,
* die CI-Skripte: jeder fehlschlagende Befehl lässt seinen Schritt scheitern (eigener Prozess je
  Schritt), Optionen erreichen die Schrittprozesse, und ``ci_macos.sh`` deinstalliert nur nach
  einer tatsächlich begonnenen Probeinstallation (simuliertes macOS mit Attrappen für ``uname``
  und ``sudo``),
* ``notarize.sh`` gegen Attrappen von ``xcrun``, ``spctl`` & Co. (Gatekeeper-Prüfung je Dateityp),
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


def write_executable(path: Path, text: str) -> Path:
    """Legt ein ausführbares Skript an (für Attrappen und Test-Repositorys)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    os.chmod(path, 0o755)
    return path


def make_sandbox_repo(directory: Path, *files: str) -> Path:
    """Kopiert common.sh, config.env und die genannten Dateien in ein Test-Repository.

    ``LW_REPO_ROOT`` der Skripte ist dann ``directory`` – Ausgaben (build/, dist/) landen dort und
    nicht im echten Repository.
    """
    for relative in ("Installer/lib/common.sh", "Installer/config.env", *files):
        target = directory / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO_ROOT / relative, target)
    return directory


def ci_env(path_prefix: Optional[Path] = None, **extra: str) -> Dict[str, str]:
    """Umgebung für die CI-Skripte: ohne CI-Kennungen und Strenge-Schalter des Aufrufers."""
    env = clean_env()
    for key in ("CI", "GITHUB_ACTIONS", "GITHUB_PATH", "LW_STRICT_STRINGS", "LW_STRICT_E2E", "PYTHON",
                "LW_E2E_PORT"):
        env.pop(key, None)
    env["PYTHON"] = sys.executable
    if path_prefix is not None:
        env["PATH"] = f"{path_prefix}{os.pathsep}{env.get('PATH', '')}"
    env.update(extra)
    return env


def fake_macos_tools(directory: Path) -> Path:
    """Attrappen für ein simuliertes macOS: ``uname -s`` meldet Darwin, ``sudo`` protokolliert nur.

    ``sudo`` führt nie etwas aus, sondern schreibt den Befehl nach ``$FAKE_SUDO_LOG``.
    """
    real_uname = shutil.which("uname") or "/usr/bin/uname"
    write_executable(directory / "uname", f'''#!/bin/sh
if [ "$1" = "-s" ]; then echo Darwin; else exec "{real_uname}" "$@"; fi
''')
    write_executable(directory / "sudo", '''#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_SUDO_LOG"
exit 0
''')
    return directory


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
        targets = ["/", "//", "/Library", "/usr/local", "/Applications", "/Users", "/Users/jemand", "/Volumes/Daten",
                   "/private/etc", "/opt", "/var", "/etc", "/home", str(Path.home()),
                   str(Path.home() / "Library"), str(Path.home() / "Library" / "Printers"), str(REPO_ROOT),
                   f"{REPO_ROOT}/", str(REPO_ROOT / "Scripts" / "..")]
        for target in targets:
            with self.subTest(target=target):
                result = run([str(SCRIPTS / "build_driver.sh"), "--dry-run", "--host", "--output", target])
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn("Ungeeignetes Zielverzeichnis", result.stderr)
                self.assertNotIn("$ rm -rf", result.stderr)

    def test_build_driver_refuses_directories_with_foreign_content(self):
        # Regression: Das Ziel wird mit rm -rf geleert – nur eigene Treiberbäume dürfen weg.
        with tempfile.TemporaryDirectory(prefix="lw-out-") as tmp:
            base = Path(tmp)
            cases = {
                "datei": [("notizen.txt", "x")],
                "versteckt": [(".git/HEAD", "ref")],
                "fremde-ppd": [("Library/Printers/PPDs/Contents/Resources/Fremd.ppd.gz", "x")],
                "fremder-treiber": [("Library/Printers/Fremd/x", "x")],
                "fremde-library": [("Library/Preferences/a.plist", "x")],
            }
            for name, files in cases.items():
                with self.subTest(case=name):
                    target = base / name
                    for relative, content in files:
                        (target / relative).parent.mkdir(parents=True, exist_ok=True)
                        (target / relative).write_text(content, encoding="utf-8")
                    result = run([str(SCRIPTS / "build_driver.sh"), "--dry-run", "--host", "--output", str(target)])
                    self.assertEqual(result.returncode, 64, result.stderr)
                    self.assertIn("nicht von einem früheren Treiberbau", result.stderr)
                    self.assertIn(files[0][0].split("/")[0], result.stderr)
                    self.assertTrue((target / files[0][0]).exists())
            # Ein Link oder eine Datei als Ziel wird ebenfalls abgelehnt.
            (base / "link").symlink_to(base / "datei")
            (base / "eine-datei").write_text("x", encoding="utf-8")
            for target in (base / "link", base / "eine-datei"):
                with self.subTest(target=target.name):
                    result = run([str(SCRIPTS / "build_driver.sh"), "--dry-run", "--host", "--output", str(target)])
                    self.assertEqual(result.returncode, 64, result.stderr)
                    self.assertIn("Ungeeignetes Zielverzeichnis", result.stderr)

    def test_build_driver_accepts_new_empty_and_previous_trees(self):
        with tempfile.TemporaryDirectory(prefix="lw-out-") as tmp:
            base = Path(tmp)
            empty = base / "leer"
            empty.mkdir()
            previous = base / "vorher"
            driver = previous / "Library" / "Printers" / "LabelWerk"
            (driver / "Filter").mkdir(parents=True)
            (driver / "Filter" / "rastertolabelwerk").write_text("x", encoding="utf-8")
            (driver / ".DS_Store").write_text("x", encoding="utf-8")
            resources = previous / "Library" / "Printers" / "PPDs" / "Contents" / "Resources"
            resources.mkdir(parents=True)
            (resources / "LabelWerk-zd421t-203dpi.ppd.gz").write_bytes(b"x")
            # Nach „uninstall.sh --root“ bleiben leere Ordner übrig.
            emptied = base / "geleert" / "Library" / "Printers" / "PPDs" / "Contents" / "Resources"
            emptied.mkdir(parents=True)
            for target in (base / "neu" / "driver-root", empty, previous, base / "geleert"):
                with self.subTest(target=target.name):
                    result = run([str(SCRIPTS / "build_driver.sh"), "--dry-run", "--host", "--output", str(target)])
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f"$ rm -rf {os.path.realpath(target)}", result.stderr)


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
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir()), ["driver-root"])

    def test_rebuild_into_previous_tree_and_refusal_of_foreign_files(self):
        self.assertEqual(self.result.returncode, 0)
        root = self.tmp / "rebuild-root"
        argv = [str(SCRIPTS / "build_driver.sh"), "--host", "--no-sign", "--output", str(root)]
        first = run(argv, timeout=900)
        self.assertEqual(first.returncode, 0, first.stderr[-4000:])
        second = run(argv, timeout=900)
        self.assertEqual(second.returncode, 0, second.stderr[-4000:])
        self.assertTrue((root / "Library" / "Printers" / "LabelWerk" / "VERSION").is_file())
        foreign = root / "Library" / "Printers" / "PPDs" / "Contents" / "Resources" / "Fremd.ppd.gz"
        foreign.write_bytes(b"x")
        third = run(argv, timeout=900)
        self.assertEqual(third.returncode, 64, third.stderr[-4000:])
        self.assertTrue(foreign.exists(), "fremde Dateien dürfen nicht gelöscht werden")
        self.assertTrue((root / "Library" / "Printers" / "LabelWerk" / "VERSION").is_file())


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
        # Regression: Der lwctl-Link zeigt in die behaltene App und muss mit ihr bleiben.
        link = self.root / "usr" / "local" / "bin" / "lwctl"
        self.assertTrue(link.is_symlink(), "--keep-app darf den lwctl-Link nicht entfernen")
        self.assertEqual(os.readlink(link), "/Applications/LabelWerk.app/Contents/Helpers/lwctl")
        self.assertFalse((self.root / "Library" / "Printers" / "LabelWerk").exists())
        self.assertEqual(sorted(p.name for p in self.ppds.iterdir()), ["Fremd.ppd.gz"])

    def test_keep_app_dry_run_does_not_list_app_or_link(self):
        result = self.uninstall("--dry-run", "--keep-app")
        self.assertEqual(result.returncode, 0, result.stderr)
        listed = result.stdout + result.stderr
        self.assertNotIn("usr/local/bin/lwctl", listed)
        self.assertNotIn("LabelWerk.app", listed)
        self.assertIn("Library/Printers/LabelWerk", listed)

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
# CI-Skripte (Schritte als eigene Prozesse, Optionen, Probeinstallation)
# ------------------------------------------------------------------------------------------------

# Minimales CI-Skript nach dem Vertrag aus common.sh (lw_ci_run_step/lw_ci_exec_process).
CI_PROBE_SCRIPT = r"""#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/../Installer/lib/common.sh"
LW_CI_SCRIPT="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
STEPS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        "${LW_CI_PROCESS_ARG}") shift; LW_CI_PROCESS_CALL=("$@"); break ;;
        *) STEPS+=("$1"); shift ;;
    esac
done
step_first_fails() { false; echo "NACH DEM FEHLER" >&2; true; }
step_pipeline_fails() { false | cat; echo "NACH DER PIPELINE" >&2; }
step_unset_variable() { echo "${NICHT_GESETZT}"; echo "NACH DER VARIABLEN" >&2; }
step_die_code() { lw_die "absichtlich" 7; }
step_ok() { echo "OK-SCHRITT" >&2; }
step_args() { printf 'ARG<%s>\n' "$@" >&2; }
not_a_step() { echo "DARF NICHT LAUFEN" >&2; }
if [[ ${#LW_CI_PROCESS_CALL[@]} -gt 0 ]]; then
    lw_ci_exec_process "${LW_CI_PROCESS_CALL[@]}"
    exit 0
fi
for step in "${STEPS[@]}"; do
    if [[ "${step}" == "args" ]]; then
        set -- "a b" "" "c"
    else
        set --
    fi
    # Bewusst im Bedingungskontext – genau dort ging set -e früher verloren.
    if lw_ci_run_step "${step}" "step_${step}" "$@"; then
        echo "ERGEBNIS ${step}=0"
    else
        echo "ERGEBNIS ${step}=$?"
    fi
done
"""


class CIStepTests(unittest.TestCase):
    """lw_ci_run_step: Jeder fehlschlagende Befehl lässt den Schritt scheitern."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-ci-"))
        self.repo = make_sandbox_repo(self.tmp / "repo", "Scripts/ci_linux.sh")
        self.probe = write_executable(self.repo / "Scripts" / "ci_probe.sh", CI_PROBE_SCRIPT)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def results(self, *steps: str) -> Dict[str, int]:
        result = run([str(self.probe), *steps], env=ci_env())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.output = result.stderr
        return {line.split()[1].split("=")[0]: int(line.split("=")[1])
                for line in result.stdout.splitlines() if line.startswith("ERGEBNIS ")}

    def test_failure_before_successful_last_command_fails_step(self):
        # Regression: Im if/!-Kontext galt set -e auch in der Subshell nicht mehr – ein Schritt
        # scheiterte nur, wenn sein letzter Befehl scheiterte.
        results = self.results("first_fails", "pipeline_fails", "unset_variable", "ok")
        self.assertEqual(results["first_fails"], 1)
        self.assertNotEqual(results["pipeline_fails"], 0)
        self.assertNotEqual(results["unset_variable"], 0)
        self.assertEqual(results["ok"], 0)
        for marker in ("NACH DEM FEHLER", "NACH DER PIPELINE", "NACH DER VARIABLEN"):
            self.assertNotIn(marker, self.output)
        self.assertIn("Schritt „first_fails“ fehlgeschlagen (Exitcode 1", self.output)
        self.assertIn("Schritt „ok“ erfolgreich", self.output)

    def test_exit_code_and_arguments_are_passed_through(self):
        results = self.results("die_code", "args")
        self.assertEqual(results["die_code"], 7)
        self.assertEqual(results["args"], 0)
        self.assertIn("ARG<a b>\nARG<>\nARG<c>", self.output)

    def test_only_step_functions_can_be_started(self):
        for function in ("not_a_step", "rm", "step_gibt_es_nicht"):
            with self.subTest(function=function):
                result = run([str(self.probe), "--lw-ci-run-function", function, "-rf", str(self.tmp)],
                             env=ci_env())
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertNotIn("DARF NICHT LAUFEN", result.stderr)
                self.assertTrue(self.repo.exists())

    def test_exec_process_refuses_conditional_context(self):
        result = bash('step_x() { false; echo "WEITER" >&2; }\n'
                      'if lw_ci_exec_process step_x; then echo "erfolgreich"; fi\n', env=ci_env())
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertIn("unwirksam", result.stderr)
        self.assertNotIn("WEITER", result.stderr)

    def test_run_step_requires_script_path(self):
        result = bash('step_x() { :; }\nlw_ci_run_step x step_x\n', env=ci_env())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LW_CI_SCRIPT", result.stderr)


class CILinuxScriptTests(unittest.TestCase):
    """Scripts/ci_linux.sh in einem Test-Repository mit Attrappen der geprüften Werkzeuge."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-ci-linux-"))
        self.repo = make_sandbox_repo(self.tmp / "repo", "Scripts/ci_linux.sh")
        self.script = self.repo / "Scripts" / "ci_linux.sh"
        # Der Generator scheitert (wie generate_ppds.py --check bei einem cupstestppd-Befund),
        # die danach laufenden Generator-Tests gelingen.
        write_executable(self.repo / "Driver" / "ppd" / "generate_ppds.py",
                         'import sys\nprint("GENERATOR: --check fehlgeschlagen", file=sys.stderr)\nsys.exit(1)\n')
        write_executable(self.repo / "Driver" / "ppd" / "tests" / "test_generate.py",
                         'import sys\nprint("GENERATOR-TESTS LIEFEN", file=sys.stderr)\n')
        write_executable(self.repo / "Scripts" / "extract_strings.py",
                         'import sys\nprint("12 Schlüssel offen", file=sys.stderr)\nsys.exit(1)\n')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def ci(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        return run([str(self.script), *args], env=ci_env(**env), cwd=self.repo)

    def test_failing_check_is_not_masked_by_later_commands(self):
        # Regression: „test-ppd“ meldete Erfolg, weil nach dem scheiternden Generator noch die
        # Generator-Tests liefen (und gelangen).
        result = self.ci("test-ppd")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("GENERATOR: --check fehlgeschlagen", result.stderr)
        self.assertNotIn("GENERATOR-TESTS LIEFEN", result.stderr)
        self.assertIn("Schritt „test-ppd“ fehlgeschlagen", result.stderr)
        self.assertIn("Fehlgeschlagen: test-ppd", result.stderr)
        self.assertNotIn("Alle Schritte erfolgreich", result.stderr)

    def test_strict_strings_reaches_step_process(self):
        result = self.ci("strings")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Lokalisierung unvollständig", result.stderr)
        for args, env in ((("--strict-strings", "strings"), {}), (("strings",), {"LW_STRICT_STRINGS": "1"})):
            with self.subTest(args=args, env=env):
                result = self.ci(*args, **env)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("Schritt „strings“ fehlgeschlagen", result.stderr)

    def test_keep_going_collects_failures(self):
        result = self.ci("--keep-going", "--strict-strings", "test-ppd", "strings")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Fehlgeschlagen: test-ppd strings", result.stderr)
        result = self.ci("--strict-strings", "test-ppd", "strings")
        self.assertIn("Fehlgeschlagen: test-ppd", result.stderr)
        self.assertNotIn("Schritt „strings“", result.stderr)

    def test_internal_option_is_not_a_step(self):
        result = self.ci("--lw-ci-run-function")
        self.assertEqual(result.returncode, 64, result.stderr)


@unittest.skipIf(IS_MACOS, "simuliert macOS mit Attrappen – auf echtem macOS nicht ausführen")
class CIMacOSInstallTestTests(unittest.TestCase):
    """ci_macos.sh auf simuliertem macOS: Deinstalliert wird nur nach begonnener Installation."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-ci-macos-"))
        self.repo = make_sandbox_repo(self.tmp / "repo", "Scripts/ci_macos.sh", "Scripts/uninstall.sh")
        self.script = self.repo / "Scripts" / "ci_macos.sh"
        self.bin = fake_macos_tools(self.tmp / "bin")
        self.sudo_log = self.tmp / "sudo.log"
        version = re.search(r"(?m)^VERSION=(.*)$", (INSTALLER / "config.env").read_text(encoding="utf-8")).group(1)
        self.pkg = self.repo / "dist" / f"LabelWerk-{version.strip()}.pkg"
        self.marker = self.repo / "build" / "ci" / "install-test.started"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def ci(self, *args: str) -> subprocess.CompletedProcess:
        return run([str(self.script), *args], env=ci_env(self.bin, FAKE_SUDO_LOG=str(self.sudo_log)), cwd=self.repo)

    def sudo_calls(self) -> List[str]:
        if not self.sudo_log.exists():
            return []
        return self.sudo_log.read_text(encoding="utf-8").splitlines()

    def test_refused_install_test_does_not_uninstall(self):
        # Regression: Auch die verweigerte Probeinstallation löste „sudo uninstall.sh“ aus und hätte
        # eine echte LabelWerk-Installation entfernt.
        self.pkg.parent.mkdir(parents=True)
        self.pkg.write_bytes(b"xar!")
        result = self.ci("install-test")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("installiert Software systemweit", result.stderr)
        self.assertNotIn("uninstall-test", result.stderr)
        self.assertEqual(self.sudo_calls(), [])

    def test_missing_package_does_not_uninstall(self):
        result = self.ci("--allow-system-changes", "install-test")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Paket fehlt", result.stderr)
        self.assertNotIn("uninstall-test", result.stderr)
        self.assertEqual(self.sudo_calls(), [])
        self.assertFalse(self.marker.exists())

    def test_started_install_is_cleaned_up_after_failure(self):
        self.pkg.parent.mkdir(parents=True)
        self.pkg.write_bytes(b"xar!")
        result = self.ci("--allow-system-changes", "install-test")
        # Die Prüfungen nach dem (simulierten) Installer scheitern – aufgeräumt wird trotzdem.
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Schritt „install-test“ fehlgeschlagen", result.stderr)
        self.assertIn("Schritt „uninstall-test“", result.stderr)
        calls = self.sudo_calls()
        self.assertEqual(len(calls), 2, calls)
        self.assertTrue(calls[0].startswith(f"installer -pkg {self.pkg} -target /"), calls)
        self.assertRegex(calls[1], r"uninstall\.sh --yes --remove-queues$")
        self.assertFalse(self.marker.exists(), "die Markierung wird nach dem Aufräumen entfernt")

    def test_stale_marker_does_not_trigger_uninstall(self):
        write_executable(self.repo / "Scripts" / "generate_catalog_swift.py", "")
        self.marker.parent.mkdir(parents=True)
        self.marker.write_text("alt\n", encoding="utf-8")
        result = self.ci("catalog")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("uninstall-test", result.stderr)
        self.assertEqual(self.sudo_calls(), [])
        self.assertFalse(self.marker.exists())

    def test_uninstall_step_requires_permission(self):
        result = run([str(self.script), "--lw-ci-run-function", "step_uninstall_test"],
                     env=ci_env(self.bin, FAKE_SUDO_LOG=str(self.sudo_log)), cwd=self.repo)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("installiert Software systemweit", result.stderr)
        self.assertEqual(self.sudo_calls(), [])

    def test_step_failures_are_not_masked(self):
        # Wie unter Linux: Ein früher Fehler im Schritt (hier der Generator) lässt ihn scheitern.
        write_executable(self.repo / "Driver" / "ppd" / "generate_ppds.py", "import sys\nsys.exit(3)\n")
        write_executable(self.repo / "Driver" / "ppd" / "tests" / "test_generate.py",
                         'print("GENERATOR-TESTS LIEFEN")\n')
        result = self.ci("test-ppd")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Schritt „test-ppd“ fehlgeschlagen (Exitcode 3", result.stderr)
        self.assertNotIn("GENERATOR-TESTS LIEFEN", result.stdout + result.stderr)


# ------------------------------------------------------------------------------------------------
# Notarisierung (simuliertes macOS)
# ------------------------------------------------------------------------------------------------


@unittest.skipIf(IS_MACOS, "simuliert macOS mit Attrappen – auf echtem macOS nicht ausführen")
class NotarizeSimulationTests(unittest.TestCase):
    """notarize.sh gegen Attrappen von xcrun, plutil, spctl, codesign und pkgutil.

    Die spctl-Attrappe verhält sich wie Gatekeeper: Ein Disk-Image ohne
    ``--context context:primary-signature`` wird mit „Insufficient Context“ abgelehnt.
    """

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-notarize-"))
        self.bin = fake_macos_tools(self.tmp / "bin")
        self.log = self.tmp / "tools.log"
        python = sys.executable
        write_executable(self.bin / "xcrun", f"""#!/bin/sh
printf 'xcrun %s\\n' "$*" >> "$FAKE_TOOLS_LOG"
if [ "$1 $2" = "notarytool submit" ]; then echo '{{"id": "abc-123", "status": "Accepted"}}'; fi
exit 0
""")
        write_executable(self.bin / "plutil", f"""#!{python}
import json, sys
args = sys.argv[1:]
key, path = args[args.index("-extract") + 1], args[-1]
with open(path, encoding="utf-8") as handle:
    value = json.load(handle).get(key)
if value is None:
    sys.exit(1)
print(value)
""")
        write_executable(self.bin / "spctl", f"""#!{python}
import os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_TOOLS_LOG"], "a", encoding="utf-8") as log:
    log.write("spctl " + " ".join(args) + "\\n")
target = args[-1]
if target.endswith(".dmg") and "context:primary-signature" not in args:
    print(target + ": rejected\\nsource=Insufficient Context", file=sys.stderr)
    sys.exit(3)
print(target + ": accepted\\nsource=Notarized Developer ID", file=sys.stderr)
""")
        write_executable(self.bin / "codesign", """#!/bin/sh
printf 'codesign %s\\n' "$*" >> "$FAKE_TOOLS_LOG"
case "$1" in
    --verify) exit "${FAKE_CODESIGN_VERIFY:-0}" ;;
    -dv) echo "Authority=Developer ID Application: Test (ABCDE12345)" >&2 ;;
esac
exit 0
""")
        write_executable(self.bin / "pkgutil", "#!/bin/sh\nexit 0\n")
        write_executable(self.bin / "ditto", '#!/bin/sh\nfor last; do :; done\n: > "$last"\n')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def notarize(self, *files: Path, **env: str) -> subprocess.CompletedProcess:
        environment = ci_env(self.bin, FAKE_TOOLS_LOG=str(self.log), FAKE_SUDO_LOG=str(self.tmp / "sudo.log"),
                             NOTARY_KEYCHAIN_PROFILE="labelwerk-test", TMPDIR=str(self.tmp), **env)
        return run([str(SCRIPTS / "notarize.sh"), *map(str, files)], env=environment)

    def logged(self, tool: str) -> List[str]:
        if not self.log.exists():
            return []
        return [line for line in self.log.read_text(encoding="utf-8").splitlines() if line.startswith(tool + " ")]

    def test_disk_image_is_assessed_with_primary_signature_context(self):
        # Regression: spctl --type open ohne Kontext lehnt jedes Disk-Image ab („Insufficient
        # Context“) – das Skript brach nach erfolgreicher Notarisierung ab.
        image = self.tmp / "LabelWerk-1.0.0.dmg"
        image.write_bytes(b"koly")
        result = self.notarize(image)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Gatekeeper akzeptiert LabelWerk-1.0.0.dmg", result.stderr)
        self.assertEqual(self.logged("spctl"),
                         [f"spctl --assess --type open --context context:primary-signature --verbose=2 {image}"])
        self.assertIn(f"xcrun stapler staple {image}", self.logged("xcrun"))

    def test_package_and_app_use_their_assessment_types(self):
        package = self.tmp / "LabelWerk-1.0.0.pkg"
        package.write_bytes(b"xar!")
        app = self.tmp / "LabelWerk.app"
        (app / "Contents").mkdir(parents=True)
        result = self.notarize(package, app)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.logged("spctl"), [
            f"spctl --assess --type install --verbose=2 {package}",
            f"spctl --assess --type execute --verbose=2 {app}",
        ])

    def test_zip_is_not_assessed(self):
        archive = self.tmp / "LabelWerk.zip"
        archive.write_bytes(b"PK")
        result = self.notarize(archive)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.logged("spctl"), [])
        self.assertFalse(any("stapler" in line for line in self.logged("xcrun")))

    def test_unsigned_disk_image_is_rejected_before_submission(self):
        image = self.tmp / "unsigniert.dmg"
        image.write_bytes(b"koly")
        result = self.notarize(image, FAKE_CODESIGN_VERIFY="1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("nicht (gültig) signiert", result.stderr)
        self.assertFalse(any("notarytool submit" in line for line in self.logged("xcrun")))

    def test_dry_run_shows_assessment(self):
        result = run([str(SCRIPTS / "notarize.sh"), "--dry-run", "x.dmg", "y.pkg"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("spctl --assess --type open --context context:primary-signature --verbose=2", result.stderr)
        self.assertIn("spctl --assess --type install --verbose=2", result.stderr)


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
