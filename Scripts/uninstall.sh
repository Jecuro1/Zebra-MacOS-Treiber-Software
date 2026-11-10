#!/bin/bash
# shellcheck disable=SC1111  # Deutsche Anführungszeichen („…“) in Meldungen sind beabsichtigt.
#
# LabelWerk – Deinstallation
#
# Entfernt den CUPS-Treiber (/Library/Printers/LabelWerk, LabelWerk-PPDs), die App, den
# lwctl-Link und die Paketbelege. Druckerwarteschlangen, die LabelWerk-PPDs verwenden, werden
# nur mit --remove-queues entfernt (sonst wird gewarnt, dass sie danach nicht mehr drucken).
#
# Eigenständig lauffähig (keine weiteren Projektdateien nötig) und kompatibel mit der Bash 3.2
# von macOS. Wird vom Treiberpaket als /Library/Printers/LabelWerk/uninstall.sh installiert:
#
#   sudo /Library/Printers/LabelWerk/uninstall.sh [--remove-queues] [--keep-app] [--yes]
#
# Die beiden folgenden Standardwerte setzt Scripts/build_driver.sh aus Installer/config.env.

set -euo pipefail

DEFAULT_APP_NAME="LabelWerk"
DEFAULT_BUNDLE_ID="com.labelwerk.app"

APP_NAME="${DEFAULT_APP_NAME}"
BUNDLE_ID="${DEFAULT_BUNDLE_ID}"

ORIGINAL_ARGS="$*"
REMOVE_QUEUES=0
KEEP_APP=0
PURGE_USER_DATA=0
ASSUME_YES=0
DRY_RUN=0
RESTART_CUPS=1
ROOT=""

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
    C_VIOLET=$'\033[35m' C_DIM=$'\033[2m'
else
    C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_VIOLET='' C_DIM=''
fi

step() { printf '\n%s==>%s %s%s%s\n' "${C_VIOLET}${C_BOLD}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}"; }
ok() { printf '%s  ✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
info() { printf '  • %s\n' "$*"; }
warn() { printf '%s  ! Warnung:%s %s\n' "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" >&2; }
die() {
    printf '%s  ✗ Fehler:%s %s\n' "${C_RED}${C_BOLD}" "${C_RESET}" "$1" >&2
    exit "${2:-1}"
}

usage() {
    cat <<EOF
Aufruf: sudo $(basename "$0") [Optionen]

Entfernt ${APP_NAME}: CUPS-Treiber (Filter, PPD-Dateien, Druckersymbol), die App
/Applications/${APP_NAME}.app, den Link /usr/local/bin/lwctl und die Installationsbelege.

Optionen:
  --remove-queues     auch alle Druckerwarteschlangen entfernen, die LabelWerk-PPDs verwenden
                      (ohne diese Option bleiben sie bestehen, drucken aber nicht mehr)
  --keep-app          die App (samt lwctl-Link) behalten und nur den Treiber entfernen
  --purge-user-data   zusätzlich Einstellungen und Daten des aufrufenden Benutzers löschen
                      (~/Library/Application Support/${APP_NAME}, Einstellungen, Caches)
  -y, --yes           ohne Rückfrage ausführen
  -n, --dry-run       nur anzeigen, was entfernt würde
  --no-restart        CUPS danach nicht neu starten
  --root VERZ         unter einem anderen Wurzelverzeichnis arbeiten (Tests, Fremdvolume);
                      Warteschlangen und Dienste werden dabei nicht angefasst
  -h, --help          diese Hilfe
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove-queues) REMOVE_QUEUES=1; shift ;;
        --keep-app) KEEP_APP=1; shift ;;
        --purge-user-data) PURGE_USER_DATA=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        --no-restart) RESTART_CUPS=0; shift ;;
        --root)
            [[ $# -ge 2 ]] || die "--root erwartet ein Verzeichnis." 64
            ROOT="${2%/}"
            shift 2
            ;;
        --root=*) ROOT="${1#*=}"; ROOT="${ROOT%/}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unbekannte Option „$1“." 64 ;;
    esac
done

# Mit --root werden keine Systemdienste angesprochen.
SYSTEM_ROOT=1
if [[ -n "${ROOT}" ]]; then
    [[ -d "${ROOT}" ]] || die "Wurzelverzeichnis „${ROOT}“ existiert nicht." 64
    SYSTEM_ROOT=0
    RESTART_CUPS=0
fi

if [[ "${SYSTEM_ROOT}" == "1" && "$(uname -s)" != "Darwin" && "${DRY_RUN}" != "1" ]]; then
    die "Die Deinstallation ist nur auf macOS möglich (dieses System: $(uname -s)). Zum Testen --root oder --dry-run verwenden." 2
fi
if [[ "${SYSTEM_ROOT}" == "1" && "${DRY_RUN}" != "1" && "$(id -u)" != "0" ]]; then
    die "Bitte mit Administratorrechten ausführen: sudo $0${ORIGINAL_ARGS:+ ${ORIGINAL_ARGS}}" 1
fi

DRIVER_DIR="${ROOT}/Library/Printers/LabelWerk"
PPD_DIR="${ROOT}/Library/Printers/PPDs/Contents/Resources"
CUPS_PPD_DIR="${ROOT}/etc/cups/ppd"
APP_PATH="${ROOT}/Applications/${APP_NAME}.app"
CLI_LINK="${ROOT}/usr/local/bin/lwctl"
RECEIPTS=("${BUNDLE_ID}.pkg" "${BUNDLE_ID}.driver" "${BUNDLE_ID}.cli")

# Führt einen Befehl aus bzw. zeigt ihn im Probelauf nur an.
run() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '%s    $ %s%s\n' "${C_DIM}" "$*" "${C_RESET}"
        return 0
    fi
    "$@"
}

