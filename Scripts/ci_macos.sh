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
# „release“ veröffentlicht das geprüfte Paket als GitHub-Release mit Update-Manifest (die App
# lädt Updates von dort) – nur in GitHub Actions oder mit --allow-publish; --release-dry-run
# bereitet alles vor und zeigt die gh-Befehle nur an.
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
# Angabe ad hoc signierte App und unsigniertes Paket), LW_STRICT_STRINGS=1; für „release“ GH_TOKEN
# (Schreibrecht auf die Inhalte von UPDATE_REPOSITORY) und LW_RELEASE_DRY_RUN=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=SCRIPTDIR/../Installer/lib/common.sh
source "${SCRIPT_DIR}/../Installer/lib/common.sh"
# shellcheck source=SCRIPTDIR/../Installer/lib/release.sh
source "${SCRIPT_DIR}/../Installer/lib/release.sh"

DEFAULT_STEPS=(setup catalog test-swift test-driver test-ppd test-scripts strings app pkg verify-pkg artifacts)
SYSTEM_STEPS=(install-test e2e-print)
PUBLISH_STEPS=(release)
ALL_STEPS=("${DEFAULT_STEPS[@]}" "${SYSTEM_STEPS[@]}" "${PUBLISH_STEPS[@]}")

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
  verify-pkg    Paketinhalt, Architekturen, Info.plist, Signaturen und Update-Fähigkeit prüfen
  artifacts     App als ZIP nach dist/ legen (für den Upload)

Schritte mit Systemänderungen (nur mit CI=true oder --allow-system-changes):
  install-test  Paket installieren, Rechte/CUPS/Warteschlange prüfen, Update mit höherer
                Build-Nummer über die installierte App, wieder deinstallieren
  e2e-print     PDF über CUPS und den Filter an einen lokalen TCP-„Drucker“ drucken

Veröffentlichen (nur in GitHub Actions oder mit --allow-publish; nicht in den Standardschritten):
  release       GitHub-Release v<Version>-b<Build> in UPDATE_REPOSITORY mit dem Paket und
                labelwerk-update.json – die App findet und installiert es als Update

Optionen:
  --allow-system-changes  install-test/e2e-print auch außerhalb der CI erlauben
  --allow-publish         release auch außerhalb von GitHub Actions erlauben (mit gh-Anmeldung)
  --release-dry-run       release: Paket, Manifest und Notizen nach dist/release/ legen, gh-Befehle
                          nur anzeigen (keine Anfrage an GitHub)
  --keep-going            nach einem fehlgeschlagenen Schritt weitermachen
  --strict-strings        fehlende Übersetzungen als Fehler werten
  --strict-e2e            fehlgeschlagenen Testdruck als Fehler werten (sonst Warnung)
  -h, --help              diese Hilfe
EOF
}

KEEP_GOING=0
ALLOW_SYSTEM="${CI:-false}"
ALLOW_PUBLISH="${GITHUB_ACTIONS:-false}"
RELEASE_DRY_RUN="${LW_RELEASE_DRY_RUN:-0}"
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
        --allow-publish) ALLOW_PUBLISH=true; shift ;;
        --release-dry-run) RELEASE_DRY_RUN=1; shift ;;
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
if [[ "${ALLOW_PUBLISH}" == "true" ]]; then
    LW_CI_PROCESS_OPTIONS+=(--allow-publish)
fi
if [[ "${RELEASE_DRY_RUN}" == "1" ]]; then
    LW_CI_PROCESS_OPTIONS+=(--release-dry-run)
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
# Eigene Etikettengröße der Testwarteschlange wie beim Anwender (ZD421t, 104 × 76,2 mm, nicht im
# Katalog): benannte Seitengröße w295h216 in einer Kopie der PPD, lwLabelWidth/lwLabelHeight in 1/100 mm.
TEST_SIZE="104x76.2mm"
TEST_SIZE_KEYWORD="w295h216"
TEST_LABEL_WIDTH="10400"
TEST_LABEL_HEIGHT="7620"
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

