#!/usr/bin/env bash
# shellcheck disable=SC1111  # Deutsche Anführungszeichen („…“) in Meldungen sind beabsichtigt.
#
# LabelWerk – CI unter macOS
#
# Baut und prüft alles, was nur auf macOS geht: Swift-Tests inklusive App-Ziel, Universal-Filter,
# das signierte App-Bundle, das Installationspaket – und installiert das Paket probeweise auf dem
# CI-Rechner (Rechte, cupsd, Warteschlange, Deinstallation). Optional druckt ein End-to-End-Test
# ein PDF über CUPS und unseren Filter an einen lokalen „Drucker“ (TCP-Port) und prüft das ZPL.
#
#   Scripts/ci_macos.sh                         alle Standardschritte
#   Scripts/ci_macos.sh test-swift app pkg      nur diese Schritte
#
# Die Schritte „install-test“ und „e2e-print“ verändern das System (sudo installer, lpadmin) und
# laufen deshalb nur auf CI-Rechnern (CI=true) oder mit --allow-system-changes. Hat
# „install-test“ den Installer tatsächlich gestartet, wird am Ende des Aufrufs immer deinstalliert
# (auch nach Fehlern) – sonst nicht, damit eine verweigerte oder vorzeitig abgebrochene
# Probeinstallation keine vorhandene LabelWerk-Installation entfernt. Ein fehlgeschlagener
# Testdruck („e2e-print“) ist nur eine Warnung, weil er von der CUPS-Konfiguration des Rechners
# abhängt – mit --strict-e2e ein Fehler.
#
# Jeder Schritt läuft als eigener Prozess dieses Skripts (siehe lw_ci_run_step in common.sh):
# Jeder fehlschlagende Befehl beendet den Schritt.
#
# Umgebung: LW_JOBS (parallele Jobs), DEVELOPER_ID_APP/DEVELOPER_ID_INSTALLER (optional; ohne
# Angabe ad hoc signierte App und unsigniertes Paket), LW_STRICT_STRINGS=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=SCRIPTDIR/../Installer/lib/common.sh
source "${SCRIPT_DIR}/../Installer/lib/common.sh"

DEFAULT_STEPS=(setup catalog test-swift test-driver test-ppd test-scripts strings app pkg verify-pkg artifacts)
SYSTEM_STEPS=(install-test e2e-print)
ALL_STEPS=("${DEFAULT_STEPS[@]}" "${SYSTEM_STEPS[@]}")

usage() {
    cat <<EOF
Aufruf: Scripts/ci_macos.sh [Optionen] [SCHRITT …]

Standardschritte (in dieser Reihenfolge):
  setup         Xcode, Swift und Werkzeuge anzeigen/prüfen
  catalog       Modellkatalog: ModelCatalogData.swift aktuell?
  test-swift    swift test (Kernmodule, CLI und App-Ziel)
  test-driver   Universal-Filter bauen (arm64 + x86_64) und Filtertests ausführen
  test-ppd      PPDs erzeugen, mit cupstestppd prüfen, Generator-Tests
  test-scripts  Tests der Python- und Shell-Werkzeuge (Scripts/tests)
  strings       Lokalisierung prüfen (fehlende Übersetzungen: Warnung)
  app           Scripts/build_app.sh – Release, Universal Binary, signiert (ad hoc ohne Identität)
  pkg           Scripts/make_pkg.sh --skip-build (unsigniert ohne DEVELOPER_ID_INSTALLER)
  verify-pkg    Paketinhalt, Architekturen, Info.plist und Signaturen prüfen
  artifacts     App als ZIP nach dist/ legen (für den Upload)

Schritte mit Systemänderungen (nur mit CI=true oder --allow-system-changes):
  install-test  Paket installieren, Rechte/CUPS/Warteschlange prüfen, wieder deinstallieren
  e2e-print     PDF über CUPS und den Filter an einen lokalen TCP-„Drucker“ drucken

Optionen:
  --allow-system-changes  install-test/e2e-print auch außerhalb der CI erlauben
  --keep-going            nach einem fehlgeschlagenen Schritt weitermachen
  --strict-strings        fehlende Übersetzungen als Fehler werten
  --strict-e2e            fehlgeschlagenen Testdruck als Fehler werten (sonst Warnung)
  -h, --help              diese Hilfe
EOF
}

