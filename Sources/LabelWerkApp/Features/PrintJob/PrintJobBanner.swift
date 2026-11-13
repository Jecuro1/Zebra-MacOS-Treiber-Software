import SwiftUI
import LabelWerkKit

/// Laufende Druckaufträge aller Drucker (oben im Hauptfenster und im Etikettendruck-Fenster): „Etikett 37
/// von 50“ mit Fortschritt; hält der Drucker an, ein deutlicher Hinweis wie „Papier leer – neue
/// Etikettenrolle einlegen. Der Druck geht danach automatisch weiter.“ – jeweils mit „Abbrechen“.
struct PrintJobBannerStack: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appReduceMotion) private var appReduceMotion

    init() {}

    private var reduceMotion: Bool { systemReduceMotion || appReduceMotion }

    private var activeSessions: [PrinterSession] {
        model.sessions.filter { $0.printJob != nil }
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(activeSessions) { session in
                if let job = session.printJob {
                    PrintJobBanner(session: session, job: job, reduceMotion: reduceMotion)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: 560)
        .animation(reduceMotion ? nil : Motion.spring, value: activeSessions.map(\.id))
    }
}

/// Ein laufender Auftrag.
struct PrintJobBanner: View {
    let session: PrinterSession
    let job: PrintJobProgress
    let reduceMotion: Bool

    private var tint: Color {
        guard let reason = job.waiting else { return job.reconnecting ? Theme.warning : Theme.printing }
        switch reason {
        case .mediaOut, .ribbonOut, .headOpen: return Theme.error
        case .paused, .labelWaitingToBePeeled, .headTemperature: return Theme.warning
        }
    }

    private var symbol: String {
        if let reason = job.waiting { return PrintJobProgress.systemImage(for: reason) }
        if job.reconnecting { return "wifi.exclamationmark" }
        return "printer.dotmatrix.filled.and.paper"
    }

    private var headline: String {
        if job.isCancelling { return tr("Wird abgebrochen …") }
        if let reason = job.waiting { return PrintJobProgress.title(for: reason) }
        if job.reconnecting { return tr("Verbindung unterbrochen") }
        return job.paced ? job.counterText : tr("Wird gesendet …")
    }

    /// Erklärung unter der Überschrift.
    private var detail: String {
        if let reason = job.waiting { return PrintJobProgress.message(for: reason) }
        if job.reconnecting { return tr("LabelWerk verbindet neu und druckt danach weiter – kein Etikett geht verloren.") }
        return tr("%@ · %@", session.displayName, job.title)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.16))
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: job.waiting?.isFault == true && !reduceMotion)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(headline)
                        .font(.system(size: 14, weight: .semibold))
                        .contentTransition(.numericText())
                    Spacer(minLength: 8)
                    if job.waiting != nil, job.total > 0 {
                        // Beim Warten bleibt der Stand sichtbar.
                        Text(job.counterText)
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(job.waiting?.isFault == true ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if job.waiting != nil {
                    Text(tr("%@ · %@", session.displayName, job.title))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let fraction = job.fraction {
                    ProgressView(value: fraction)
                        .tint(tint)
                        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(tint)
                }
                if session.queuedPrintJobs > 0 {
                    HStack(spacing: 8) {
                        Text(tr("Weitere Aufträge warten: %d", session.queuedPrintJobs))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Button(tr("Wartende verwerfen")) { session.cancelWaitingPrintJobs() }
                            .buttonStyle(.link)
                            .font(.system(size: 11.5))
                            .help(tr("Die wartenden Aufträge werden nicht gesendet. Der laufende Auftrag druckt weiter."))
                    }
                }
            }

            Button(tr("Abbrechen")) { session.cancelPrintJob() }
                .buttonStyle(.labelWerkSecondary)
                .controlSize(.small)
                .disabled(job.isCancelling)
                .help(tr("Bricht den Auftrag ab und leert den Speicher des Druckers. Bereits gedruckte Etiketten bleiben im Verlauf vermerkt."))
        }
        .padding(14)
        .labelWerkGlass(cornerRadius: 16, tint: tint)
        .overlay(alignment: .leading) {
            Capsule().fill(tint).frame(width: 3).padding(.vertical, 12).padding(.leading, 4)
        }
        .animation(reduceMotion ? nil : Motion.snappy, value: job)
        .accessibilityElement(children: .contain)
    }
}
