# shellcheck shell=bash
# shellcheck disable=SC1111  # Deutsche Anführungszeichen („…“) in Meldungen sind beabsichtigt.
#
# LabelWerk – gemeinsame Hilfsfunktionen für die Build-, Paket- und CI-Skripte.
#
# Wird mit `source` eingebunden (nicht direkt ausführen). Erwartet, dass das aufrufende Skript
# bereits `set -euo pipefail` gesetzt hat. Alle Funktionen tragen das Präfix `lw_`, alle
# globalen Variablen das Präfix `LW_`.

if [[ -n "${LW_COMMON_LOADED:-}" ]]; then
    return 0
fi
LW_COMMON_LOADED=1

# Wurzel des Repositorys (zwei Ebenen über Installer/lib/).
LW_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export LW_REPO_ROOT

# 1 = Befehle nur anzeigen (gesetzt von --dry-run der Skripte).
LW_DRY_RUN="${LW_DRY_RUN:-0}"

# --- Ausgabe -------------------------------------------------------------------------------

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    LW_C_RESET=$'\033[0m'
    LW_C_BOLD=$'\033[1m'
    LW_C_DIM=$'\033[2m'
    LW_C_RED=$'\033[31m'
    LW_C_GREEN=$'\033[32m'
    LW_C_YELLOW=$'\033[33m'
    LW_C_VIOLET=$'\033[35m'
    LW_C_CYAN=$'\033[36m'
else
    LW_C_RESET='' LW_C_BOLD='' LW_C_DIM='' LW_C_RED='' LW_C_GREEN='' LW_C_YELLOW='' LW_C_VIOLET='' LW_C_CYAN=''
fi

# Überschrift eines Arbeitsschritts.
lw_step() {
    printf '\n%s==>%s %s%s%s\n' "${LW_C_VIOLET}${LW_C_BOLD}" "${LW_C_RESET}" "${LW_C_BOLD}" "$*" "${LW_C_RESET}" >&2
}

# Informationsmeldung.
lw_info() {
    printf '%s  •%s %s\n' "${LW_C_CYAN}" "${LW_C_RESET}" "$*" >&2
}

# Erfolgsmeldung.
lw_ok() {
    printf '%s  ✓%s %s\n' "${LW_C_GREEN}" "${LW_C_RESET}" "$*" >&2
}

# Warnung (Skript läuft weiter).
lw_warn() {
    printf '%s  ! Warnung:%s %s\n' "${LW_C_YELLOW}${LW_C_BOLD}" "${LW_C_RESET}" "$*" >&2
}

# Fehlermeldung und Abbruch mit Exitcode (Standard 1).
lw_die() {
    local message="$1"
    local code="${2:-1}"
    printf '%s  ✗ Fehler:%s %s\n' "${LW_C_RED}${LW_C_BOLD}" "${LW_C_RESET}" "${message}" >&2
    exit "${code}"
}

# Gibt einen Befehl lesbar (shell-maskiert) aus.
lw_print_command() {
    local rendered=""
    local arg
    for arg in "$@"; do
        rendered+=" $(printf '%q' "${arg}")"
    done
    printf '%s    $%s%s\n' "${LW_C_DIM}" "${rendered}" "${LW_C_RESET}" >&2
}

# Führt einen Befehl aus – bzw. zeigt ihn im Probelauf (--dry-run) nur an.
lw_run() {
    lw_print_command "$@"
    if [[ "${LW_DRY_RUN}" == "1" ]]; then
        return 0
    fi
    "$@"
}

# --- Plattform -----------------------------------------------------------------------------

lw_is_macos() {
    [[ "$(uname -s)" == "Darwin" ]]
}

# Bricht auf anderen Systemen als macOS mit einer verständlichen Meldung ab – außer im Probelauf.
# $1: Beschreibung dessen, was macOS erfordert.
lw_require_macos() {
    local what="$1"
    if lw_is_macos; then
        return 0
    fi
    if [[ "${LW_DRY_RUN}" == "1" ]]; then
        lw_warn "${what} erfordert macOS – Probelauf auf $(uname -s): Befehle werden nur angezeigt."
        return 0
    fi
    lw_die "${what} erfordert macOS (dieses System: $(uname -s)). Mit --dry-run lassen sich die Schritte anzeigen." 2
}