KEEP_GOING=0
ALLOW_SYSTEM="${CI:-false}"
STRICT_STRINGS="${LW_STRICT_STRINGS:-0}"
STRICT_E2E="${LW_STRICT_E2E:-0}"
STEPS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        "${LW_CI_PROCESS_ARG}")
            # Intern (lw_ci_run_step): nur diese Funktion in diesem Prozess ausführen.
            shift
            [[ $# -gt 0 ]] || lw_die "${LW_CI_PROCESS_ARG} erwartet einen Funktionsnamen." 64
            LW_CI_PROCESS_CALL=("$@")
            break
            ;;
        --allow-system-changes) ALLOW_SYSTEM=true; shift ;;
        --keep-going) KEEP_GOING=1; shift ;;
        --strict-strings) STRICT_STRINGS=1; shift ;;
        --strict-e2e) STRICT_E2E=1; shift ;;
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
    STEPS=("${DEFAULT_STEPS[@]}")
fi

# Optionen, die jeder Schrittprozess erneut erhält (siehe lw_ci_run_step in common.sh).
LW_CI_SCRIPT="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
LW_CI_PROCESS_OPTIONS=()
if [[ "${ALLOW_SYSTEM}" == "true" ]]; then
    LW_CI_PROCESS_OPTIONS+=(--allow-system-changes)
fi
if [[ "${STRICT_STRINGS}" == "1" ]]; then
    LW_CI_PROCESS_OPTIONS+=(--strict-strings)
fi
if [[ "${STRICT_E2E}" == "1" ]]; then
    LW_CI_PROCESS_OPTIONS+=(--strict-e2e)
fi

lw_is_macos || lw_die "Scripts/ci_macos.sh läuft nur auf macOS – unter Linux Scripts/ci_linux.sh verwenden." 2

cd "${LW_REPO_ROOT}"
lw_load_config
JOBS="$(lw_jobs)"
PYTHON="${PYTHON:-python3}"
CI_TMP="${LW_REPO_ROOT}/build/ci"
APP="${LW_REPO_ROOT}/build/${APP_NAME}.app"
PKG="${LW_REPO_ROOT}/dist/${APP_NAME}-${VERSION}.pkg"
TEST_QUEUE="LabelWerkCI"
TEST_PORT="${LW_E2E_PORT:-19100}"
INSTALLED_DRIVER="/Library/Printers/LabelWerk"
INSTALLED_PPDS="/Library/Printers/PPDs/Contents/Resources"
# Legt „install-test“ an, unmittelbar bevor es den Installer startet; nur dann räumt der Ablauf
# am Ende mit „uninstall-test“ auf. (Der Schritt läuft in einem eigenen Prozess – eine Variable
# käme beim Ablauf nicht an.)
INSTALL_MARKER="${CI_TMP}/install-test.started"

require_system_changes() {
    if [[ "${ALLOW_SYSTEM}" != "true" ]]; then
        lw_die "Dieser Schritt installiert Software systemweit. Nur in der CI (CI=true) oder mit --allow-system-changes."
    fi
}

# Prüft, ob eine Datei die Architekturen arm64 und x86_64 enthält.
require_universal() {
    local path="$1"
    local archs
    archs="$(lipo -archs "${path}")"
    [[ "${archs}" == *arm64* && "${archs}" == *x86_64* ]] \
        || lw_die "$(basename "${path}") ist kein Universal Binary (${archs})."
    lw_ok "$(basename "${path}"): ${archs}"
}

# --- Schritte ----------------------------------------------------------------------------------

step_setup() {
    lw_info "Xcode: $(xcode-select -p)"
    xcodebuild -version 2>&1 | sed 's/^/    /' >&2
    swift --version 2>&1 | sed 's/^/    /' >&2
    sw_vers 2>&1 | sed 's/^/    /' >&2
    "${PYTHON}" --version 2>&1 | sed 's/^/    /' >&2
    local tool
    for tool in swift clang make lipo codesign pkgbuild productbuild pkgutil plutil ditto "${PYTHON}"; do
        command -v "${tool}" >/dev/null 2>&1 || lw_die "„${tool}“ fehlt."
    done
    lw_info "parallele Jobs: ${JOBS}, Version ${VERSION} (${BUILD})"
    if [[ -n "${DEVELOPER_ID_APP}" ]]; then
        lw_info "App-Signatur: ${DEVELOPER_ID_APP}"
    else
        lw_info "App-Signatur: ad hoc"
    fi
}

