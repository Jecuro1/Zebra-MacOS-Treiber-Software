#!/usr/bin/env bash
# shellcheck disable=SC1111  # Deutsche Anführungszeichen („…“) in Meldungen sind beabsichtigt.
#
# LabelWerk – Installationspaket bauen
#
# Erzeugt dist/LabelWerk-<version>.pkg (Produktarchiv) aus drei Komponenten:
#
#   LabelWerkApp.pkg      build/LabelWerk.app → /Applications (nicht verschiebbar, „upgrade“,
#                         Versionsprüfung: höhere Build-Nummer bei gleicher Version ersetzt die App)
#   LabelWerkDriver.pkg   build/driver-root → / (Filter, PPDs, Symbol, VERSION, Backend
#                         /usr/libexec/cups/backend/labelwerk)
#                         mit preinstall (alte Version entfernen) und postinstall (Rechte,
#                         cupsd-Neustart, vorhandene Warteschlangen aktualisieren)
#   LabelWerkCLI.pkg      ohne Nutzdaten; postinstall legt /usr/local/bin/lwctl an (optional)
#
# Oberfläche: Installer/pkg/distribution.xml mit deutschen und englischen Texten
# (Willkommen, Hinweise, Lizenz, Abschluss) und Hintergrundbild für hell/dunkel. Signiert wird mit
# DEVELOPER_ID_INSTALLER, falls gesetzt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=SCRIPTDIR/../Installer/lib/common.sh
source "${SCRIPT_DIR}/../Installer/lib/common.sh"

usage() {
    cat <<EOF
Aufruf: Scripts/make_pkg.sh [Optionen]

Baut das Installationspaket dist/<App>-<Version>.pkg. Ohne --skip-build werden Treiber und App
vorher neu gebaut (Scripts/build_app.sh).

Optionen:
  --skip-build    vorhandenes build/LabelWerk.app und build/driver-root verwenden
  --unsigned      nicht signieren, auch wenn DEVELOPER_ID_INSTALLER gesetzt ist
  --output VERZ   Zielverzeichnis (Standard: dist)
  --dry-run       Schritte nur anzeigen, nichts ausführen
  -h, --help      diese Hilfe

Umgebung: VERSION, BUILD, DEVELOPER_ID_APP, DEVELOPER_ID_INSTALLER … überschreiben
Installer/config.env.
EOF
}

SKIP_BUILD=0
UNSIGNED=0
OUTPUT="${LW_REPO_ROOT}/dist"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --unsigned) UNSIGNED=1; shift ;;
        --output)
            [[ $# -ge 2 ]] || lw_die "--output erwartet ein Verzeichnis."
            OUTPUT="$2"
            shift 2
            ;;
        --output=*) OUTPUT="${1#*=}"; shift ;;
        --dry-run) LW_DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; lw_die "Unbekannte Option „$1“." 64 ;;
    esac
done

lw_load_config
lw_require_macos "Das Bauen des Installationspakets (pkgbuild, productbuild)"

