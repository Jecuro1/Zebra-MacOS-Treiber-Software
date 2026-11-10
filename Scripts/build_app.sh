#!/usr/bin/env bash
# shellcheck disable=SC1111  # Deutsche Anführungszeichen („…“) in Meldungen sind beabsichtigt.
#
# LabelWerk – App-Bundle bauen
#
# Baut die SwiftPM-Produkte „LabelWerk“ (SwiftUI-App) und „lwctl“ als Universal Binary
# (arm64 + x86_64) und setzt daraus build/LabelWerk.app zusammen:
#
#   LabelWerk.app/Contents/Info.plist              aus Installer/Info.plist + Installer/config.env
#   LabelWerk.app/Contents/PkgInfo
#   LabelWerk.app/Contents/MacOS/LabelWerk
#   LabelWerk.app/Contents/Helpers/lwctl
#   LabelWerk.app/Contents/Resources/AppIcon.icns
#   LabelWerk.app/Contents/Resources/{de,en}.lproj/{Localizable,InfoPlist}.strings
#   LabelWerk.app/Contents/Resources/Driver/…      Treiberbaum aus Scripts/build_driver.sh
#
# Anschließend wird von innen nach außen signiert (Filter, lwctl, App) – mit DEVELOPER_ID_APP
# und Zeitstempel, sonst ad hoc („-“) – jeweils mit gehärteter Laufzeitumgebung.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=SCRIPTDIR/../Installer/lib/common.sh
source "${SCRIPT_DIR}/../Installer/lib/common.sh"

usage() {
    cat <<EOF
Aufruf: Scripts/build_app.sh [Optionen]

Baut ${APP_NAME:-LabelWerk}.app (Universal Binary) nach build/ und signiert das Bundle.

Optionen:
  --debug         Debug-Build nur für die aktuelle Architektur (schneller, ohne Symbolentfernung)
  --skip-driver   Treiber nicht neu bauen; vorhandenes build/driver-root verwenden (falls vorhanden)
  --skip-build    swift build überspringen und vorhandene Build-Produkte verwenden
  --output VERZ   Zielverzeichnis für das Bundle (Standard: build)
  --dry-run       Schritte nur anzeigen, nichts ausführen
  -h, --help      diese Hilfe

Umgebung: VERSION, BUILD, DEVELOPER_ID_APP … überschreiben Installer/config.env;
SWIFT_BUILD_JOBS begrenzt die parallelen Übersetzungsjobs.
EOF
}

CONFIGURATION="release"
SKIP_DRIVER=0
SKIP_BUILD=0
OUTPUT="${LW_REPO_ROOT}/build"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) CONFIGURATION="debug"; shift ;;
        --skip-driver) SKIP_DRIVER=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
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
lw_require_macos "Das Bauen des App-Bundles (SwiftUI, codesign)"

