# shellcheck shell=bash
# shellcheck disable=SC1111  # Deutsche Anführungszeichen („…“) in Meldungen sind beabsichtigt.
#
# LabelWerk – Hilfsfunktionen für Updates: GitHub-Release der CI und Prüfung des Pakets
#
# Wird nach Installer/lib/common.sh mit `source` eingebunden (Scripts/ci_macos.sh, Tests) und
# erwartet geladene Konfiguration (lw_load_config). Kompatibel mit der Bash 3.2 von macOS.
#
# Ein Release je erfolgreichem macOS-CI-Lauf (siehe docs/DEVELOPMENT.md, „Updates“):
#
#   Tag     v<VERSION>-b<BUILD>                  z. B. v1.1.0-b58
#   Titel   <APP_NAME> <VERSION> (Build <BUILD>)  z. B. LabelWerk 1.1.0 (Build 58)
#   Dateien <APP_NAME>-<VERSION>-<BUILD>.pkg und labelwerk-update.json (Manifest, Schema 1)
#
# Die App liest das Manifest des neuesten Releases von UPDATE_REPOSITORY
# (…/releases/latest/download/labelwerk-update.json bzw. über die GitHub-API mit Token), vergleicht
# Version und Build-Nummer, lädt das Paket, prüft Größe und SHA-256 und installiert es.

if [[ -n "${LW_RELEASE_LOADED:-}" ]]; then
    return 0
fi
LW_RELEASE_LOADED=1

# Dateiname des Manifests im Release (fest – die App fragt genau diesen Namen ab).
# shellcheck disable=SC2034  # wird von Scripts/ci_macos.sh verwendet
LW_RELEASE_MANIFEST_NAME="labelwerk-update.json"
# Höchstzahl der Commit-Betreffzeilen in den Release-Notizen.
LW_RELEASE_MAX_NOTES="${LW_RELEASE_MAX_NOTES:-30}"

# Bricht ab, wenn BUILD keine ganze Zahl ist (Updates vergleichen Build-Nummern numerisch).
lw_release_require_build() {
    local re_integer='^[0-9]+$'
    [[ "${BUILD}" =~ ${re_integer} ]] \
        || lw_die "BUILD „${BUILD}“ ist für Updates ungeeignet – erwartet eine ganze Zahl (die CI nimmt die Laufnummer)."
}

# Tag des Releases: v<VERSION>-b<BUILD>.
lw_release_tag() {
    printf 'v%s-b%s' "${VERSION}" "${BUILD}"
}

# Titel des Releases: <APP_NAME> <VERSION> (Build <BUILD>).
lw_release_title() {
    printf '%s %s (Build %s)' "${APP_NAME}" "${VERSION}" "${BUILD}"
}

# Dateiname des Pakets im Release: <APP_NAME>-<VERSION>-<BUILD>.pkg (Leerzeichen → „-“, weil
# GitHub sie in Dateinamen von Release-Dateien ohnehin ersetzt).
lw_release_asset_name() {
    printf '%s-%s-%s.pkg' "${APP_NAME// /-}" "${VERSION}" "${BUILD}"
}

# Öffentliche Download-Adresse einer Release-Datei. $1: Tag, $2: Dateiname.
lw_release_download_url() {
    printf 'https://github.com/%s/releases/download/%s/%s' "${UPDATE_REPOSITORY}" "$1" "$2"
}

# Erfolg, wenn $1 und $2 dasselbe GitHub-Repository bezeichnen (Groß-/Kleinschreibung egal).
lw_release_same_repository() {
    local first second
    first="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    second="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
    [[ -n "${first}" && "${first}" == "${second}" ]]
}