# Prüft, ob ein Programm vorhanden ist (im Probelauf nur Warnung).
# $1: Programmname, $2: Hinweis zur Installation.
lw_require_tool() {
    local tool="$1"
    local hint="${2:-}"
    if command -v "${tool}" >/dev/null 2>&1; then
        return 0
    fi
    if [[ "${LW_DRY_RUN}" == "1" ]]; then
        lw_warn "„${tool}“ fehlt – im Probelauf ignoriert.${hint:+ ${hint}}"
        return 0
    fi
    lw_die "„${tool}“ wurde nicht gefunden.${hint:+ ${hint}}"
}

# Prüft, ob eine benötigte Datei vorhanden ist (im Probelauf nur Warnung).
# $1: Pfad, $2: Beschreibung, $3: Hinweis zur Abhilfe (optional).
lw_require_file() {
    local path="$1"
    local what="$2"
    local hint="${3:-}"
    if [[ -e "${path}" ]]; then
        return 0
    fi
    if [[ "${LW_DRY_RUN}" == "1" ]]; then
        lw_warn "${what} fehlt: ${path} – im Probelauf ignoriert.${hint:+ ${hint}}"
        return 0
    fi
    lw_die "${what} fehlt: ${path}${hint:+ – ${hint}}"
}

# --- Konfiguration -------------------------------------------------------------------------

LW_CONFIG_FILE="${LW_CONFIG_FILE:-${LW_REPO_ROOT}/Installer/config.env}"
LW_CONFIG_KEYS=(APP_NAME BUNDLE_ID VERSION BUILD COPYRIGHT_YEAR TEAM_ID DEVELOPER_ID_APP DEVELOPER_ID_INSTALLER)

