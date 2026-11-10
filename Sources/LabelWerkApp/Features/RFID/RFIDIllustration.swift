import SwiftUI
import LabelWerkKit

/// Animierte Darstellung von Kodierer-Antenne, Funkwellen und RFID-Etikett.
///
/// * Ruhezustand: statische, dezente Wellen (keine laufende Zeitleiste).
/// * Lesen: Wellen laufen zur Antenne, Datenbits wandern vom Tag nach oben.
/// * Schreiben: Datenbits wandern von der Antenne in den Tag.
/// * Kalibrieren: Das Etikett gleitet unter der Antenne hin und her.
/// * `successTrigger`/`failureTrigger` lassen den Tag aufleuchten bzw. kurz schütteln.
struct RFIDAntennaIllustration: View {
    let activity: RFIDRadioActivity
    let successTrigger: Int
    let failureTrigger: Int
    let reduceMotion: Bool

    init(activity: RFIDRadioActivity, successTrigger: Int, failureTrigger: Int, reduceMotion: Bool) {
        self.activity = activity
        self.successTrigger = successTrigger
        self.failureTrigger = failureTrigger
        self.reduceMotion = reduceMotion
    }

    private var animating: Bool { activity.isActive && !reduceMotion }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let shift = animating && activity == .calibrating ? sin(time * 1.7) * Double(width) * 0.09 : 0
                ZStack(alignment: .top) {
                    Canvas { context, size in
                        RFIDWavePainter.draw(context: &context, size: size, time: time,
                                             activity: animating ? activity : .idle)
                    }
                    .frame(width: width, height: height)

                    reader
                        .frame(width: width * 0.56, height: height * 0.2)
                        .offset(y: height * 0.02)

                    RFIDTagGlyph(energy: animating ? 0.55 + 0.45 * sin(time * 7) : 0,
                                 tint: activity.tint)
                        .frame(width: width * 0.8, height: height * 0.3)
                        .keyframeAnimator(initialValue: RFIDPingValues(),
                                          trigger: reduceMotion ? 0 : successTrigger) { content, value in
                            content
                                .scaleEffect(value.scale)
                                .shadow(color: Theme.ready.opacity(value.glow), radius: 16)
                        } keyframes: { _ in
                            KeyframeTrack(\RFIDPingValues.scale) {
                                SpringKeyframe(1.12, duration: 0.18, spring: .snappy)
                                SpringKeyframe(1.0, duration: 0.55, spring: .bouncy)
                            }
                            KeyframeTrack(\RFIDPingValues.glow) {
                                LinearKeyframe(0.9, duration: 0.15)
                                LinearKeyframe(0.0, duration: 0.9)
                            }
                        }
                        .keyframeAnimator(initialValue: 0.0, trigger: reduceMotion ? 0 : failureTrigger) { content, offset in
                            content.offset(x: offset)
                        } keyframes: { _ in
                            CubicKeyframe(-9, duration: 0.06)
                            CubicKeyframe(8, duration: 0.08)
                            CubicKeyframe(-6, duration: 0.08)
                            CubicKeyframe(4, duration: 0.08)
                            SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                        }
                        .offset(x: CGFloat(shift), y: height * 0.66)
                }
                .frame(width: width, height: height, alignment: .top)
            }
        }
        .aspectRatio(1.1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(tr("RFID-Antenne: %@", activity.displayName))
    }

    /// Kodierer mit Antennensymbol und Status-LED.
    private var reader: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [Theme.labelInk.opacity(0.78), Theme.labelInk],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.18), .clear],
                                          startPoint: .top, endPoint: .center))
            }
            .overlay { shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1) }
            .overlay {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: animating)
                    Circle()
                        .fill(activity.tint)
                        .frame(width: 7, height: 7)
                        .shadow(color: activity.tint.opacity(0.9), radius: 4)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            .animation(Motion.animation(Motion.gentle, reduceMotion: reduceMotion), value: activity)
    }
}

/// Werte der „Erfolg“-Animation des Tags.
struct RFIDPingValues {
    var scale: Double = 1
    var glow: Double = 0
}

