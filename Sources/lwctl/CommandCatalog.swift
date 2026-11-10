import Foundation
import LabelWerkKit

/// Alle Befehle von `lwctl` mit deutschen Hilfetexten.
enum CommandCatalog {

    /// Globale Optionen (vor oder nach dem Befehl).
    static let globalOptions: [OptionSpec] = [
        OptionSpec("printer", short: "p", value: "uri",
                   "Drucker: tcp://host[:port], usb://vid:pid[/seriennummer], cups://warteschlange, virtual://demo (Standard: Umgebungsvariable LWCTL_PRINTER)"),
        OptionSpec("language", short: "l", value: "zpl|epl|cpcl", "Druckersprache (Standard: zpl)"),
        OptionSpec("timeout", short: "t", value: "sekunden", "Wartezeit auf Antworten (Standard: 3; bei discover: Suchdauer, Standard 6)"),
        OptionSpec("json", "Ausgabe als JSON (status, info, discover, install, queues, uninstall-queue, models, stocks, settings, config, files, network)"),
        OptionSpec("help", short: "h", "Hilfe anzeigen"),
        OptionSpec("version", short: "V", "Version anzeigen"),
    ]

    static let imageOptions: [OptionSpec] = [
        OptionSpec("stock", short: "s", value: "id", "Etikettenformat (lwctl stocks), Standard: Format des Modells bzw. w4h6in"),
        OptionSpec("dpi", value: "152|203|300|600", "Auflösung (Standard: vom Drucker bzw. 203)"),
        OptionSpec("model", short: "m", value: "id", "Druckermodell (begrenzt die Druckbreite), Standard: vom Drucker erkannt"),
        OptionSpec("dither", short: "d", value: "verfahren", "threshold, ordered, halftone, floydSteinberg, atkinson, stucki (Standard: threshold)"),
        OptionSpec("threshold", value: "1…254", "Schwelle der Rasterung (Standard: 128)"),
        OptionSpec("fit", value: "contain|cover|stretch|none", "Einpassen ins Etikett (Standard: contain)"),
        OptionSpec("rotate", short: "r", value: "0|90|180|270|auto", "Bild vor dem Einpassen drehen (Standard: 0)"),
        OptionSpec("copies", short: "c", value: "anzahl", "Kopien je Etikett (Standard: 1)"),
        OptionSpec("compression", value: "z64|acs|hex", "Grafikkompression bei ZPL (Standard: z64)"),
        OptionSpec("darkness", value: "0…30", "Schwärzung (~SD), Standard: Druckereinstellung"),
        OptionSpec("speed", value: "1…14", "Geschwindigkeit in Zoll/s (^PR), Standard: Druckereinstellung"),
        OptionSpec("negative", "Negativ drucken"),
        OptionSpec("mirror", "Spiegeln"),
        OptionSpec("rotate180", "Um 180° gedreht drucken (^POI)"),
        OptionSpec("no-layout", "Bild unverändert übernehmen: nicht drehen, nicht einpassen, Etikett so groß wie das Bild"),
        OptionSpec("media-type", value: "directThermal|thermalTransfer", "Druckverfahren (^MT), Standard: Druckereinstellung"),
        OptionSpec("tracking", value: "gap|blackMark|continuous|auto|notch", "Medienerkennung (^MN), Standard: Druckereinstellung"),
        OptionSpec("print-mode", value: "modus",
                   "tearOff, peelOff, cutter, delayedCut, rewind, applicator, kiosk (^MM) bzw. linerlessPeel, linerlessCut, "
                   + "linerlessDelayedCut, linerlessRewind, linerlessTear (SGD media.printmode), Standard: Druckereinstellung"),
        OptionSpec("label-top", value: "-120…120", "Vertikaler Versatz in Punkten (^LT), Standard: Druckereinstellung"),
        OptionSpec("label-left", value: "-9999…9999", "Horizontaler Versatz in Punkten (^LS), Standard: Druckereinstellung"),
        OptionSpec("tear-off", value: "-120…120", "Abreißposition in Punkten (~TA), Standard: Druckereinstellung"),
        OptionSpec("backfeed", value: "after|before|normal|off", "Rückzugsfolge (~JS), Standard: Druckereinstellung"),
        OptionSpec("cut-every", value: "0…9999",
                   "Nach jeweils N Etiketten schneiden (^PQ; zählt je Seite und Kopiengruppe – ohne Wirkung bei sortierten "
                   + "Aufträgen mit mehreren Seiten), Standard: 0 = nur am Auftragsende"),
        OptionSpec("calibrate", "Vor dem Auftrag kalibrieren (~JC)"),
        OptionSpec("save-settings", "Einstellungen dauerhaft im Drucker speichern (^JUS)"),
        OptionSpec("skip-blank", "Leere Etiketten nicht drucken"),
        OptionSpec("start-commands", value: "befehle", "Rohbefehle vor dem ersten Etikett (ZPL, EPL)"),
        OptionSpec("end-commands", value: "befehle", "Rohbefehle nach dem letzten Etikett (ZPL, EPL)"),
        OptionSpec("rotation", value: "0|90|180|270",
                   "Drehung durch den Treiber (lwRotation): 90/270 dreht die Bitmap, 180 per ^POI/ZB; auch mit --no-layout (Standard: 0)"),
        OptionSpec("mark-offset", value: "-80…283", "Versatz der schwarzen Markierung in Punkten (^MNM,n; nur mit --tracking blackMark)"),
        OptionSpec("stop-at-last", "Bei letztem Element stoppen: Etikett endet nach der letzten schwarzen Zeile (nur --tracking continuous)"),
        OptionSpec("stop-offset", value: "0…32000", "Stoppversatz in Punkten nach dem letzten Element (Standard: 0)"),
        OptionSpec("pause-every", value: "0…9999",
                   "Nach jeweils N Etiketten pausieren (^PQn,N,0,N; Vorrang vor --cut-every; zählt je Seite und Kopiengruppe – "
                   + "ohne Wirkung bei sortierten Aufträgen mit mehreren Seiten)"),
        OptionSpec("control-chars", value: "standard|printer",
                   "Steuerzeichen: standard (^ ~ ,) oder printer = Zeichen aus --format-prefix/--control-prefix/--delimiter"),
        OptionSpec("format-prefix", value: "zeichen|33…126", "Formatpräfix statt ^ (nur mit --control-chars printer)"),
        OptionSpec("control-prefix", value: "zeichen|33…126", "Steuerpräfix statt ~ (nur mit --control-chars printer)"),
        OptionSpec("delimiter", value: "zeichen|33…126", "Trennzeichen statt , (nur mit --control-chars printer)"),
        OptionSpec("rtc", value: "jobStart|everyLabel|everyMinute", "Echtzeituhr stellen (^ST), Standard: nie"),
        OptionSpec("cancel-before", "Aufträge vor dem Drucken abbrechen (~JA am Auftragsanfang vor den Startbefehlen; ZPL, EPL)"),
        OptionSpec("cancel-delay", value: "0…10000", "Wartezeit nach ~JA in Millisekunden (Standard: 1000; nur beim Drucken)"),
        OptionSpec("label-start-commands", value: "befehle", "Rohbefehle am Anfang jedes Etiketts (ZPL nach ^XA, EPL nach N)"),
        OptionSpec("label-end-commands", value: "befehle", "Rohbefehle am Ende jedes Etiketts (ZPL vor ^XZ, EPL vor P)"),
        OptionSpec("power-up-action", value: "feed|calibrate|length|noMotion|shortCal",
                   "Aktion beim Einschalten (^MF; nur zusammen mit --head-close-action; wirkt erst beim nächsten Einschalten "
                   + "und braucht dafür --save-settings)"),
        OptionSpec("head-close-action", value: "feed|calibrate|length|noMotion|shortCal",
                   "Aktion nach dem Schließen des Druckkopfs (^MF; nur zusammen mit --power-up-action)"),
    ]