# Erfolg, wenn Tag $1 eine neuere Version bezeichnet als Tag $2. Tags: v<Version>[-b<Build>]
# (Version: Zahlen mit Punkten, fehlender Build = 0). Verglichen wird wie in der App: Version
# Komponente für Komponente numerisch, dann die Build-Nummer. Ein nicht lesbarer Tag $1 ist nie
# neuer, ein nicht lesbarer Tag $2 immer älter.
lw_release_tag_is_newer() {
    local re='^v([0-9]+(\.[0-9]+)*)(-b([0-9]+))?$'
    local first_version first_build second_version second_build
    [[ "$1" =~ ${re} ]] || return 1
    first_version="${BASH_REMATCH[1]}"
    first_build="${BASH_REMATCH[4]:-0}"
    [[ "$2" =~ ${re} ]] || return 0
    second_version="${BASH_REMATCH[1]}"
    second_build="${BASH_REMATCH[4]:-0}"

    local first_parts=() second_parts=()
    IFS=. read -r -a first_parts <<< "${first_version}"
    IFS=. read -r -a second_parts <<< "${second_version}"
    local count="${#first_parts[@]}"
    if [[ "${#second_parts[@]}" -gt "${count}" ]]; then
        count="${#second_parts[@]}"
    fi
    local index=0 a b
    while [[ "${index}" -lt "${count}" ]]; do
        a="${first_parts[index]:-0}"
        b="${second_parts[index]:-0}"
        if (( 10#${a} > 10#${b} )); then
            return 0
        fi
        if (( 10#${a} < 10#${b} )); then
            return 1
        fi
        index=$((index + 1))
    done
    (( 10#${first_build} > 10#${second_build} ))
}

# Schreibt die Release-Notizen (Markdown) nach stdout: Überschrift „Änderungen“ und die
# Betreffzeilen der Commits seit dem vorherigen v*-Tag (ohne Merge-Commits, höchstens
# LW_RELEASE_MAX_NOTES, neueste zuerst). Gibt es keinen vorherigen Tag oder keine Commits seitdem,
# steht dort die Nachricht des Commits selbst (Betreff und Text, ohne Git-Trailer wie
# „Co-Authored-By:“). Der vorherige Tag wird ab dem Eltern-Commit gesucht, damit ein Tag auf dem
# Commit selbst (Tag-Push, erneuter Lauf) nicht als „vorheriger“ zählt.
# $1: Commit (Standard HEAD).
lw_release_notes() {
    local head="${1:-HEAD}"
    local git=(git -C "${LW_REPO_ROOT}")
    "${git[@]}" rev-parse --verify --quiet "${head}^{commit}" >/dev/null \
        || lw_die "Commit „${head}“ fehlt in ${LW_REPO_ROOT} – die Release-Notizen brauchen die Git-Historie."
    local previous="" subjects="" total=0 line
    previous="$("${git[@]}" describe --tags --abbrev=0 --match 'v*' "${head}^" 2>/dev/null || true)"
    if [[ -n "${previous}" ]]; then
        total="$("${git[@]}" rev-list --count --no-merges "${previous}..${head}")"
        subjects="$("${git[@]}" log --no-merges --format='%s' -n "${LW_RELEASE_MAX_NOTES}" "${previous}..${head}")"
    fi

    printf '## Änderungen\n\n'
    if [[ -n "${subjects}" ]]; then
        while IFS= read -r line; do
            if [[ -n "${line}" ]]; then
                printf -- '- %s\n' "${line}"
            fi
        done <<< "${subjects}"
        if [[ "$((total - LW_RELEASE_MAX_NOTES))" -eq 1 ]]; then
            printf -- '- … und eine weitere Änderung\n'
        elif [[ "${total}" -gt "${LW_RELEASE_MAX_NOTES}" ]]; then
            printf -- '- … und %d weitere Änderungen\n' "$((total - LW_RELEASE_MAX_NOTES))"
        fi
        return 0
    fi

    local subject body
    subject="$("${git[@]}" log -1 --format='%s' "${head}")"
    body="$("${git[@]}" log -1 --format='%b' "${head}" | lw_release_strip_trailers)"
    printf -- '- %s\n' "${subject}"
    if [[ -n "${body}" ]]; then
        printf '\n%s\n' "${body}"
    fi
}

# Filter: entfernt den letzten Absatz, wenn er nur aus Git-Trailern („Schlüssel: Wert“) besteht,
# sowie Leerzeilen am Anfang und Ende.
lw_release_strip_trailers() {
    awk '
        { lines[NR] = $0 }
        END {
            last = NR
            while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
            start = last
            while (start > 0 && lines[start] !~ /^[[:space:]]*$/) start--
            trailers = (last > start)
            for (i = start + 1; i <= last; i++) {
                if (lines[i] !~ /^[A-Za-z][A-Za-z0-9-]*: [^ ]/) trailers = 0
            }
            if (trailers) {
                last = start
                while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
            }
            first = 1
            while (first <= last && lines[first] ~ /^[[:space:]]*$/) first++
            for (i = first; i <= last; i++) print lines[i]
        }
    '
}

# Prüft die Info.plist der gebauten App gegen die Konfiguration (Bundle-ID, Version, Build,
# LWUpdateRepository) – damit kein veraltetes Bundle veröffentlicht wird. Plattformunabhängig.
# $1: Pfad der Info.plist.
lw_release_check_app_info() {
    "${PYTHON:-python3}" - "$1" "${BUNDLE_ID}" "${VERSION}" "${BUILD}" "${UPDATE_REPOSITORY:-}" <<'PY'
import plistlib
import sys

path, bundle_id, version, build, repository = sys.argv[1:6]
with open(path, "rb") as handle:
    info = plistlib.load(handle)
expected = {
    "CFBundleIdentifier": bundle_id,
    "CFBundleShortVersionString": version,
    "CFBundleVersion": build,
    "LWUpdateRepository": repository,
}
problems = [f"{key} ist {info.get(key)!r}, erwartet {value!r}"
            for key, value in expected.items() if info.get(key) != value]
if problems:
    print(f"  ✗ Fehler: Die gebaute App passt nicht zur Konfiguration ({path}): " + "; ".join(problems)
          + " – App und Paket neu bauen.", file=sys.stderr)
    sys.exit(1)
PY
}

# Schreibt das Update-Manifest (labelwerk-update.json, Schema 1):
#   {"schema":1,"version":"1.1.0","build":58,"tag":"v1.1.0-b58",
#    "pkg":{"name":"LabelWerk-1.1.0-58.pkg","url":"https://github.com/<repo>/releases/download/<tag>/<name>",
#           "size":<Bytes>,"sha256":"<hex>"},
#    "minimumSystemVersion":"14.0","publishedAt":"2026-11-10T12:00:00Z","notes":"<Markdown>"}
# Größe und SHA-256 stammen aus der Paketdatei, die Mindestversion aus der Info.plist der App,
# der Zeitpunkt aus SOURCE_DATE_EPOCH (falls gesetzt) bzw. der aktuellen Uhrzeit (UTC).
# $1: Paket (Dateiname = Name im Release), $2: Info.plist, $3: Notizen (Markdown), $4: Ziel.
lw_release_write_manifest() {
    lw_release_require_build
    [[ -n "${UPDATE_REPOSITORY:-}" ]] || lw_die "UPDATE_REPOSITORY ist leer – kein Update-Manifest möglich."
    local package="$1" info="$2" notes="$3" target="$4"
    local tag name url
    tag="$(lw_release_tag)"
    name="$(basename "${package}")"
    url="$(lw_release_download_url "${tag}" "${name}")"
    "${PYTHON:-python3}" - "${package}" "${info}" "${notes}" "${target}" "${VERSION}" "${BUILD}" "${tag}" \
        "${name}" "${url}" <<'PY'
import datetime
import hashlib
import json
import os
import plistlib
import re
import sys

package, info_path, notes_path, target, version, build, tag, name, url = sys.argv[1:10]


def fail(message):
    print(f"  ✗ Fehler: {message}", file=sys.stderr)
    sys.exit(1)


if not re.fullmatch(r"[0-9]+(\.[0-9]+){1,2}", version):
    fail(f"Version {version!r} ist ungültig.")
if not re.fullmatch(r"[0-9]+", build):
    fail(f"Build-Nummer {build!r} ist keine ganze Zahl.")
if not url.startswith("https://github.com/"):
    fail(f"Download-Adresse {url!r} liegt nicht auf github.com.")
with open(info_path, "rb") as handle:
    minimum = plistlib.load(handle).get("LSMinimumSystemVersion")
if not isinstance(minimum, str) or not re.fullmatch(r"[0-9]+(\.[0-9]+){0,2}", minimum):
    fail(f"LSMinimumSystemVersion {minimum!r} in {info_path} ist ungültig.")

digest = hashlib.sha256()
size = 0
with open(package, "rb") as handle:
    for chunk in iter(lambda: handle.read(1 << 20), b""):
        digest.update(chunk)
        size += len(chunk)
if size == 0:
    fail(f"Paket {package} ist leer.")

with open(notes_path, encoding="utf-8") as handle:
    notes = handle.read().strip() + "\n"

epoch = os.environ.get("SOURCE_DATE_EPOCH", "").strip()
moment = (datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc) if epoch.isdigit()
          else datetime.datetime.now(datetime.timezone.utc))

manifest = {
    "schema": 1,
    "version": version,
    "build": int(build),
    "tag": tag,
    "pkg": {"name": name, "url": url, "size": size, "sha256": digest.hexdigest()},
    "minimumSystemVersion": minimum,
    "publishedAt": moment.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "notes": notes,
}
with open(target, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
print(f"  ✓ {os.path.basename(target)}: {tag}, {name} ({size} Bytes, SHA-256 {digest.hexdigest()})",
      file=sys.stderr)
PY
}

# Liest ein Feld aus einem Manifest (Punktpfad, z. B. pkg.sha256) und gibt es aus.
# $1: Manifest, $2: Feld.
lw_release_manifest_field() {
    "${PYTHON:-python3}" - "$1" "$2" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
for key in sys.argv[2].split("."):
    value = value[key]
print(value)
PY
}

# Prüft die PackageInfo der App-Komponente eines (mit pkgutil --expand[-full] entpackten) Pakets:
#   * Ziel /Applications, Bundle <APP_NAME>.app mit BUNDLE_ID, VERSION und BUILD,
#   * nicht verschiebbar (nicht unter <relocate>): Der Installer ersetzt immer /Applications/…app,
#     nie eine andere Kopie der App (z. B. im Downloads- oder Build-Ordner),
#   * BundleOverwriteAction „upgrade“ (unter <upgrade-bundle>): Das alte Bundle wird ersetzt,
#   * Versionsprüfung (unter <bundle-version>, BundleIsVersionChecked): Der Installer vergleicht
#     CFBundleShortVersionString, dann CFBundleVersion – ein Update mit gleicher Marketing-Version
#     und höherer Build-Nummer ersetzt die installierte App, ein älteres Paket nicht.
# $1: Pfad der PackageInfo-Datei.
lw_check_app_package_info() {
    "${PYTHON:-python3}" - "$1" "${BUNDLE_ID}" "${VERSION}" "${BUILD}" "${APP_NAME}" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, bundle_id, version, build, app_name = sys.argv[1:6]
root = ET.parse(path).getroot()
problems = []


def bundle_ids(tag):
    element = root.find(tag)
    return [] if element is None else [bundle.get("id") for bundle in element.iter("bundle")]


if root.tag != "pkg-info":
    problems.append(f"Wurzelelement {root.tag!r} statt pkg-info")
location = root.get("install-location")
if location != "/Applications":
    problems.append(f"Installationsort {location!r} statt /Applications")
bundles = [bundle for bundle in root.findall("bundle") if bundle.get("id") == bundle_id]
if not bundles:
    problems.append(f"Bundle {bundle_id} fehlt")
else:
    bundle = bundles[0]
    bundle_path = bundle.get("path", "")
    if (bundle_path[2:] if bundle_path.startswith("./") else bundle_path) != f"{app_name}.app":
        problems.append(f"Pfad {bundle_path!r} statt ./{app_name}.app")
    if bundle.get("CFBundleShortVersionString") != version:
        problems.append(f"CFBundleShortVersionString {bundle.get('CFBundleShortVersionString')!r} statt {version!r}")
    if bundle.get("CFBundleVersion") != build:
        problems.append(f"CFBundleVersion {bundle.get('CFBundleVersion')!r} statt {build!r}")
if bundle_id in bundle_ids("relocate"):
    problems.append("die App ist verschiebbar (BundleIsRelocatable) – ein Update könnte statt "
                    "/Applications eine andere Kopie der App ersetzen")
if bundle_id not in bundle_ids("upgrade-bundle"):
    problems.append("BundleOverwriteAction ist nicht „upgrade“")
if bundle_id not in bundle_ids("bundle-version"):
    problems.append("Versionsprüfung (BundleIsVersionChecked) fehlt")
if problems:
    print("  ✗ Fehler: App-Komponente ungeeignet für Updates: " + "; ".join(problems), file=sys.stderr)
    sys.exit(1)
print(f"  ✓ App-Komponente: /Applications/{app_name}.app ({bundle_id} {version}, Build {build}), "
      "nicht verschiebbar, ersetzt das alte Bundle (upgrade), Versionsprüfung lässt jede höhere "
      "Build-Nummer bei gleicher Version zu", file=sys.stderr)
PY
}