require_publish() {
    if [[ "${ALLOW_PUBLISH}" != "true" ]]; then
        lw_die "„release“ veröffentlicht ein Update für alle installierten Apps. Nur in GitHub Actions, mit --allow-publish oder als Probelauf (--release-dry-run)."
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
    # Erst alles bauen (inkl. App-Ziel auf macOS), dann jedes Testziel in einem eigenen Lauf:
    # In einem gemeinsamen Prozess verzögern rechenintensive Tests (QR/PDF417, Renderer-Fuzzing)
    # auf kleinen CI-Runnern sonst die zeitkritischen Netzwerk- und Zeitlimit-Tests.
    lw_run swift build -j "${JOBS}" --build-tests
    local target
    for target in LabelWerkCoreTests LabelWerkImagingTests LabelWerkBarcodeTests LabelWerkRenderTests LabelWerkStatusTests LabelWerkTransportTests LabelWerkKitTests; do
        lw_run swift test --skip-build --filter "${target}"
    done
}

step_test_driver() {
    lw_run make -C Driver/filter -j "${JOBS}" universal
    local filter
    for filter in rastertolabelwerk commandtolabelwerk; do
        require_universal "Driver/filter/build/universal/${filter}"
    done
    lw_run make -C Driver/filter -j "${JOBS}" tests
    lw_run make -C Driver/filter test
    lw_run make -C Driver/backend -j "${JOBS}" universal
    require_universal "Driver/backend/build/universal/labelwerk"
    lw_run make -C Driver/backend -j "${JOBS}" tests
    lw_run make -C Driver/backend test
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
    # CUPS-Backend labelwerk (ARCHITECTURE.md §10): Universal, signiert, 0755 (cupsd startet es als _lp).
    local backend="${driver}/usr/libexec/cups/backend/labelwerk"
    [[ -x "${backend}" ]] || lw_die "Backend labelwerk fehlt im Paket."
    require_universal "${backend}"
    codesign --verify --strict "${backend}" || lw_die "Signatur des Backends ungültig."
    [[ "$(stat -f %Lp "${backend}")" == "755" ]] || lw_die "Backend hat nicht die Rechte 0755."
    [[ "$(cat "${driver}/Library/Printers/LabelWerk/VERSION")" == "${VERSION}" ]] || lw_die "VERSION im Treiber falsch."
    [[ -f "${driver}/Library/Printers/LabelWerk/Icons/LabelWerk.icns" ]] || lw_die "Druckersymbol fehlt."
    local ppds
    ppds="$(find "${driver}/Library/Printers/PPDs/Contents/Resources" -name 'LabelWerk-*.ppd.gz' | wc -l | tr -d ' ')"
    [[ "${ppds}" -gt 0 ]] || lw_die "Keine PPD-Dateien im Paket."
    for script in preinstall postinstall; do
        [[ -x "${expanded}/LabelWerkDriver.pkg/Scripts/${script}" ]] || lw_die "${script} fehlt."
    done
    lw_ok "Treiber: 2 Filter und Backend (Universal, signiert), ${ppds} PPD-Dateien, Skripte"

    # App-Komponente.
    local app="${expanded}/LabelWerkApp.pkg/Payload/${APP_NAME}.app"
    [[ -d "${app}" ]] || lw_die "App fehlt im Paket."
    local info="${app}/Contents/Info.plist"
    [[ "$(plutil -extract CFBundleIdentifier raw -o - "${info}")" == "${BUNDLE_ID}" ]] || lw_die "Bundle-ID falsch."
    [[ "$(plutil -extract CFBundleShortVersionString raw -o - "${info}")" == "${VERSION}" ]] || lw_die "Version falsch."
    [[ "$(plutil -extract CFBundleVersion raw -o - "${info}")" == "${BUILD}" ]] || lw_die "Build-Nummer falsch."
    [[ "$(plutil -extract LSMinimumSystemVersion raw -o - "${info}")" == "14.0" ]] || lw_die "Mindestversion falsch."
    [[ "$(plutil -extract LWUpdateRepository raw -o - "${info}")" == "${UPDATE_REPOSITORY}" ]] \
        || lw_die "LWUpdateRepository falsch (erwartet „${UPDATE_REPOSITORY}“)."
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
    [[ -x "${app}/Contents/Resources/Driver/usr/libexec/cups/backend/labelwerk" ]] || lw_die "Backend fehlt im Treiberpaket der App."
    require_universal "${app}/Contents/MacOS/LabelWerk"
    lw_ok "App: ${BUNDLE_ID} ${VERSION} (${BUILD}), Universal, signiert, Berechtigungen, Lokalisierung, Treiber, Updates aus ${UPDATE_REPOSITORY:-(abgeschaltet)}"

    # Update-Fähigkeit: Ziel /Applications, nicht verschiebbar, „upgrade“, Versionsprüfung mit der
    # Build-Nummer (Belege im Protokoll; Paketaufbau siehe Scripts/make_pkg.sh).
    local package_info="${expanded}/LabelWerkApp.pkg/PackageInfo"
    [[ -f "${package_info}" ]] || lw_die "PackageInfo der App-Komponente fehlt."
    sed 's/^/    /' "${package_info}" >&2
    lw_check_app_package_info "${package_info}"
    grep -q "CFBundleVersion=\"${BUILD}\"" "${expanded}/Distribution" \
        || lw_die "Distribution nennt nicht CFBundleVersion=\"${BUILD}\"."

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
    # Warteschlange mit unserer PPD anlegen – cupsd prüft dabei Filterpfad und Rechte. Angelegt wird
    # mit dem installierten lwctl und einer eigenen Etikettengröße (derselbe Code wie in der App:
    # PPDFiles/QueuePPD ergänzen die Größe in einer Kopie der Modell-PPD, lpadmin -P).
    # Geräte-URI ohne Abfrage: Das socket-Backend schließt nach dem Auftrag seine Senderichtung
    # (Standard waiteof=true), der Test-„Drucker“ liest bis dahin und schließt dann selbst. Eine
    # Abfrage bräuchte „/“ vor „?“ (socket://host:port/?waiteof=false) – CUPS (httpSeparateURI)
    # verlangt nach einer Portnummer einen Pfad und weist „…:port?…“ mit „Bad device-uri“ ab.
    lw_run sudo /usr/local/bin/lwctl install -p "tcp://127.0.0.1:${TEST_PORT}" -m zd421t --dpi 203 \
        --name "${TEST_QUEUE}" --size "${TEST_SIZE}" ||
        lw_die "Warteschlange ${TEST_QUEUE} konnte nicht angelegt werden."
    lpstat -p "${TEST_QUEUE}" >&2 || lw_die "Warteschlange ${TEST_QUEUE} fehlt."
    lpoptions -p "${TEST_QUEUE}" -l | grep -q '^lwDarkness' || lw_die "Warteschlange kennt die LabelWerk-Optionen nicht."
    check_queue_label_size "nach lwctl install --size"
    lw_ok "Warteschlange ${TEST_QUEUE} mit $(basename "${ppd}") und Etikett ${TEST_SIZE} eingerichtet"

    # App-Update wie aus der App (gleiche Marketing-Version, höhere Build-Nummer – so sieht jedes
    # CI-Release aus): Die installierte App bekommt Build-Nummer 0, die zweite Installation muss
    # genau /Applications/<App>.app wieder auf BUILD bringen (nicht verschiebbar, Versionsprüfung).
    local installed_info="/Applications/${APP_NAME}.app/Contents/Info.plist" lowered=0
    if [[ "${BUILD}" =~ ^[0-9]+$ ]] && (( 10#${BUILD} > 0 )); then
        if sudo plutil -replace CFBundleVersion -string 0 "${installed_info}"; then
            lowered=1
            lw_info "Installierte App auf Build 0 gesetzt – das Paket (Build ${BUILD}) muss sie ersetzen."
        else
            lw_ci_warning "Build-Nummer der installierten App ließ sich nicht ändern – Update-Probe übersprungen."
        fi
    fi

    # Treiber-Update: Der postinstall ersetzt die PPD der Warteschlange durch die neue Modell-PPD –
    # die ergänzte Etikettengröße und lwLabelWidth/lwLabelHeight müssen dabei erhalten bleiben.
    lw_run sudo installer -pkg "${PKG}" -target / -verboseR
    check_queue_label_size "nach dem Treiber-Update (postinstall)"
    lw_ok "Treiber-Update behält die Etikettengröße von ${TEST_QUEUE}"
    if [[ "${lowered}" == "1" ]]; then
        local installed_build
        installed_build="$(plutil -extract CFBundleVersion raw -o - "${installed_info}")"
        [[ "${installed_build}" == "${BUILD}" ]] \
            || lw_die "Update hat /Applications/${APP_NAME}.app nicht ersetzt (Build ${installed_build}, erwartet ${BUILD})."
        lw_ok "App-Update: /Applications/${APP_NAME}.app von Build 0 auf ${BUILD} ersetzt (gleiche Version ${VERSION})"
    fi
    probe_print_dialog
}

# Welches Papierformat schlagen macOS-Programme für die Testwarteschlange vor? Einmal mit dem
# Standardpapierformat des Systems (meist US Letter) und einmal wie beim Anwender mit A4. Bisher nur
# Auskunft (Warnung statt Abbruch), bis das Verhalten auf echten macOS-Versionen belegt ist.
probe_print_dialog() {
    local probe="${LW_REPO_ROOT}/Scripts/probe_page_format.swift" previous_default="" output
    [[ -f "${probe}" ]] || return 0
    previous_default="$(lpstat -d 2>/dev/null | sed -n 's/^.*: //p' || true)"
    lpoptions -d "${TEST_QUEUE}" >/dev/null 2>&1 || lw_ci_warning "Standarddrucker ließ sich nicht setzen."
    local paper
    for paper in "" iso-a4; do
        if [[ -n "${paper}" ]]; then
            defaults write com.apple.print.PrintingPrefs DefaultPaperID -string "${paper}" || true
        else
            defaults delete com.apple.print.PrintingPrefs DefaultPaperID >/dev/null 2>&1 || true
        fi
        if output="$(swift "${probe}" "${TEST_QUEUE}" "${TEST_SIZE_KEYWORD}" 2>&1)"; then
            lw_ok "Druckdialog (Systempapier ${paper:-Standard}): ${output//$'\n'/ · }"
        else
            lw_ci_warning "Druckdialog (Systempapier ${paper:-Standard}): ${output//$'\n'/ · }"
        fi
    done
    defaults delete com.apple.print.PrintingPrefs DefaultPaperID >/dev/null 2>&1 || true
    if [[ -n "${previous_default}" ]]; then
        lpoptions -d "${previous_default}" >/dev/null 2>&1 || true
    fi
}

# Prüft, dass die Testwarteschlange das Etikett TEST_SIZE als benannte Standard-Papiergröße hat
# (lpoptions -l markiert sie mit „*“), lwLabelWidth/lwLabelHeight trägt und ihre PPD gültig ist.
check_queue_label_size() {
    local when="$1" queue_ppd="/etc/cups/ppd/${TEST_QUEUE}.ppd" page_sizes plain
    page_sizes="$(LC_ALL=C lpoptions -p "${TEST_QUEUE}" -l | grep '^PageSize' || true)"
    printf '%s\n' "${page_sizes}" >&2
    case " ${page_sizes} " in
        *" *${TEST_SIZE_KEYWORD} "*) ;;
        *) lw_die "PageSize-Standard von ${TEST_QUEUE} ist nicht ${TEST_SIZE_KEYWORD} (${when})." ;;
    esac
    plain="$(LC_ALL=C lpoptions -p "${TEST_QUEUE}")"
    case " ${plain} " in
        *" lwLabelWidth=${TEST_LABEL_WIDTH} "*) ;;
        *) lw_die "lwLabelWidth=${TEST_LABEL_WIDTH} fehlt in den Standards von ${TEST_QUEUE} (${when}): ${plain}" ;;
    esac
    case " ${plain} " in
        *" lwLabelHeight=${TEST_LABEL_HEIGHT} "*) ;;
        *) lw_die "lwLabelHeight=${TEST_LABEL_HEIGHT} fehlt in den Standards von ${TEST_QUEUE} (${when}): ${plain}" ;;
    esac
    sudo grep -q "^\\*lwLabelPageSize: \"${TEST_SIZE_KEYWORD}\"" "${queue_ppd}" ||
        lw_die "${queue_ppd} enthält die ergänzte Etikettengröße nicht (${when})."
    sudo grep -q '^\*de\.PageSize '"${TEST_SIZE_KEYWORD}"'/Etikett 104 × 76,2 mm:' "${queue_ppd}" ||
        lw_die "${queue_ppd}: deutscher Name „Etikett 104 × 76,2 mm“ fehlt (${when})."
    if command -v cupstestppd >/dev/null 2>&1; then
        lw_run sudo cupstestppd -W translations "${queue_ppd}" || lw_die "cupstestppd lehnt ${queue_ppd} ab (${when})."
    fi
    lw_ok "${TEST_QUEUE}: Standard-Papiergröße ${TEST_SIZE_KEYWORD} (Etikett 104 × 76,2 mm), lwLabelWidth/lwLabelHeight (${when})"
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
        # Alle Aufträge (auch abgebrochene und abgeschlossene – lpstat zeigt sonst nur offene; „-W“
        # muss vor „-o“ stehen) und den Zustand der Warteschlange (printer-state-reasons).
        lpstat -W all -l -o "${TEST_QUEUE}" >&2 || true
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
# lokalen TCP-„Drucker“ und prüft das empfangene ZPL – einmal ohne Seitengröße (es gilt die
# benannte Standardgröße der Warteschlange, 104 × 76,2 mm), einmal mit 4 × 6 Zoll wie ein
# Programm, das seine eigene Seitengröße schickt: „An Etikett anpassen“ legt sie auf das Etikett.
# In beiden Fällen muss das Etikett 76,2 mm lang sein (^LL um 609 Punkte bei 203 dpi).
step_e2e_print_job() {
    local work="${CI_TMP}/e2e"
    rm -rf "${work}"
    mkdir -p "${work}"
    write_test_pdf "${work}/label.pdf"
    print_and_check "${work}" default
    print_and_check "${work}" w288h432 -o PageSize=w288h432
}

