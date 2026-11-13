import SwiftUI
import LabelWerkKit

// MARK: - Hilfetexte

extension PrintPrefsSetting {
    /// Erklärung für die Hilfe (Deutsch, mit den gesendeten Befehlen).
    var helpText: String {
        switch self {
        case .template:
            return tr("Wählt ein gespeichertes Etikettenformat; Breite, Höhe, Lücke und Medientyp werden übernommen. „Benutzerdefiniert“ erlaubt eigene Maße – beim Speichern legt LabelWerk dafür ein eigenes Format an.")
        case .size:
            return tr("Breite und Höhe eines Etiketts in der gewählten Maßeinheit. Breitere Etiketten als die Druckbreite des Modells werden rechts abgeschnitten. Eine Änderung schaltet die Vorlage auf „Benutzerdefiniert“.")
        case .tracking:
            return tr("Wie der Drucker den Etikettenanfang erkennt: Endlosmaterial (^MNN), Einzeletiketten mit Lücke (^MNY), Etiketten mit schwarzen Markierungen auf der Rückseite (^MNM), Etiketten mit Seitenkerben (^MNW) oder automatische Erkennung (^MNA).")
        case .rotation:
            return tr("Dreht das Druckbild im Uhrzeigersinn. 90° und 270° (Querformat) dreht der Treiber selbst, 180° übernimmt der Drucker (^POI bei ZPL, ZB bei EPL).")
        case .markOffset:
            return tr("Abstand zwischen der schwarzen Markierung und dem Etikettenanfang (^MNM,n), −80 bis 283 Punkte. Nur bei „Etiketten mit schwarzen Markierungen“ und ZPL.")
        case .mirror:
            return tr("Spiegelt das Etikett horizontal (^PMY) – z. B. für Etiketten, die von hinten durch Glas gelesen werden.")
        case .negative:
            return tr("Druckt invers: Schwarz und Weiß werden vertauscht.")
        case .stopAtLast:
            return tr("Nur bei Endlosmaterial: Das Etikett endet nach dem letzten bedruckten Element statt nach der vollen Seitenlänge – das spart Material.")
        case .stopOffset:
            return tr("Zusätzlicher Vorschub nach dem letzten Element, wenn „Bei letztem Element stoppen“ aktiv ist (0 bis 32 000 Punkte).")
        case .fitToLabel:
            return tr("Schickt ein Programm eine andere Papiergröße als das Etikett (z. B. A4 aus Vorschau), legt der Treiber den Inhalt der Seite mittig auf das Etikett: zu große Inhalte werden verkleinert, nie vergrößert. Seiten in Etikettengröße bleiben unverändert. „Aus“ druckt die Seite wie geliefert (nur auf die Druckbreite abgeschnitten).")
        case .speed:
            return tr("Druckgeschwindigkeit (^PR) in mm/s bis zum Höchstwert des Modells (51 mm/s = 2 Zoll/s). Langsamer druckt sauberer, schneller erhöht den Durchsatz.")
        case .darkness:
            return tr("Temperatur des Druckkopfs bzw. Schwärzung (~SD) von 1 bis 30. Höhere Werte drucken dunkler, lassen den Druckkopf aber schneller altern.")
        case .mediaType:
            return tr("Thermotransfer druckt mit Farbband (^MTT), Thermo-Direkt auf wärmeempfindliches Papier ohne Farbband (^MTD).")
        case .labelTop:
            return tr("Verschiebt das Druckbild nach unten (positive Werte) bzw. nach oben (^LT, −120 bis 120 Punkte).")
        case .labelLeft:
            return tr("Verschiebt das Druckbild nach links (positive Werte) bzw. nach rechts (^LS).")
        case .backfeed:
            return tr("Wann das Etikett nach dem Abreißen oder Spenden zurückgezogen wird (~JS): kein Rückzug, vor dem Drucken, nach dem Drucken oder Standard (überwiegend vor dem Drucken).")
        case .pauseEvery:
            return tr("Hält den Drucker nach jeweils N Etiketten an (^PQ n,N,0,N), z. B. zum Entnehmen. Hat Vorrang vor „Schneiden alle N Etiketten“. Gezählt wird je Seite und Kopiengruppe: Bei sortierten Aufträgen mit mehreren Seiten (jede Seite einzeln) pausiert der Drucker ab N = 2 nicht. Nur ZPL.")
        case .controlCharacters:
            return tr("„Standard“ verwendet ^, ~ und , als Steuerzeichen. „Intern“ verwendet die im Drucker eingestellten Zeichen (^CC, ^CT, ^CD) für alle vom Treiber erzeugten Befehle – eigene Befehle bleiben unverändert. Nur ZPL.")
        case .rtcUpdate:
            return tr("Stellt die Echtzeituhr des Druckers mit ^ST auf die Uhrzeit des Mac: einmal zu Beginn des Auftrags, vor jedem Etikett oder höchstens einmal je Minute. Nur ZPL.")
        case .calibrateBeforeJob:
            return tr("Kalibriert die Medien (~JC) vor jedem Auftrag – sinnvoll bei häufigem Rollenwechsel.")
        case .saveToPrinter:
            return tr("Speichert die Einstellungen mit dem ersten Etikett jedes Auftrags dauerhaft im Drucker (^JUS).")
        case .language:
            return tr("Befehlssprache des Druckers (ZPL II, EPL2, CPCL). ZPL bietet alle Funktionen. Ein Wechsel baut die Verbindung nach dem Speichern neu auf.")
        case .cancelJobs:
            return tr("Löscht vor jedem Auftrag alle aktuellen und wartenden Aufträge im Drucker (~JA, ganz am Anfang des Auftrags vor den Startbefehlen), damit nur der neue gedruckt wird. Wirkt bei ZPL und EPL.")
        case .cancelDelay:
            return tr("Wartezeit nach dem Abbrechen, bevor der neue Auftrag folgt (0 bis 10 000 ms, Standard 1000 ms).")
        case .resumeAfterError:
            return tr("Wie bei einem normalen Drucker: Der Auftrag bleibt in der macOS-Warteschlange, bis jedes Etikett gedruckt ist. Gehen Etiketten oder Farbband aus oder ist der Druckkopf offen, zeigt macOS „Kein Papier“ bzw. „Farbband leer“; nach dem Einlegen geht der Druck genau dort weiter – das unterbrochene Etikett druckt der Drucker erneut, nichts muss nachgezählt werden. Gilt für Netzwerkdrucker mit ZPL (macOS-Geräte-URI labelwerk:// statt socket://) und für Drucke aus LabelWerk. Aus: Der Auftrag gilt als erledigt, sobald die Daten beim Drucker sind.")
        case .printMode:
            return tr("Was nach dem Druck geschieht (^MM): Abreißen, Spendemodus, Abschneider, verzögerter Abschneider, Aufwickeln, Applikator oder Kiosk. Linerless-Modi (Etiketten ohne Trägermaterial) setzt der Treiber per SGD „media.printmode“.")
        case .tearOff:
            return tr("Feinjustierung der Abreiß- bzw. Spendeposition (~TA, −120 bis 120 Punkte).")
        case .cutEvery:
            return tr("Mit Abschneider: nur am Auftragsende schneiden oder nach jeweils N Etiketten (^PQ n,N,0,Y). Gezählt wird je Seite und Kopiengruppe: Bei sortierten Aufträgen mit mehreren Seiten schneidet der Drucker ab N = 2 nicht zwischendurch.")
        case .dither:
            return tr("Wie Graustufen und Fotos in Druckpunkte umgewandelt werden: Schwellenwert für Text und Barcodes, Raster- oder Fehlerdiffusionsverfahren für Bilder.")
        case .threshold:
            return tr("Helligkeitsgrenze von 1 bis 254: Dunklere Bildpunkte werden gedruckt. Höhere Werte drucken mehr Punkte.")
        case .compression:
            return tr("Kodierung der Grafikdaten bei ZPL: Z64 (Deflate, empfohlen), ACS (Lauflänge) oder Hex (unkomprimiert). EPL und CPCL übertragen binär.")
        case .skipBlank:
            return tr("Seiten ohne Inhalt werden nicht gedruckt.")
        case .startCommands:
            return tr("Befehle, die unverändert vor dem ersten Etikett eines Auftrags gesendet werden.")
        case .endCommands:
            return tr("Befehle, die unverändert nach dem letzten Etikett eines Auftrags gesendet werden.")
        case .labelStartCommands:
            return tr("Befehle am Anfang jedes Etiketts (ZPL: direkt nach ^XA). CPCL sendet sie nicht.")
        case .labelEndCommands:
            return tr("Befehle am Ende jedes Etiketts (ZPL: direkt vor ^XZ). CPCL sendet sie nicht.")
        case .powerUpAction:
            return tr("Was der Drucker beim Einschalten tut (^MF): Vorschub, Kalibrieren, Länge messen, keine Bewegung oder Kurzkalibrierung. Wird nur zusammen mit der Aktion nach dem Schließen des Druckkopfs gesendet und wirkt erst beim nächsten Einschalten – dafür muss „Einstellungen im Drucker speichern“ eingeschaltet sein.")
        case .headCloseAction:
            return tr("Was der Drucker nach dem Schließen des Druckkopfs tut (^MF). Wird nur zusammen mit der Aktion beim Einschalten gesendet.")
        }
    }
}