    /// Zusätzliche Optionen von `encode` (bei `print` bestimmen Drucker und `PrinterClient` diese Werte).
    static let encodeOptions: [OptionSpec] = [
        OptionSpec("output", short: "o", value: "datei", "Zieldatei (Standard: Standardausgabe)"),
        OptionSpec("max-width", value: "punkte",
                   "Druckbreite; breitere Etiketten werden nach der Rasterung rechts abgeschnitten (Standard: Druckbreite von --model, sonst unbegrenzt)"),
        OptionSpec("no-collate", "Bei mehreren Bildern jedes Etikett mit allen Kopien einzeln senden statt die Folge zu wiederholen"),
        OptionSpec("fixed-time", value: "sekunden",
                   "Feste Uhrzeit für ^ST (Sekunden seit 1970, UTC) statt der Systemzeit – für reproduzierbare Aufträge"),
        OptionSpec("time-step", value: "sekunden",
                   "Für Tests: Etikett k sieht die Uhrzeit + k · sekunden (wie LW_TIME_STEP_SECONDS beim Filter; Standard: 0)"),
        OptionSpec("time-zone", value: "id", "Zeitzone für ^ST, z. B. UTC oder Europe/Berlin (Standard: Systemzeitzone bzw. TZ)"),
        OptionSpec("fit-to-label", value: "auto|off",
                   "An Etikett anpassen (lwFitToLabel): Bilder, deren --page-size um mehr als 2 mm von --label-size abweicht, "
                   + "auf den Inhalt zuschneiden, bei Bedarf um 90° drehen, vergrößern oder verkleinern und mittig mit 1,5 mm Rand "
                   + "auf das Etikett setzen – wie der CUPS-Filter (Standard: auto)"),
        OptionSpec("label-size", value: "BxH[mm|in]",
                   "Etikettengröße der Warteschlange (lwLabelWidth/lwLabelHeight), z. B. 104x76.2mm oder 4x6in; Höhe 0 = frei "
                   + "(Endlosmaterial). Ohne Angabe keine Anpassung"),
        OptionSpec("page-size", value: "BxH[,BxH…]",
                   "Seitengröße der Bilder in Punkten (1/72 Zoll, wie cupsPageSize), z. B. 595.28x841.89 für A4: eine Angabe für "
                   + "alle Bilder oder genau eine je Bild; nur mit --no-layout. Ohne Angabe gilt jedes Bild als etikettengroß"),
    ]

