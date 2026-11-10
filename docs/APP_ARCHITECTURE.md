# LabelWerk.app – Architektur & UI-Vertrag

SwiftUI-App für macOS 14+ (Swift-5-Sprachmodus, Observation-Framework). Quelltext unter
`Sources/LabelWerkApp/`. Gebaut mit `swift build --product LabelWerk` (nur macOS) und zu einem
`.app` gebündelt mit `Scripts/build_app.sh`.

## Grundregeln

* **Nur macOS-SDK-APIs, die es in macOS 14 gibt.** Neuere APIs nur hinter
  `if #available(macOS 15.0, *)` bzw. für macOS 26 (Liquid Glass) zusätzlich hinter
  `#if compiler(>=6.2)` — sonst bricht der Build mit älterem Xcode.
* Jede sichtbare Zeichenkette über `tr("Deutscher Text")` (bzw. `tr("… %@ …", wert)`),
  **niemals** String-Interpolation im Schlüssel. `Text(tr("…"))`, `Label(tr("…"), systemImage:)`,
  `Button(tr("…"))`. (`Text("…")` mit Literal wäre ein `LocalizedStringKey` und würde nicht über
  unsere Tabelle laufen.)
* Farben, Abstände, Radien, Schriften nur aus `Theme` (`Design/Theme.swift`), Animationen aus
  `Motion`. „Bewegung reduzieren“ respektieren: `@Environment(\.accessibilityReduceMotion)` **und**
  `model.preferences.reduceMotion`.
* Views greifen nie direkt auf `PrinterClient` zu, sondern nur auf `PrinterSession`
  (`Model/PrinterSession.swift`) bzw. `AppModel` (`Model/AppModel.swift`). Diese fangen Fehler ab,
  zeigen Hinweise (Toasts) und schreiben den Auftragsverlauf.
* SF Symbols nur aus SF Symbols 5 (macOS 14). Im Zweifel ein gängiges Symbol wählen.
* Keine Platzhalter, keine „TODO“-Ansichten: Jede Funktion ist voll funktionsfähig.
* Hochwertige Animationen sind Pflicht (Federn, `matchedGeometryEffect`, `phaseAnimator`,
  `keyframeAnimator`, `symbolEffect`, `contentTransition(.numericText())`, Übergänge),
  aber zweckmäßig und flüssig (keine Dauerschleifen mit hoher CPU-Last; `TimelineView` nur mit
  moderater Bildrate und nur solange sichtbar/aktiv).

## Vorhandene Bausteine (nicht ändern, nur verwenden)

| Datei | Inhalt |
|---|---|
| `App/LabelWerkApp.swift` | `@main`, Szenen (Fenster, Einstellungen, Menüleiste), `AppDelegate`, `MenuBarIcon`, `LabelWerkCommands` |
| `App/Localization.swift` | `tr(_:)`, `tr(_:_:...)` |
| `Model/AppTypes.swift` | `SavedPrinter`, `JobRecord`, `AppPreferences` (inkl. `measurementUnit`), `AppearancePreference`, `MeasurementUnit` (mm/Zoll/Punkte), `PersistedState`, `Toast`, `ConnectionState`, `StatusSample` |
| `Model/Navigation.swift` | `SidebarItem`, `PrinterSection` |
| `Model/AppModel.swift` | `AppModel` (Drucker, Auswahl, Etiketten, Verlauf, Einstellungen, Toasts) |
| `Model/PrinterSession.swift` | `PrinterSession` (Verbindung, Status, alle Geräteoperationen) |
| `Model/PersistenceStore.swift` | JSON-Persistenz |
| `Services/ProcessRunner.swift` | Prozesse, Admin-Rechte via osascript |
| `Services/UpdateController.swift` | Update-Dienst (`model.updates`, `@Observable`): Suchen (10 s nach dem Start, alle 6 h), Laden, Installieren mit Administratorrechten und Neustart; Kern in `LabelWerkKit/Update` |
| `Services/UpdateTokenStore.swift` | Zugriffstoken für private Repositorys im Schlüsselbund |
| `Services/CUPSService.swift` | Warteschlangen anlegen/ändern/entfernen, PPD-Suche, Treiberstatus |
| `Services/NotificationService.swift` | Systembenachrichtigungen, `SoundService` |
| `Services/ImageImport.swift` | Bild/PDF → `CGImage`/`GrayImage`, Einpassen (`ImageFitMode`), `MonoBitmap`/`GrayImage` → `CGImage`/`NSImage` |
| `Design/Theme.swift` | `Theme`, `Motion`, `PrinterState.displayName/systemImage/color`, `AlertSeverity.color` |
| `Features/Root/*` | `RootView`, `DetailRouter`, `SidebarView`, `PrinterSidebarRow`, `PrinterDetailView`, `PrinterHeaderView` |