step_catalog() {
    lw_run "${PYTHON}" Scripts/generate_catalog_swift.py --check
}

step_test_swift() {
    lw_run swift test -j "${JOBS}"
}

step_test_driver() {
    lw_run make -C Driver/filter -j "${JOBS}" universal
    local filter
    for filter in rastertolabelwerk commandtolabelwerk; do
        require_universal "Driver/filter/build/universal/${filter}"
    done
    lw_run make -C Driver/filter -j "${JOBS}" tests
    lw_run make -C Driver/filter test
}

step_test_ppd() {
    local out="${CI_TMP}/ppd"
    lw_run rm -rf "${out}"
    lw_run "${PYTHON}" Driver/ppd/generate_ppds.py --output "${out}" --gzip --check
    lw_run "${PYTHON}" Driver/ppd/tests/test_generate.py
}

step_test_scripts() {
    lw_run "${PYTHON}" -m unittest discover -s Scripts/tests -t Scripts/tests
}

step_strings() {
    if lw_run "${PYTHON}" Scripts/extract_strings.py --check --strict; then
        return 0
    fi
    if [[ "${STRICT_STRINGS}" == "1" ]]; then
        return 1
    fi
    lw_ci_warning "Lokalisierung unvollständig – Scripts/extract_strings.py ausführen und übersetzen."
    return 0
}

step_app() {
    export SWIFT_BUILD_JOBS="${JOBS}"
    lw_run Scripts/build_app.sh
    require_universal "${APP}/Contents/MacOS/LabelWerk"
    require_universal "${APP}/Contents/Helpers/lwctl"
}

step_pkg() {
    local args=(--skip-build)
    if [[ -z "${DEVELOPER_ID_INSTALLER}" ]]; then
        args+=(--unsigned)
    fi
    lw_run Scripts/make_pkg.sh "${args[@]}"
}

step_verify_pkg() {
    [[ -f "${PKG}" ]] || lw_die "Paket fehlt: ${PKG}"
    local expanded="${CI_TMP}/pkg-expanded"
    rm -rf "${expanded}"
    lw_run pkgutil --expand-full "${PKG}" "${expanded}"

    # Treiberkomponente: Aufbau nach ARCHITECTURE.md §10.
    local driver="${expanded}/LabelWerkDriver.pkg/Payload"
    local filter
    for filter in rastertolabelwerk commandtolabelwerk; do
        [[ -x "${driver}/Library/Printers/LabelWerk/Filter/${filter}" ]] || lw_die "${filter} fehlt im Paket."
        require_universal "${driver}/Library/Printers/LabelWerk/Filter/${filter}"
        codesign --verify --strict "${driver}/Library/Printers/LabelWerk/Filter/${filter}" \
            || lw_die "Signatur von ${filter} ungültig."
    done
    [[ "$(cat "${driver}/Library/Printers/LabelWerk/VERSION")" == "${VERSION}" ]] || lw_die "VERSION im Treiber falsch."
    [[ -f "${driver}/Library/Printers/LabelWerk/Icons/LabelWerk.icns" ]] || lw_die "Druckersymbol fehlt."
    local ppds
    ppds="$(find "${driver}/Library/Printers/PPDs/Contents/Resources" -name 'LabelWerk-*.ppd.gz' | wc -l | tr -d ' ')"
    [[ "${ppds}" -gt 0 ]] || lw_die "Keine PPD-Dateien im Paket."
    for script in preinstall postinstall; do
        [[ -x "${expanded}/LabelWerkDriver.pkg/Scripts/${script}" ]] || lw_die "${script} fehlt."
    done
    lw_ok "Treiber: 2 Filter (Universal, signiert), ${ppds} PPD-Dateien, Skripte"

    # App-Komponente.
    local app="${expanded}/LabelWerkApp.pkg/Payload/${APP_NAME}.app"
    [[ -d "${app}" ]] || lw_die "App fehlt im Paket."
    local info="${app}/Contents/Info.plist"
    [[ "$(plutil -extract CFBundleIdentifier raw -o - "${info}")" == "${BUNDLE_ID}" ]] || lw_die "Bundle-ID falsch."
    [[ "$(plutil -extract CFBundleShortVersionString raw -o - "${info}")" == "${VERSION}" ]] || lw_die "Version falsch."
    [[ "$(plutil -extract CFBundleVersion raw -o - "${info}")" == "${BUILD}" ]] || lw_die "Build-Nummer falsch."
    [[ "$(plutil -extract LSMinimumSystemVersion raw -o - "${info}")" == "14.0" ]] || lw_die "Mindestversion falsch."
    if grep -q '@[A-Z_]*@' "${info}"; then
        lw_die "Info.plist enthält nicht ersetzte Platzhalter."
    fi
    codesign --verify --deep --strict --verbose=2 "${app}" || lw_die "Signatur der App ungültig."
    codesign -d --entitlements - "${app}" 2>/dev/null | grep -q 'com.apple.security.device.usb' \
        || lw_die "Berechtigungen fehlen in der App-Signatur."
    codesign -dv "${app}" 2>&1 | grep -q 'flags=.*runtime' || lw_die "Gehärtete Laufzeitumgebung fehlt."
    for lang in de en; do
        plutil -lint -s "${app}/Contents/Resources/${lang}.lproj/Localizable.strings" \
            || lw_die "${lang}.lproj/Localizable.strings ungültig."
    done
    [[ -d "${app}/Contents/Resources/Driver/Library/Printers/LabelWerk" ]] || lw_die "Treiberpaket fehlt in der App."
    require_universal "${app}/Contents/MacOS/LabelWerk"
    lw_ok "App: ${BUNDLE_ID} ${VERSION} (${BUILD}), Universal, signiert, Berechtigungen, Lokalisierung, Treiber"

    if [[ -f "${PKG}.sha256" ]]; then
        (cd "$(dirname "${PKG}")" && shasum -a 256 -c "$(basename "${PKG}").sha256")
    fi
    rm -rf "${expanded}"
}

