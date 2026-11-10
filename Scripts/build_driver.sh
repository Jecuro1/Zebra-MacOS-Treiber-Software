#!/usr/bin/env bash
# shellcheck disable=SC1111  # Deutsche Anführungszeichen („…“) in Meldungen sind beabsichtigt.
#
# LabelWerk – Treiberpaket bauen
#
# Erzeugt den Installationsbaum des CUPS-Treibers im Aufbau von ARCHITECTURE.md §10:
#
#   <ausgabe>/Library/Printers/LabelWerk/Filter/rastertolabelwerk     (Universal, 0755)
#   <ausgabe>/Library/Printers/LabelWerk/Filter/commandtolabelwerk    (Universal, 0755)
#   <ausgabe>/Library/Printers/LabelWerk/Icons/LabelWerk.icns
#   <ausgabe>/Library/Printers/LabelWerk/VERSION
#   <ausgabe>/Library/Printers/LabelWerk/ppd-index.json               (Modellübersicht der PPDs)
#   <ausgabe>/Library/Printers/LabelWerk/uninstall.sh                 (Deinstallation, 0755)
#   <ausgabe>/Library/Printers/PPDs/Contents/Resources/LabelWerk-<modell>-<dpi>dpi.ppd.gz
#
# Der Baum ist Nutzlast des Installationspakets (Scripts/make_pkg.sh) und wird von
# Scripts/build_app.sh als Contents/Resources/Driver in die App gelegt (Treiberinstallation aus
# der App heraus).
#
# Auf macOS werden Universal-Binaries (arm64 + x86_64) gebaut und signiert. Mit --host entsteht
# ein Testaufbau mit Filtern für das aktuelle System – so lässt sich der Aufbau auch unter Linux
# (CI) prüfen.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=SCRIPTDIR/../Installer/lib/common.sh
source "${SCRIPT_DIR}/../Installer/lib/common.sh"

usage() {
    cat <<EOF
Aufruf: Scripts/build_driver.sh [Optionen]

Baut Filter (Universal Binary), PPD-Dateien, Symbol und Versionsdatei des LabelWerk-Treibers
in einen Installationsbaum (Standard: build/driver-root).

Optionen:
  --output VERZ   Zielverzeichnis des Installationsbaums (wird neu angelegt)
  --host          Filter für das aktuelle System statt Universal Binary (Testaufbau, z. B. Linux)
  --no-sign       Filter nicht signieren (nur macOS relevant)
  --dry-run       Schritte nur anzeigen, nichts ausführen
  -h, --help      diese Hilfe

Umgebung: VERSION, BUILD, DEVELOPER_ID_APP … überschreiben Installer/config.env.
EOF
}

OUTPUT="${LW_REPO_ROOT}/build/driver-root"
HOST_BUILD=0
SIGN=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || lw_die "--output erwartet ein Verzeichnis."
            OUTPUT="$2"
            shift 2
            ;;
        --output=*) OUTPUT="${1#*=}"; shift ;;
        --host) HOST_BUILD=1; shift ;;
        --no-sign) SIGN=0; shift ;;
        --dry-run) LW_DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; lw_die "Unbekannte Option „$1“." 64 ;;
    esac
done

lw_load_config

