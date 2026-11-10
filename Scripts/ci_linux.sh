#!/usr/bin/env bash
# shellcheck disable=SC1111  # Deutsche Anführungszeichen („…“) in Meldungen sind beabsichtigt.
#
# LabelWerk – CI unter Linux (Ubuntu 24.04)
#
# Baut und testet alles, was ohne macOS möglich ist: Modellkatalog, Swift-Kern und CLI, CUPS-Filter
# (C-Unit-Tests und End-to-End-Tests), PPD-Generator (inkl. cupstestppd), die Python- und
# Shell-Werkzeuge, den Treiberbaum (Testaufbau) und die Probeläufe der macOS-Skripte.
#
# Wird von .github/workflows/ci.yml schrittweise aufgerufen und funktioniert genauso lokal:
#
#   Scripts/ci_linux.sh                       alle Schritte
#   Scripts/ci_linux.sh build test-swift      nur diese Schritte
#   Scripts/ci_linux.sh --install-deps setup  Pakete (apt) und Swift-Toolchain installieren
#
# Umgebung: LW_JOBS (parallele Jobs), SWIFT_VERSION (Toolchain für --install-deps, Standard
# 6.4.2), LW_SWIFT_HOME (Installationsort der Toolchain), LW_STRICT_STRINGS=1 (fehlende
# Übersetzungen sind ein Fehler statt einer Warnung).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=SCRIPTDIR/../Installer/lib/common.sh
source "${SCRIPT_DIR}/../Installer/lib/common.sh"

ALL_STEPS=(setup lint catalog build test-swift test-driver test-ppd test-scripts driver-tree strings)

usage() {
    cat <<EOF
Aufruf: Scripts/ci_linux.sh [Optionen] [SCHRITT …]

Schritte (Standard: alle, in dieser Reihenfolge):
  setup         Werkzeuge prüfen und Versionen anzeigen
  lint          Shell- und Python-Syntax, ShellCheck, Workflow-YAML, Info.plist
  catalog       Modellkatalog: ModelCatalogData.swift aktuell?
  build         swift build (inkl. Tests und lwctl)
  test-swift    swift test
  test-driver   CUPS-Filter: make -C Driver/filter test
  test-ppd      PPDs erzeugen, mit cupstestppd prüfen, Generator-Tests
  test-scripts  Tests der Python- und Shell-Werkzeuge (Scripts/tests)
  driver-tree   Treiberbaum bauen (--host) und Probeläufe von App-, Paket- und Notarisierungsskript
  strings       Lokalisierung prüfen (fehlende Übersetzungen: Warnung)

Optionen:
  --install-deps    vor „setup“ Systempakete (apt) und Swift \${SWIFT_VERSION:-6.4.2} installieren
  --keep-going      nach einem fehlgeschlagenen Schritt weitermachen und am Ende zusammenfassen
  --strict-strings  fehlende Übersetzungen als Fehler werten (wie LW_STRICT_STRINGS=1)
  -h, --help        diese Hilfe
EOF
}

INSTALL_DEPS=0
KEEP_GOING=0
STRICT_STRINGS="${LW_STRICT_STRINGS:-0}"
STEPS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-deps) INSTALL_DEPS=1; shift ;;
        --keep-going) KEEP_GOING=1; shift ;;
        --strict-strings) STRICT_STRINGS=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; lw_die "Unbekannte Option „$1“." 64 ;;
        *)
            known=0
            for step in "${ALL_STEPS[@]}"; do
                [[ "$1" == "${step}" ]] && known=1
            done
            [[ "${known}" == "1" ]] || { usage >&2; lw_die "Unbekannter Schritt „$1“." 64; }
            STEPS+=("$1")
            shift
            ;;
    esac