case "${OUTPUT}" in
    /*) ;;
    *) OUTPUT="$(pwd -P)/${OUTPUT}" ;;
esac
OUTPUT="${OUTPUT%/}"

APP="${OUTPUT}/${APP_NAME}.app"
CONTENTS="${APP}/Contents"
DRIVER_ROOT="${LW_REPO_ROOT}/build/driver-root"
RESOURCES_SRC="${LW_REPO_ROOT}/Installer/Resources"
ENTITLEMENTS="${LW_REPO_ROOT}/Installer/LabelWerk.entitlements"
SWIFT="${SWIFT:-swift}"

lw_step "${APP_NAME} ${VERSION} (${BUILD}) – ${CONFIGURATION}"
lw_info "Bundle: ${APP}"

lw_require_tool "${SWIFT}" "Xcode 16 oder neuer installieren und mit „xcode-select“ auswählen."
lw_require_tool codesign
lw_require_tool plutil
lw_require_tool ditto
lw_require_tool lipo
lw_require_file "${RESOURCES_SRC}/AppIcon.icns" "App-Symbol" "„make icons“ ausführen."
lw_require_file "${ENTITLEMENTS}" "Berechtigungsdatei"
lw_require_file "${LW_REPO_ROOT}/Installer/Info.plist" "Info.plist-Vorlage"

# --- Treiber -------------------------------------------------------------------------------
if [[ "${SKIP_DRIVER}" == "1" ]]; then
    if [[ -d "${DRIVER_ROOT}/Library/Printers/LabelWerk" ]]; then
        lw_info "Treiber: vorhandenes build/driver-root wird verwendet."
    else
        lw_warn "build/driver-root fehlt – die App enthält kein Treiberpaket (Treiberinstallation aus der App nicht möglich)."
    fi
else
    driver_args=()
    if [[ "${LW_DRY_RUN}" == "1" ]]; then
        driver_args+=(--dry-run)
    fi
    "${SCRIPT_DIR}/build_driver.sh" --output "${DRIVER_ROOT}" ${driver_args[@]+"${driver_args[@]}"}
fi

# --- Swift-Build ---------------------------------------------------------------------------
lw_step "Swift-Produkte bauen"
swift_args=(build -c "${CONFIGURATION}" --package-path "${LW_REPO_ROOT}")
if [[ "${CONFIGURATION}" == "release" ]]; then
    swift_args+=(--arch arm64 --arch x86_64)
fi
if [[ -n "${SWIFT_BUILD_JOBS:-}" ]]; then
    swift_args+=(-j "${SWIFT_BUILD_JOBS}")
fi
if [[ "${SKIP_BUILD}" != "1" ]]; then
    lw_run "${SWIFT}" "${swift_args[@]}" --product LabelWerk
    lw_run "${SWIFT}" "${swift_args[@]}" --product lwctl
fi
if [[ "${LW_DRY_RUN}" == "1" ]]; then
    lw_print_command "${SWIFT}" "${swift_args[@]}" --show-bin-path
    BIN_DIR="${LW_REPO_ROOT}/.build/apple/Products/Release"
else
    BIN_DIR="$("${SWIFT}" "${swift_args[@]}" --show-bin-path)"
fi
lw_info "Build-Produkte: ${BIN_DIR}"

if [[ "${LW_DRY_RUN}" != "1" ]]; then
    for product in LabelWerk lwctl; do
        [[ -x "${BIN_DIR}/${product}" ]] || lw_die "Build-Produkt fehlt: ${BIN_DIR}/${product}"
        archs="$(lipo -archs "${BIN_DIR}/${product}")"
        if [[ "${CONFIGURATION}" == "release" ]] && [[ "${archs}" != *arm64* || "${archs}" != *x86_64* ]]; then
            lw_die "${product} ist kein Universal Binary (Architekturen: ${archs})."
        fi
        lw_ok "${product}: ${archs}"
    done
fi

# --- Bundle zusammensetzen -----------------------------------------------------------------
lw_step "Bundle zusammensetzen"
lw_run rm -rf "${APP}" "${OUTPUT}/${APP_NAME}.app.dSYM"
lw_run mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Helpers" "${CONTENTS}/Resources"
lw_run ditto "${BIN_DIR}/LabelWerk" "${CONTENTS}/MacOS/LabelWerk"
lw_run ditto "${BIN_DIR}/lwctl" "${CONTENTS}/Helpers/lwctl"

if [[ "${LW_DRY_RUN}" == "1" ]]; then
    lw_info "würde schreiben: ${CONTENTS}/Info.plist (aus Installer/Info.plist) und PkgInfo"
else
    lw_render_template "${LW_REPO_ROOT}/Installer/Info.plist" "${CONTENTS}/Info.plist"
    plutil -convert xml1 "${CONTENTS}/Info.plist"
    plutil -lint -s "${CONTENTS}/Info.plist" || lw_die "Info.plist ist ungültig."
    printf 'APPL????' > "${CONTENTS}/PkgInfo"
fi
lw_run cp "${RESOURCES_SRC}/AppIcon.icns" "${CONTENTS}/Resources/AppIcon.icns"

for lproj in "${RESOURCES_SRC}"/*.lproj; do
    [[ -d "${lproj}" ]] || continue
    name="$(basename "${lproj}")"
    lw_run mkdir -p "${CONTENTS}/Resources/${name}"
    for strings in "${lproj}"/*.strings; do
        [[ -f "${strings}" ]] || continue
        destination="${CONTENTS}/Resources/${name}/$(basename "${strings}")"
        if [[ "${LW_DRY_RUN}" == "1" ]]; then
            lw_print_command cp "${strings}" "${destination}"
            continue
        fi
        if [[ "$(basename "${strings}")" == "InfoPlist.strings" ]]; then
            lw_render_template "${strings}" "${destination}"
        else
            cp "${strings}" "${destination}"
        fi
        plutil -lint -s "${destination}" || lw_die "Ungültige Lokalisierungsdatei: ${destination}"
    done
done

# Ressourcen-Bundles von SwiftPM-Zielen (falls ein Ziel künftig Ressourcen deklariert).
if [[ "${LW_DRY_RUN}" != "1" ]]; then
    for bundle in "${BIN_DIR}"/*.bundle; do
        [[ -d "${bundle}" ]] || continue
        lw_warn "SwiftPM-Ressourcenbündel $(basename "${bundle}") wird mitkopiert."
        ditto "${bundle}" "${CONTENTS}/Resources/$(basename "${bundle}")"
    done
fi

if [[ -d "${DRIVER_ROOT}/Library/Printers/LabelWerk" || "${LW_DRY_RUN}" == "1" ]]; then
    lw_run ditto "${DRIVER_ROOT}" "${CONTENTS}/Resources/Driver"
fi

# Debug-Symbole sichern und aus den Programmen entfernen (nur Release).
if [[ "${CONFIGURATION}" == "release" ]]; then
    lw_step "Debug-Symbole"
    if [[ "${LW_DRY_RUN}" == "1" ]]; then
        lw_run dsymutil "${CONTENTS}/MacOS/LabelWerk" -o "${OUTPUT}/${APP_NAME}.app.dSYM"
    elif dsymutil "${CONTENTS}/MacOS/LabelWerk" -o "${OUTPUT}/${APP_NAME}.app.dSYM"; then
        lw_ok "${APP_NAME}.app.dSYM (für die Symbolisierung von Absturzberichten aufbewahren)"
    else
        lw_warn "dsymutil fehlgeschlagen – es wird kein dSYM-Bündel erzeugt."
    fi
    lw_run strip -S -x "${CONTENTS}/MacOS/LabelWerk" "${CONTENTS}/Helpers/lwctl"
fi

if [[ "${LW_DRY_RUN}" != "1" ]]; then
    find "${APP}" -name .DS_Store -delete
    chmod -R u+rwX,go+rX,go-w "${APP}"
fi

# --- Signieren (von innen nach außen) ------------------------------------------------------
IDENTITY="$(lw_app_identity)"
if [[ "${IDENTITY}" == "-" ]]; then
    lw_step "Signieren (ad hoc – nur für Entwicklung und Tests)"
else
    lw_step "Signieren mit „${IDENTITY}“"
fi
if [[ "${LW_DRY_RUN}" == "1" ]]; then
    for filter in rastertolabelwerk commandtolabelwerk; do
        lw_codesign "${CONTENTS}/Resources/Driver/Library/Printers/LabelWerk/Filter/${filter}" "${BUNDLE_ID}.${filter}"
    done
else
    for filter in "${CONTENTS}/Resources/Driver/Library/Printers/LabelWerk/Filter/"*; do
        [[ -f "${filter}" ]] || continue
        lw_codesign "${filter}" "${BUNDLE_ID}.$(basename "${filter}")"
    done
fi
lw_codesign "${CONTENTS}/Helpers/lwctl" "${BUNDLE_ID}.lwctl"
lw_codesign "${APP}" "" --entitlements "${ENTITLEMENTS}"

lw_step "Signatur prüfen"
lw_run codesign --verify --deep --strict --verbose=2 "${APP}"
if [[ "${IDENTITY}" != "-" && "${LW_DRY_RUN}" != "1" ]]; then
    # Vor der Notarisierung meldet Gatekeeper „Unnotarized Developer ID“ – das ist erwartet.
    spctl --assess --type execute --verbose=2 "${APP}" 2>&1 | sed 's/^/    /' || true
fi

lw_step "Fertig"
if [[ "${LW_DRY_RUN}" == "1" ]]; then
    lw_ok "Probelauf beendet – es wurde nichts verändert."
else
    lw_ok "${APP} ($(lw_human_size "${APP}"))"
    if [[ "${IDENTITY}" == "-" ]]; then
        lw_info "Ad-hoc-signiert: Für die Weitergabe DEVELOPER_ID_APP setzen und Scripts/notarize.sh verwenden."
    fi
fi