case "${OUTPUT}" in
    /*) ;;
    *) OUTPUT="$(pwd -P)/${OUTPUT}" ;;
esac
OUTPUT="${OUTPUT%/}"

BUILD_DIR="${LW_REPO_ROOT}/build"
APP="${BUILD_DIR}/${APP_NAME}.app"
DRIVER_ROOT="${BUILD_DIR}/driver-root"
WORK="${BUILD_DIR}/pkg"
PKG_SRC="${LW_REPO_ROOT}/Installer/pkg"
PRODUCT="${OUTPUT}/${APP_NAME}-${VERSION}.pkg"

SIGN_IDENTITY=""
if [[ "${UNSIGNED}" != "1" && -n "${DEVELOPER_ID_INSTALLER}" ]]; then
    SIGN_IDENTITY="${DEVELOPER_ID_INSTALLER}"
fi

lw_step "${APP_NAME} ${VERSION} – Installationspaket"
lw_info "Ziel: ${PRODUCT}"
if [[ -n "${SIGN_IDENTITY}" ]]; then
    lw_info "Signatur: ${SIGN_IDENTITY}"
else
    lw_info "Signatur: keine (nur für Entwicklung und Tests – Gatekeeper blockiert unsignierte Pakete)"
fi

lw_require_tool pkgbuild
lw_require_tool productbuild
lw_require_tool pkgutil
lw_require_tool plutil
lw_require_tool ditto
lw_require_file "${PKG_SRC}/distribution.xml" "Distribution-Vorlage"

# --- Bauen ---------------------------------------------------------------------------------
if [[ "${SKIP_BUILD}" != "1" ]]; then
    build_args=()
    if [[ "${LW_DRY_RUN}" == "1" ]]; then
        build_args+=(--dry-run)
    fi
    "${SCRIPT_DIR}/build_app.sh" ${build_args[@]+"${build_args[@]}"}
fi

lw_require_file "${APP}/Contents/Info.plist" "App-Bundle" "Zuerst Scripts/build_app.sh ausführen."
lw_require_file "${DRIVER_ROOT}/Library/Printers/LabelWerk/Filter/rastertolabelwerk" "Treiberbaum" \
    "Zuerst Scripts/build_driver.sh ausführen."
lw_require_file "${DRIVER_ROOT}/usr/libexec/cups/backend/labelwerk" "CUPS-Backend im Treiberbaum" \
    "Treiber neu bauen (Scripts/build_driver.sh)."
if [[ "${LW_DRY_RUN}" != "1" ]]; then
    bundle_version="$(plutil -extract CFBundleShortVersionString raw -o - "${APP}/Contents/Info.plist")"
    [[ "${bundle_version}" == "${VERSION}" ]] \
        || lw_die "Die App hat Version ${bundle_version}, erwartet ${VERSION} – App neu bauen (ohne --skip-build)."
    driver_version="$(head -n 1 "${DRIVER_ROOT}/Library/Printers/LabelWerk/VERSION")"
    [[ "${driver_version}" == "${VERSION}" ]] \
        || lw_die "Der Treiber hat Version ${driver_version}, erwartet ${VERSION} – Treiber neu bauen."
fi

# --- Arbeitsverzeichnis --------------------------------------------------------------------
lw_step "Komponenten vorbereiten"
lw_run rm -rf "${WORK}"
lw_run mkdir -p "${WORK}/components" "${WORK}/scripts-driver" "${WORK}/scripts-cli" "${WORK}/app-root" \
    "${WORK}/resources" "${OUTPUT}"

lw_run cp "${PKG_SRC}/scripts/driver/preinstall" "${WORK}/scripts-driver/"
# Die postinstall-Skripte sind Vorlagen (Pfad der App aus APP_NAME).
if [[ "${LW_DRY_RUN}" == "1" ]]; then
    lw_info "würde schreiben: ${WORK}/scripts-driver/postinstall (aus Installer/pkg/scripts/driver/postinstall)"
    lw_info "würde schreiben: ${WORK}/scripts-cli/postinstall (aus Installer/pkg/scripts/cli/postinstall)"
else
    lw_render_template "${PKG_SRC}/scripts/driver/postinstall" "${WORK}/scripts-driver/postinstall"
    lw_render_template "${PKG_SRC}/scripts/cli/postinstall" "${WORK}/scripts-cli/postinstall"
fi
lw_run chmod 755 "${WORK}/scripts-driver/preinstall" "${WORK}/scripts-driver/postinstall" \
    "${WORK}/scripts-cli/postinstall"
lw_run ditto "${APP}" "${WORK}/app-root/${APP_NAME}.app"

# --- Komponente: App -----------------------------------------------------------------------
lw_step "Komponente „App“"
COMPONENT_PLIST="${WORK}/app-component.plist"
lw_run pkgbuild --analyze --root "${WORK}/app-root" "${COMPONENT_PLIST}"
# Nicht verschiebbar: Sonst „installiert“ der Installer in eine beliebige andere Kopie der App
# (z. B. im Build- oder Downloads-Ordner) statt nach /Applications – auch jedes Update der App
# (UpdateController: installer -pkg … -target /) muss /Applications/<App>.app ersetzen.
# „upgrade“ ersetzt das alte Bundle vollständig. Die Versionsprüfung (Standard, hier ausdrücklich)
# vergleicht CFBundleShortVersionString und dann CFBundleVersion: Ein CI-Release mit gleicher
# Marketing-Version und höherer Build-Nummer ersetzt die App, ein älteres Paket nicht. Belegt in
# Scripts/ci_macos.sh (verify-pkg: PackageInfo, install-test: Build-Nummer 0 wird ersetzt).
COMPONENT_KEYS=(
    BundleIsRelocatable -bool NO
    BundleOverwriteAction -string upgrade
    BundleIsVersionChecked -bool YES
    BundleHasStrictIdentifier -bool YES
)
set_component_keys() {
    local index="$1" position=0
    while [[ "${position}" -lt "${#COMPONENT_KEYS[@]}" ]]; do
        lw_run plutil -replace "${index}.${COMPONENT_KEYS[position]}" "${COMPONENT_KEYS[position + 1]}" \
            "${COMPONENT_KEYS[position + 2]}" "${COMPONENT_PLIST}"
        position=$((position + 3))
    done
}
if [[ "${LW_DRY_RUN}" == "1" ]]; then
    set_component_keys 0
else
    index=0
    while plutil -extract "${index}" xml1 -o /dev/null "${COMPONENT_PLIST}" >/dev/null 2>&1; do
        set_component_keys "${index}"
        index=$((index + 1))
    done
    [[ "${index}" -gt 0 ]] || lw_die "pkgbuild --analyze hat kein Bundle in ${WORK}/app-root gefunden."
    [[ "$(plutil -extract 0.BundleIsRelocatable raw -o - "${COMPONENT_PLIST}")" == "false" ]] \
        || lw_die "BundleIsRelocatable ließ sich nicht abschalten (${COMPONENT_PLIST})."
    lw_ok "${index} Bundle(s): nicht verschiebbar, Aktualisierung ersetzt die alte Version, Versionsprüfung"
fi
lw_run pkgbuild --root "${WORK}/app-root" \
    --component-plist "${COMPONENT_PLIST}" \
    --identifier "${LW_PKG_ID_APP}" \
    --version "${VERSION}" \
    --install-location /Applications \
    "${WORK}/components/LabelWerkApp.pkg"

# --- Komponente: Treiber -------------------------------------------------------------------
lw_step "Komponente „Druckertreiber“"
lw_run pkgbuild --root "${DRIVER_ROOT}" \
    --identifier "${LW_PKG_ID_DRIVER}" \
    --version "${VERSION}" \
    --install-location / \
    --scripts "${WORK}/scripts-driver" \
    --ownership recommended \
    "${WORK}/components/LabelWerkDriver.pkg"

# --- Komponente: lwctl ---------------------------------------------------------------------
lw_step "Komponente „lwctl“"
lw_run pkgbuild --nopayload \
    --identifier "${LW_PKG_ID_CLI}" \
    --version "${VERSION}" \
    --scripts "${WORK}/scripts-cli" \
    "${WORK}/components/LabelWerkCLI.pkg"

# --- Oberfläche ----------------------------------------------------------------------------
lw_step "Installer-Oberfläche"
DISTRIBUTION="${WORK}/distribution.xml"
if [[ "${LW_DRY_RUN}" == "1" ]]; then
    lw_info "würde schreiben: ${DISTRIBUTION} und ${WORK}/resources/{de,en}.lproj (Platzhalter ersetzt)"
else
    lw_render_template "${PKG_SRC}/distribution.xml" "${DISTRIBUTION}"
    for image in "${PKG_SRC}/Resources/"*.png; do
        [[ -f "${image}" ]] || continue
        cp "${image}" "${WORK}/resources/"
    done
    for lproj in "${PKG_SRC}/Resources/"*.lproj; do
        [[ -d "${lproj}" ]] || continue
        name="$(basename "${lproj}")"
        mkdir -p "${WORK}/resources/${name}"
        for file in "${lproj}"/*; do
            [[ -f "${file}" ]] || continue
            lw_render_template "${file}" "${WORK}/resources/${name}/$(basename "${file}")"
        done
        plutil -lint -s "${WORK}/resources/${name}/Localizable.strings" \
            || lw_die "Ungültige Installer-Texte: ${name}/Localizable.strings"
    done
    # Jede in distribution.xml genannte Datei muss in jeder Sprache bzw. als Bild vorhanden sein.
    while IFS= read -r referenced; do
        case "${referenced}" in
            *.png) [[ -f "${WORK}/resources/${referenced}" ]] || lw_die "Bild fehlt: ${referenced} – „make icons“ ausführen." ;;
            *)
                for lproj in "${WORK}/resources/"*.lproj; do
                    [[ -f "${lproj}/${referenced}" ]] || lw_die "${referenced} fehlt in $(basename "${lproj}")."
                done
                ;;
        esac
    done < <(sed -n 's/.*file="\([^"]*\)".*/\1/p' "${DISTRIBUTION}")
    lw_ok "distribution.xml, $(find "${WORK}/resources" -name '*.lproj' -type d | wc -l | tr -d ' ') Sprachen"
