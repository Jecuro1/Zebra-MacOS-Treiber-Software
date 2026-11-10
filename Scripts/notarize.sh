#!/usr/bin/env bash
# shellcheck disable=SC1111  # Deutsche Anführungszeichen („…“) in Meldungen sind beabsichtigt.
#
# LabelWerk – Notarisierung
#
# Reicht signierte Pakete bzw. Apps bei Apples Notardienst ein (xcrun notarytool submit --wait),
# zeigt bei Ablehnung das Prüfprotokoll an, heftet das Ticket an (xcrun stapler staple) und prüft
# das Ergebnis mit Gatekeeper (spctl).
#
# Anmeldung – die erste vollständige Variante wird verwendet:
#   1. NOTARY_KEYCHAIN_PROFILE   Profil aus „xcrun notarytool store-credentials“ (empfohlen)
#   2. NOTARY_API_KEY_PATH, NOTARY_API_KEY_ID [, NOTARY_API_ISSUER]
#                                App-Store-Connect-API-Schlüssel (.p8); ISSUER für Team-Schlüssel
#   3. NOTARY_APPLE_ID, NOTARY_PASSWORD (app-spezifisches Passwort) und TEAM_ID
#
# Unterstützt .pkg, .dmg, .zip und .app (wird für die Einreichung mit ditto gezippt; das Ticket
# wird anschließend an die .app geheftet).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=SCRIPTDIR/../Installer/lib/common.sh
source "${SCRIPT_DIR}/../Installer/lib/common.sh"

usage() {
    cat <<EOF
Aufruf: Scripts/notarize.sh [Optionen] [DATEI …]

Notarisiert die angegebenen Dateien (.pkg, .dmg, .zip, .app). Ohne Angabe:
dist/<App>-<Version>.pkg.

Optionen:
  --no-staple     Ticket nicht anheften (z. B. für .zip-Archive zur Weitergabe)
  --timeout DAUER maximale Wartezeit auf den Notardienst (Standard: 2h)
  --dry-run       Schritte nur anzeigen, nichts einreichen
  -h, --help      diese Hilfe

Anmeldung über Umgebungsvariablen (siehe Kopf dieses Skripts):
  NOTARY_KEYCHAIN_PROFILE
  NOTARY_API_KEY_PATH, NOTARY_API_KEY_ID, NOTARY_API_ISSUER
  NOTARY_APPLE_ID, NOTARY_PASSWORD, TEAM_ID
EOF
}

STAPLE=1
TIMEOUT="2h"
FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-staple) STAPLE=0; shift ;;
        --timeout)
            [[ $# -ge 2 ]] || lw_die "--timeout erwartet eine Dauer (z. B. 30m)."
            TIMEOUT="$2"
            shift 2
            ;;
        --dry-run) LW_DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; lw_die "Unbekannte Option „$1“." 64 ;;
        *) FILES+=("$1"); shift ;;
    esac
done

lw_load_config
lw_require_macos "Die Notarisierung (xcrun notarytool, stapler)"
lw_require_tool xcrun "Xcode oder die Xcode-Befehlszeilenwerkzeuge installieren."
lw_require_tool ditto
lw_require_tool plutil