step_artifacts() {
    [[ -d "${APP}" ]] || lw_die "App fehlt: ${APP}"
    local zip="${LW_REPO_ROOT}/dist/${APP_NAME}-${VERSION}-app.zip"
    lw_run mkdir -p "${LW_REPO_ROOT}/dist"
    lw_run rm -f "${zip}"
    lw_run ditto -c -k --sequesterRsrc --keepParent "${APP}" "${zip}"
    if [[ -d "${LW_REPO_ROOT}/build/${APP_NAME}.app.dSYM" ]]; then
        lw_run ditto -c -k --keepParent "${LW_REPO_ROOT}/build/${APP_NAME}.app.dSYM" \
            "${LW_REPO_ROOT}/dist/${APP_NAME}-${VERSION}-dSYM.zip"
    fi
    ls -l "${LW_REPO_ROOT}/dist" >&2
}

# Erwartet Besitzer root:wheel und genau den Modus $2.
require_root_owned() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(stat -f '%Su:%Sg %Lp' "${path}")"
    [[ "${actual}" == "root:wheel ${expected}" ]] || lw_die "${path}: ${actual}, erwartet root:wheel ${expected}."
}

step_install_test() {
    require_system_changes
    [[ -f "${PKG}" ]] || lw_die "Paket fehlt: ${PKG}"
    # Ab hier kann das System verändert sein (schon preinstall entfernt einen alten Treiber):
    # Der Ablauf deinstalliert am Ende – auch wenn der Installer selbst scheitert.
    mkdir -p "$(dirname "${INSTALL_MARKER}")"
    printf '%s\n' "${PKG}" > "${INSTALL_MARKER}"
    lw_run sudo installer -pkg "${PKG}" -target / -verboseR
    require_root_owned "${INSTALLED_DRIVER}/Filter/rastertolabelwerk" 755
    require_root_owned "${INSTALLED_DRIVER}/Filter/commandtolabelwerk" 755
    require_root_owned "${INSTALLED_DRIVER}/VERSION" 644
    require_root_owned "${INSTALLED_DRIVER}/uninstall.sh" 755
    [[ "$(cat "${INSTALLED_DRIVER}/VERSION")" == "${VERSION}" ]] || lw_die "Installierte Version falsch."
    [[ -d "/Applications/${APP_NAME}.app" ]] || lw_die "App wurde nicht installiert."
    [[ -L /usr/local/bin/lwctl ]] || lw_die "/usr/local/bin/lwctl fehlt."
    pkgutil --pkg-info "${LW_PKG_ID_DRIVER}" >/dev/null || lw_die "Installationsbeleg des Treibers fehlt."
    lw_ok "Paket installiert: Rechte, App, lwctl-Link, Beleg"

    local ppd="${INSTALLED_PPDS}/LabelWerk-zd421t-203dpi.ppd.gz"
    [[ -f "${ppd}" ]] || ppd="$(find "${INSTALLED_PPDS}" -name 'LabelWerk-*.ppd.gz' | head -n 1)"
    require_root_owned "${ppd}" 644
    if command -v cupstestppd >/dev/null 2>&1; then
        lw_run cupstestppd -W translations "${ppd}" || lw_die "cupstestppd lehnt $(basename "${ppd}") ab."
    fi
    # Warteschlange mit unserer PPD anlegen – cupsd prüft dabei Filterpfad und Rechte.
    lw_run sudo lpadmin -p "${TEST_QUEUE}" -E -v "socket://127.0.0.1:${TEST_PORT}?waiteof=false" -P "${ppd}"
    lpstat -p "${TEST_QUEUE}" >&2 || lw_die "Warteschlange ${TEST_QUEUE} fehlt."
    lpoptions -p "${TEST_QUEUE}" -l | grep -q '^lwDarkness' || lw_die "Warteschlange kennt die LabelWerk-Optionen nicht."
    lw_ok "Warteschlange ${TEST_QUEUE} mit $(basename "${ppd}") eingerichtet"
}

