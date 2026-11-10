import AppKit
import SwiftUI
import LabelWerkKit

// MARK: - Quellenschalter

/// Schalter für eine Suchquelle mit Symbol, Name und Trefferzahl.
struct DiscoverySourceToggle: View {
    let source: DiscoverySource
    @Binding var isOn: Bool
    let count: Int
    var compact: Bool = false
    var reduceMotion: Bool = false

    @State private var hovering = false

    var body: some View {
        let tint = DiscoverySourceStyle.tint(source)
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: DiscoverySourceStyle.systemImage(source))
                    .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                    .symbolEffect(.bounce, value: reduceMotion ? false : isOn)
                    .frame(width: compact ? 13 : 15)
                Text(DiscoverySourceStyle.title(source))
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .lineLimit(1)
                if count > 0 {
                    Text(count.formatted())
                        .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(value: Double(count)))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isOn ? Color.white.opacity(0.28) : tint.opacity(0.18)))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.75))
            .padding(.horizontal, compact ? 9 : 11)
            .padding(.vertical, compact ? 5 : 6)
            .background {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.72)],
                                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                               : AnyShapeStyle(Theme.subtleFill.opacity(hovering ? 2 : 1)))
                    .shadow(color: isOn ? tint.opacity(0.35) : .clear, radius: 6, y: 2)
            }
            .overlay(Capsule().strokeBorder(isOn ? Color.white.opacity(0.25) : Theme.cardStroke, lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: isOn)
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: hovering)
        .animation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion), value: count)
        .help(DiscoverySourceStyle.detail(source))
        .accessibilityLabel(DiscoverySourceStyle.title(source))
        .accessibilityValue(isOn ? tr("Ein") : tr("Aus"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Quellen-Abzeichen

struct DiscoverySourceBadge: View {
    let source: DiscoverySource

    var body: some View {
        let tint = DiscoverySourceStyle.tint(source)
        Label(DiscoverySourceStyle.title(source), systemImage: DiscoverySourceStyle.systemImage(source))
            .font(.system(size: 10.5, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.13)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.8))
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Trefferkarte

/// Karte eines gefundenen Druckers. Fliegt beim Erscheinen gestaffelt ein; „Hinzufügen“ verwandelt
/// sich nach dem Hinzufügen in ein grünes Häkchen.
struct DiscoveryPrinterCard: View {
    let printer: DiscoveredPrinter
    let isAdded: Bool
    let isHighlighted: Bool
    let appearDelay: Double
    let reduceMotion: Bool
    var compact: Bool = false
    let onAdd: () -> Void
    var onOpen: (() -> Void)?

    @State private var appeared = false
    @State private var showDetails = false
    @State private var successPulse = 0
    @Namespace private var namespace

    private var tint: Color { DiscoverySourceStyle.tint(printer.source) }
    private var catalogModel: PrinterModel? { DiscoveryMatcher.model(for: printer) }
    private var isUnidentified: Bool { DiscoveryMatcher.isUnidentified(printer) }

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 26)
        .scaleEffect(appeared ? 1 : 0.92, anchor: .top)
        .blur(radius: appeared ? 0 : 5)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(appearDelay)) {
                    appeared = true
                }
            }
        }
        .onChange(of: isAdded) { _, added in
            if added && !reduceMotion { successPulse += 1 }
        }
    }

    // MARK: Groß

    private var fullBody: some View {
        GlassCard(padding: 14, tint: isAdded ? Theme.ready : (isHighlighted ? tint : nil)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    icon(size: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(printer.name)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            DiscoverySourceBadge(source: printer.source)
                        }
                        modelLine
                        Label(printer.descriptor.displayString, systemImage: printer.descriptor.systemImage)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 8) {
                    if !printer.details.isEmpty {
                        Button {
                            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                                showDetails.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(showDetails ? 90 : 0))
                                Text(tr("Details"))
                            }
                        }
                        .buttonStyle(.labelWerkPlain)
                        .controlSize(.small)
                    }
                    if !printer.descriptor.supportsBidirectional {
                        Label(tr("Nur Senden"), systemImage: "arrow.up.right")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .help(tr("Über diese Verbindung kann LabelWerk drucken, aber keinen Live-Status abfragen."))
                    }
                    Spacer(minLength: 0)
                    actionArea
                }

                if showDetails {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(DiscoveryDetailText.sortedKeys(printer.details), id: \.self) { key in
                            KeyValueRow(DiscoveryDetailText.title(for: key),
                                        DiscoveryDetailText.value(for: key, raw: printer.details[key] ?? ""),
                                        monospaced: true, copyable: true)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Theme.Metrics.cornerSmall, style: .continuous)
                        .fill(Theme.subtleFill))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous)
                    .strokeBorder(tint, lineWidth: 2)
                    .shadow(color: tint.opacity(0.5), radius: 8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .cardHoverEffect()
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: isHighlighted)
    }

    // MARK: Kompakt (Onboarding)

    private var compactBody: some View {
        HStack(spacing: 10) {
            icon(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(printer.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if isUnidentified {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    } else {
                        Image(systemName: printer.descriptor.systemImage)
                    }
                    Text(DiscoveryMatcher.modelLine(for: printer) ?? printer.descriptor.displayString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .help(isUnidentified ? DiscoveryMatcher.unidentifiedWarning : "")
            }
            Spacer(minLength: 4)
            actionArea
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isAdded ? Theme.ready.opacity(0.1) : Theme.subtleFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isHighlighted ? tint : (isAdded ? Theme.ready.opacity(0.35) : Theme.cardStroke),
                              lineWidth: isHighlighted ? 1.5 : 1)
        }
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: isHighlighted)
    }

    // MARK: Bausteine

    private func icon(size: CGFloat) -> some View {
        IconBadge(systemImage: catalogModel?.systemImage ?? "printer", tint: tint, size: size)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: DiscoverySourceStyle.systemImage(printer.source))
                    .font(.system(size: size * 0.24, weight: .bold))
                    .foregroundStyle(tint)
                    .padding(size * 0.07)
                    .background(Circle().fill(.regularMaterial))
                    .offset(x: size * 0.14, y: size * 0.14)
            }
            .keyframeAnimator(initialValue: DiscoveryCardPop(), trigger: successPulse) { content, value in
                content
                    .scaleEffect(value.scale)
                    .rotationEffect(.degrees(value.rotation))
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.18, duration: 0.18, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.45, spring: .bouncy)
                }
                KeyframeTrack(\.rotation) {
                    CubicKeyframe(-8, duration: 0.12)
                    CubicKeyframe(6, duration: 0.14)
                    SpringKeyframe(0, duration: 0.35, spring: .bouncy)
                }
            }
    }

    @ViewBuilder
    private var modelLine: some View {
        if isUnidentified {
            Label(tr("Nicht als Zebra-Drucker erkannt"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.warning)
                .lineLimit(1)
                .help(DiscoveryMatcher.unidentifiedWarning)
        } else if let line = DiscoveryMatcher.modelLine(for: printer) {
            Label(line, systemImage: "checkmark.seal.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.teal)
                .lineLimit(1)
        } else if let hint = printer.modelHint, !hint.isEmpty {
            Label(tr("Unbekanntes Modell: %@", hint), systemImage: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if printer.descriptor.supportsBidirectional {
            Label(tr("Modell wird beim Verbinden erkannt"), systemImage: "sparkle.magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Label(tr("Modell unbekannt"), systemImage: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// „Hinzufügen“ ↔ „Hinzugefügt“ (morphende Kapsel über `matchedGeometryEffect`).
    private var actionArea: some View {
        HStack(spacing: 6) {
            if isAdded {
                if let onOpen {
                    Button(tr("Öffnen"), action: onOpen)
                        .buttonStyle(.labelWerkPlain)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolEffect(.bounce, value: successPulse)
                    Text(tr("Hinzugefügt"))
                }
                .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                .foregroundStyle(Theme.ready)
                .padding(.horizontal, compact ? 9 : 12)
                .padding(.vertical, compact ? 4 : 6)
                .background {
                    Capsule()
                        .fill(Theme.ready.opacity(0.15))
                        .overlay(Capsule().strokeBorder(Theme.ready.opacity(0.4), lineWidth: 1))
                        .matchedGeometryEffect(id: "action", in: namespace)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                Button(action: onAdd) {
                    Label(tr("Hinzufügen"), systemImage: "plus.circle.fill")
                }
                .buttonStyle(.labelWerkPrimary)
                .background {
                    Capsule()
                        .fill(Color.clear)
                        .matchedGeometryEffect(id: "action", in: namespace)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(Motion.animation(Motion.bouncy, reduceMotion: reduceMotion), value: isAdded)
    }
}

/// Werte der „Pop“-Animation nach dem Hinzufügen.
struct DiscoveryCardPop {
    var scale: CGFloat = 1
    var rotation: Double = 0
}