# Liest Installer/config.env. Bereits gesetzte Umgebungsvariablen haben Vorrang.
# Die Datei wird bewusst nicht mit `source` ausgeführt, sondern zeilenweise geparst.
# Kompatibel mit der Bash 3.2 von macOS (keine assoziativen Arrays, keine ${x,,} …).
lw_load_config() {
    [[ -f "${LW_CONFIG_FILE}" ]] || lw_die "Konfigurationsdatei fehlt: ${LW_CONFIG_FILE}"
    local line key value lineno=0
    local re_skip='^[[:space:]]*(#|$)'
    local re_assign='^([A-Z][A-Z0-9_]*)=(.*)$'
    local re_dquoted='^"(.*)"$'
    local re_squoted="^'(.*)'\$"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        [[ "${line}" =~ ${re_skip} ]] && continue
        if [[ ! "${line}" =~ ${re_assign} ]]; then
            lw_die "${LW_CONFIG_FILE}:${lineno}: ungültige Zeile „${line}“ (erwartet SCHLÜSSEL=Wert)."
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if [[ "${value}" =~ ${re_dquoted} ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "${value}" =~ ${re_squoted} ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        # Umgebung hat Vorrang (auch eine bewusst leer gesetzte Variable).
        if ! declare -p "${key}" >/dev/null 2>&1; then
            printf -v "${key}" '%s' "${value}"
        fi
        export "${key?}"
    done < "${LW_CONFIG_FILE}"

    for key in "${LW_CONFIG_KEYS[@]}"; do
        if ! declare -p "${key}" >/dev/null 2>&1; then
            printf -v "${key}" '%s' ""
        fi
        export "${key?}"
    done
    for key in APP_NAME BUNDLE_ID VERSION BUILD; do
        [[ -n "${!key}" ]] || lw_die "${key} ist in ${LW_CONFIG_FILE} nicht gesetzt."
    done

    local re_version='^[0-9]+(\.[0-9]+){1,2}$'
    local re_build='^[0-9]+(\.[0-9]+){0,2}$'
    local re_bundle='^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
    local re_name='^[A-Za-z0-9][A-Za-z0-9 ._-]*$'
    local re_year='^[0-9]{4}$'
    [[ "${VERSION}" =~ ${re_version} ]] \
        || lw_die "VERSION „${VERSION}“ ist ungültig (erwartet z. B. 1.0.0)."
    [[ "${BUILD}" =~ ${re_build} ]] \
        || lw_die "BUILD „${BUILD}“ ist ungültig (erwartet eine Zahl, z. B. 42)."
    [[ "${BUNDLE_ID}" =~ ${re_bundle} ]] \
        || lw_die "BUNDLE_ID „${BUNDLE_ID}“ ist ungültig (erwartet z. B. com.firma.app)."
    [[ "${APP_NAME}" =~ ${re_name} ]] \
        || lw_die "APP_NAME „${APP_NAME}“ enthält unzulässige Zeichen."
    if [[ -z "${COPYRIGHT_YEAR}" ]]; then
        COPYRIGHT_YEAR="$(date +%Y)"
    fi
    [[ "${COPYRIGHT_YEAR}" =~ ${re_year} ]] \
        || lw_die "COPYRIGHT_YEAR „${COPYRIGHT_YEAR}“ ist ungültig (erwartet eine Jahreszahl)."

    # Abgeleitete Kennungen der Paketkomponenten.
    LW_PKG_ID_APP="${BUNDLE_ID}.pkg"
    LW_PKG_ID_DRIVER="${BUNDLE_ID}.driver"
    LW_PKG_ID_CLI="${BUNDLE_ID}.cli"
    export COPYRIGHT_YEAR LW_PKG_ID_APP LW_PKG_ID_DRIVER LW_PKG_ID_CLI
}

# Ersetzt @SCHLÜSSEL@-Platzhalter einer Vorlage (APP_NAME, BUNDLE_ID, VERSION, BUILD,
# COPYRIGHT_YEAR, LW_PKG_ID_APP, LW_PKG_ID_DRIVER, LW_PKG_ID_CLI) wörtlich und schreibt das Ergebnis.
# $1: Vorlage, $2: Ziel. Bricht ab, wenn danach noch Platzhalter übrig sind.
lw_render_template() {
    local template="$1"
    local destination="$2"
    [[ -f "${template}" ]] || lw_die "Vorlage fehlt: ${template}"
    # awk mit index()/substr() ersetzt wörtlich (keine Sonderbedeutung von & oder \ im Wert).
    LWT_APP_NAME="${APP_NAME}" LWT_BUNDLE_ID="${BUNDLE_ID}" LWT_VERSION="${VERSION}" \
    LWT_BUILD="${BUILD}" LWT_COPYRIGHT_YEAR="${COPYRIGHT_YEAR}" \
    LWT_LW_PKG_ID_APP="${LW_PKG_ID_APP}" LWT_LW_PKG_ID_DRIVER="${LW_PKG_ID_DRIVER}" \
    LWT_LW_PKG_ID_CLI="${LW_PKG_ID_CLI}" \
    awk '
        function replace_all(text, needle, replacement,    result, position) {
            result = ""
            while ((position = index(text, needle)) > 0) {
                result = result substr(text, 1, position - 1) replacement
                text = substr(text, position + length(needle))
            }
            return result text
        }
        BEGIN {
            count = split("APP_NAME BUNDLE_ID VERSION BUILD COPYRIGHT_YEAR LW_PKG_ID_APP LW_PKG_ID_DRIVER LW_PKG_ID_CLI", keys, " ")
        }
        {
            line = $0
            for (i = 1; i <= count; i++) {
                line = replace_all(line, "@" keys[i] "@", ENVIRON["LWT_" keys[i]])
            }
            print line
        }
    ' "${template}" > "${destination}"
    local leftover
    leftover="$(grep -oE '@[A-Z][A-Z0-9_]*@' "${destination}" | head -n 1 || true)"
    if [[ -n "${leftover}" ]]; then
        lw_die "Unbekannter Platzhalter ${leftover} in ${template}."
    fi
}

# Signaturidentität der App: DEVELOPER_ID_APP oder „-“ (ad hoc).
lw_app_identity() {
    if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
        printf '%s' "${DEVELOPER_ID_APP}"
    else
        printf '%s' "-"
    fi
}

# Signiert eine Datei bzw. ein Bundle mit gehärteter Laufzeitumgebung.
# $1: Pfad, $2: Kennung (leer = von codesign ableiten), weitere Argumente gehen an codesign.
lw_codesign() {
    local path="$1"
    local identifier="$2"
    shift 2
    local identity
    identity="$(lw_app_identity)"
    local args=(--force --sign "${identity}" --options runtime)
    if [[ "${identity}" == "-" ]]; then
        args+=(--timestamp=none)
    else
        args+=(--timestamp)
    fi
    if [[ -n "${identifier}" ]]; then
        args+=(--identifier "${identifier}")
    fi
    lw_run codesign "${args[@]}" "$@" "${path}"
}

# Prüft, ob eine Datei ein Mach-O-Programm ist (nur macOS, sonst „falsch“).
lw_is_macho() {
    local path="$1"
    [[ -f "${path}" ]] || return 1
    command -v file >/dev/null 2>&1 || return 1
    file -b "${path}" | grep -q 'Mach-O'
}

# Menschlich lesbare Größe einer Datei/eines Verzeichnisses.
lw_human_size() {
    du -sh "$1" 2>/dev/null | cut -f1
}

# --- CI (GitHub Actions) ---------------------------------------------------------------------

# 1 = Ausgabe für GitHub Actions (Gruppen, Anmerkungen).
lw_in_github_actions() {
    [[ "${GITHUB_ACTIONS:-}" == "true" ]]
}

# Beginnt eine einklappbare Gruppe im CI-Protokoll (sonst eine normale Schrittüberschrift).
lw_ci_group() {
    if lw_in_github_actions; then
        printf '::group::%s\n' "$*"
    else
        lw_step "$*"
    fi
}

# Beendet eine mit lw_ci_group begonnene Gruppe.
lw_ci_endgroup() {
    if lw_in_github_actions; then
        printf '::endgroup::\n'
    fi
}

# Warnung, die in GitHub Actions zusätzlich als Anmerkung am Lauf erscheint.
lw_ci_warning() {
    if lw_in_github_actions; then
        printf '::warning title=LabelWerk::%s\n' "$*"
    fi
    lw_warn "$*"
}

# Fehlermeldung als Anmerkung (ohne Abbruch).
lw_ci_error() {
    if lw_in_github_actions; then
        printf '::error title=LabelWerk::%s\n' "$*"
    fi
    printf '%s  ✗ Fehler:%s %s\n' "${LW_C_RED}${LW_C_BOLD}" "${LW_C_RESET}" "$*" >&2
}

# Fügt ein Verzeichnis dem PATH hinzu – in GitHub Actions auch für alle folgenden Schritte.
lw_ci_add_path() {
    local directory="$1"
    PATH="${directory}:${PATH}"
    export PATH
    if lw_in_github_actions && [[ -n "${GITHUB_PATH:-}" ]]; then
        printf '%s\n' "${directory}" >> "${GITHUB_PATH}"
    fi
}

# Anzahl paralleler Jobs: LW_JOBS, sonst alle Prozessorkerne.
lw_jobs() {
    if [[ -n "${LW_JOBS:-}" ]]; then
        printf '%s' "${LW_JOBS}"
    elif command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.ncpu
    else
        printf '2'
    fi
}

# Führt einen benannten CI-Schritt aus, misst die Dauer und meldet das Ergebnis.
# $1: Name, $2: Funktionsname, weitere Argumente gehen an die Funktion.
#
# Der Schritt läuft in einer Subshell mit aktivem `set -e`: Jeder fehlschlagende Befehl beendet
# den Schritt (ein Aufruf in einem `||`-Kontext würde `set -e` für die ganze Funktion abschalten).
# Änderungen an Variablen (z. B. PATH) wirken deshalb nicht über den Schritt hinaus.
lw_ci_run_step() {
    local name="$1"
    local function="$2"
    shift 2
    local started status=0
    started="$(date +%s)"
    lw_ci_group "Schritt „${name}“"
    set +e
    (
        set -euo pipefail
        "${function}" "$@"
    )
    status=$?
    set -e
    lw_ci_endgroup
    local elapsed=$(( $(date +%s) - started ))
    if [[ "${status}" -eq 0 ]]; then
        lw_ok "Schritt „${name}“ erfolgreich (${elapsed} s)"
    else
        lw_ci_error "Schritt „${name}“ fehlgeschlagen (Exitcode ${status}, ${elapsed} s)"
    fi
    return "${status}"
}
