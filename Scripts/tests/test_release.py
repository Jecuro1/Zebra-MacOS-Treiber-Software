#!/usr/bin/env python3
"""Tests für den Update-Dienst auf Seite der CI (unittest, nur Standardbibliothek).

Aufruf (vom Repository-Wurzelverzeichnis)::

    python3 Scripts/tests/test_release.py
    python3 -m unittest discover -s Scripts/tests -t Scripts/tests

Geprüft werden – auf jedem System, also auch unter Linux in der CI –

* ``Installer/lib/release.sh``: Tag, Titel und Dateiname des Releases, Vergleich zweier Tags
  (Version, dann Build-Nummer), Release-Notizen aus der Git-Historie (Commits seit dem vorherigen
  ``v*``-Tag, ohne Merges, höchstens 30; sonst die Commit-Nachricht ohne Trailer), das
  Update-Manifest ``labelwerk-update.json`` (Schema 1: Größe, SHA-256, Download-Adresse,
  Mindestversion, Zeitpunkt) und die Prüfung der ``PackageInfo`` der App-Komponente (nicht
  verschiebbar, „upgrade“, Versionsprüfung),
* ``UPDATE_REPOSITORY`` in ``config.env`` (Validierung, Platzhalter in der Info.plist),
* ``ci_macos.sh release`` auf simuliertem macOS mit einer Attrappe von ``gh``: Probelauf ohne
  Anfrage an GitHub, Veröffentlichung (Aufrufe, Dateien, ``GH_REPO``, kein Token im Protokoll),
  „neuestes Release“ nur ohne neueres Release, erneuter Lauf, Abbruch bei Fehlern, Forks und
  abgeschaltete Updates,
* der Workflow (Rechte, vollständige Historie, Release-Schritt als letzter Schritt) und die
  Komponenten-Einstellungen in ``make_pkg.sh``.
"""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Dict, List, Optional

from test_installer_scripts import (COMMON, INSTALLER, REPO_ROOT, SCRIPTS, ci_env, clean_env, fake_macos_tools,
                                    make_sandbox_repo, run, write_config, write_executable)

RELEASE = INSTALLER / "lib" / "release.sh"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ci.yml"
REPOSITORY = "Jecuro1/Zebra-MacOS-Treiber-Software"
# Git ohne Einstellungen des Aufrufers (Signatur, Hooks, Standardzweig …).
GIT_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
}
# 2026-11-10T12:00:00Z
EPOCH = "1794312000"

PACKAGE_INFO = """<?xml version="1.0" encoding="utf-8"?>
<pkg-info overwrite-permissions="true" relocatable="false" identifier="com.labelwerk.app.pkg" postinstall-action="none" version="1.1.0" format-version="2" generator-version="InstallCmds-846 (24A335)" install-location="{location}" auth="root">
    <payload numberOfFiles="42" installKBytes="12345"/>
    <bundle path="./LabelWerk.app" id="com.labelwerk.app" CFBundleShortVersionString="1.1.0" CFBundleVersion="{build}"/>
    <bundle-version>
        {checked}
    </bundle-version>
    <upgrade-bundle>
        {upgrade}
    </upgrade-bundle>
    <update-bundle/>
    <atomic-update-bundle/>
    <strict-identifier>
        <bundle id="com.labelwerk.app"/>
    </strict-identifier>
    <relocate>
        {relocate}
    </relocate>
</pkg-info>
"""
APP_BUNDLE = '<bundle id="com.labelwerk.app"/>'


def config_version() -> str:
    return re.search(r"(?m)^VERSION=(.*)$", (INSTALLER / "config.env").read_text(encoding="utf-8")).group(1).strip()


def release_bash(script: str, env: Optional[Dict[str, str]] = None) -> subprocess.CompletedProcess:
    """Führt Bash-Code mit eingebundenem common.sh und release.sh aus."""
    prelude = f'set -euo pipefail\nsource "{COMMON}"\nsource "{RELEASE}"\n'
    return run(["bash", "-c", prelude + script], env=env)


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], env={**os.environ, **GIT_ENV}, capture_output=True,
                            text=True, check=True)
    return result.stdout.strip()


def commit(repo: Path, subject: str, *body: str) -> str:
    message = [arg for paragraph in body for arg in ("-m", paragraph)]
    git(repo, "commit", "-q", "--allow-empty", "-m", subject, *message)
    return git(repo, "rev-parse", "HEAD")