// MARK: - Hilfe

/// Hilfe zum Dialog „Druckeinstellungen“: Bedienung (Stift-Menü, Knöpfe) und jede Option mit Erklärung.
@MainActor
struct PrintPrefsHelpSheet: View {
    let initialPane: PrintPrefsPane
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    init(initialPane: PrintPrefsPane) {
        self.initialPane = initialPane
    }

    private struct Topic: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    private func topics(for pane: PrintPrefsPane) -> [Topic] {
        var list = PrintPrefsSetting.allCases.filter { $0.pane == pane }.map {
            Topic(id: $0.rawValue, title: $0.title == $0.summaryTitle ? $0.title : $0.summaryTitle, text: $0.helpText)
        }
        switch pane {
        case .labelTypes:
            list.append(contentsOf: [
                Topic(id: "labelTypes", title: tr("Etikettentypen"),
                      text: tr("Jeder Etikettentyp erscheint in macOS als eigener Drucker („<Drucker> – <Typ>“). Im Druckdialog jedes Programms einfach diesen Drucker wählen – Etikettengröße und Einstellungen kommen von hier, im Dialog ist nichts weiter einzustellen.")),
                Topic(id: "labelTypeOverrides", title: tr("Abweichungen vom Drucker"),
                      text: tr("Drehung, Temperatur, Geschwindigkeit, Versatz, Medientyp, Druckmodus und Bedienermodus stehen auf „Wie Drucker“, bis Sie einen eigenen Wert wählen. Alle übrigen Einstellungen und spätere Änderungen am Drucker gelten auch für den Typ.")),
                Topic(id: "labelTypeQueue", title: tr("macOS-Drucker des Typs"),
                      text: tr("LabelWerk richtet den Drucker beim Sichern automatisch ein und hält ihn aktuell. Wird der Typ gelöscht, entfernt LabelWerk auch seinen macOS-Drucker.")),
            ])
        case .maintenance:
            list.insert(contentsOf: [
                Topic(id: "reset", title: tr("Auf Standardeinstellungen zurücksetzen"),
                      text: tr("Setzt alle Werte des Dialogs auf den Auslieferungszustand des Treibers.")),
                Topic(id: "printer", title: tr("Alle Einstellungen des Druckers verwenden"),
                      text: tr("Stellt alle Werte mit Stift-Menü auf „Druckerwert“: Der Treiber sendet dafür keine Befehle.")),
                Topic(id: "calibrate", title: tr("Medien kalibrieren"),
                      text: tr("Misst Etikettenlänge und Sensoren neu (~JC).")),
                Topic(id: "rtc", title: tr("Echtzeituhr (RTC) synchronisieren"),
                      text: tr("Stellt die Uhr des Druckers sofort auf die Uhrzeit dieses Mac (ZPL ^ST, sonst SGD rtc.date/rtc.time).")),
                Topic(id: "send", title: tr("An den Drucker senden"),
                      text: tr("Überträgt die Werte sofort als Gerätebefehle; „Dauerhaft speichern“ hängt ^JUS an.")),
                Topic(id: "profile", title: tr("Profil"),
                      text: tr("Importiert oder exportiert alle Werte als JSON-Datei.")),
            ], at: 0)
        case .units:
            list.append(Topic(id: "units", title: tr("Standard-Maßeinheiten"),
                              text: tr("Millimeter, Zoll oder Druckpunkte der Auflösung. Etikettenmaße zeigen eine (mm) bzw. zwei (Zoll) Nachkommastellen, Versätze so viele, dass sich jeder Druckpunkt eingeben lässt. Gilt für alle Längenangaben dieses Dialogs.")))
        case .about:
            list.append(Topic(id: "about", title: tr("Hilfe und Über"),
                              text: tr("Öffnet diese Hilfe und zeigt App-, Treiber- und Druckerinformationen.")))
        default:
            break
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return list }
        return list.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) || $0.text.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconBadge(systemImage: "questionmark.circle", tint: Theme.violet, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Hilfe – Druckeinstellungen"))
                        .font(Theme.Typography.title)
                    Text(tr("Alle Optionen des Treibers und was LabelWerk an den Drucker sendet"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                TextField(tr("Suchen"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            .padding(20)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if query.isEmpty {
                            basics
                        }
                        ForEach(PrintPrefsPane.allCases) { pane in
                            let items = topics(for: pane)
                            if !items.isEmpty {
                                section(pane, items: items)
                                    .id(pane)
                            }
                        }
                    }
                    .padding(20)
                }
                .onAppear {
                    if initialPane != .page { proxy.scrollTo(initialPane, anchor: .top) }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(tr("Fertig")) { dismiss() }
                    .buttonStyle(.labelWerkPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 640)
    }

    private var basics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Bedienung"))
                .font(Theme.Typography.headline)
            helpLine(symbol: "pencil", tint: Theme.accent, title: tr("Stift-Menü"),
                     text: tr("„Treiberwert verwenden“ sendet den eingestellten Wert mit jedem Auftrag. „Druckerwert verwenden“ sendet nichts – der Drucker behält seine Einstellung; der Wert erscheint grau und kursiv. „Vom Drucker lesen“ übernimmt den aktuellen Wert des Druckers."))
            helpLine(symbol: "checkmark.circle", tint: Theme.ready, title: tr("OK, Abbrechen, Übernehmen"),
                     text: tr("„OK“ speichert die Werte als Treiber-Standard (auch für die macOS-Warteschlange) und schließt den Dialog, „Übernehmen“ speichert ohne zu schließen, „Abbrechen“ verwirft alle nicht gespeicherten Änderungen."))
            helpLine(symbol: "eye", tint: Theme.teal, title: tr("Druckvorschau"),
                     text: tr("Zeigt Seitenverhältnis, Medientyp, Drehung, Spiegeln, Invers und Bedienermodus der aktuellen Werte."))
            helpLine(symbol: "printer.dotmatrix.filled.and.paper", tint: Theme.magenta, title: tr("Testseite drucken"),
                     text: tr("Druckt eine Testseite mit den Werten dieses Dialogs – auch mit noch nicht gespeicherten Änderungen."))
        }
        .padding(14)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func helpLine(symbol: String, tint: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section(_ pane: PrintPrefsPane, items: [Topic]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(systemImage: pane.systemImage, tint: pane.tint, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pane.title)
                        .font(Theme.Typography.headline)
                    Text(pane.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(items) { topic in
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(topic.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.leading, 36)
            }
        }
    }
}