# Minimales einseitiges PDF (4 × 6 Zoll) mit Rahmen und gefülltem Balken.
write_test_pdf() {
    "${PYTHON}" - "$1" <<'PY'
import sys
content = b"0 g 18 18 252 396 re S 36 300 216 60 re f 36 120 m 252 120 l S"
objects = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 288 432] /Contents 4 0 R /Resources << >> >>",
    b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
]
out = bytearray(b"%PDF-1.4\n")
offsets = []
for number, body in enumerate(objects, 1):
    offsets.append(len(out))
    out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
xref = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
out += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
open(sys.argv[1], "wb").write(bytes(out))
PY
}

# Testdruck; ohne --strict-e2e wird ein Fehlschlag als Warnung gemeldet.
step_e2e_print() {
    require_system_changes
    lpstat -p "${TEST_QUEUE}" >/dev/null 2>&1 || lw_die "Warteschlange ${TEST_QUEUE} fehlt – zuerst „install-test“."
    lw_run sudo cupsctl --debug-logging
    local status=0
    # Eigener Prozess (wie jeder Schritt): Jeder fehlschlagende Befehl beendet den Testdruck,
    # danach werden hier die Diagnosedaten gesammelt.
    lw_ci_run_process step_e2e_print_job || status=$?
    if [[ "${status}" -ne 0 ]]; then
        lpstat -l -o "${TEST_QUEUE}" >&2 || true
        lpstat -l -p "${TEST_QUEUE}" >&2 || true
        sudo tail -n 150 /var/log/cups/error_log >&2 || true
    fi
    lw_run sudo cupsctl --no-debug-logging || true
    if [[ "${status}" -ne 0 && "${STRICT_E2E}" != "1" ]]; then
        lw_ci_warning "Testdruck über CUPS fehlgeschlagen (Exitcode ${status}) – siehe Protokoll; mit --strict-e2e ein Fehler."
        return 0
    fi
    return "${status}"
}