    static let commands: [CommandSpec] = [
        CommandSpec(
            name: "discover", usage: "discover [--hosts <liste>] [--networks <liste>] [--sources <liste>] [--json]",
            summary: "Drucker im Netzwerk, per USB, Bluetooth und CUPS suchen",
            details: """
            Sucht Zebra-Drucker über Bonjour, die Zebra-Suche (UDP 4201, wie die Zebra-Programme unter
            Windows), Netzwerkscan (Port 9100), USB, Bluetooth und CUPS und listet sie mit der passenden
            Drucker-URI für --printer auf. Durchsucht werden die lokalen Netze, private VPN-Netze und die
            mit --networks angegebenen Netze (je höchstens 4096 Adressen). Die Suchdauer bestimmt --timeout.
            """,
            options: [
                OptionSpec("hosts", value: "liste", "Nur diese Adressen prüfen (kommagetrennt) statt das lokale Netz zu durchsuchen"),
                OptionSpec("networks", value: "liste", "Zusätzliche Netze, z. B. 10.62.13.0/24, 10.62.13.1-10.62.13.254 oder 10.62.13.* (kommagetrennt)"),
                OptionSpec("sources", value: "liste", "Quellen: bonjour,zebra,network,usb,cups,bluetooth,ble (Standard: alle)"),
            ],
            needsPrinter: false, minimumArguments: 0, maximumArguments: 0,
            examples: ["lwctl discover", "lwctl discover --hosts 192.168.1.20,192.168.1.21 --json",
                       "lwctl discover --sources zebra,network --networks 10.62.13.0/24"]),
        CommandSpec(
            name: "install",
            usage: "install --printer tcp://HOST[:PORT] [--model auto|<id>|generic] [--name NAME] [optionen]",
            summary: "Netzwerkdrucker (LAN) als macOS-/CUPS-Drucker einrichten – wie ein Windows-Installationsprogramm",
            details: """
            Verbindet sich mit dem Drucker, erkennt Modell, Auflösung und Druckersprache (--model auto),
            wählt die passende LabelWerk-PPD (LabelWerk-<modell>-<dpi>dpi, sonst eine generische PPD wie
            LabelWerk-generic-zpl-203dpi) und legt mit lpadmin eine Warteschlange an (Geräte-URI
            socket://HOST:PORT, nicht freigegeben). Danach steht der Drucker unter „Drucker & Scanner“ und
            in jedem Druckdialog bereit. Jeder ausgeführte Befehl wird angezeigt; --dry-run zeigt ihn nur an.

            Ohne Verbindung (z. B. zum Vorbereiten vieler Macs) das Modell mit --model angeben
            (Liste: lwctl models); --model generic verwendet eine generische PPD. --language legt die
            Druckersprache fest (Standard: vom Modell bzw. Drucker). Auf macOS genügt ein
            Administratorkonto, sonst mit sudo ausführen.

            Vorhandene Warteschlangen: Eine LabelWerk-Warteschlange desselben Druckers wird
            aktualisiert, ihre Einstellungen (Schwärzung, Geschwindigkeit, Etikett …) bleiben erhalten;
            ohne --name wird sie auch unter anderem Namen gefunden (etwa vom Assistenten der App), statt
            den Drucker ein zweites Mal einzurichten. Andere Warteschlangen gleichen Namens – auch in
            anderer Groß-/Kleinschreibung – nur mit --replace. Die Prüfung läuft auch mit --dry-run.

            Etikettengröße: --stock wählt ein Katalogformat, --size eine beliebige Größe wie im
            Windows-Treiber (z. B. --size 104x76.2mm oder --size 4x3in). Sie wird Standard-Papiergröße
            der Warteschlange und steht im Druckdialog als „Etikett 104 × 76,2 mm“; fehlt sie in der
            Modell-PPD, erhält die Warteschlange eine Kopie der PPD mit dieser Seitengröße. Zusätzlich
            gehen lwLabelWidth/lwLabelHeight (1/100 mm) als Warteschlangen-Standard an den Filter, der
            Seiten anderer Größe (A4, Letter …) automatisch an das Etikett anpasst. Eine früher
            ergänzte Größe bleibt bei einer Aktualisierung ohne --stock/--size erhalten; fehlen
            lwLabelWidth/lwLabelHeight, gelten die Maße der Standard-Seitengröße der Warteschlange.
            """,
            options: [
                OptionSpec("model", short: "m", value: "auto|id|generic",
                           "Druckermodell (Standard: auto = vom Drucker erkennen; generic = generische PPD)"),
                OptionSpec("dpi", value: "152|203|300|600", "Auflösung (Standard: vom Drucker bzw. vom Modell)"),
                OptionSpec("name", short: "n", value: "name",
                           "Name der Warteschlange (Standard: Zebra_<Modell>_<Adresse>); erscheint auch als Beschreibung"),
                OptionSpec("replace", "Vorhandene Warteschlange gleichen Namens ersetzen (auch ohne LabelWerk-Treiber)"),
                OptionSpec("location", value: "text", "Standort, z. B. „Lager, Tor 3“"),
                OptionSpec("stock", short: "s", value: "id", "Etikettenformat als Standard-Papiergröße (Liste: lwctl stocks)"),
                OptionSpec("size", value: "BxH(mm|in)",
                           "Eigene Etikettengröße als Standard-Papiergröße, z. B. 104x76.2mm oder 4x3in (statt --stock)"),
                OptionSpec("default", "Als Standarddrucker festlegen"),
                OptionSpec("test-page", "Danach eine Testseite über die neue Warteschlange drucken"),
                OptionSpec("ppd-dir", value: "ordner", "Ordner mit den LabelWerk-PPDs (Standard: \(InstallCommands.defaultPPDDirectory))"),
                OptionSpec("dry-run", "Befehle nur anzeigen, nichts einrichten"),
            ],
            needsPrinter: true, minimumArguments: 0, maximumArguments: 0,
            examples: [
                "lwctl install --printer tcp://192.168.1.50",
                "lwctl install -p tcp://192.168.1.51 --name Versand --location \"Lager, Tor 3\" --stock w4h6in --default --test-page",
                "lwctl install -p tcp://etiketten-2.local:9100 --model zt410 --dpi 300 --dry-run",
                "lwctl install -p tcp://192.168.1.52 --size 104x76.2mm",
                "for ip in 192.168.1.50 192.168.1.51; do lwctl install -p tcp://$ip --json; done",
            ]),
        CommandSpec(
            name: "queues", usage: "queues [--labelwerk] [--json]",
            summary: "Eingerichtete Druckerwarteschlangen (CUPS) auflisten",
            details: """
            Listet alle macOS-/CUPS-Warteschlangen mit Geräte-URI und Treiber. Warteschlangen mit dem
            LabelWerk-Treiber sind markiert; --labelwerk zeigt nur diese.
            """,
            options: [OptionSpec("labelwerk", "Nur Warteschlangen mit LabelWerk-Treiber")],
            needsPrinter: false, minimumArguments: 0, maximumArguments: 0,
            examples: ["lwctl queues", "lwctl queues --labelwerk --json"]),
        CommandSpec(
            name: "uninstall-queue", usage: "uninstall-queue <name> [--force] [--dry-run]",
            summary: "Druckerwarteschlange entfernen",
            details: """
            Entfernt eine mit „install“ oder der App eingerichtete Warteschlange (lpadmin -x). Der
            Treiber bleibt installiert. Warteschlangen ohne LabelWerk-Treiber werden nur mit --force
            entfernt.
            """,
            options: [OptionSpec("force", short: "f", "Auch Warteschlangen ohne LabelWerk-Treiber entfernen"),
                      OptionSpec("dry-run", "Befehl nur anzeigen, nichts entfernen")],
            needsPrinter: false, minimumArguments: 1, maximumArguments: 1,
            examples: ["lwctl uninstall-queue Zebra_ZD421t_192.168.1.50", "lwctl uninstall-queue Versand --dry-run"]),
        CommandSpec(
            name: "status", usage: "status [--json]",
            summary: "Zustand, Meldungen und Zähler anzeigen",
            details: """
            Fragt ~HS und ~HQES (und bei Link-OS-Druckern SGD-Kennzahlen) ab. Rückgabewert 4, wenn der
            Drucker einen Fehler meldet (z. B. Druckkopf offen, Etiketten leer).
            """,
            options: [], needsPrinter: true, minimumArguments: 0, maximumArguments: 0,
            examples: ["lwctl --printer tcp://192.168.1.20 status", "lwctl -p virtual://demo status --json"]),
        CommandSpec(
            name: "info", usage: "info [--json]",
            summary: "Modell, Seriennummer, Firmware und Netzwerkadresse anzeigen",
            details: "Ermittelt die Identität per ~HI und SGD und ordnet das Modell dem Katalog zu.",
            options: [], needsPrinter: true, minimumArguments: 0, maximumArguments: 0,
            examples: ["lwctl -p tcp://192.168.1.20 info"]),
        CommandSpec(
            name: "send", usage: "send <datei|->",
            summary: "Datei oder Standardeingabe unverändert an den Drucker senden",
            details: "Sendet Rohdaten (ZPL, EPL, CPCL, SGD) ohne Umwandlung. „-“ liest von der Standardeingabe.",
            options: [], needsPrinter: true, minimumArguments: 1, maximumArguments: 1,
            examples: ["lwctl -p tcp://192.168.1.20 send etikett.zpl", "echo '~HS' | lwctl -p virtual://demo send -"]),
        CommandSpec(
            name: "print", usage: "print <bild…> [optionen]",
            summary: "PNG- oder PNM-Bilder als Etiketten drucken",
            details: """
            Lädt die Bilder, dreht und passt sie in das Etikettenformat ein, rastert sie mit dem gewählten
            Verfahren und sendet sie im Byteformat des CUPS-Treibers (ZPL, EPL oder CPCL).
            """,
            options: imageOptions, needsPrinter: true, minimumArguments: 1, maximumArguments: nil,
            examples: ["lwctl -p tcp://192.168.1.20 print versand.png --stock w4h6in --dither atkinson",
                       "lwctl -p virtual://demo print a.png b.png --copies 2 --fit cover"]),
        CommandSpec(
            name: "encode", usage: "encode <bild…> [-o datei] [optionen]",
            summary: "Druckauftrag aus Bildern erzeugen, ohne zu drucken",
            details: """
            Wie „print“, schreibt den Auftrag aber in eine Datei (bzw. auf die Standardausgabe). Jedes
            Bild wird ein Etikett; das Byteformat ist identisch mit dem des CUPS-Filters.
            """,
            options: imageOptions + encodeOptions,
            needsPrinter: false, minimumArguments: 1, maximumArguments: nil,
            examples: ["lwctl encode logo.png -o logo.zpl --stock w2h1in", "lwctl --language epl encode logo.png > logo.epl",
                       "lwctl encode a.png b.png --no-layout --copies 2 --no-collate --cut-every 2 -o auftrag.zpl",
                       "lwctl encode a4-seite.png --no-layout --page-size 595.28x841.89 --label-size 104x76.2mm -o etikett.zpl"]),
        CommandSpec(
            name: "render", usage: "render <zpl-datei|-> -o out.png [--dpmm 8]",
            summary: "ZPL in ein PNG-Vorschaubild umwandeln",
            details: """
            Interpretiert ZPL mit dem eingebauten Renderer und schreibt je Etikett ein PNG (out.png,
            out-2.png, …). Hinweise zu nicht nachgebildeten Befehlen erscheinen auf der Fehlerausgabe.
            """,
            options: [
                OptionSpec("output", short: "o", value: "datei", "Zieldatei (PNG)"),
                OptionSpec("dpmm", value: "6|8|12|24", "Punkte je Millimeter (Standard: 8 = 203 dpi)"),
                OptionSpec("width", value: "punkte", "Etikettenbreite, falls das ZPL kein ^PW enthält (Standard: 4 Zoll)"),
                OptionSpec("height", value: "punkte", "Etikettenlänge, falls das ZPL kein ^LL enthält (Standard: 6 Zoll)"),
            ],
            needsPrinter: false, minimumArguments: 1, maximumArguments: 1,
            examples: ["lwctl render etikett.zpl -o vorschau.png", "lwctl render etikett.zpl -o v.png --dpmm 12"]),
        CommandSpec(
            name: "action", usage: "action <name> | action --list",
            summary: "Gerätefunktion ausführen (kalibrieren, pausieren, Konfiguration drucken …)",
            details: "Namen in Kurzform (calibrate, feed-label, print-configuration …); „--list“ zeigt alle.",
            options: [
                OptionSpec("list", "Alle Aktionen auflisten"),
                OptionSpec("stock", short: "s", value: "id", "Etikettenformat für das Testetikett"),
                OptionSpec("dpi", value: "152|203|300|600", "Auflösung für das Testetikett"),
            ],
            needsPrinter: true, minimumArguments: 0, maximumArguments: 1,
            examples: ["lwctl -p tcp://192.168.1.20 action calibrate", "lwctl action --list"]),
        CommandSpec(
            name: "getvar", usage: "getvar <name>",
            summary: "SGD-Variable lesen",
            details: "Liest eine Set-Get-Do-Variable, z. B. device.friendly_name oder ip.addr.",
            options: [], needsPrinter: true, minimumArguments: 1, maximumArguments: 1,
            examples: ["lwctl -p tcp://192.168.1.20 getvar device.friendly_name"]),
        CommandSpec(
            name: "setvar", usage: "setvar <name> <wert>",
            summary: "SGD-Variable setzen",
            details: "Setzt eine Set-Get-Do-Variable. Der Drucker prüft den Wert und ignoriert ungültige Werte.",
            options: [], needsPrinter: true, minimumArguments: 2, maximumArguments: 2,
            examples: ["lwctl -p tcp://192.168.1.20 setvar device.friendly_name Versand-1"]),
        CommandSpec(
            name: "do", usage: "do <name> [wert]",
            summary: "SGD-Befehl ausführen (z. B. device.reset)",
            details: "Führt einen Set-Get-Do-Befehl aus und zeigt eine Antwort, falls der Drucker eine sendet.",
            options: [], needsPrinter: true, minimumArguments: 1, maximumArguments: 2,
            examples: ["lwctl -p tcp://192.168.1.20 do file.dir E:"]),
        CommandSpec(
            name: "settings", usage: "settings [--filter <präfix>] [--json]",
            summary: "Alle Einstellungen lesen (allconfig bzw. allcv)",
            details: "Zeigt alle SGD-Einstellungen mit Wert; mit --json zusätzlich Typ, Bereich und Zugriff.",
            options: [OptionSpec("filter", short: "f", value: "präfix", "Nur Variablen, die so beginnen (z. B. ip.)")],
            needsPrinter: true, minimumArguments: 0, maximumArguments: 0,
            examples: ["lwctl -p virtual://demo settings --filter media."]),
        CommandSpec(
            name: "config", usage: "config [--json]",
            summary: "Druckerkonfiguration (^HH) anzeigen",
            details: "Liest die Konfiguration wie auf dem Konfigurationsetikett.",
            options: [], needsPrinter: true, minimumArguments: 0, maximumArguments: 0,
            examples: ["lwctl -p tcp://192.168.1.20 config"]),
        CommandSpec(
            name: "network", usage: "network [--json]",
            summary: "Netzwerkeinstellungen anzeigen",
            details: "Zeigt Adressvergabe, IP-Adresse, Maske, Gateway, DNS, WLAN und MAC-Adresse.",
            options: [], needsPrinter: true, minimumArguments: 0, maximumArguments: 0,
            examples: ["lwctl -p tcp://192.168.1.20 network"]),
        CommandSpec(
            name: "files", usage: "files [--drive E:] [--json]",
            summary: "Dateien im Druckerspeicher auflisten",
            details: "Listet Schriften, Grafiken und Formate eines Laufwerks (E: Flash, R: RAM, * alle).",
            options: [OptionSpec("drive", value: "laufwerk", "Laufwerk (Standard: E:)")],
            needsPrinter: true, minimumArguments: 0, maximumArguments: 0,
            examples: ["lwctl -p tcp://192.168.1.20 files --drive R:"]),
        CommandSpec(
            name: "delete-file", usage: "delete-file <pfad>",
            summary: "Datei im Druckerspeicher löschen",
            details: "Löscht z. B. E:LOGO.GRF; Platzhalter wie E:*.GRF sind erlaubt.",
            options: [], needsPrinter: true, minimumArguments: 1, maximumArguments: 1,
            examples: ["lwctl -p tcp://192.168.1.20 delete-file E:LOGO.GRF"]),
        CommandSpec(
            name: "upload-font", usage: "upload-font <ttf> [--name NAME] [--drive E:]",
            summary: "TrueType-/OpenType-Schrift übertragen (~DY)",
            details: "Überträgt eine Schrift; im ZPL abrufbar z. B. mit ^A@N,40,40,E:NAME.TTF.",
            options: [OptionSpec("name", short: "n", value: "name", "Name im Drucker (Standard: Dateiname)"),
                      OptionSpec("drive", value: "laufwerk", "Laufwerk (Standard: E:)")],
            needsPrinter: true, minimumArguments: 1, maximumArguments: 1,
            examples: ["lwctl -p tcp://192.168.1.20 upload-font Arial.ttf --name ARIAL"]),
        CommandSpec(
            name: "upload-graphic", usage: "upload-graphic <png> [--name NAME] [--drive E:]",
            summary: "Grafik übertragen (~DG), abrufbar mit ^XG",
            details: "Rastert ein PNG- oder PNM-Bild und speichert es als .GRF im Drucker.",
            options: [OptionSpec("name", short: "n", value: "name", "Name im Drucker (Standard: Dateiname)"),
                      OptionSpec("drive", value: "laufwerk", "Laufwerk (Standard: E:)"),
                      OptionSpec("dither", short: "d", value: "verfahren", "Rasterverfahren (Standard: threshold)"),
                      OptionSpec("threshold", value: "1…254", "Schwelle (Standard: 128)")],
            needsPrinter: true, minimumArguments: 1, maximumArguments: 1,
            examples: ["lwctl -p tcp://192.168.1.20 upload-graphic logo.png --name LOGO"]),
        CommandSpec(
            name: "firmware", usage: "firmware <datei> [--yes]",
            summary: "Firmware übertragen",
            details: """
            Überträgt eine Firmware-Datei (.zpl/.nrd) mit Fortschrittsanzeige. Der Drucker installiert sie
            anschließend und startet neu – nicht ausschalten! Ohne --yes wird im Terminal nachgefragt.
            """,
            options: [OptionSpec("yes", short: "y", "Ohne Rückfrage übertragen"),
                      OptionSpec("chunk-size", value: "bytes", "Blockgröße (Standard: 16384)")],
            needsPrinter: true, minimumArguments: 1, maximumArguments: 1,
            examples: ["lwctl -p tcp://192.168.1.20 firmware V84.20.21Z.zpl"]),
        CommandSpec(
            name: "terminal", usage: "terminal",
            summary: "Interaktives Terminal für ZPL-, SGD- und EPL-Befehle",
            details: """
            Jede Eingabezeile wird mit CR LF gesendet, Antworten erscheinen mit sichtbaren Steuerzeichen.
            Befehle: :hilfe, :hex (Hexanzeige ein/aus), :zeilenende crlf|lf|keins, :warte <sek>,
            :datei <pfad> (Datei senden), :ende (oder Ctrl+D).
            """,
            options: [], needsPrinter: true, minimumArguments: 0, maximumArguments: 0,
            examples: ["lwctl -p tcp://192.168.1.20 terminal"]),
        CommandSpec(
            name: "models", usage: "models [--category <kategorie>] [--search <text>] [--json]",
            summary: "Unterstützte Druckermodelle auflisten",
            details: "Listet alle Modelle des Katalogs mit Auflösungen, Druckbreite und Sprachen.",
            options: [OptionSpec("category", value: "kategorie", "desktop, industrial, mobile, healthcare, printEngine"),
                      OptionSpec("search", value: "text", "Nur Modelle, deren Name den Text enthält")],
            needsPrinter: false, minimumArguments: 0, maximumArguments: 0,
            examples: ["lwctl models --category desktop", "lwctl models --json"]),
        CommandSpec(
            name: "stocks", usage: "stocks [--model <id>] [--json]",
            summary: "Etikettenformate auflisten",
            details: "Listet die Standard-Etikettenformate; mit --model nur die, die auf das Modell passen.",
            options: [OptionSpec("model", short: "m", value: "id", "Nur Formate für dieses Modell")],
            needsPrinter: false, minimumArguments: 0, maximumArguments: 0,
            examples: ["lwctl stocks --model zd421t"]),
        CommandSpec(
            name: "test-label", usage: "test-label [--stock <id>] [--dpi <n>] [--title <text>]",
            summary: "Testetikett drucken",
            details: "Druckt ein Testetikett mit Rahmen, Barcodes, Schwärzungsskala und Lineal in der gewählten Sprache.",
            options: [OptionSpec("stock", short: "s", value: "id", "Etikettenformat (Standard: w4h6in)"),
                      OptionSpec("dpi", value: "152|203|300|600", "Auflösung (Standard: vom Drucker bzw. 203)"),
                      OptionSpec("title", value: "text", "Überschrift (Standard: LabelWerk)")],
            needsPrinter: true, minimumArguments: 0, maximumArguments: 0,
            examples: ["lwctl -p tcp://192.168.1.20 test-label --stock w4h3in"]),
        CommandSpec(
            name: "virtual-printer", usage: "virtual-printer [--port 9100] [--model zd421t] [--dpi 203] [--host 0.0.0.0]",
            summary: "Virtuellen Drucker im Netzwerk bereitstellen",
            details: """
            Startet einen simulierten Link-OS-Drucker als TCP-Server (RAW-Port). Er beantwortet Status-,
            SGD- und JSON-Abfragen, speichert Dateien und rendert empfangene Etiketten. --port 0 wählt
            einen freien Port; der tatsächliche Port wird ausgegeben. Beenden mit Ctrl+C.
            """,
            options: [OptionSpec("port", value: "port", "TCP-Port (Standard: 9100)"),
                      OptionSpec("model", short: "m", value: "id", "Simuliertes Modell (Standard: zd421t)"),
                      OptionSpec("dpi", value: "152|203|300|600", "Auflösung (Standard: 203)"),
                      OptionSpec("host", value: "adresse", "Adresse, an die gebunden wird (Standard: alle)"),
                      OptionSpec("id", value: "kennung", "Kennung (bestimmt Seriennummer und MAC-Adresse, Standard: demo)")],
            needsPrinter: false, minimumArguments: 0, maximumArguments: 0,
            examples: ["lwctl virtual-printer --port 9100", "lwctl virtual-printer --port 0 --model zt410 --dpi 300"]),
        CommandSpec(
            name: "version", usage: "version",
            summary: "Version anzeigen",
            details: "Zeigt die Version von lwctl und LabelWerk.",
            options: [], needsPrinter: false, minimumArguments: 0, maximumArguments: 0, examples: ["lwctl version"]),
        CommandSpec(
            name: "help", usage: "help [befehl]",
            summary: "Hilfe zu allen bzw. einem Befehl",
            details: "Zeigt die Übersicht oder die ausführliche Hilfe eines Befehls.",
            options: [], needsPrinter: false, minimumArguments: 0, maximumArguments: 1, examples: ["lwctl help print"]),
    ]