def init_repo(repo: Path) -> None:
    repo.mkdir(parents=True, exist_ok=True)
    git(repo, "init", "-q", "-b", "main")


def write_app_info(path: Path, build: str = "58", version: Optional[str] = None,
                   repository: str = REPOSITORY) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": "com.labelwerk.app", "CFBundleShortVersionString": version or config_version(),
                       "CFBundleVersion": build, "LWUpdateRepository": repository,
                       "LSMinimumSystemVersion": "14.0"}, handle)
    return path


FAKE_GH = '''#!{python}
"""Attrappe von gh: protokolliert jeden Aufruf (Argumente, GH_REPO, Token vorhanden, Dateien)."""
import hashlib, json, os, sys
args = sys.argv[1:]
files = {{}}
notes = None
for index, arg in enumerate(args):
    if os.path.isfile(arg):
        with open(arg, "rb") as handle:
            files[os.path.basename(arg)] = hashlib.sha256(handle.read()).hexdigest()
    if arg == "--notes-file":
        with open(args[index + 1], encoding="utf-8") as handle:
            notes = handle.read()
entry = {{"args": args, "GH_REPO": os.environ.get("GH_REPO"), "token": bool(os.environ.get("GH_TOKEN")),
         "files": files, "notes": notes}}
with open(os.environ["FAKE_GH_LOG"], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(entry) + "\\n")
if args[:2] == ["release", "view"]:
    tag = args[2] if len(args) > 2 and not args[2].startswith("-") else None
    if tag is None:
        latest = os.environ.get("FAKE_GH_LATEST", "")
        if latest:
            print(latest)
            sys.exit(0)
    elif tag in os.environ.get("FAKE_GH_EXISTING", "").split():
        print(json.dumps({{"tagName": tag}}))
        sys.exit(0)
    print("release not found", file=sys.stderr)
    sys.exit(1)
if os.environ.get("FAKE_GH_FAIL") and args[:2] == ["release", os.environ["FAKE_GH_FAIL"]]:
    print("HTTP 422: Validation Failed", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
'''


# ------------------------------------------------------------------------------------------------
# release.sh
# ------------------------------------------------------------------------------------------------


class ReleaseNamingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-release-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def env(self, **values: str) -> Dict[str, str]:
        return clean_env(LW_CONFIG_FILE=str(write_config(self.tmp, **values)))

    def test_tag_title_and_asset_name(self):
        result = release_bash('lw_load_config\nlw_release_tag; echo; lw_release_title; echo; lw_release_asset_name; echo\n'
                              'lw_release_download_url "$(lw_release_tag)" "$(lw_release_asset_name)"; echo\n'
                              'echo "$LW_RELEASE_MANIFEST_NAME"',
                              env=self.env(VERSION="1.1.0", BUILD="58", UPDATE_REPOSITORY=REPOSITORY))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "v1.1.0-b58", "LabelWerk 1.1.0 (Build 58)", "LabelWerk-1.1.0-58.pkg",
            f"https://github.com/{REPOSITORY}/releases/download/v1.1.0-b58/LabelWerk-1.1.0-58.pkg",
            "labelwerk-update.json",
        ])

    def test_asset_name_without_spaces(self):
        result = release_bash("lw_load_config\nlw_release_asset_name",
                              env=self.env(APP_NAME='"Label Werk"', VERSION="2.0", BUILD="7"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Label-Werk-2.0-7.pkg")

    def test_build_must_be_an_integer(self):
        result = release_bash("lw_load_config\nlw_release_require_build\necho gut", env=self.env(BUILD="58"))
        self.assertEqual(result.stdout.strip(), "gut", result.stderr)
        result = release_bash("lw_load_config\nlw_release_require_build\necho gut", env=self.env(BUILD="1.2"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ganze Zahl", result.stderr)
        self.assertNotIn("gut", result.stdout)

    def test_tag_comparison_matches_app_ordering(self):
        cases = [
            ("v1.1.0-b59", "v1.1.0-b58", True),
            ("v1.1.0-b58", "v1.1.0-b59", False),
            ("v1.1.0-b58", "v1.1.0-b58", False),
            ("v1.2.0-b3", "v1.1.0-b58", True),
            ("v1.1.0-b99", "v1.2.0-b3", False),
            ("v1.10.0-b1", "v1.9.0-b99", True),
            ("v1.1-b2", "v1.1.0-b1", True),
            ("v1.1.0", "v1.1.0-b1", False),
            ("v2.0.0", "v1.9.9-b500", True),
            ("v1.1.0-b010", "v1.1.0-b9", True),
            ("kaputt", "v1.0.0-b1", False),
            ("v1.0.0-b1", "kaputt", True),
            ("v1.0.0-b1", "", True),
        ]
        script = "\n".join(
            f'if lw_release_tag_is_newer "{a}" "{b}"; then echo "{a}>{b} ja"; else echo "{a}>{b} nein"; fi'
            for a, b, _ in cases)
        result = release_bash(script, env=clean_env())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         [f"{a}>{b} {'ja' if newer else 'nein'}" for a, b, newer in cases])

    def test_same_repository_ignores_case(self):
        result = release_bash(
            f'lw_release_same_repository "{REPOSITORY}" "{REPOSITORY.lower()}" && echo gleich\n'
            f'lw_release_same_repository "{REPOSITORY}" "fork/Zebra-MacOS-Treiber-Software" || echo verschieden\n'
            'lw_release_same_repository "" "" || echo leer', env=clean_env())
        self.assertEqual(result.stdout.splitlines(), ["gleich", "verschieden", "leer"], result.stderr)


class UpdateRepositoryConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-update-config-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def load(self, config: Path, **env: str) -> subprocess.CompletedProcess:
        return release_bash('lw_load_config\nprintf "%s" "${UPDATE_REPOSITORY}"',
                            env=clean_env(LW_CONFIG_FILE=str(config), **env))

    def test_repository_default(self):
        result = self.load(INSTALLER / "config.env")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, REPOSITORY)

    def test_valid_empty_and_overridden_values(self):
        for value in (REPOSITORY, "a/b", "Some-Org/repo.name_2", ""):
            with self.subTest(value=value):
                result = self.load(write_config(self.tmp, UPDATE_REPOSITORY=value))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, value)
        result = self.load(write_config(self.tmp, UPDATE_REPOSITORY=REPOSITORY), UPDATE_REPOSITORY="fork/x")
        self.assertEqual(result.stdout, "fork/x")
        # Ohne Schlüssel in der Datei: leer (Updates abgeschaltet), kein Fehler.
        result = self.load(write_config(self.tmp))
        self.assertEqual((result.returncode, result.stdout), (0, ""), result.stderr)

    def test_invalid_values_are_rejected(self):
        for value in ("https://github.com/a/b", "a", "a/b/c", "-a/b", "a/b c", "a/..", "a/.", "a/$(touch x)"):
            with self.subTest(value=value):
                result = self.load(write_config(self.tmp, UPDATE_REPOSITORY=f'"{value}"'))
                self.assertNotEqual(result.returncode, 0, value)
                self.assertIn("UPDATE_REPOSITORY", result.stderr)

    def test_info_plist_placeholder_is_rendered(self):
        template = INSTALLER / "Info.plist"
        for value in (REPOSITORY, ""):
            with self.subTest(value=value):
                out = self.tmp / "Info.plist"
                result = release_bash(f'lw_load_config\nlw_render_template "{template}" "{out}"',
                                      env=clean_env(LW_CONFIG_FILE=str(write_config(self.tmp, UPDATE_REPOSITORY=value))))
                self.assertEqual(result.returncode, 0, result.stderr)
                info = plistlib.loads(out.read_bytes())
                self.assertEqual(info["LWUpdateRepository"], value)
                self.assertNotIn("@", out.read_text(encoding="utf-8").split("<plist", 1)[1])


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-notes-"))
        self.repo = make_sandbox_repo(self.tmp / "repo")
        init_repo(self.repo)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def notes(self, head: str = "HEAD", **env: str) -> subprocess.CompletedProcess:
        script = (f'source "{self.repo}/Installer/lib/common.sh"\nsource "{self.repo}/Installer/lib/release.sh"\n'
                  f'lw_release_notes "{head}"')
        return run(["bash", "-c", "set -euo pipefail\n" + script], env=clean_env(**GIT_ENV, **env), cwd=self.repo)

    def test_subjects_since_previous_tag_without_merges(self):
        commit(self.repo, "Erster Stand")
        git(self.repo, "tag", "v1.0.0-b5")
        commit(self.repo, "Etikettengröße vom Drucker lesen")
        git(self.repo, "checkout", "-q", "-b", "feature")
        commit(self.repo, "Update-Dienst: Manifest prüfen")
        git(self.repo, "checkout", "-q", "main")
        git(self.repo, "merge", "-q", "--no-ff", "-m", "Merge pull request #7 from feature", "feature")
        commit(self.repo, "Fehler `x` behoben – *wichtig*")
        result = self.notes()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[:2], ["## Änderungen", ""])
        self.assertEqual(sorted(lines[2:]), sorted(["- Fehler `x` behoben – *wichtig*",
                                                     "- Update-Dienst: Manifest prüfen",
                                                     "- Etikettengröße vom Drucker lesen"]))
        self.assertEqual(lines[2], "- Fehler `x` behoben – *wichtig*", "neueste zuerst")
        self.assertNotIn("Merge", result.stdout)
        self.assertNotIn("Erster Stand", result.stdout)

    def test_tag_on_the_commit_itself_is_not_the_previous_tag(self):
        commit(self.repo, "Erster Stand")
        git(self.repo, "tag", "v1.0.0")
        commit(self.repo, "Neu A")
        commit(self.repo, "Neu B")
        git(self.repo, "tag", "v1.1.0")            # Tag-Push: der gebaute Commit trägt selbst einen v*-Tag
        git(self.repo, "tag", "v1.1.0-b58")        # erneuter Lauf: Release-Tag auf dem Commit
        result = self.notes()
        self.assertEqual(result.stdout, "## Änderungen\n\n- Neu B\n- Neu A\n", result.stderr)

    def test_at_most_thirty_subjects(self):
        commit(self.repo, "Basis")
        git(self.repo, "tag", "v1.0.0-b1")
        for number in range(1, 33):
            commit(self.repo, f"Änderung {number}")
        result = self.notes()
        lines = result.stdout.splitlines()
        self.assertEqual(lines[2], "- Änderung 32")
        self.assertEqual(lines[31], "- Änderung 3")
        self.assertEqual(lines[32], "- … und 2 weitere Änderungen")
        self.assertEqual(len(lines), 33)
        result = self.notes(LW_RELEASE_MAX_NOTES="31")
        self.assertEqual(result.stdout.splitlines()[-1], "- … und eine weitere Änderung")

    def test_fallback_to_commit_message_without_trailers(self):
        commit(self.repo, "Update-Dienst", "Die App lädt Updates selbst.\nZweite Zeile.",
               "Co-Authored-By: Jemand <jemand@example.com>\nClaude-Session: https://example.com/x")
        result = self.notes()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout,
                         "## Änderungen\n\n- Update-Dienst\n\nDie App lädt Updates selbst.\nZweite Zeile.\n")
        # Seit dem vorherigen Tag nur ein Merge-Commit: ebenfalls die Nachricht des Commits.
        commit(self.repo, "Zweiter Stand")
        git(self.repo, "tag", "v1.0.0-b1")
        merge = git(self.repo, "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-p", "HEAD~1", "-m", "Zusammengeführt")
        git(self.repo, "reset", "-q", "--hard", merge)
        result = self.notes()
        self.assertEqual(result.stdout, "## Änderungen\n\n- Zusammengeführt\n", result.stderr)

    def test_without_git_history(self):
        shutil.rmtree(self.repo / ".git")
        result = self.notes(GIT_CEILING_DIRECTORIES=str(self.tmp))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Git-Historie", result.stderr)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-manifest-"))
        self.package = self.tmp / "LabelWerk-1.1.0-58.pkg"
        self.package.write_bytes(b"xar!" + bytes(range(256)) * 4100)
        self.notes = self.tmp / "notes.md"
        self.notes.write_text("## Änderungen\n\n- Update-Dienst \"neu\" – mit \\ und Umlauten\n\n", encoding="utf-8")
        self.info = write_app_info(self.tmp / "Info.plist")
        self.manifest = self.tmp / "labelwerk-update.json"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, **config: str) -> subprocess.CompletedProcess:
        values = {"VERSION": "1.1.0", "BUILD": "58", "UPDATE_REPOSITORY": REPOSITORY}
        values.update(config)
        env = clean_env(LW_CONFIG_FILE=str(write_config(self.tmp, **values)), SOURCE_DATE_EPOCH=EPOCH)
        return release_bash(f'lw_load_config\nlw_release_write_manifest "{self.package}" "{self.info}" '
                            f'"{self.notes}" "{self.manifest}"', env=env)

    def test_schema_1(self):
        result = self.write()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = self.package.read_bytes()
        manifest = json.loads(self.manifest.read_text(encoding="utf-8"))
        self.assertEqual(manifest, {
            "schema": 1,
            "version": "1.1.0",
            "build": 58,
            "tag": "v1.1.0-b58",
            "pkg": {
                "name": "LabelWerk-1.1.0-58.pkg",
                "url": f"https://github.com/{REPOSITORY}/releases/download/v1.1.0-b58/LabelWerk-1.1.0-58.pkg",
                "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            },
            "minimumSystemVersion": "14.0",
            "publishedAt": "2026-11-10T12:00:00Z",
            "notes": "## Änderungen\n\n- Update-Dienst \"neu\" – mit \\ und Umlauten\n",
        })
        self.assertIsInstance(manifest["build"], int)
        self.assertIn(hashlib.sha256(data).hexdigest(), result.stderr)

    def test_published_at_defaults_to_now_in_utc(self):
        env = clean_env(LW_CONFIG_FILE=str(write_config(self.tmp, VERSION="1.1.0", BUILD="58",
                                                        UPDATE_REPOSITORY=REPOSITORY)))
        result = release_bash(f'lw_load_config\nlw_release_write_manifest "{self.package}" "{self.info}" '
                              f'"{self.notes}" "{self.manifest}"', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(json.loads(self.manifest.read_text(encoding="utf-8"))["publishedAt"],
                         r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_minimum_system_version_comes_from_info_plist(self):
        with open(self.info, "wb") as handle:
            plistlib.dump({"LSMinimumSystemVersion": "15.1"}, handle)
        self.assertEqual(self.write().returncode, 0)
        self.assertEqual(json.loads(self.manifest.read_text(encoding="utf-8"))["minimumSystemVersion"], "15.1")

    def test_manifest_field(self):
        self.assertEqual(self.write().returncode, 0)
        result = release_bash(f'lw_release_manifest_field "{self.manifest}" pkg.sha256', env=clean_env())
        self.assertEqual(result.stdout.strip(), hashlib.sha256(self.package.read_bytes()).hexdigest())

    def test_refusals(self):
        cases = [
            ({"BUILD": "1.2"}, "ganze Zahl"),
            ({"UPDATE_REPOSITORY": ""}, "UPDATE_REPOSITORY ist leer"),
        ]
        for config, message in cases:
            with self.subTest(config=config):
                result = self.write(**config)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.manifest.exists())
        self.package.write_bytes(b"")
        result = self.write()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("leer", result.stderr)
        self.assertFalse(self.manifest.exists())


class AppInfoCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-appinfo-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def check(self, info: Path) -> subprocess.CompletedProcess:
        env = clean_env(LW_CONFIG_FILE=str(write_config(self.tmp, VERSION=config_version(), BUILD="58",
                                                        UPDATE_REPOSITORY=REPOSITORY)))
        return release_bash(f'lw_load_config\nlw_release_check_app_info "{info}"\necho gut', env=env)

    def test_matching_and_stale_apps(self):
        result = self.check(write_app_info(self.tmp / "ok.plist"))
        self.assertEqual(result.stdout.strip(), "gut", result.stderr)
        for name, kwargs, message in (("build", {"build": "57"}, "CFBundleVersion"),
                                      ("version", {"version": "0.9.0"}, "CFBundleShortVersionString"),
                                      ("repo", {"repository": ""}, "LWUpdateRepository")):
            with self.subTest(case=name):
                result = self.check(write_app_info(self.tmp / f"{name}.plist", **kwargs))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertIn("neu bauen", result.stderr)


class PackageInfoCheckTests(unittest.TestCase):
    """lw_check_app_package_info gegen PackageInfo-Dateien, wie pkgbuild sie schreibt."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-pkginfo-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def check(self, **fields: str) -> subprocess.CompletedProcess:
        values = {"location": "/Applications", "build": "58", "checked": APP_BUNDLE, "upgrade": APP_BUNDLE,
                  "relocate": ""}
        values.update(fields)
        path = self.tmp / "PackageInfo"
        path.write_text(PACKAGE_INFO.format(**values), encoding="utf-8")
        env = clean_env(LW_CONFIG_FILE=str(write_config(self.tmp, VERSION="1.1.0", BUILD="58")))
        return release_bash(f'lw_load_config\nlw_check_app_package_info "{path}"\necho gut', env=env)

    def test_update_ready_component(self):
        result = self.check()
        self.assertEqual(result.stdout.strip(), "gut", result.stderr)
        self.assertIn("nicht verschiebbar", result.stderr)
        self.assertIn("Build 58", result.stderr)

    def test_problems_are_reported(self):
        cases = {
            "verschiebbar": ({"relocate": APP_BUNDLE}, "verschiebbar (BundleIsRelocatable)"),
            "kein upgrade": ({"upgrade": ""}, "upgrade"),
            "keine Versionsprüfung": ({"checked": ""}, "BundleIsVersionChecked"),
            "falsche Build-Nummer": ({"build": "1"}, "CFBundleVersion '1' statt '58'"),
            "anderer Ort": ({"location": "/Users/Shared"}, "Installationsort"),
        }
        for name, (fields, message) in cases.items():
            with self.subTest(case=name):
                result = self.check(**fields)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("gut", result.stdout)
                self.assertIn(message, result.stderr)


# ------------------------------------------------------------------------------------------------
# ci_macos.sh release (simuliertes macOS, Attrappe von gh)
# ------------------------------------------------------------------------------------------------


class CIMacOSReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-ci-release-"))
        self.repo = make_sandbox_repo(self.tmp / "repo", "Scripts/ci_macos.sh")
        self.script = self.repo / "Scripts" / "ci_macos.sh"
        self.bin = fake_macos_tools(self.tmp / "bin")
        write_executable(self.bin / "gh", FAKE_GH.format(python=sys.executable))
        self.gh_log = self.tmp / "gh.log"
        self.version = config_version()
        self.package = self.repo / "dist" / f"LabelWerk-{self.version}.pkg"
        self.package.parent.mkdir(parents=True)
        self.package.write_bytes(b"xar!" + b"Paket" * 1000)
        self.info = write_app_info(self.repo / "build" / "LabelWerk.app" / "Contents" / "Info.plist")
        init_repo(self.repo)
        commit(self.repo, "Erster Stand")
        git(self.repo, "tag", f"v{self.version}-b57")
        commit(self.repo, "Update-Dienst in der App")
        self.head = git(self.repo, "rev-parse", "HEAD")
        self.tag = f"v{self.version}-b58"
        self.asset = f"LabelWerk-{self.version}-58.pkg"
        self.stage = self.repo / "dist" / "release"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def ci(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        values = {"BUILD": "58", "FAKE_GH_LOG": str(self.gh_log), "FAKE_SUDO_LOG": str(self.tmp / "sudo.log"),
                  "SOURCE_DATE_EPOCH": EPOCH, **GIT_ENV}
        values.update(env)
        return run([str(self.script), *args, "release"], env=ci_env(self.bin, **values), cwd=self.repo)

    def publish(self, **env: str) -> subprocess.CompletedProcess:
        values = {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": REPOSITORY, "GH_TOKEN": "ghs_geheim123"}
        values.update(env)
        return self.ci(**values)

    def gh_calls(self) -> List[dict]:
        if not self.gh_log.exists():
            return []
        return [json.loads(line) for line in self.gh_log.read_text(encoding="utf-8").splitlines()]

    def test_release_is_not_a_default_step(self):
        text = self.script.read_text(encoding="utf-8")
        default = re.search(r"(?m)^DEFAULT_STEPS=\((.*)\)$", text).group(1).split()
        self.assertNotIn("release", default)
        self.assertIn("artifacts", default)
        result = run([str(self.script), "--help"], env=ci_env(self.bin))
        self.assertEqual(result.returncode, 0, result.stderr)
        for fragment in ("release", "--allow-publish", "--release-dry-run", "labelwerk-update.json"):
            self.assertIn(fragment, result.stdout)

    def test_dry_run_prepares_files_without_asking_github(self):
        result = self.ci("--release-dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.gh_calls(), [])
        self.assertEqual(sorted(p.name for p in self.stage.iterdir()),
                         sorted([self.asset, "labelwerk-update.json", "notes.md", "release-body.md"]))
        self.assertEqual((self.stage / self.asset).read_bytes(), self.package.read_bytes())
        manifest = json.loads((self.stage / "labelwerk-update.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["tag"], self.tag)
        self.assertEqual(manifest["build"], 58)
        self.assertEqual(manifest["pkg"]["sha256"], hashlib.sha256(self.package.read_bytes()).hexdigest())
        self.assertEqual(manifest["notes"], "## Änderungen\n\n- Update-Dienst in der App\n")
        self.assertIn(f"$ gh release create {self.tag} {self.stage / self.asset} "
                      f"{self.stage / 'labelwerk-update.json'} --title", result.stderr)
        self.assertIn(f"--target {self.head} --latest=true", result.stderr)
        self.assertIn("Probelauf", result.stderr)
        body = (self.stage / "release-body.md").read_text(encoding="utf-8")
        self.assertTrue(body.startswith("## Änderungen\n\n- Update-Dienst in der App\n"))
        self.assertIn(manifest["pkg"]["sha256"], body)
        # Auch über die Umgebung (wie in den Schrittprozessen).
        self.assertEqual(self.ci(LW_RELEASE_DRY_RUN="1").returncode, 0)
        self.assertEqual(self.gh_calls(), [])

    def test_publishing_requires_github_actions_or_permission(self):
        result = self.ci()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("veröffentlicht ein Update", result.stderr)
        self.assertEqual(self.gh_calls(), [])
        result = self.ci("--allow-publish", GH_TOKEN="x")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.gh_calls())

    def test_publish_creates_latest_release_with_both_files(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("ghs_geheim123", result.stdout + result.stderr)
        calls = self.gh_calls()
        self.assertEqual([call["args"][:3] for call in calls], [
            ["release", "view", "--json"],
            ["release", "view", self.tag],
            ["release", "create", self.tag],
        ])
        create = calls[-1]
        self.assertEqual(create["args"][3:], [
            str(self.stage / self.asset), str(self.stage / "labelwerk-update.json"),
            "--title", f"LabelWerk {self.version} (Build 58)",
            "--notes-file", str(self.stage / "release-body.md"),
            "--target", self.head, "--latest=true",
        ])
        for call in calls:
            self.assertEqual(call["GH_REPO"], REPOSITORY)
            self.assertTrue(call["token"])
        manifest = json.loads((self.stage / "labelwerk-update.json").read_text(encoding="utf-8"))
        self.assertEqual(create["files"][self.asset], hashlib.sha256(self.package.read_bytes()).hexdigest())
        self.assertEqual(manifest["pkg"]["sha256"], create["files"][self.asset])
        self.assertIn("- Update-Dienst in der App", create["notes"])
        self.assertIn(f"/releases/tag/{self.tag}", result.stderr)

    def test_newer_latest_release_is_not_replaced(self):
        result = self.publish(FAKE_GH_LATEST=f"v{self.version}-b60")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.gh_calls()[-1]["args"][-1], "--latest=false")
        self.assertIn("nicht als neuestes", result.stderr)
        for latest in (f"v{self.version}-b57", "v0.9.0", "irgendwas"):
            with self.subTest(latest=latest):
                self.gh_log.unlink()
                result = self.publish(FAKE_GH_LATEST=latest)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.gh_calls()[-1]["args"][-1], "--latest=true")

    def test_rerun_replaces_files_of_existing_release(self):
        result = self.publish(FAKE_GH_EXISTING=self.tag, FAKE_GH_LATEST=self.tag)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [call["args"] for call in self.gh_calls()]
        self.assertEqual(calls[2], ["release", "upload", self.tag, str(self.stage / self.asset),
                                    str(self.stage / "labelwerk-update.json"), "--clobber"])
        self.assertEqual(calls[3][:3], ["release", "edit", self.tag])
        self.assertEqual(calls[3][-1], "--latest=true")
        self.assertNotIn("create", [call[1] for call in calls])
        self.assertIn("gibt es schon", result.stderr)

    def test_failed_create_fails_the_step(self):
        result = self.publish(FAKE_GH_FAIL="create")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Schritt „release“ fehlgeschlagen", result.stderr)
        self.assertIn("HTTP 422", result.stderr)
        self.assertNotIn("veröffentlicht: https://", result.stderr)

    def test_fork_and_disabled_updates_skip_without_failing(self):
        result = self.publish(GITHUB_REPOSITORY="someone/Zebra-MacOS-Treiber-Software")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("kein Release", result.stderr)
        self.assertEqual(self.gh_calls(), [])
        result = self.publish(GITHUB_REPOSITORY=REPOSITORY.upper())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.gh_calls(), "Groß-/Kleinschreibung zählt nicht")
        self.gh_log.unlink()
        result = self.publish(UPDATE_REPOSITORY="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Update-Dienst abgeschaltet", result.stderr)
        self.assertEqual(self.gh_calls(), [])

    def test_missing_or_stale_build_fails(self):
        write_app_info(self.info, build="57")
        result = self.publish()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("CFBundleVersion", result.stderr)
        self.assertEqual(self.gh_calls(), [])
        write_app_info(self.info)
        self.package.unlink()
        result = self.publish()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Paket fehlt", result.stderr)
        result = self.publish(BUILD="5.1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("ganze Zahl", result.stderr)
        self.assertEqual(self.gh_calls(), [])


# ------------------------------------------------------------------------------------------------
# Workflow und Paketbau
# ------------------------------------------------------------------------------------------------


class WorkflowReleaseTests(unittest.TestCase):
    def setUp(self):
        try:
            import yaml  # noqa: F401  (python3-yaml, wie im Lint-Schritt)
        except ImportError:
            self.skipTest("PyYAML fehlt")
        import yaml
        self.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.macos = self.workflow["jobs"]["macos"]

    def test_permissions(self):
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertEqual(self.macos["permissions"], {"contents": "write"})
        self.assertNotIn("permissions", self.workflow["jobs"]["linux"])

    def test_build_number_and_history(self):
        self.assertEqual(self.macos["env"]["BUILD"], "${{ github.run_number }}")
        checkout = self.macos["steps"][0]
        self.assertTrue(checkout["uses"].startswith("actions/checkout@"))
        self.assertEqual(checkout["with"]["fetch-depth"], 0)

    def test_release_is_the_last_step_and_only_after_success(self):
        steps = self.macos["steps"]
        runs = [step.get("run", "") for step in steps]
        release = steps[-1]
        self.assertEqual(release["run"], "Scripts/ci_macos.sh release")
        self.assertNotIn("if", release, "nur nach Erfolg aller Schritte (Standardbedingung)")
        self.assertNotIn("continue-on-error", release)
        self.assertEqual(release["env"], {"GH_TOKEN": "${{ github.token }}"})
        self.assertLess(runs.index("Scripts/ci_macos.sh artifacts"), len(steps) - 1)
        self.assertLess(runs.index("Scripts/ci_macos.sh verify-pkg"), runs.index("Scripts/ci_macos.sh artifacts"))
        condition = " ".join(self.macos["if"].split())
        for trigger in ("workflow_dispatch", "refs/heads/main", "refs/tags/v"):
            self.assertIn(trigger, condition)


class PackageComponentTests(unittest.TestCase):
    def test_app_component_is_not_relocatable_and_version_checked(self):
        with tempfile.TemporaryDirectory(prefix="lw-dry-") as tmp:
            result = run([str(SCRIPTS / "make_pkg.sh"), "--dry-run", "--skip-build", "--output", tmp])
        self.assertEqual(result.returncode, 0, result.stderr)
        for fragment in ("0.BundleIsRelocatable -bool NO", "0.BundleOverwriteAction -string upgrade",
                         "0.BundleIsVersionChecked -bool YES", "--install-location /Applications"):
            self.assertIn(fragment, result.stderr)

    def test_ci_checks_update_readiness(self):
        text = (SCRIPTS / "ci_macos.sh").read_text(encoding="utf-8")
        verify = text[text.index("step_verify_pkg()"):text.index("step_artifacts()")]
        self.assertIn("lw_check_app_package_info", verify)
        self.assertIn("LWUpdateRepository", verify)
        install = text[text.index("step_install_test()"):text.index("check_queue_label_size()")]
        self.assertIn("plutil -replace CFBundleVersion -string 0", install)
        self.assertLess(install.index("plutil -replace CFBundleVersion"), install.rindex("installer -pkg"))


if __name__ == "__main__":
    unittest.main()