/// Zeichnet Funkwellen und wandernde Datenbits.
enum RFIDWavePainter {
    static func draw(context: inout GraphicsContext, size: CGSize, time: TimeInterval, activity: RFIDRadioActivity) {
        let center = CGPoint(x: size.width / 2, y: size.height * 0.2)
        let tagTop = size.height * 0.64
        let maxRadius = max(1, tagTop - center.y)
        let tint = activity.isActive ? activity.tint : Theme.violet

        for ring in 0..<4 {
            let phase: Double
            let opacity: Double
            if activity.isActive {
                let speed = activity == .reading ? -0.9 : 0.9
                let raw = (time * speed + Double(ring) / 4).truncatingRemainder(dividingBy: 1)
                phase = raw < 0 ? raw + 1 : raw
                opacity = 0.85 * (1 - phase) + 0.1
            } else {
                phase = Double(ring + 1) / 5
                opacity = 0.22 - Double(ring) * 0.04
            }
            let radius = maxRadius * CGFloat(0.22 + 0.78 * phase)
            context.stroke(arc(center: center, radius: radius), with: .color(tint.opacity(opacity)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // Datenbits zwischen Antenne und Tag.
        guard activity == .reading || activity == .writing else { return }
        let travel = tagTop - center.y - 8
        for bit in 0..<5 {
            let raw = (time * 0.8 + Double(bit) / 5).truncatingRemainder(dividingBy: 1)
            let progress = activity == .writing ? raw : 1 - raw
            let y = center.y + 6 + travel * CGFloat(progress)
            let side: CGFloat = 5
            let rect = CGRect(x: size.width / 2 - side / 2 + CGFloat(bit % 2 == 0 ? -7 : 7), y: y - side / 2,
                              width: side, height: side)
            let fade = sin(Double.pi * raw)
            let shape = Path(roundedRect: rect, cornerRadius: 1.5)
            if bit % 2 == 0 {
                context.fill(shape, with: .color(tint.opacity(fade)))
            } else {
                context.stroke(shape, with: .color(tint.opacity(fade)), lineWidth: 1.2)
            }
        }
    }

    /// Bogen nach unten (Öffnungswinkel ca. 120°).
    static func arc(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        var first = true
        for degrees in stride(from: 30.0, through: 150.0, by: 6.0) {
            let radians = degrees * .pi / 180
            let point = CGPoint(x: center.x + radius * CGFloat(cos(radians)),
                                y: center.y + radius * CGFloat(sin(radians)))
            if first {
                path.move(to: point)
                first = false
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

/// Etikett mit RFID-Inlay (Dipol-Mäander und Chip).
struct RFIDTagGlyph: View {
    /// 0 = ruhend, 1 = voll angeregt.
    let energy: Double
    let tint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack {
            shape
                .fill(Theme.labelPaper)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
            Canvas { context, size in
                RFIDInlayPainter.draw(context: &context, size: size, energy: energy, tint: tint)
            }
            .padding(6)
        }
        .overlay { shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.6) }
    }
}

/// Zeichnet das Inlay eines UHF-Etiketts.
enum RFIDInlayPainter {
    static func draw(context: inout GraphicsContext, size: CGSize, energy: Double, tint: Color,
                     dashed: Bool = false) {
        let midY = size.height / 2
        let chip = max(4, min(size.width, size.height) * 0.2)
        let inset = size.width * 0.05
        let amplitude = size.height * 0.3
        let leftStart = size.width / 2 - chip * 0.9
        let rightStart = size.width / 2 + chip * 0.9

        let idle = Theme.offline
        let color = energy > 0 ? tint.opacity(0.45 + 0.55 * energy) : idle.opacity(dashed ? 0.55 : 0.85)
        let style = StrokeStyle(lineWidth: max(1.2, size.height * 0.035), lineCap: .round, lineJoin: .round,
                                dash: dashed ? [4, 3] : [])

        context.stroke(meander(from: leftStart, to: inset, midY: midY, amplitude: amplitude, turns: 6),
                       with: .color(color), style: style)
        context.stroke(meander(from: rightStart, to: size.width - inset, midY: midY, amplitude: amplitude, turns: 6),
                       with: .color(color), style: style)

        // Anpassschleife um den Chip.
        let loop = CGRect(x: size.width / 2 - chip * 0.9, y: midY - chip * 0.9, width: chip * 1.8, height: chip * 1.8)
        context.stroke(Path(roundedRect: loop, cornerRadius: chip * 0.3), with: .color(color), style: style)

        // Chip.
        let chipRect = CGRect(x: size.width / 2 - chip / 2, y: midY - chip / 2, width: chip, height: chip)
        context.fill(Path(roundedRect: chipRect, cornerRadius: chip * 0.18),
                     with: .color(energy > 0 ? tint : Theme.labelInk.opacity(dashed ? 0.4 : 0.85)))
        if energy > 0 {
            var glow = context
            glow.addFilter(.blur(radius: chip * 0.5))
            glow.fill(Path(ellipseIn: chipRect.insetBy(dx: -chip * 0.3, dy: -chip * 0.3)),
                      with: .color(tint.opacity(0.5 * energy)))
        }
    }

    /// Rechteck-Mäander von `start` nach `end` (beide Richtungen möglich).
    static func meander(from start: CGFloat, to end: CGFloat, midY: CGFloat, amplitude: CGFloat, turns: Int) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: start, y: midY))
        let count = max(1, turns)
        let step = (end - start) / CGFloat(count)
        var x = start
        for turn in 0..<count {
            let y = midY + (turn % 2 == 0 ? -amplitude : amplitude)
            path.addLine(to: CGPoint(x: x, y: y))
            x += step
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: x, y: midY))
        return path
    }
}