# Druckt label.pdf aus $1 (Name $2, weitere lp-Argumente danach) und prüft das empfangene ZPL.
print_and_check() {
    local work="$1" name="$2"
    shift 2
    local received="${work}/received-${name}.bin"

    # Lokaler „Drucker“: nimmt eine Verbindung an und speichert alles bis zum Verbindungsende.
    "${PYTHON}" - "${TEST_PORT}" "${received}" <<'PY' &
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
    lw_run lp -d "${TEST_QUEUE}" -o lwDarkness=20 "$@" -t "LabelWerk CI ${name}" "${work}/label.pdf"
    local waited=0
    while kill -0 "${listener}" 2>/dev/null && (( waited < 120 )); do
        sleep 2
        waited=$((waited + 2))
    done
    if kill -0 "${listener}" 2>/dev/null; then
        kill "${listener}" 2>/dev/null || true
    fi
    wait "${listener}" 2>/dev/null || true

    [[ -s "${received}" ]] || lw_die "Der Testdrucker hat keine Daten empfangen (${name})."
    local bytes marker length
    bytes="$(wc -c < "${received}" | tr -d ' ')"
    for marker in '^XA' '^GFA' '^PQ' '^XZ' '~SD20'; do
        if ! LC_ALL=C grep -aqF -- "${marker}" "${received}"; then
            head -c 600 "${received}" | LC_ALL=C cat -v >&2
            lw_die "Empfangener Auftrag (${name}) enthält „${marker}“ nicht."
        fi
    done
    # Etikettenlänge: 76,2 mm bei 203 dpi = 609,6 Punkte (ohne Anpassung hätte 4 × 6 Zoll 1218).
    length="$(LC_ALL=C grep -aoE '\^LL[0-9]+' "${received}" | head -n 1 | tr -dc '0-9')"
    if [[ -z "${length}" ]] || (( length < 600 || length > 620 )); then
        head -c 600 "${received}" | LC_ALL=C cat -v >&2
        lw_die "Etikettenlänge ^LL${length:-?} (${name}) passt nicht zu 76,2 mm."
    fi
    lw_ok "PDF (${name}) → CUPS → rastertolabelwerk → ZPL: ${bytes} Bytes, ^XA … ^GFA … ^XZ, ~SD20, ^LL${length}"
}