fi

# --- Produktarchiv -------------------------------------------------------------------------
lw_step "Produktarchiv bauen"
product_args=(--distribution "${DISTRIBUTION}" --resources "${WORK}/resources" --package-path "${WORK}/components")
if [[ -n "${SIGN_IDENTITY}" ]]; then
    product_args+=(--sign "${SIGN_IDENTITY}" --timestamp)
fi
lw_run rm -f "${PRODUCT}" "${PRODUCT}.sha256"
lw_run productbuild "${product_args[@]}" "${PRODUCT}"

# --- Prüfen --------------------------------------------------------------------------------
lw_step "Paket prüfen"
if [[ "${LW_DRY_RUN}" == "1" ]]; then
    lw_run pkgutil --check-signature "${PRODUCT}"
    lw_run pkgutil --expand "${PRODUCT}" "${WORK}/expanded"
else
    if [[ -n "${SIGN_IDENTITY}" ]]; then
        pkgutil --check-signature "${PRODUCT}" | sed 's/^/    /'
    fi
    pkgutil --expand "${PRODUCT}" "${WORK}/expanded"
    for component in LabelWerkApp.pkg LabelWerkDriver.pkg LabelWerkCLI.pkg; do
        [[ -d "${WORK}/expanded/${component}" ]] || lw_die "Komponente ${component} fehlt im Paket."
    done
    for script in preinstall postinstall; do
        [[ -x "${WORK}/expanded/LabelWerkDriver.pkg/Scripts/${script}" ]] \
            || lw_die "Skript ${script} fehlt in der Treiberkomponente."
    done
    rm -rf "${WORK}/expanded"
    (cd "${OUTPUT}" && shasum -a 256 "$(basename "${PRODUCT}")" > "$(basename "${PRODUCT}").sha256")
    lw_ok "Komponenten und Skripte vollständig"
fi

lw_step "Fertig"
if [[ "${LW_DRY_RUN}" == "1" ]]; then
    lw_ok "Probelauf beendet – es wurde nichts verändert."
else
    lw_ok "${PRODUCT} ($(lw_human_size "${PRODUCT}"))"
    lw_info "SHA-256: $(cut -d ' ' -f 1 "${PRODUCT}.sha256")"
    if [[ -n "${SIGN_IDENTITY}" ]]; then
        lw_info "Nächster Schritt: Scripts/notarize.sh \"${PRODUCT}\""
    else
        lw_info "Test-Installation: sudo installer -pkg \"${PRODUCT}\" -target /"
    fi
fi
