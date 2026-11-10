import Foundation

/// Bausteine für die Installation eines geladenen Update-Pakets auf macOS – reine Funktionen
/// (Befehle als Text bzw. Argumentliste), damit die Maskierung testbar ist. Ausgeführt werden sie
/// von der App:
///
/// 1. ``shellCommand(pkg:expectedSHA256:)`` – `installer`; die Ausgaben kommen über `osascript`
///    zurück, das Protokoll schreibt die App selbst (``installLog(stdout:stderr:status:)``),
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

    /// Shell-Befehl (für `/bin/sh`, läuft als root), der das Paket mit
    /// `/usr/sbin/installer -pkg '<Paket>' -target /` installiert.
    ///
    /// Die Ausgaben sammelt der Befehl in einem nur für root zugänglichen Ordner (`mktemp -d`) und
    /// gibt sie am Ende aus – bei Erfolg auf stdout (Ergebnis von `do shell script`), sonst auf
    /// stderr (Fehlermeldung von `do shell script`, endet mit „(Exit-Code)“). Er öffnet **nie** eine
    /// Datei im Benutzerordner zum Schreiben: Als root folgte die Shell einem dort untergeschobenen
    /// symbolischen Link und überschriebe z. B. Systemdateien. Das Protokoll schreibt die App als
    /// Benutzer (``installLog(stdout:stderr:status:)``).
    ///
    /// Mit `expectedSHA256` wird das Paket zuerst in diesen Ordner kopiert, die Kopie geprüft
    /// (`shasum`, sonst `openssl dgst`) und erst dann installiert – so kann die Datei zwischen
    /// Prüfung und Installation nicht ausgetauscht werden. Exit-Code 1: kein privater Ordner,
    /// 2: Kopieren fehlgeschlagen, 3: Prüfsumme falsch, sonst der von `installer`.
    public static func shellCommand(pkg: URL, expectedSHA256: String? = nil) -> String {
        shellCommand(pkg: pkg, expectedSHA256: expectedSHA256, tools: .macOS)
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
    /// Passwortdialog abgebrochen wurde. Geprüft wird nur das Ende der Fehlermeldung – davor kann
    /// die Ausgabe von `installer` stehen.
    public static func isUserCancellation(_ osascriptError: String) -> Bool {
        osascriptError.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("(-128)")
    }

    /// Text für das Installationsprotokoll aus dem Ergebnis von `osascript`: bei Erfolg (`status`
    /// 0) die Ausgabe von `do shell script` (stdout), sonst dessen Fehlermeldung (stderr) ohne
    /// „0:123: execution error: “ vorn und „ (Exit-Code)“ hinten. `do shell script` liefert
    /// Zeilenenden als `\r` – sie werden zu `\n`.
    public static func installLog(stdout: String, stderr: String, status: Int32) -> String {
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard status != 0 else { return normalized(stdout) }
        var text = normalized(stderr)
        let marker = "execution error: "
        if let range = text.range(of: marker),
           text[..<range.lowerBound].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ":" || $0 == " ") }) {
            text = String(text[range.upperBound...])
        }
        if text.hasSuffix(")"), let open = text.lastIndex(of: "("),
           Int(text[text.index(after: open)..<text.index(before: text.endIndex)]) != nil {
            text = String(text[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? normalized(stdout) : text
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
        var cat: String
        var remove: String
        var shasum: String
        var openssl: String
        var awk: String

        static let macOS = Tools(installer: UpdateInstaller.installerPath, mktemp: "/usr/bin/mktemp",
                                 temporaryBase: "/private/tmp", copy: "/bin/cp", cat: "/bin/cat", remove: "/bin/rm",
                                 shasum: "/usr/bin/shasum", openssl: "/usr/bin/openssl", awk: "/usr/bin/awk")
    }

    static func shellCommand(pkg: URL, expectedSHA256: String?, tools: Tools) -> String {
        let pkgPath = shellQuote(pkg.path)
        let template = shellQuote(tools.temporaryBase + "/labelwerk-update.XXXXXX")
        let install: String
        if let expected = expectedSHA256?.lowercased(),
           expected.count == 64, expected.allSatisfy(\.isASCIIHexDigit) {
            let mismatch = shellQuote("LabelWerk: Die SHA-256-Prüfsumme der Update-Datei stimmt nicht.")
            install = "p=\"$d/update.pkg\"; "
                + "if \(tools.copy) \(pkgPath) \"$p\"; then "
                + "h=$(\(tools.shasum) -a 256 \"$p\" 2>/dev/null | \(tools.awk) '{print $1}'); "
                + "[ -n \"$h\" ] || h=$(\(tools.openssl) dgst -sha256 \"$p\" | \(tools.awk) '{print $NF}'); "
                + "if [ \"$h\" = '\(expected)' ]; then "
                + "\(tools.installer) -pkg \"$p\" -target /; s=$?; "
                + "else echo \(mismatch); s=3; fi; "
                + "else s=2; fi"
        } else {
            install = "\(tools.installer) -pkg \(pkgPath) -target /; s=$?"
        }
        // stdout/stderr von `do shell script` merken (3, 4), Ausgaben im privaten Ordner sammeln,
        // danach zurückschalten und das Protokoll je nach Ergebnis auf stdout bzw. stderr ausgeben.
        return [
            "exec 3>&1 4>&2",
            "d=$(\(tools.mktemp) -d \(template)) || exit 1",
            "exec > \"$d/install.log\" 2>&1",
            install,
            "exec 1>&3 2>&4 3>&- 4>&-",
            "if [ \"$s\" -eq 0 ]; then \(tools.cat) \"$d/install.log\"; else \(tools.cat) \"$d/install.log\" >&2; fi",
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
