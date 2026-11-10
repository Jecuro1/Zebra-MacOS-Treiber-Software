import SwiftUI
import LabelWerkKit

/// Design-Tokens von LabelWerk: Farben, Verläufe, Abstände, Radien, Typografie.
///
/// Alle Views verwenden ausschließlich diese Tokens (keine hart codierten Farben), damit Hell-/
/// Dunkelmodus und Akzentfarben konsistent bleiben.
enum Theme {
    // MARK: Markenfarben

    static let indigo = Color(red: 0.24, green: 0.20, blue: 0.62)
    static let violet = Color(red: 0.49, green: 0.36, blue: 0.99)
    static let teal = Color(red: 0.10, green: 0.78, blue: 0.80)
    static let magenta = Color(red: 0.86, green: 0.31, blue: 0.78)

    /// Primäre Akzentfarbe (Buttons, Auswahl).
    static let accent = violet

    /// Markenverlauf (Hero-Flächen, Primärbuttons, App-Icon-Anmutung).
    static let brandGradient = LinearGradient(
        colors: [indigo, violet, teal],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let brandAngularGradient = AngularGradient(
        colors: [violet, teal, magenta, violet],
        center: .center
    )

    // MARK: Statusfarben

    static let ready = Color(red: 0.20, green: 0.80, blue: 0.47)
    static let printing = Color(red: 0.25, green: 0.56, blue: 1.00)
    static let paused = Color(red: 1.00, green: 0.78, blue: 0.20)
    static let warning = Color(red: 1.00, green: 0.58, blue: 0.16)
    static let error = Color(red: 1.00, green: 0.27, blue: 0.33)
    static let offline = Color(white: 0.55)

    static func color(for state: PrinterState) -> Color {
        switch state {
        case .ready: return ready
        case .printing: return printing
        case .paused: return paused
        case .warning: return warning
        case .error: return error
        case .offline, .unknown: return offline
        }
    }

    static func color(for severity: AlertSeverity) -> Color {
        switch severity {
        case .info: return printing
        case .warning: return warning
        case .error: return error
        }
    }

    static func gradient(for state: PrinterState) -> LinearGradient {
        let base = color(for: state)
        return LinearGradient(colors: [base.opacity(0.95), base.opacity(0.65)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Flächen

    /// Kartenhintergrund (Material + feiner Rand werden in `GlassCard` ergänzt).
    static let cardStroke = Color.primary.opacity(0.08)
    static let subtleFill = Color.primary.opacity(0.045)
    static let separator = Color.primary.opacity(0.1)

    /// Papierfarbe der Etikettenvorschau.
    static let labelPaper = Color(red: 0.995, green: 0.99, blue: 0.975)
    static let labelInk = Color(red: 0.08, green: 0.08, blue: 0.1)

    // MARK: Maße

    enum Metrics {
        static let cornerSmall: CGFloat = 8
        static let corner: CGFloat = 14
        static let cornerLarge: CGFloat = 22
        static let padding: CGFloat = 16
        static let paddingLarge: CGFloat = 24
        static let spacing: CGFloat = 12
        static let cardSpacing: CGFloat = 16
        static let sidebarWidth: CGFloat = 260
        static let contentMaxWidth: CGFloat = 1180
    }

    // MARK: Typografie

    enum Typography {
        static let hero = Font.system(size: 34, weight: .bold, design: .rounded)
        static let title = Font.system(size: 24, weight: .bold, design: .rounded)
        static let headline = Font.system(size: 15, weight: .semibold, design: .rounded)
        static let metric = Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
        static let metricSmall = Font.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit()
        static let caption = Font.system(size: 11, weight: .medium)
        static let code = Font.system(size: 12.5, weight: .regular, design: .monospaced)
        static let codeSmall = Font.system(size: 11, weight: .regular, design: .monospaced)
    }
}

/// Animationsvorgaben. `Motion.animation(_:)` respektiert „Bewegung reduzieren“.
enum Motion {
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let bouncy = Animation.spring(response: 0.5, dampingFraction: 0.62)
    static let snappy = Animation.snappy(duration: 0.28)
    static let gentle = Animation.easeInOut(duration: 0.6)
    static let slow = Animation.easeInOut(duration: 1.2)

    /// Liefert `nil` (keine Animation), wenn Bewegung reduziert werden soll.
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - App-Einstellung „Bewegung reduzieren“

private struct AppReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// App-eigene Einstellung „Bewegung zusätzlich reduzieren“ (wird in `RootView` gesetzt).
    /// Komponenten kombinieren sie mit `accessibilityReduceMotion`.
    var appReduceMotion: Bool {
        get { self[AppReduceMotionKey.self] }
        set { self[AppReduceMotionKey.self] = newValue }
    }
}

// MARK: - Anzeige-Erweiterungen für Statusmodelle

extension PrinterState {
    var displayName: String {
        switch self {
        case .ready: return tr("Bereit")
        case .printing: return tr("Druckt")
        case .paused: return tr("Pausiert")
        case .warning: return tr("Warnung")
        case .error: return tr("Fehler")
        case .offline: return tr("Offline")
        case .unknown: return tr("Unbekannt")
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .printing: return "printer.fill"
        case .paused: return "pause.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .offline: return "wifi.slash"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color { Theme.color(for: self) }
}

extension AlertSeverity {
    var color: Color { Theme.color(for: self) }
}