## Design-System (`Design/Components/`) – implementiert, verbindliche Signaturen

Die Komponenten sind fertig implementiert (`Cards.swift`, `Status.swift`, `Background.swift`,
`PrinterIllustration.swift`, `NavigationComponents.swift`, `Metrics.swift`, `Feedback.swift`,
`Inputs.swift`, `Buttons.swift`, `LabelViews.swift`, `CodeEditor.swift`). Vor der Verwendung den
Quelltext lesen. Zusätzlich vorhanden: `LabelElementPainter`, `SyntaxHighlighter`, `CodeTextView`,
`Comparable.clamped(to:)`.

```swift
struct GlassCard<Content: View>: View {
    init(padding: CGFloat = Theme.Metrics.padding, cornerRadius: CGFloat = Theme.Metrics.corner,
         tint: Color? = nil, @ViewBuilder content: () -> Content)
}
extension View {
    func labelWerkGlass(cornerRadius: CGFloat = Theme.Metrics.corner, tint: Color? = nil) -> some View // Liquid Glass ab macOS 26, sonst Material + Rand + Schatten
    func shimmering(active: Bool = true) -> some View
    func cardHoverEffect() -> some View          // leichtes Anheben/Schatten bei Hover
}
struct StatusOrb: View { init(state: PrinterState, size: CGFloat = 12) }            // pulsiert bei printing/error/warning
struct StatusPill: View { init(state: PrinterState, text: String? = nil) }
struct IconBadge: View { init(systemImage: String, tint: Color, size: CGFloat = 34) } // Verlaufs-Quadrat mit Symbol
enum AnimatedBackgroundStyle: Equatable { case brand, subtle, state(PrinterState) }
struct AnimatedBackground: View { init(style: AnimatedBackgroundStyle) }             // MeshGradient (macOS 15+) bzw. Verläufe, sanft animiert
struct PrinterIllustration: View {
    init(state: PrinterState, isPrinting: Bool, accent: Color,
         category: PrinterCategory = .desktop, labelAspect: CGFloat = 1.5, printTrigger: Int = 0)
}   // animierter Drucker; printTrigger-Änderung → Etikett fährt heraus
struct AnimatedTabBar<Item: Hashable>: View {
    init(items: [Item], selection: Binding<Item>, title: @escaping (Item) -> String, systemImage: @escaping (Item) -> String)
}
struct SectionHeader<Trailing: View>: View {
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, @ViewBuilder trailing: () -> Trailing)
}
extension SectionHeader where Trailing == EmptyView { init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) }
struct MetricTile: View {
    init(title: String, value: String, unit: String? = nil, systemImage: String, tint: Color, trend: [Double]? = nil)
}
struct RingGauge: View {
    init(value: Double, lineWidth: CGFloat = 10, colors: [Color] = [Theme.violet, Theme.teal],
         label: String? = nil, valueText: String? = nil)   // value 0…1, animiert
}
struct ProgressRing: View { init(progress: Double?, size: CGFloat = 28, lineWidth: CGFloat = 4) } // nil = unbestimmt (drehend)
struct StripedProgressBar: View { init(progress: Double?, tint: Color = Theme.accent) }
struct Sparkline: View { init(values: [Double], tint: Color) }
struct KeyValueRow: View { init(_ key: String, _ value: String, monospaced: Bool = false, copyable: Bool = false) }
struct EmptyStateView: View {
    init(title: String, message: String, systemImage: String, actionTitle: String? = nil, action: (() -> Void)? = nil)
}
struct HoldToConfirmButton: View {
    init(title: String, systemImage: String, tint: Color = Theme.error, duration: Double = 1.2, action: @escaping () -> Void)
}
struct ToastOverlay: View { init() }                         // liest AppModel.toasts aus der Umgebung
struct PulseRings: View { init(color: Color, active: Bool = true) }   // Radar-Wellen (Suche)
struct CelebrationBurst: View { init(trigger: Int, colors: [Color] = [Theme.violet, Theme.teal, Theme.magenta]) } // Partikel bei Erfolg
struct OptionalStepper: View {
    init(title: String, value: Binding<Int?>, range: ClosedRange<Int>, step: Int = 1, defaultValue: Int, unit: String? = nil)
}   // „Druckerwert“-Schalter + Stepper/Slider; nil = Druckerwert
struct NumberStepperField: View {
    init(title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: String? = nil)
}
struct LabelSheet<Content: View>: View {                     // Etikett auf Trägerpapier, Seitenverhältnis widthMM:heightMM
    init(widthMM: Double, heightMM: Double, @ViewBuilder content: () -> Content)
}
struct LabelCanvas: View {                                   // Vektor-Rendering einer RenderedLabel-Displayliste (Canvas)
    init(label: RenderedLabel, showsGrid: Bool = false, highlightedElement: Int? = nil)
}
struct BitmapPreview: View { init(bitmap: MonoBitmap) }      // pixelgenau (ohne Interpolation), seitenverhältnistreu
struct GrayImagePreview: View { init(image: GrayImage) }
enum CodeLanguage { case zpl, sgd, plain }
struct CodeEditor: View {                                    // NSTextView mit Syntaxhervorhebung, Zeilennummern
    init(text: Binding<String>, language: CodeLanguage = .zpl, isEditable: Bool = true,
         fontSize: CGFloat = 12.5, onSubmit: (() -> Void)? = nil)  // onSubmit: ⌘↩
}
extension ButtonStyle where Self == LabelWerkButtonStyle {
    static var labelWerkPrimary: LabelWerkButtonStyle      // Markenverlauf, weiße Schrift, Druck-Animation
    static var labelWerkSecondary: LabelWerkButtonStyle    // Glas/Material
    static var labelWerkDestructive: LabelWerkButtonStyle
    static var labelWerkPlain: LabelWerkButtonStyle        // nur Hover-Hervorhebung
}
```

