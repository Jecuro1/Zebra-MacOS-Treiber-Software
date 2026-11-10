import Foundation

/// Bausteine für die Installation eines geladenen Update-Pakets auf macOS – reine Funktionen
/// (Befehle als Text bzw. Argumentliste), damit die Maskierung testbar ist. Ausgeführt werden sie
/// von der App:
///
/// 1. ``shellCommand(pkg:logFile:expectedSHA256:)`` – `installer` mit Ausgabe ins Protokoll,
/// 2. ``appleScript(shellCommand:prompt:)`` – über `osascript -e` mit Administratorrechten
///    (macOS fragt nach dem Passwort; Abbruch erkennt ``isUserCancellation(_:)``),
/// 3. ``relaunchCommand(waitingFor:appPath:)`` – losgelöster Prozess, der nach dem Beenden der
///    alten App die neue startet.
public enum UpdateInstaller {

    /// Pfad des macOS-Installationsprogramms.
    public static let installerPath = "/usr/sbin/installer"
    /// Pfad von `osascript`.
    public static let osascriptPath = "/usr/bin/osascript"
    /// Pfad von `open`.
    public static let openPath = "/usr/bin/open"

    /// Shell-Befehl (für `/bin/sh`), der das Paket installiert und alle Ausgaben in `logFile`
    /// schreibt: `/usr/sbin/installer -pkg '<Paket>' -target / > '<Protokoll>' 2>&1`.
    ///
    /// Mit `expectedSHA256` wird das Paket zuerst in ein nur für root beschreibbares
    /// Verzeichnis kopiert, die Kopie geprüft (`shasum`, sonst `openssl dgst`) und erst dann
    /// installiert – so kann die Datei zwischen Prüfung und Installation nicht ausgetauscht
    /// werden. Exit-Code 2: Kopieren fehlgeschlagen, 3: Prüfsumme falsch, sonst der von `installer`.
    public static func shellCommand(pkg: URL, logFile: URL, expectedSHA256: String? = nil) -> String {
        shellCommand(pkg: pkg, logFile: logFile, expectedSHA256: expectedSHA256, tools: .macOS)
    }

    /// AppleScript-Quelltext, der `shellCommand` mit Administratorrechten ausführt:
    /// `do shell script "…" with prompt "…" with administrator privileges`.
    public static func appleScript(shellCommand: String, prompt: String) -> String {
        "do shell script \(appleScriptLiteral(shellCommand)) with prompt \(appleScriptLiteral(prompt))"
            + " with administrator privileges"
    }

    /// Argumentliste (`/bin/sh -c …`) für einen losgelösten Prozess, der wartet, bis der Prozess
    /// `pid` beendet ist (höchstens zwei Minuten), und dann `appPath` mit `/usr/bin/open` startet.
    public static func relaunchCommand(waitingFor pid: Int32, appPath: String) -> [String] {
        relaunchCommand(waitingFor: pid, appPath: appPath, openPath: openPath)
    }

    /// `true`, wenn `osascript` mit „Benutzer hat abgebrochen“ (-128) endete, z. B. weil der
    /// Passwortdialog abgebrochen wurde.
    public static func isUserCancellation(_ osascriptOutput: String) -> Bool {
        osascriptOutput.contains("(-128)")
    }

    // MARK: - Maskierung

    /// Maskiert ein Argument für `/bin/sh` in einfachen Anführungszeichen (`'` → `'\''`).
    public static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript-Stringliteral einschließlich der Anführungszeichen (`\` → `\\`, `"` → `\"`,
    /// Zeilenumbrüche und Tabulatoren als `\n`, `\r`, `\t`).
    public static func appleScriptLiteral(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: - Intern (testbar mit anderen Werkzeugpfaden)

    /// Pfade der Werkzeuge im Installationsbefehl.
    struct Tools: Sendable {
        var installer: String
        var mktemp: String
        var temporaryBase: String
        var copy: String
        var remove: String
        var shasum: String
        var openssl: String
        var awk: String

        static let macOS = Tools(installer: UpdateInstaller.installerPath, mktemp: "/usr/bin/mktemp",
                                 temporaryBase: "/private/tmp", copy: "/bin/cp", remove: "/bin/rm",
                                 shasum: "/usr/bin/shasum", openssl: "/usr/bin/openssl", awk: "/usr/bin/awk")
    }

    static func shellCommand(pkg: URL, logFile: URL, expectedSHA256: String?, tools: Tools) -> String {
        let pkgPath = shellQuote(pkg.path)
        let logPath = shellQuote(logFile.path)
        guard let expected = expectedSHA256?.lowercased(),
              expected.count == 64, expected.allSatisfy(\.isASCIIHexDigit) else {
            return "\(tools.installer) -pkg \(pkgPath) -target / > \(logPath) 2>&1"
        }
        let template = shellQuote(tools.temporaryBase + "/labelwerk-update.XXXXXX")
        let mismatch = shellQuote("LabelWerk: Die SHA-256-Prüfsumme der Update-Datei stimmt nicht.")
        return [
            "exec > \(logPath) 2>&1",
            "d=$(\(tools.mktemp) -d \(template)) || exit 1",
            "p=\"$d/update.pkg\"",
            "if \(tools.copy) \(pkgPath) \"$p\"; then "
                + "h=$(\(tools.shasum) -a 256 \"$p\" 2>/dev/null | \(tools.awk) '{print $1}'); "
                + "[ -n \"$h\" ] || h=$(\(tools.openssl) dgst -sha256 \"$p\" | \(tools.awk) '{print $NF}'); "
                + "if [ \"$h\" = '\(expected)' ]; then "
                + "\(tools.installer) -pkg \"$p\" -target /; s=$?; "
                + "else echo \(mismatch); s=3; fi; "
                + "else s=2; fi",
            "\(tools.remove) -rf \"$d\"",
            "exit $s",
        ].joined(separator: "; ")
    }

    static func relaunchCommand(waitingFor pid: Int32, appPath: String, openPath: String) -> [String] {
        let script = "i=0; while kill -0 \(pid) 2>/dev/null && [ \"$i\" -lt 600 ]; do sleep 0.2; i=$((i+1)); done; "
            + "\(openPath) \(shellQuote(appPath))"
        return ["/bin/sh", "-c", script]
    }
}