# Veröffentlicht das Paket als Update: GitHub-Release v<VERSION>-b<BUILD> in UPDATE_REPOSITORY
# (Ziel: der gebaute Commit) mit <App>-<VERSION>-<BUILD>.pkg und labelwerk-update.json, als
# „neuestes“ markiert – außer es gibt schon ein neueres Release (später gestarteter Lauf, der früher
# fertig war). Gibt es das Release schon (erneuter Lauf mit derselben Laufnummer), werden Dateien und
# Text ersetzt. Vorbereitete Dateien liegen in dist/release/.
step_release() {
    if [[ -z "${UPDATE_REPOSITORY}" ]]; then
        lw_ci_warning "UPDATE_REPOSITORY ist leer (Installer/config.env) – Update-Dienst abgeschaltet, kein Release."
        return 0
    fi
    if [[ -n "${GITHUB_REPOSITORY:-}" ]] && ! lw_release_same_repository "${GITHUB_REPOSITORY}" "${UPDATE_REPOSITORY}"; then
        lw_ci_warning "Dieser Lauf gehört zu ${GITHUB_REPOSITORY}, die App sucht Updates in ${UPDATE_REPOSITORY} – kein Release (UPDATE_REPOSITORY in Installer/config.env anpassen)."
        return 0
    fi
    if [[ "${RELEASE_DRY_RUN}" != "1" ]]; then
        require_publish
        lw_require_tool gh "GitHub CLI installieren (https://cli.github.com) und GH_TOKEN setzen."
    fi
    lw_release_require_build
    [[ -f "${PKG}" ]] || lw_die "Paket fehlt: ${PKG} – zuerst die Schritte „app“, „pkg“ und „verify-pkg“."
    local info="${APP}/Contents/Info.plist"
    [[ -f "${info}" ]] || lw_die "App fehlt: ${APP} – zuerst den Schritt „app“."
    lw_release_check_app_info "${info}"

    local tag title asset target stage notes manifest body sha
    tag="$(lw_release_tag)"
    title="$(lw_release_title)"
    asset="$(lw_release_asset_name)"
    target="$(git -C "${LW_REPO_ROOT}" rev-parse --verify HEAD)"
    stage="${LW_REPO_ROOT}/dist/release"
    notes="${stage}/notes.md"
    manifest="${stage}/${LW_RELEASE_MANIFEST_NAME}"
    body="${stage}/release-body.md"
    lw_info "Release ${tag} „${title}“ in ${UPDATE_REPOSITORY}, Commit ${target}"

    rm -rf "${stage}"
    mkdir -p "${stage}"
    cp "${PKG}" "${stage}/${asset}"
    lw_release_notes "${target}" > "${notes}"
    lw_release_write_manifest "${stage}/${asset}" "${info}" "${notes}" "${manifest}"
    sha="$(lw_release_manifest_field "${manifest}" pkg.sha256)"
    {
        cat "${notes}"
        printf '\n---\n\n'
        printf 'Installierte Versionen mit Update-Dienst finden dieses Update selbst (%s › Nach Updates suchen …) und installieren es auf Wunsch. ' "${APP_NAME}"
        # shellcheck disable=SC2016  # Backticks sind Markdown (Code), keine Befehlsersetzung.
        printf 'Zum ersten Installieren `%s` laden und öffnen.\n\nSHA-256 `%s` · Commit %s\n' \
            "${asset}" "${sha}" "${target}"
    } > "${body}"
    sed 's/^/    /' "${notes}" >&2

    export GH_REPO="${UPDATE_REPOSITORY}"
    local exists=0 latest="true" current=""
    if [[ "${RELEASE_DRY_RUN}" == "1" ]]; then
        lw_info "Probelauf: nichts wird veröffentlicht. Ohne Abfrage bei GitHub gilt ${tag} als neu und als neuestes Release."
        LW_DRY_RUN=1
    else
        current="$(gh release view --json tagName --jq .tagName 2>/dev/null || true)"
        if [[ -n "${current}" && "${current}" != "${tag}" ]] && lw_release_tag_is_newer "${current}" "${tag}"; then
            latest="false"
            lw_ci_warning "Neuestes Release ist ${current} (neuer als ${tag}) – ${tag} wird nicht als neuestes markiert."
        fi
        if gh release view "${tag}" --json tagName >/dev/null 2>&1; then
            exists=1
        fi
    fi
    if [[ "${exists}" == "1" ]]; then
        lw_warn "Release ${tag} gibt es schon (erneuter Lauf) – Dateien und Text werden ersetzt."
        lw_run gh release upload "${tag}" "${stage}/${asset}" "${manifest}" --clobber
        lw_run gh release edit "${tag}" --title "${title}" --notes-file "${body}" "--latest=${latest}"
    else
        lw_run gh release create "${tag}" "${stage}/${asset}" "${manifest}" --title "${title}" \
            --notes-file "${body}" --target "${target}" "--latest=${latest}"
    fi
    if [[ "${RELEASE_DRY_RUN}" == "1" ]]; then
        lw_ok "Probelauf: ${stage}/ enthält ${asset}, ${LW_RELEASE_MANIFEST_NAME}, notes.md, release-body.md"
    else
        lw_ok "Release ${tag} veröffentlicht: https://github.com/${UPDATE_REPOSITORY}/releases/tag/${tag}"
    fi
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