# Teil von „e2e-print“ (eigener Prozess): druckt ein PDF über die Testwarteschlange an einen
# lokalen TCP-„Drucker“ und prüft das empfangene ZPL.
step_e2e_print_job() {
    local work="${CI_TMP}/e2e"
    rm -rf "${work}"
    mkdir -p "${work}"
    write_test_pdf "${work}/label.pdf"

    # Lokaler „Drucker“: nimmt eine Verbindung an und speichert alles bis zum Verbindungsende.
    "${PYTHON}" - "${TEST_PORT}" "${work}/received.bin" <<'PY' &
import socket, sys
port, target = int(sys.argv[1]), sys.argv[2]
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.listen(1)
server.settimeout(120)
connection, _ = server.accept()
connection.settimeout(30)
data = bytearray()
try:
    while True:
        chunk = connection.recv(65536)
        if not chunk:
            break
        data += chunk
except socket.timeout:
    pass
with open(target, "wb") as handle:
    handle.write(bytes(data))
connection.close()
PY
    local listener=$!
    sleep 1
    lw_run lp -d "${TEST_QUEUE}" -o lwDarkness=20 -t "LabelWerk CI" "${work}/label.pdf"
    local waited=0
    while kill -0 "${listener}" 2>/dev/null && (( waited < 120 )); do
        sleep 2
        waited=$((waited + 2))
    done
    if kill -0 "${listener}" 2>/dev/null; then
        kill "${listener}" 2>/dev/null || true
    fi
    wait "${listener}" 2>/dev/null || true

    [[ -s "${work}/received.bin" ]] || lw_die "Der Testdrucker hat keine Daten empfangen."
    local bytes marker
    bytes="$(wc -c < "${work}/received.bin" | tr -d ' ')"
    for marker in '^XA' '^GFA' '^PQ' '^XZ' '~SD20'; do
        if ! LC_ALL=C grep -aqF -- "${marker}" "${work}/received.bin"; then
            head -c 600 "${work}/received.bin" | LC_ALL=C cat -v >&2
            lw_die "Empfangener Auftrag enthält „${marker}“ nicht."
        fi
    done
    lw_ok "PDF → CUPS → rastertolabelwerk → ZPL: ${bytes} Bytes, ^XA … ^GFA … ^XZ, ~SD20"
}

# Räumt nach „install-test“ auf (nur wenn dessen Installer gestartet wurde, siehe Ablauf).
step_uninstall_test() {
    require_system_changes
    local uninstaller="${INSTALLED_DRIVER}/uninstall.sh"
    if [[ ! -x "${uninstaller}" ]]; then
        # Der Installer brach ab, bevor er das Deinstallationsskript anlegen konnte.
        uninstaller="${LW_REPO_ROOT}/Scripts/uninstall.sh"
        lw_warn "${INSTALLED_DRIVER}/uninstall.sh fehlt – aufgeräumt wird mit ${uninstaller}."
    fi
    lw_run sudo "${uninstaller}" --yes --remove-queues
    [[ ! -e "${INSTALLED_DRIVER}" ]] || lw_die "Treiber wurde nicht entfernt."
    [[ ! -e "/Applications/${APP_NAME}.app" ]] || lw_die "App wurde nicht entfernt."
    if find "${INSTALLED_PPDS}" -name 'LabelWerk-*' | grep -q .; then
        lw_die "LabelWerk-PPDs wurden nicht entfernt."
    fi
    if lpstat -p "${TEST_QUEUE}" >/dev/null 2>&1; then
        lw_die "Warteschlange ${TEST_QUEUE} wurde nicht entfernt."
    fi
    lw_ok "Deinstallation vollständig"
}

# --- Ablauf ------------------------------------------------------------------------------------

# Schrittprozess: nur die eine Funktion ausführen – auf oberster Ebene, damit `set -e` wirkt.
if [[ ${#LW_CI_PROCESS_CALL[@]} -gt 0 ]]; then
    lw_ci_exec_process "${LW_CI_PROCESS_CALL[@]}"
    exit 0
fi

lw_step "LabelWerk CI (macOS) – Schritte: ${STEPS[*]}"
mkdir -p "${CI_TMP}"
# Eine Markierung aus einem früheren (abgebrochenen) Aufruf darf hier keine Deinstallation auslösen.
rm -f "${INSTALL_MARKER}"
FAILED=()
for step in "${STEPS[@]}"; do
    if ! lw_ci_run_step "${step}" "step_${step//-/_}"; then
        FAILED+=("${step}")
        if [[ "${KEEP_GOING}" != "1" ]]; then
            break
        fi
    fi
done
# Nach einer (begonnenen) Probeinstallation immer aufräumen – auch wenn ein Schritt fehlschlug.
if [[ -f "${INSTALL_MARKER}" ]]; then
    if ! lw_ci_run_step "uninstall-test" step_uninstall_test; then
        FAILED+=("uninstall-test")
    fi
    rm -f "${INSTALL_MARKER}"
fi

lw_step "Zusammenfassung"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    lw_die "Fehlgeschlagen: ${FAILED[*]}"
fi
lw_ok "Alle Schritte erfolgreich: ${STEPS[*]}"