    static let byName: [String: CommandSpec] = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })

    // MARK: - Hilfetexte

    static func overview() -> String {
        var text = """
        lwctl \(LabelWerkKitInfo.version) – Steuerung von Zebra-Etikettendruckern (LabelWerk)

        Aufruf: lwctl <befehl> [optionen] [--printer <uri>]

        Befehle:

        """
        let width = (commands.map(\.name.count).max() ?? 10) + 2
        for command in commands {
            text += "  " + command.name.padding(toLength: width, withPad: " ", startingAt: 0) + command.summary + "\n"
        }
        text += "\nGlobale Optionen:\n"
        text += options(globalOptions)
        text += """

        Drucker-URIs: tcp://192.168.1.20[:9100], usb://0a5f:0181[/seriennummer], cups://Zebra_ZD421,
        virtual://demo (eingebauter virtueller Drucker; virtual://zt410-300 simuliert ein anderes Modell).

        Rückgabewerte: 0 Erfolg, 1 Fehler, 2 falscher Aufruf, 3 Verbindungsfehler,
        4 Drucker meldet Fehler (status), 130 abgebrochen.

        Ausführliche Hilfe: lwctl help <befehl>

        """
        return text
    }

    static func help(for command: CommandSpec) -> String {
        var text = "lwctl \(command.usage)\n\n\(command.summary).\n\n\(command.details)\n"
        if !command.options.isEmpty {
            text += "\nOptionen:\n" + options(command.options)
        }
        text += "\nGlobale Optionen:\n" + options(globalOptions)
        if !command.examples.isEmpty {
            text += "\nBeispiele:\n" + command.examples.map { "  \($0)\n" }.joined()
        }
        return text
    }

    static func options(_ list: [OptionSpec]) -> String {
        let width = (list.map(\.signature.count).max() ?? 10) + 2
        return list.map { "  " + $0.signature.padding(toLength: width, withPad: " ", startingAt: 0) + $0.help + "\n" }.joined()
    }
}