# --- Bestandsaufnahme ------------------------------------------------------------------------

TARGETS=()
add_target() {
    if [[ -e "$1" || -L "$1" ]]; then
        TARGETS+=("$1")
    fi
}

add_target "${DRIVER_DIR}"
shopt -s nullglob
for ppd in "${PPD_DIR}"/LabelWerk-*.ppd.gz "${PPD_DIR}"/LabelWerk-*.ppd; do
    add_target "${ppd}"
done
shopt -u nullglob
PPD_COUNT=0
if [[ ${#TARGETS[@]} -gt 0 ]]; then
    for target in "${TARGETS[@]}"; do
        case "${target}" in
            "${PPD_DIR}"/*) PPD_COUNT=$((PPD_COUNT + 1)) ;;
        esac
    done
fi
# Der lwctl-Link zeigt in die App (Contents/Helpers/lwctl) und gehört zu ihr: Mit --keep-app
# bleibt er bestehen – ebenso wie die Belege der App- und CLI-Komponente (siehe unten).
if [[ "${KEEP_APP}" != "1" ]]; then
    add_target "${APP_PATH}"
    if [[ -L "${CLI_LINK}" ]]; then
        case "$(readlink "${CLI_LINK}")" in
            */Contents/Helpers/lwctl) add_target "${CLI_LINK}" ;;
        esac
    fi
fi

# Warteschlangen, deren PPD von LabelWerk stammt (Attribut *lwModel oder Filterpfad).
QUEUES=()
if [[ -d "${CUPS_PPD_DIR}" ]]; then
    shopt -s nullglob
    for queue_ppd in "${CUPS_PPD_DIR}"/*.ppd; do
        if grep -q -e '^\*lwModel:' -e '/Library/Printers/LabelWerk/Filter/' "${queue_ppd}" 2>/dev/null; then
            QUEUES+=("$(basename "${queue_ppd}" .ppd)")
        fi
    done
    shopt -u nullglob
elif [[ "${SYSTEM_ROOT}" == "1" && "${DRY_RUN}" == "1" && "$(id -u)" != "0" ]]; then
    warn "Ohne Administratorrechte sind die CUPS-Warteschlangen nicht lesbar – Probelauf ohne Warteschlangenprüfung."
fi

# Benutzerdaten des aufrufenden Benutzers (bei sudo: SUDO_USER).
USER_TARGETS=()
TARGET_USER="${SUDO_USER:-$(id -un)}"
if [[ "${PURGE_USER_DATA}" == "1" ]]; then
    # /Search findet auch Verzeichnisdienst-Konten (AD/LDAP), nicht nur lokale. Werte mit
    # Leerzeichen gibt dscl in einer Folgezeile aus („NFSHomeDirectory:“, dann „ /Users/A B“).
    # „|| true“: Eine fehlgeschlagene Abfrage darf das Skript (set -e, pipefail) nicht beenden,
    # damit die Ausweichwege greifen.
    user_home=""
    if command -v dscl >/dev/null 2>&1; then
        dscl_record="$(dscl /Search -read "/Users/${TARGET_USER}" NFSHomeDirectory 2>/dev/null || true)"
        user_home="$(printf '%s\n' "${dscl_record}" | sed -n -e 's/^NFSHomeDirectory: //p' -e '/^NFSHomeDirectory:$/{n;s/^ //p;}')"
    fi
    if [[ -z "${user_home}" ]] && command -v getent >/dev/null 2>&1; then
        user_home="$(getent passwd "${TARGET_USER}" 2>/dev/null | cut -d: -f6 || true)"
    fi
    [[ -n "${user_home}" ]] || user_home="${HOME}"
    for candidate in \
        "${ROOT}${user_home}/Library/Application Support/${APP_NAME}" \
        "${ROOT}${user_home}/Library/Preferences/${BUNDLE_ID}.plist" \
        "${ROOT}${user_home}/Library/Caches/${BUNDLE_ID}" \
        "${ROOT}${user_home}/Library/HTTPStorages/${BUNDLE_ID}" \
        "${ROOT}${user_home}/Library/Saved Application State/${BUNDLE_ID}.savedState"; do
        if [[ -e "${candidate}" ]]; then
            USER_TARGETS+=("${candidate}")
        fi
    done
fi

# --- Übersicht und Rückfrage -----------------------------------------------------------------

step "${APP_NAME} entfernen${ROOT:+ (Wurzel: ${ROOT})}"
if [[ -f "${DRIVER_DIR}/VERSION" ]]; then
    info "installierte Treiberversion: $(head -n 1 "${DRIVER_DIR}/VERSION")"
fi
if [[ ${#TARGETS[@]} -eq 0 && ${#USER_TARGETS[@]} -eq 0 && ${#QUEUES[@]} -eq 0 ]]; then
    ok "Es ist nichts von ${APP_NAME} installiert."
    exit 0
fi
if [[ ${#TARGETS[@]} -gt 0 ]]; then
    for target in "${TARGETS[@]}"; do
        case "${target}" in
            "${PPD_DIR}"/*) ;;
            *) info "${target}" ;;
        esac
    done
fi
if [[ "${PPD_COUNT}" -gt 0 ]]; then
    info "${PPD_COUNT} PPD-Dateien in ${PPD_DIR}"
fi
if [[ ${#USER_TARGETS[@]} -gt 0 ]]; then
    for target in "${USER_TARGETS[@]}"; do
        info "${target}"
    done
fi
if [[ ${#QUEUES[@]} -gt 0 ]]; then
    if [[ "${REMOVE_QUEUES}" == "1" ]]; then
        info "Warteschlangen: ${QUEUES[*]}"
    else
        warn "Diese Warteschlangen verwenden LabelWerk und drucken nach dem Entfernen nicht mehr: ${QUEUES[*]}"
        warn "Mit --remove-queues werden sie mit entfernt."
    fi
fi

if [[ "${DRY_RUN}" != "1" && "${ASSUME_YES}" != "1" ]]; then
    if [[ ! -t 0 ]]; then
        die "Keine Rückfrage möglich (keine Terminal-Eingabe) – zum Bestätigen --yes angeben." 1
    fi
    printf '\nWirklich entfernen? [j/N] '
    read -r answer
    case "${answer}" in
        j|J|ja|Ja|JA|y|Y|yes|Yes) ;;
        *) info "Abgebrochen – es wurde nichts verändert."; exit 0 ;;
    esac
fi

# --- Entfernen -------------------------------------------------------------------------------

if [[ "${SYSTEM_ROOT}" == "1" && "${KEEP_APP}" != "1" ]] && command -v pgrep >/dev/null 2>&1; then
    if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
        warn "${APP_NAME} läuft noch – bitte die App beenden; sie wird trotzdem entfernt."
    fi
fi

if [[ ${#QUEUES[@]} -gt 0 && "${REMOVE_QUEUES}" == "1" ]]; then
    step "Warteschlangen entfernen"
    for queue in "${QUEUES[@]}"; do
        if [[ "${SYSTEM_ROOT}" == "1" ]]; then
            if run /usr/sbin/lpadmin -x "${queue}"; then
                ok "${queue}"
            else
                warn "Warteschlange „${queue}“ konnte nicht entfernt werden."
            fi
        else
            run rm -f "${CUPS_PPD_DIR}/${queue}.ppd"
            ok "${queue} (nur PPD unter ${ROOT})"
        fi
    done
fi

step "Dateien entfernen"
if [[ ${#TARGETS[@]} -gt 0 ]]; then
    for target in "${TARGETS[@]}"; do
        case "${target}" in
            "${PPD_DIR}"/*)
                # PPD-Dateien im Probelauf nicht einzeln auflisten (über 100 Stück).
                if [[ "${DRY_RUN}" == "1" ]]; then
                    continue
                fi
                ;;
            *) ;;
        esac
        run rm -rf "${target}"
    done
    if [[ "${DRY_RUN}" == "1" && "${PPD_COUNT}" -gt 0 ]]; then
        printf '%s    $ rm -f %s/LabelWerk-*.ppd.gz %s/LabelWerk-*.ppd   # %s Dateien%s\n' \
            "${C_DIM}" "${PPD_DIR}" "${PPD_DIR}" "${PPD_COUNT}" "${C_RESET}"
    fi
fi
if [[ ${#USER_TARGETS[@]} -gt 0 ]]; then
    if [[ "${SYSTEM_ROOT}" == "1" && "${DRY_RUN}" != "1" ]] && command -v defaults >/dev/null 2>&1; then
        # Zwischengespeicherte Einstellungen über cfprefsd verwerfen, bevor die Datei verschwindet.
        sudo -u "${TARGET_USER}" defaults delete "${BUNDLE_ID}" >/dev/null 2>&1 || true
    fi
    for target in "${USER_TARGETS[@]}"; do
        run rm -rf "${target}"
    done
fi
if [[ "${DRY_RUN}" != "1" ]]; then
    ok "$(( ${#TARGETS[@]} + ${#USER_TARGETS[@]} )) Einträge entfernt"
fi

if [[ "${SYSTEM_ROOT}" == "1" ]] && command -v pkgutil >/dev/null 2>&1; then
    step "Installationsbelege entfernen"
    for receipt in "${RECEIPTS[@]}"; do
        if [[ "${KEEP_APP}" == "1" && ( "${receipt}" == "${BUNDLE_ID}.pkg" || "${receipt}" == "${BUNDLE_ID}.cli" ) ]]; then
            continue
        fi
        if pkgutil --pkg-info "${receipt}" >/dev/null 2>&1; then
            if [[ "${DRY_RUN}" == "1" ]]; then
                run pkgutil --forget "${receipt}"
            else
                pkgutil --forget "${receipt}" >/dev/null
                ok "${receipt}"
            fi
        fi
    done
fi

if [[ "${RESTART_CUPS}" == "1" ]]; then
    step "CUPS neu starten"
    if [[ "${DRY_RUN}" == "1" ]]; then
        run launchctl kickstart -k system/org.cups.cupsd
    elif launchctl kickstart -k system/org.cups.cupsd >/dev/null 2>&1; then
        ok "cupsd neu gestartet"
    elif killall -HUP cupsd >/dev/null 2>&1; then
        ok "cupsd neu geladen"
    else
        info "cupsd läuft nicht – nichts zu tun."
    fi
fi

step "Fertig"
if [[ "${DRY_RUN}" == "1" ]]; then
    ok "Probelauf – es wurde nichts verändert."
else
    ok "${APP_NAME} wurde entfernt."
fi