# Absoluter Zielpfad; Schutz vor versehentlichem Löschen von Systemverzeichnissen.
case "${OUTPUT}" in
    /*) ;;
    *) OUTPUT="$(pwd -P)/${OUTPUT}" ;;
esac
OUTPUT="${OUTPUT%/}"
case "${OUTPUT}" in
    ""|/|/Library|/Library/*|/System|/System/*|/usr|/usr/*|"${HOME}")
        lw_die "Ungeeignetes Zielverzeichnis „${OUTPUT}“ – bitte ein eigenes Build-Verzeichnis angeben." 64
        ;;
esac

FILTER_DIR_SRC="${LW_REPO_ROOT}/Driver/filter"
PPD_GENERATOR="${LW_REPO_ROOT}/Driver/ppd/generate_ppds.py"
PRINTER_ICON="${LW_REPO_ROOT}/Installer/Resources/LabelWerk.icns"
UNINSTALLER="${LW_REPO_ROOT}/Scripts/uninstall.sh"
PYTHON="${PYTHON:-python3}"
MAKE="${MAKE:-make}"

DRIVER_ROOT="${OUTPUT}/Library/Printers/LabelWerk"
PPD_DEST="${OUTPUT}/Library/Printers/PPDs/Contents/Resources"
FILTERS=(rastertolabelwerk commandtolabelwerk)

if [[ "${HOST_BUILD}" == "1" ]]; then
    MODE="Testaufbau für $(uname -s)/$(uname -m)"
elif lw_is_macos; then
    MODE="Universal Binary (arm64 + x86_64)"
elif [[ "${LW_DRY_RUN}" == "1" ]]; then
    MODE="Universal Binary (arm64 + x86_64) – Probelauf"
    lw_warn "Universal Binaries erfordern macOS – Probelauf auf $(uname -s): Befehle werden nur angezeigt."
else
    lw_die "Universal Binaries der Filter lassen sich nur auf macOS bauen. Für einen Testaufbau mit Filtern für dieses System „--host“ verwenden, zum Anzeigen der Schritte „--dry-run“." 2
fi

lw_step "LabelWerk-Treiber ${VERSION} (${MODE})"
lw_info "Ziel: ${OUTPUT}"

# --- Voraussetzungen -----------------------------------------------------------------------
lw_require_tool "${MAKE}" "Xcode-Befehlszeilenwerkzeuge bzw. build-essential installieren."
lw_require_tool "${PYTHON}" "Python 3 installieren."
lw_require_tool gzip
lw_require_file "${FILTER_DIR_SRC}/Makefile" "Makefile der Filter"
lw_require_file "${PPD_GENERATOR}" "PPD-Generator"
lw_require_file "${PRINTER_ICON}" "Druckersymbol" "„make icons“ ausführen."
lw_require_file "${UNINSTALLER}" "Deinstallationsskript"

# --- Filter --------------------------------------------------------------------------------
lw_step "Filter bauen"
lw_run rm -rf "${OUTPUT}"
lw_run mkdir -p "${DRIVER_ROOT}/Filter" "${DRIVER_ROOT}/Icons" "${PPD_DEST}"

if [[ "${HOST_BUILD}" == "1" ]]; then
    lw_run "${MAKE}" -C "${FILTER_DIR_SRC}" all
    FILTER_BUILD="${FILTER_DIR_SRC}/build"
else
    lw_run "${MAKE}" -C "${FILTER_DIR_SRC}" universal
    FILTER_BUILD="${FILTER_DIR_SRC}/build/universal"
fi

if [[ "${HOST_BUILD}" == "1" ]] && lw_is_macos; then
    # Das install-Ziel des Filter-Makefiles installiert auf macOS immer die Universal Binaries.
    for filter in "${FILTERS[@]}"; do
        lw_run install -m 0755 "${FILTER_BUILD}/${filter}" "${DRIVER_ROOT}/Filter/${filter}"
    done
else
    lw_run "${MAKE}" -C "${FILTER_DIR_SRC}" install DESTDIR="${OUTPUT}" FILTERDIR=/Library/Printers/LabelWerk/Filter
fi

if [[ "${LW_DRY_RUN}" != "1" ]]; then
    for filter in "${FILTERS[@]}"; do
        [[ -x "${DRIVER_ROOT}/Filter/${filter}" ]] || lw_die "Filter fehlt nach dem Bauen: ${DRIVER_ROOT}/Filter/${filter}"
        if [[ "${HOST_BUILD}" != "1" ]] && lw_is_macos; then
            archs="$(lipo -archs "${DRIVER_ROOT}/Filter/${filter}")"
            [[ "${archs}" == *arm64* && "${archs}" == *x86_64* ]] \
                || lw_die "${filter} ist kein Universal Binary (Architekturen: ${archs})."
            lw_ok "${filter}: ${archs}"
        else
            lw_ok "${filter}"
        fi
    done
fi

# --- PPD-Dateien ---------------------------------------------------------------------------
lw_step "PPD-Dateien erzeugen"
PPD_TMP="${OUTPUT}.ppd-tmp"
lw_run rm -rf "${PPD_TMP}"
lw_run mkdir -p "${PPD_TMP}"
lw_run "${PYTHON}" "${PPD_GENERATOR}" --output "${PPD_TMP}" --gzip --file-version "${VERSION}" --quiet

if [[ "${LW_DRY_RUN}" != "1" ]]; then
    shopt -s nullglob
    generated=("${PPD_TMP}"/LabelWerk-*.ppd.gz)
    shopt -u nullglob
    [[ ${#generated[@]} -gt 0 ]] || lw_die "Der PPD-Generator hat keine Dateien LabelWerk-*.ppd.gz erzeugt."
    for ppd in "${generated[@]}"; do
        gzip -t "${ppd}" || lw_die "Beschädigte PPD-Datei: ${ppd}"
        cp "${ppd}" "${PPD_DEST}/"
    done
    # Stichprobe: Die PPDs müssen auf unseren Filterpfad verweisen.
    if ! gzip -dc "${generated[0]}" | grep -q '/Library/Printers/LabelWerk/Filter/rastertolabelwerk'; then
        lw_die "$(basename "${generated[0]}") verweist nicht auf /Library/Printers/LabelWerk/Filter/rastertolabelwerk."
    fi
    if [[ -f "${PPD_TMP}/index.json" ]]; then
        cp "${PPD_TMP}/index.json" "${DRIVER_ROOT}/ppd-index.json"
    else
        lw_warn "index.json des PPD-Generators fehlt – ppd-index.json wird nicht angelegt."
    fi
    rm -rf "${PPD_TMP}"
    lw_ok "${#generated[@]} PPD-Dateien"
else
    lw_run cp "${PPD_TMP}/LabelWerk-*.ppd.gz" "${PPD_DEST}/"
    lw_run cp "${PPD_TMP}/index.json" "${DRIVER_ROOT}/ppd-index.json"
    lw_run rm -rf "${PPD_TMP}"
fi

# --- Symbol, Version, Deinstallation -------------------------------------------------------
lw_step "Symbol, Versionsdatei und Deinstallationsskript"
lw_run cp "${PRINTER_ICON}" "${DRIVER_ROOT}/Icons/LabelWerk.icns"
if [[ "${LW_DRY_RUN}" == "1" ]]; then
    lw_info "würde schreiben: ${DRIVER_ROOT}/VERSION (${VERSION})"
    lw_info "würde schreiben: ${DRIVER_ROOT}/uninstall.sh (Standardwerte aus der Konfiguration)"
else
    printf '%s\n' "${VERSION}" > "${DRIVER_ROOT}/VERSION"
    # Standardwerte des eigenständigen Deinstallationsskripts an die Konfiguration anpassen.
    sed -e "s|^DEFAULT_APP_NAME=.*$|DEFAULT_APP_NAME=\"${APP_NAME}\"|" \
        -e "s|^DEFAULT_BUNDLE_ID=.*$|DEFAULT_BUNDLE_ID=\"${BUNDLE_ID}\"|" \
        "${UNINSTALLER}" > "${DRIVER_ROOT}/uninstall.sh"
    grep -q "^DEFAULT_BUNDLE_ID=\"${BUNDLE_ID}\"$" "${DRIVER_ROOT}/uninstall.sh" \
        || lw_die "Standardwerte im Deinstallationsskript konnten nicht gesetzt werden."
    lw_ok "VERSION ${VERSION}, Icons/LabelWerk.icns, uninstall.sh"
fi

# --- Rechte --------------------------------------------------------------------------------
lw_step "Rechte setzen"
if [[ "${LW_DRY_RUN}" != "1" ]]; then
    find "${OUTPUT}" -name .DS_Store -delete
    find "${OUTPUT}" -type d -exec chmod 755 {} +
    find "${OUTPUT}" -type f -exec chmod 644 {} +
    chmod 755 "${DRIVER_ROOT}/Filter/"* "${DRIVER_ROOT}/uninstall.sh"
    # /Library/Printers und der PPD-Ordner gehören auf macOS root:admin mit 0775; die Nutzlast
    # bildet das nach, damit der Installer bestehende Systemordner nicht verändert.
    chmod 775 "${OUTPUT}/Library/Printers" "${OUTPUT}/Library/Printers/PPDs" \
        "${OUTPUT}/Library/Printers/PPDs/Contents" "${PPD_DEST}"
    lw_ok "Ordner 0755 (Systemordner 0775), Dateien 0644, Filter 0755"
else
    lw_info "würde setzen: Ordner 0755 (Systemordner 0775), Dateien 0644, Filter und uninstall.sh 0755"
fi

# --- Signieren -----------------------------------------------------------------------------
SIGN_LABEL="ad hoc"
if [[ -n "${DEVELOPER_ID_APP}" ]]; then
    SIGN_LABEL="${DEVELOPER_ID_APP}"
fi
if lw_is_macos && [[ "${SIGN}" == "1" ]]; then
    lw_step "Filter signieren (${SIGN_LABEL})"
    for filter in "${FILTERS[@]}"; do
        lw_codesign "${DRIVER_ROOT}/Filter/${filter}" "${BUNDLE_ID}.${filter}"
        lw_run codesign --verify --strict "${DRIVER_ROOT}/Filter/${filter}"
    done
    lw_ok "Filter signiert"
elif [[ "${SIGN}" == "1" && "${LW_DRY_RUN}" == "1" ]]; then
    lw_step "Filter signieren"
    for filter in "${FILTERS[@]}"; do
        lw_codesign "${DRIVER_ROOT}/Filter/${filter}" "${BUNDLE_ID}.${filter}"
    done
fi

# --- Zusammenfassung -----------------------------------------------------------------------
lw_step "Fertig"
if [[ "${LW_DRY_RUN}" == "1" ]]; then
    lw_ok "Probelauf beendet – es wurde nichts verändert."
else
    lw_ok "Treiberbaum: ${OUTPUT} ($(lw_human_size "${OUTPUT}"))"
fi