if [[ ${#FILES[@]} -eq 0 ]]; then
    FILES=("${LW_REPO_ROOT}/dist/${APP_NAME}-${VERSION}.pkg")
fi

# --- Anmeldedaten --------------------------------------------------------------------------
AUTH=()
AUTH_LABEL=""
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    AUTH=(--keychain-profile "${NOTARY_KEYCHAIN_PROFILE}")
    AUTH_LABEL="Schlüsselbundprofil „${NOTARY_KEYCHAIN_PROFILE}“"
elif [[ -n "${NOTARY_API_KEY_PATH:-}" && -n "${NOTARY_API_KEY_ID:-}" ]]; then
    lw_require_file "${NOTARY_API_KEY_PATH}" "API-Schlüssel (.p8)"
    AUTH=(--key "${NOTARY_API_KEY_PATH}" --key-id "${NOTARY_API_KEY_ID}")
    if [[ -n "${NOTARY_API_ISSUER:-}" ]]; then
        AUTH+=(--issuer "${NOTARY_API_ISSUER}")
    fi
    AUTH_LABEL="API-Schlüssel ${NOTARY_API_KEY_ID}"
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" && -n "${TEAM_ID:-}" ]]; then
    AUTH=(--apple-id "${NOTARY_APPLE_ID}" --password "${NOTARY_PASSWORD}" --team-id "${TEAM_ID}")
    AUTH_LABEL="Apple-ID ${NOTARY_APPLE_ID} (Team ${TEAM_ID})"
elif [[ "${LW_DRY_RUN}" == "1" ]]; then
    AUTH=(--keychain-profile "<NOTARY_KEYCHAIN_PROFILE>")
    AUTH_LABEL="(keine Anmeldedaten – Probelauf)"
else
    lw_die "Keine Anmeldedaten für den Notardienst. Empfohlen: einmalig
      xcrun notarytool store-credentials labelwerk --apple-id <id> --team-id <team>
    ausführen und dann NOTARY_KEYCHAIN_PROFILE=labelwerk setzen. Alternativ NOTARY_API_KEY_PATH/
    NOTARY_API_KEY_ID[/NOTARY_API_ISSUER] oder NOTARY_APPLE_ID/NOTARY_PASSWORD/TEAM_ID."
fi

# Gibt den Befehl ohne Passwort aus und führt ihn aus.
notary() {
    local shown=()
    local hide_next=0
    local arg
    for arg in "$@"; do
        if [[ "${hide_next}" == "1" ]]; then
            shown+=("******")
            hide_next=0
            continue
        fi
        shown+=("${arg}")
        if [[ "${arg}" == "--password" ]]; then
            hide_next=1
        fi
    done
    lw_print_command xcrun notarytool "${shown[@]}"
    if [[ "${LW_DRY_RUN}" == "1" ]]; then
        return 0
    fi
    xcrun notarytool "$@"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/labelwerk-notarize.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

lw_step "Notarisierung (${AUTH_LABEL})"

for file in "${FILES[@]}"; do
    case "${file}" in
        /*) ;;
        *) file="$(pwd -P)/${file}" ;;
    esac
    file="${file%/}"
    name="$(basename "${file}")"
    lw_step "${name}"
    lw_require_file "${file}" "Datei"

    upload="${file}"
    staple_target="${file}"
    assess_type=""
    case "${file}" in
        *.pkg) assess_type="install" ;;
        *.dmg) assess_type="open" ;;
        *.app)
            upload="${WORK}/${name%.app}.zip"
            lw_run ditto -c -k --sequesterRsrc --keepParent "${file}" "${upload}"
            assess_type="execute"
            ;;
        *.zip)
            staple_target=""
            ;;
        *) lw_die "Nicht unterstützter Dateityp: ${name} (erwartet .pkg, .dmg, .zip oder .app)." 64 ;;
    esac

    # Signatur vorab prüfen – unsignierte Dateien lehnt der Notardienst ohnehin ab.
    if [[ "${LW_DRY_RUN}" != "1" ]]; then
        case "${file}" in
            *.pkg)
                pkgutil --check-signature "${file}" >/dev/null 2>&1 \
                    || lw_die "${name} ist nicht signiert – DEVELOPER_ID_INSTALLER setzen und Scripts/make_pkg.sh erneut ausführen."
                ;;
            *.app)
                codesign --verify --deep --strict "${file}" \
                    || lw_die "Die Signatur von ${name} ist ungültig."
                if codesign -dv "${file}" 2>&1 | grep -q 'Signature=adhoc'; then
                    lw_die "${name} ist nur ad hoc signiert – DEVELOPER_ID_APP setzen und Scripts/build_app.sh erneut ausführen."
                fi
                ;;
        esac
    fi

    result="${WORK}/result.json"
    lw_info "Einreichen und auf das Ergebnis warten (bis ${TIMEOUT}) …"
    if [[ "${LW_DRY_RUN}" == "1" ]]; then
        notary submit "${upload}" ${AUTH[@]+"${AUTH[@]}"} --wait --timeout "${TIMEOUT}" --output-format json
        continue
    fi
    set +e
    notary submit "${upload}" ${AUTH[@]+"${AUTH[@]}"} --wait --timeout "${TIMEOUT}" --output-format json > "${result}"
    submit_status=$?
    set -e
    submission_id="$(plutil -extract id raw -o - "${result}" 2>/dev/null || true)"
    status="$(plutil -extract status raw -o - "${result}" 2>/dev/null || true)"
    lw_info "Einreichung ${submission_id:-?}: ${status:-unbekannt}"

    if [[ "${status}" != "Accepted" ]]; then
        if [[ -n "${submission_id}" ]]; then
            lw_warn "Prüfprotokoll des Notardienstes:"
            notary log "${submission_id}" ${AUTH[@]+"${AUTH[@]}"} "${WORK}/log.json" >/dev/null 2>&1 || true
            if [[ -f "${WORK}/log.json" ]]; then
                sed 's/^/    /' "${WORK}/log.json" >&2
            fi
        else
            sed 's/^/    /' "${result}" >&2 || true
        fi
        lw_die "Notarisierung von ${name} fehlgeschlagen (Status: ${status:-unbekannt}, Exitcode ${submit_status})."
    fi
    lw_ok "von Apple akzeptiert"

    if [[ "${STAPLE}" == "1" && -n "${staple_target}" ]]; then
        lw_run xcrun stapler staple "${staple_target}"
        lw_run xcrun stapler validate "${staple_target}"
        lw_ok "Ticket angeheftet"
    fi
    if [[ -n "${assess_type}" ]]; then
        if spctl --assess --type "${assess_type}" --verbose=2 "${staple_target:-${file}}" 2>&1 | sed 's/^/    /'; then
            lw_ok "Gatekeeper akzeptiert ${name}"
        else
            lw_die "Gatekeeper lehnt ${name} trotz Notarisierung ab."
        fi
    fi
    if [[ "${file}" == *.pkg && -f "${file}.sha256" ]]; then
        # Durch das Anheften ändert sich die Prüfsumme.
        (cd "$(dirname "${file}")" && shasum -a 256 "${name}" > "${name}.sha256")
        lw_info "SHA-256 aktualisiert: $(cut -d ' ' -f 1 "${file}.sha256")"
    fi
done

lw_step "Fertig"
if [[ "${LW_DRY_RUN}" == "1" ]]; then
    lw_ok "Probelauf beendet – es wurde nichts eingereicht."
else
    lw_ok "${#FILES[@]} Datei(en) notarisiert."
fi
