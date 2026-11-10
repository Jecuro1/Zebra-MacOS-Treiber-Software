import SwiftUI
import LabelWerkKit

/// Eine Station im Druckweg (Programm → CUPS → rastertolabelwerk → Drucker).
struct DriverPipelineStage: Identifiable, Equatable {
    enum Health: Equatable { case ok, missing, idle }

    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let health: Health

    /// Standard-Druckweg mit dem aktuellen Zustand des Treibers.
    @MainActor
    static func standard(installer: DriverInstaller, printerName: String? = nil) -> [DriverPipelineStage] {
        [
            DriverPipelineStage(id: "app", title: tr("Programm"), subtitle: tr("Druckdialog ⌘P"),
                                systemImage: "macwindow", tint: Theme.violet, health: .ok),
            DriverPipelineStage(id: "cups", title: "CUPS", subtitle: tr("macOS-Druckdienst"),
                                systemImage: "server.rack", tint: Theme.indigo,
                                health: installer.schedulerRunning == false ? .missing : .ok),
            DriverPipelineStage(id: "filter", title: "rastertolabelwerk", subtitle: tr("LabelWerk-Filter"),
                                systemImage: "cpu", tint: Theme.teal,
                                health: installer.isInstalled ? .ok : .missing),
            DriverPipelineStage(id: "printer", title: tr("Drucker"), subtitle: printerName ?? "ZPL · EPL · CPCL",
                                systemImage: "printer.fill", tint: Theme.magenta,
                                health: printerName == nil ? .idle : .ok),
        ]
    }
}

/// Animiertes Schaubild des Druckwegs. Bei `isActive` fließen Datenpakete von Station zu Station;
/// fehlt eine Station (z. B. Filter nicht installiert), ist die Verbindung unterbrochen dargestellt.
struct DriverPipelineDiagram: View {
    let stages: [DriverPipelineStage]
    let isActive: Bool
    var compact: Bool = false
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                DriverPipelineNode(stage: stage, isActive: isActive && stage.health == .ok,
                                   compact: compact, reduceMotion: reduceMotion)
                if index < stages.count - 1 {
                    let next = stages[index + 1]
                    let broken = stage.health == .missing || next.health == .missing
                    DriverPipelineConnector(
                        active: isActive && !broken && !reduceMotion,
                        broken: broken,
                        tint: next.tint,
                        phaseOffset: Double(index) * 0.21
                    )
                    .frame(height: compact ? 38 : 50)
                    .frame(minWidth: 24, maxWidth: .infinity)
                }
            }
        }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: stages)
        .animation(Motion.animation(Motion.gentle, reduceMotion: reduceMotion), value: isActive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("Druckweg: Programm, CUPS, LabelWerk-Filter, Drucker"))
    }
}

// MARK: - Station

private struct DriverPipelineNode: View {
    let stage: DriverPipelineStage
    let isActive: Bool
    let compact: Bool
    let reduceMotion: Bool

    var body: some View {
        let size: CGFloat = compact ? 38 : 50
        let tint = stage.health == .missing ? Theme.offline : stage.tint
        VStack(spacing: compact ? 4 : 7) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.35))
                    .frame(width: size * 1.5, height: size * 1.5)
                    .blur(radius: size * 0.3)
                    .scaleEffect(isActive ? 1 : 0.6)
                    .opacity(isActive ? 1 : 0)
                IconBadge(systemImage: stage.systemImage, tint: tint, size: size)
                    .saturation(stage.health == .missing ? 0.2 : 1)
                    .symbolEffect(.pulse, options: .repeating, isActive: isActive && !reduceMotion && stage.id == "filter")
                healthBadge
                    .offset(x: size * 0.4, y: -size * 0.4)
            }
            .frame(width: size, height: size)
            VStack(spacing: 1) {
                Text(stage.title)
                    .font(.system(size: compact ? 10.5 : 12, weight: .semibold, design: stage.id == "filter" ? .monospaced : .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(stage.subtitle)
                    .font(.system(size: compact ? 9.5 : 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .multilineTextAlignment(.center)
        }
        .frame(width: compact ? 84 : 112)
    }

    @ViewBuilder
    private var healthBadge: some View {
        switch stage.health {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: compact ? 11 : 14, weight: .bold))
                .foregroundStyle(.white, Theme.ready)
                .background(Circle().fill(.background).padding(1))
                .transition(.scale.combined(with: .opacity))
        case .missing:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: compact ? 11 : 14, weight: .bold))
                .foregroundStyle(.white, Theme.error)
                .background(Circle().fill(.background).padding(1))
                .transition(.scale.combined(with: .opacity))
        case .idle:
            EmptyView()
        }
    }
}

// MARK: - Verbindung mit Datenpaketen

private struct DriverPipelineConnector: View {
    let active: Bool
    let broken: Bool
    let tint: Color
    let phaseOffset: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { timeline in
            Canvas { context, size in
                let midY = size.height / 2
                let start = CGPoint(x: 6, y: midY)
                let end = CGPoint(x: size.width - 10, y: midY)
                var line = Path()
                line.move(to: start)
                line.addLine(to: end)
                if broken {
                    context.stroke(line, with: .color(Theme.error.opacity(0.45)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5]))
                    return
                }
                context.stroke(
                    line,
                    with: .linearGradient(Gradient(colors: [tint.opacity(0.25), tint.opacity(active ? 0.85 : 0.55)]),
                                          startPoint: start, endPoint: end),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                // Pfeilspitze
                var arrow = Path()
                arrow.move(to: CGPoint(x: end.x - 5, y: midY - 5))
                arrow.addLine(to: CGPoint(x: end.x + 1, y: midY))
                arrow.addLine(to: CGPoint(x: end.x - 5, y: midY + 5))
                context.stroke(arrow, with: .color(tint.opacity(active ? 0.9 : 0.55)),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                guard active else { return }
                let t = timeline.date.timeIntervalSinceReferenceDate
                let span = max(1, end.x - start.x)
                for packet in 0..<3 {
                    let progress = (t * 0.65 + phaseOffset + Double(packet) / 3).truncatingRemainder(dividingBy: 1)
                    let x = start.x + span * CGFloat(progress)
                    let fade = min(1, min(progress, 1 - progress) * 6)
                    let rect = CGRect(x: x - 6, y: midY - 3, width: 12, height: 6)
                    context.fill(Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)), with: .color(tint.opacity(0.22 * fade)))
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(tint.opacity(fade)))
                    context.fill(Path(roundedRect: rect.insetBy(dx: 3, dy: 1.5), cornerRadius: 1.5),
                                 with: .color(Color.white.opacity(0.7 * fade)))
                }
            }
        }
        .overlay {
            if broken {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white, Theme.error)
                    .background(Circle().fill(.background).padding(1))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }
}