## Feature-Bereiche (je eine Root-View mit exakt dieser Signatur)

Alle Bereiche sind vollständig implementiert (Spalte „Stand“); `DashboardView`, `HistoryView`,
`MenuBarView` und `AppSettingsView` dienen als Stil- und Qualitätsreferenz für Erweiterungen.
Druckerbereiche (`PrinterSection` in `Model/Navigation.swift`) erscheinen in der Tab-Leiste von
`PrinterDetailView` nur, wenn sie zu Modell und Verbindung passen
(`PrinterSection.available(for:descriptor:developerMode:)`: Dateien, Sicherung & Wartung und RFID
nur mit bidirektionaler Verbindung, Netzwerk nur mit Netzwerkschnittstelle, RFID nur bei Modellen
mit RFID-Option).

| Datei/Ordner | Root-View | Inhalt | Stand |
|---|---|---|---|
| `Features/Dashboard` | `DashboardView(session: PrinterSession)` | Übersicht: animierter Drucker, Status/Alarme mit Lösungsschritten, Kennzahlen, Schnellaktionen, Identität, letzte Aufträge, Demo-Steuerung | ✔ implementiert |
| `Features/Preferences` | `PrintPreferencesView(session: PrinterSession)` | „Druckeinstellungen für …“ wie der Windows-Treiber ZDesigner: Seitenleiste (Seite einrichten, Druckoptionen, Bedienermodus, Grafik Optionen, Kundenspezifische Befehle, Wartung, Einheiten, Hilfe und Über) mit „Testseite drucken“, Stift-Menü je Wert (Treiberwert/Druckerwert/Vom Drucker lesen), animierte „Druckvorschau“, OK/Abbrechen/Übernehmen/Hilfe. Entwurf je Drucker (`PrintPrefsEditor`); gespeichert wird mit OK/Übernehmen in `saved.settings` und – falls vorhanden – als Standard der macOS-Warteschlange. Wartung: Senden, Dauerhaft speichern (`^JUS`), Kalibrieren, Echtzeituhr, Profil-Import/-Export (`PrinterSession+Preferences.swift`: `readPrintSettings`, `syncClock`, `printTestPage`) | ✔ implementiert |
| `Features/Stocks` | `StocksView(session: PrinterSession)` | Etikettenformate (Katalog + eigene), Auswahl, Anlegen/Bearbeiten, Maße vom Drucker übernehmen | ✔ implementiert |
| `Features/Tools` | `ToolsView(session: PrinterSession)` | Gerätebefehle (`PrinterAction`), Konfiguration (`^HH`), SGD-Explorer (Filter, Bearbeitung, JSON-Export), Kalibrier-Assistent, Testseite über macOS | ✔ implementiert |
| `Features/Terminal` | `TerminalView(session: PrinterSession)` | ZPL/SGD/JSON-Konsole mit Hervorhebung, Verlauf, Autovervollständigung, Befehlsreferenz, Hex-Ansicht, Dateiversand, Export | ✔ implementiert |
| `Features/Designer` | `DesignerView()` | ZPL-Editor + Live-Vorschau, Vorlagen, Bausteine, Bild/PDF → Etikett mit Rasterungsvergleich, Drucken/Exportieren | ✔ implementiert |
| `Features/Files` | `FilesView(session: PrinterSession)` | Dateien auf dem Drucker, Speicherbelegung, Schriften (TTF) & Grafiken hochladen/löschen, Probedruck | ✔ implementiert |
| `Features/Network` | `NetworkView(session: PrinterSession)` | IP/DHCP/Gateway/DNS/WLAN/Bluetooth lesen & setzen, Live-Prüfung, Änderungsübersicht | ✔ implementiert |
| `Features/Maintenance` | `MaintenanceView(session: PrinterSession)` | „Sicherung & Wartung“: Konfiguration als `.lwbackup` sichern, wiederherstellen und auf andere Drucker klonen (Wert-für-Wert-Vergleich), Gerätesprache (`device.languages`) umstellen, Druckkopf-Zähler mit Reinigungserinnerung, Druckkopftest, Reinigungsanleitung | ✔ implementiert |
| `Features/RFID` | `RFIDView(session: PrinterSession)` | Status des Kodierers, Tags lesen (EPC/TID/Benutzerspeicher, Dekodierung), Tags schreiben (Serien, SGTIN-96, Prüfung durch Rücklesen, bedruckte Etiketten), `^HR`-Kalibrierung, Programmierposition, Sendeleistung, RFID-SGD-Variablen | ✔ implementiert |
| `Features/Firmware` | `FirmwareView(session: PrinterSession)` | Firmware-Datei prüfen (Version, Modell, SHA-256) & übertragen mit Fortschritt, Neustart-Countdown und Wiederverbindung | ✔ implementiert |
| `Features/History` | `HistoryView(printerID: UUID?)` | Auftragsverlauf mit Vorschau, Filter, Statistik, erneut drucken, CSV-Export | ✔ implementiert |
| `Features/Driver` | `DriverView()` | Treiberstatus, Installation/Update/Reparatur, macOS-Warteschlangen verwalten, Diagnose | ✔ implementiert |
| `Features/Discovery` | `DiscoveryView()`, `AddPrinterView(initialTab: DiscoveryPanelTab = .search)` | Suche (Bonjour, USB, Netzwerk, CUPS, Bluetooth) mit Radar-Animation, manuelles Hinzufügen, Warnung bei Geräten, die sich nicht als Zebra-Drucker zu erkennen geben | ✔ implementiert |
| `Features/Onboarding` | `OnboardingView()` | Erststart-Assistent (Willkommen → Treiber → Drucker → Mitteilungen → Fertig) | ✔ implementiert |
| `Features/MenuBar` | `MenuBarView()` | Menüleisten-Fenster: alle Drucker mit Status, Schnellaktionen | ✔ implementiert |
| `Features/Settings` | `AppSettingsView()` | App-Einstellungen (`AppPreferences`), Tabs Allgemein, Drucken, Erweitert, Updates, Über | ✔ implementiert |
| `Features/Updates` | `UpdateBanner()`, `UpdateDetailsSheet()`, `UpdateSettingsView()`, `UpdateMenuBarSection(openMain:)` | Update-Dienst: Hinweis „Update verfügbar“ über den Toasts im Hauptfenster, Details-Sheet (Änderungen als Markdown, Fortschritt, Jetzt installieren/Später/Überspringen), Einstellungen › Updates (automatisch suchen/laden, Jetzt suchen, Token für private Repositorys), Zeile im Menüleisten-Fenster; Menü „LabelWerk › Nach Updates suchen …“, Druckeinstellungen › Hilfe und Über | ✔ implementiert |