done
if [[ ${#STEPS[@]} -eq 0 ]]; then
    STEPS=("${ALL_STEPS[@]}")
fi

cd "${LW_REPO_ROOT}"
JOBS="$(lw_jobs)"
PYTHON="${PYTHON:-python3}"
SWIFT_VERSION="${SWIFT_VERSION:-6.4.2}"
CI_TMP="${LW_REPO_ROOT}/build/ci"

# --- Abhängigkeiten ----------------------------------------------------------------------------

# Führt einen Befehl mit Administratorrechten aus (sudo, falls nicht bereits root).
as_root() {
    if [[ "$(id -u)" == "0" ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

install_packages() {
    lw_require_tool apt-get "Dieses Skript erwartet Ubuntu/Debian."
    # Swift-Laufzeitabhängigkeiten laut swift.org (Ubuntu 24.04) und die des Projekts.
    local packages=(
        binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libncurses-dev
        libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev libz3-dev pkg-config tzdata unzip
        curl ca-certificates make gcc
        libcups2-dev libcupsimage2-dev zlib1g-dev cups-client cups-ppdc
        python3 python3-yaml shellcheck
    )
    lw_run as_root apt-get update -qq
    lw_run as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${packages[@]}"
}

# Installiert die offizielle Swift-Toolchain von swift.org (mit Signaturprüfung, falls gpg vorhanden).
install_swift() {
    local version="$1"
    local arch_suffix=""
    case "$(uname -m)" in
        x86_64) arch_suffix="" ;;
        aarch64|arm64) arch_suffix="-aarch64" ;;
        *) lw_die "Keine Swift-Toolchain für $(uname -m) verfügbar." ;;
    esac
    local platform="ubuntu24.04"
    local name="swift-${version}-RELEASE-${platform}${arch_suffix}"
    local home="${LW_SWIFT_HOME:-${HOME}/.cache/labelwerk/swift}"
    local toolchain="${home}/${name}"

    if command -v swift >/dev/null 2>&1 && swift --version 2>/dev/null | grep -q "Swift version ${version} "; then
        lw_ok "Swift ${version} ist bereits installiert: $(command -v swift)"
        return 0
    fi
    if [[ -x "${toolchain}/usr/bin/swift" ]]; then
        lw_ok "Swift ${version} aus dem Zwischenspeicher: ${toolchain}"
        lw_ci_add_path "${toolchain}/usr/bin"
        return 0
    fi

    local url="https://download.swift.org/swift-${version}-release/${platform//./}${arch_suffix}/swift-${version}-RELEASE/${name}.tar.gz"
    local download
    download="$(mktemp -d "${TMPDIR:-/tmp}/labelwerk-swift.XXXXXX")"
    lw_info "Lade ${url}"
    lw_run curl -fsSL --retry 3 -o "${download}/${name}.tar.gz" "${url}"
    if command -v gpg >/dev/null 2>&1; then
        local keyring="${download}/gnupg"
        lw_run curl -fsSL --retry 3 -o "${download}/${name}.tar.gz.sig" "${url}.sig"
        lw_run curl -fsSL --retry 3 -o "${download}/all-keys.asc" "https://www.swift.org/keys/all-keys.asc"
        lw_run mkdir -m 700 "${keyring}"
        lw_run gpg --batch --quiet --homedir "${keyring}" --import "${download}/all-keys.asc"
        if ! lw_run gpg --batch --quiet --homedir "${keyring}" --verify "${download}/${name}.tar.gz.sig" \
            "${download}/${name}.tar.gz"; then
            rm -rf "${download}"
            lw_die "Die Signatur der Swift-Toolchain ist ungültig."
        fi
        lw_ok "Signatur der Toolchain geprüft"
    else
        lw_warn "gpg fehlt – die Signatur der Swift-Toolchain wird nicht geprüft."
    fi
    lw_run mkdir -p "${home}"
    lw_run tar -xzf "${download}/${name}.tar.gz" -C "${home}"
    rm -rf "${download}"
    [[ -x "${toolchain}/usr/bin/swift" ]] || lw_die "Swift wurde nicht nach ${toolchain} entpackt."
    lw_ci_add_path "${toolchain}/usr/bin"
    lw_ok "Swift ${version} installiert: ${toolchain}"
}

# --- Schritte ----------------------------------------------------------------------------------

step_setup() {
    local missing=0 tool
    for tool in swift "${PYTHON}" make cc gzip; do
        if command -v "${tool}" >/dev/null 2>&1; then
            lw_ok "${tool}: $(command -v "${tool}")"
        else
            lw_ci_error "„${tool}“ fehlt."
            missing=1
        fi
    done
    for header in /usr/include/cups/cups.h /usr/include/cups/raster.h /usr/include/zlib.h; do
        if [[ -f "${header}" ]]; then
            lw_ok "${header}"
        else
            lw_ci_error "${header} fehlt (libcups2-dev, libcupsimage2-dev, zlib1g-dev)."
            missing=1
        fi
    done
    for tool in cupstestppd shellcheck; do
        if command -v "${tool}" >/dev/null 2>&1; then
            lw_ok "${tool}: $(command -v "${tool}")"
        else
            lw_warn "„${tool}“ fehlt – die zugehörige Prüfung wird übersprungen."
        fi
    done
    if command -v swift >/dev/null 2>&1; then
        swift --version 2>&1 | sed 's/^/    /' >&2
    fi
    "${PYTHON}" --version 2>&1 | sed 's/^/    /' >&2
    lw_info "parallele Jobs: ${JOBS}"
    return "${missing}"
}

step_lint() {
    local status=0 script
    local shell_scripts=(
        Scripts/build_app.sh Scripts/build_driver.sh Scripts/make_pkg.sh Scripts/notarize.sh
        Scripts/uninstall.sh Scripts/ci_linux.sh Scripts/ci_macos.sh Installer/lib/common.sh
        Installer/pkg/scripts/driver/preinstall Installer/pkg/scripts/driver/postinstall
        Installer/pkg/scripts/cli/postinstall
    )
    for script in "${shell_scripts[@]}"; do
        bash -n "${script}" || { lw_ci_error "Syntaxfehler: ${script}"; status=1; }
    done
    lw_ok "Bash-Syntax: ${#shell_scripts[@]} Skripte"
    if command -v shellcheck >/dev/null 2>&1; then
        if shellcheck -x "${shell_scripts[@]}"; then
            lw_ok "ShellCheck: keine Befunde"
        else
            lw_ci_error "ShellCheck meldet Befunde."
            status=1
        fi
    else
        lw_warn "shellcheck fehlt – übersprungen."
    fi
    local python_files=()
    while IFS= read -r -d '' script; do
        python_files+=("${script}")
    done < <(find Scripts Driver/ppd Driver/filter/tests Catalog -name '*.py' -not -path '*/__pycache__/*' -print0)
    if "${PYTHON}" - "${python_files[@]}" <<'PY'
import ast, sys
failed = False
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as handle:
            ast.parse(handle.read(), path)
    except SyntaxError as error:
        print(f"{path}:{error.lineno}: {error.msg}", file=sys.stderr)
        failed = True
sys.exit(1 if failed else 0)
PY
    then
        lw_ok "Python-Syntax: ${#python_files[@]} Dateien"
    else
        lw_ci_error "Python-Syntaxfehler."
        status=1
    fi
    if "${PYTHON}" -c 'import yaml' 2>/dev/null; then
        if "${PYTHON}" - .github/workflows/*.yml <<'PY'
import sys, yaml
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        document = yaml.safe_load(handle)
    # PyYAML liest den Schlüssel „on“ als True (YAML 1.1).
    triggers = document.get("on", document.get(True))
    assert isinstance(document.get("jobs"), dict) and document["jobs"], f"{path}: keine Jobs"
    assert triggers, f"{path}: keine Auslöser"
    for name, job in document["jobs"].items():
        assert "runs-on" in job and job.get("steps"), f"{path}: Job {name} unvollständig"
    print(f"{path}: {len(document['jobs'])} Jobs")
PY
        then
            lw_ok "Workflow-YAML gültig"
        else
            lw_ci_error "Workflow-YAML ungültig."
            status=1
        fi
    else
        lw_warn "PyYAML fehlt – Workflow-YAML wird nicht geprüft (python3-yaml installieren)."
    fi
    if "${PYTHON}" - Installer/Info.plist Installer/LabelWerk.entitlements <<'PY'
import plistlib, sys
for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        plistlib.load(handle)
PY
    then
        lw_ok "Info.plist und Berechtigungen sind gültige Property-Listen"
    else
        lw_ci_error "Info.plist oder LabelWerk.entitlements ist ungültig."
        status=1
    fi
    return "${status}"
}

step_catalog() {
    lw_run "${PYTHON}" Scripts/generate_catalog_swift.py --check
}

step_build() {
    lw_run swift build -j "${JOBS}" --build-tests
}

step_test_swift() {
    # Baut bei Bedarf nach (z. B. wenn „build“ nicht vorher lief).
    lw_run swift test -j "${JOBS}"
}

step_test_driver() {
    if [[ ! -f Driver/filter/Makefile ]]; then
        lw_ci_warning "Driver/filter/Makefile fehlt – Filtertests übersprungen."
        return 0
    fi
    lw_run make -C Driver/filter -j "${JOBS}" tests
    lw_run make -C Driver/filter test
}

step_test_ppd() {
    if [[ ! -f Driver/ppd/generate_ppds.py ]]; then
        lw_ci_warning "Driver/ppd/generate_ppds.py fehlt – PPD-Prüfung übersprungen."
        return 0
    fi
    local out="${CI_TMP}/ppd"
    lw_run rm -rf "${out}"
    lw_run "${PYTHON}" Driver/ppd/generate_ppds.py --output "${out}" --gzip --check
    lw_run "${PYTHON}" Driver/ppd/tests/test_generate.py
}

step_test_scripts() {
    lw_run "${PYTHON}" -m unittest discover -s Scripts/tests -t Scripts/tests
}

step_driver_tree() {
    local root="${CI_TMP}/driver-root"
    lw_run Scripts/build_driver.sh --host --output "${root}"
    local filter
    for filter in rastertolabelwerk commandtolabelwerk; do
        [[ -x "${root}/Library/Printers/LabelWerk/Filter/${filter}" ]] || lw_die "${filter} fehlt im Treiberbaum."
    done
    local ppds
    ppds="$(find "${root}/Library/Printers/PPDs/Contents/Resources" -name 'LabelWerk-*.ppd.gz' | wc -l | tr -d ' ')"
    [[ "${ppds}" -gt 0 ]] || lw_die "Keine PPD-Dateien im Treiberbaum."
    lw_ok "Treiberbaum: 2 Filter, ${ppds} PPD-Dateien, Version $(cat "${root}/Library/Printers/LabelWerk/VERSION")"
    # Die macOS-Skripte müssen auch hier fehlerfrei durchlaufen (nur Anzeige der Befehle).
    lw_run Scripts/build_app.sh --dry-run --skip-driver --output "${CI_TMP}/dry"
    lw_run Scripts/make_pkg.sh --dry-run --skip-build --output "${CI_TMP}/dry"
    lw_run Scripts/notarize.sh --dry-run "${CI_TMP}/dry/LabelWerk.pkg"
    # Deinstallation gegen den eben gebauten Baum als Testwurzel.
    lw_run Scripts/uninstall.sh --root "${root}" --yes
    [[ ! -e "${root}/Library/Printers/LabelWerk" ]] || lw_die "uninstall.sh hat den Treiber nicht entfernt."
    lw_ok "Deinstallation (Testwurzel) erfolgreich"
}

step_strings() {
    if lw_run "${PYTHON}" Scripts/extract_strings.py --check --strict; then
        return 0
    fi
    if [[ "${STRICT_STRINGS}" == "1" ]]; then
        return 1
    fi
    lw_ci_warning "Lokalisierung unvollständig – Scripts/extract_strings.py ausführen und Installer/Resources/en.lproj/Localizable.strings übersetzen."
    return 0
}

# --- Ablauf ------------------------------------------------------------------------------------

lw_step "LabelWerk CI (Linux) – Schritte: ${STEPS[*]}"
mkdir -p "${CI_TMP}"
if [[ "${INSTALL_DEPS}" == "1" ]]; then
    # Nicht in einer Schritt-Subshell, damit der erweiterte PATH für alle Schritte gilt.
    lw_ci_group "Abhängigkeiten installieren"
    install_packages
    install_swift "${SWIFT_VERSION}"
    lw_ci_endgroup
fi
FAILED=()
for step in "${STEPS[@]}"; do
    if ! lw_ci_run_step "${step}" "step_${step//-/_}"; then
        FAILED+=("${step}")
        if [[ "${KEEP_GOING}" != "1" ]]; then
            break
        fi
    fi
done

lw_step "Zusammenfassung"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    lw_die "Fehlgeschlagen: ${FAILED[*]}"
fi
lw_ok "Alle Schritte erfolgreich: ${STEPS[*]}"
