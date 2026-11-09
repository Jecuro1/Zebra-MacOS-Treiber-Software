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
| `Model/AppTypes.swift` | `SavedPrinter`, `JobRecord`, `AppPreferences`, `AppearancePreference`, `PersistedState`, `Toast`, `ConnectionState`, `StatusSample` |
| `Model/Navigation.swift` | `SidebarItem`, `PrinterSection` |
| `Model/AppModel.swift` | `AppModel` (Drucker, Auswahl, Etiketten, Verlauf, Einstellungen, Toasts) |
| `Model/PrinterSession.swift` | `PrinterSession` (Verbindung, Status, alle Geräteoperationen) |
| `Model/PersistenceStore.swift` | JSON-Persistenz |
| `Services/ProcessRunner.swift` | Prozesse, Admin-Rechte via osascript |
| `Services/CUPSService.swift` | Warteschlangen anlegen/ändern/entfernen, PPD-Suche, Treiberstatus |
| `Services/NotificationService.swift` | Systembenachrichtigungen, `SoundService` |
| `Services/ImageImport.swift` | Bild/PDF → `CGImage`/`GrayImage`, Einpassen (`ImageFitMode`), `MonoBitmap`/`GrayImage` → `CGImage`/`NSImage` |
| `Design/Theme.swift` | `Theme`, `Motion`, `PrinterState.displayName/systemImage/color`, `AlertSeverity.color` |
| `Features/Root/*` | `RootView`, `DetailRouter`, `SidebarView`, `PrinterSidebarRow`, `PrinterDetailView`, `PrinterHeaderView` |

## Design-System (`Design/Components/`) – verbindliche Signaturen

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

| Datei/Ordner | Root-View | Inhalt |
|---|---|---|
| `Features/Dashboard` | `DashboardView(session: PrinterSession)` | Übersicht: animierter Drucker, Status/Alarme mit Lösungsschritten, Kennzahlen, Schnellaktionen, Identität, letzte Aufträge, Demo-Steuerung |
| `Features/Preferences` | `PrintPreferencesView(session: PrinterSession)` | Alle `PrintSettings` mit Live-Vorschau; „An Drucker senden“, „Dauerhaft speichern“, „Als macOS-Standard übernehmen“ |
| `Features/Stocks` | `StocksView(session: PrinterSession)` | Etikettenformate (Katalog + eigene), Auswahl, Anlegen/Bearbeiten |
| `Features/Tools` | `ToolsView(session: PrinterSession)` | Gerätebefehle (`PrinterAction`), Konfiguration (`^HH`), SGD-Explorer, Kalibrier-Assistent |
| `Features/Terminal` | `TerminalView(session: PrinterSession)` | ZPL/SGD-Konsole mit Hervorhebung, Verlauf, Autovervollständigung, Hex-Ansicht |
| `Features/Designer` | `DesignerView()` | ZPL-Editor + Live-Vorschau, Vorlagen, Bild/PDF → Etikett, Drucken/Exportieren |
| `Features/Files` | `FilesView(session: PrinterSession)` | Dateien auf dem Drucker, Schriften (TTF) & Grafiken hochladen/löschen |
| `Features/Network` | `NetworkView(session: PrinterSession)` | IP/DHCP/Gateway/WLAN/Bluetooth lesen & setzen |
| `Features/Firmware` | `FirmwareView(session: PrinterSession)` | Firmware-Datei prüfen & übertragen mit Fortschritt |
| `Features/History` | `HistoryView(printerID: UUID?)` | Auftragsverlauf mit Vorschau, Filter, erneut drucken |
| `Features/Driver` | `DriverView()` | Treiberstatus, Installation/Update, macOS-Warteschlangen verwalten |
| `Features/Discovery` | `DiscoveryView()`, `AddPrinterView()` | Suche (Bonjour, USB, Netzwerk, CUPS, Bluetooth) mit Radar-Animation, manuelles Hinzufügen |
| `Features/Onboarding` | `OnboardingView()` | Erststart-Assistent (Willkommen → Treiber → Drucker → fertig) |
| `Features/MenuBar` | `MenuBarView()` | Menüleisten-Fenster: alle Drucker mit Status, Schnellaktionen |
| `Features/Settings` | `AppSettingsView()` | App-Einstellungen (`AppPreferences`) |
