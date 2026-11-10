import AppKit
import SwiftUI
import LabelWerkKit

// MARK: - Entwurf & Einheit

/// Vorlage für den Format-Editor.
struct StockLibraryDraft: Identifiable {
    enum Mode {
        case create
        case edit
        case duplicate
        case fromPrinter
    }

    let id = UUID()
    var stock: LabelStock
    var mode: Mode

    init(stock: LabelStock, mode: Mode) {
        self.stock = stock
        self.mode = mode
    }

    /// Neue, eindeutige Kennung für eigene Formate.
    static func newID() -> String {
        "custom-" + UUID().uuidString.lowercased()
    }
}

/// Anzeigeeinheit im Editor (gespeichert wird immer in Millimetern).
enum StockLibraryUnit: String, CaseIterable, Identifiable {
    case mm
    case inch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mm: return tr("Millimeter")
        case .inch: return tr("Zoll")
        }
    }

    var symbol: String {
        switch self {
        case .mm: return "mm"
        case .inch: return tr("Zoll")
        }
    }

    /// Millimeter pro Einheit.
    var millimetres: Double {
        switch self {
        case .mm: return 1
        case .inch: return 25.4
        }
    }

    func format(_ millimetres: Double) -> String {
        switch self {
        case .mm:
            return tr("%@ mm", millimetres.formatted(.number.precision(.fractionLength(0...1))))
        case .inch:
            return tr("%@ Zoll", (millimetres / 25.4).formatted(.number.precision(.fractionLength(0...2))))
        }
    }
}

// MARK: - Maßstäbliche Etikettendarstellung

/// Etikett im richtigen Seitenverhältnis mit Bemaßung, Lücke bzw. schwarzer Marke und angedeutetem
/// Folgeetikett. Endlosmaterial läuft unten weich aus. Optional: nicht bedruckbare Ränder.
struct StockLibraryLabelArt: View {
    let widthMM: Double
    let heightMM: Double
    let gapMM: Double
    let tracking: MediaTracking
    let maxSize: CGSize
    var compact: Bool = false
    var showsDimensions: Bool = true
    var printableWidthMM: Double?
    var unit: StockLibraryUnit = .mm

    init(widthMM: Double, heightMM: Double, gapMM: Double, tracking: MediaTracking, maxSize: CGSize,
         compact: Bool = false, showsDimensions: Bool = true, printableWidthMM: Double? = nil,
         unit: StockLibraryUnit = .mm) {
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.gapMM = gapMM
        self.tracking = tracking
        self.maxSize = maxSize
        self.compact = compact
        self.showsDimensions = showsDimensions
        self.printableWidthMM = printableWidthMM
        self.unit = unit
    }

    init(stock: LabelStock, maxSize: CGSize, compact: Bool = false, showsDimensions: Bool = true) {
        self.init(widthMM: stock.widthMM, heightMM: stock.heightMM, gapMM: stock.gapMM, tracking: stock.tracking,
                  maxSize: maxSize, compact: compact, showsDimensions: showsDimensions)
    }

    private var safeWidth: Double { max(widthMM, 0.5) }
    private var safeHeight: Double { max(heightMM, 0.5) }

    private var labelSize: CGSize {
        let scale = min(maxSize.width / CGFloat(safeWidth), maxSize.height / CGFloat(safeHeight))
        return CGSize(width: max(8, CGFloat(safeWidth) * scale), height: max(6, CGFloat(safeHeight) * scale))
    }

    private var isContinuous: Bool { tracking == .continuous }

    var body: some View {
        let size = labelSize
        let scale = size.width / CGFloat(safeWidth)
        let gapHeight = isContinuous ? 0 : max(2, min(CGFloat(gapMM) * scale, compact ? 6 : 14))
        let sliverHeight: CGFloat = isContinuous ? 0 : (compact ? 7 : 14)
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            if showsDimensions {
                StockLibraryDimension(text: unit.format(widthMM), vertical: false, compact: compact)
                    .frame(width: size.width)
            }
            HStack(alignment: .top, spacing: compact ? 3 : 6) {
                VStack(spacing: 0) {
                    labelSheet
                        .frame(width: size.width, height: size.height)
                    if !isContinuous {
                        ZStack(alignment: .leading) {
                            Color.clear
                                .frame(width: size.width, height: gapHeight)
                            if tracking == .blackMark {
                                Rectangle()
                                    .fill(Theme.labelInk)
                                    .frame(width: max(4, size.width * 0.18), height: gapHeight)
                            }
                        }
                        RoundedRectangle(cornerRadius: compact ? 2 : 4, style: .continuous)
                            .fill(Theme.labelPaper)
                            .frame(width: size.width, height: sliverHeight)
                            .mask {
                                LinearGradient(colors: [Color.black, Color.black.opacity(0)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                    }
                }
                if showsDimensions {
                    StockLibraryDimension(text: unit.format(heightMM), vertical: true, compact: compact)
                        .frame(height: size.height)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Etikett %@ × %@", unit.format(widthMM), unit.format(heightMM)))
    }

    private var labelSheet: some View {
        LabelSheet(widthMM: safeWidth, heightMM: safeHeight) {
            ZStack {
                PrintPrefsSampleLabel(drawsPaper: false)
                    .opacity(compact ? 0.7 : 0.85)
                if let printable = printableWidthMM, printable > 0, printable < safeWidth {
                    StockLibraryUnprintableOverlay(fraction: CGFloat(printable / safeWidth))
                }
            }
        }
        .mask {
            if isContinuous {
                LinearGradient(stops: [.init(color: Color.black, location: 0),
                                       .init(color: Color.black, location: 0.72),
                                       .init(color: Color.black.opacity(0.08), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                Rectangle()
            }
        }
    }
}

/// Schraffierte Ränder außerhalb der Druckbreite (mittig ausgerichtete Medien).
private struct StockLibraryUnprintableOverlay: View {
    let fraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width * max(0, 1 - fraction) / 2
            HStack(spacing: 0) {
                StockLibraryHatch()
                    .frame(width: side)
                Spacer(minLength: 0)
                StockLibraryHatch()
                    .frame(width: side)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct StockLibraryHatch: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Theme.error.opacity(0.16))
            StockLibraryStripes()
                .stroke(Theme.error.opacity(0.55), lineWidth: 1)
                .clipped()
        }
    }
}

private struct StockLibraryStripes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 6
        }
        return path
    }
}

/// Maßlinie mit Endstrichen und Beschriftung.
private struct StockLibraryDimension: View {
    let text: String
    let vertical: Bool
    let compact: Bool

    var body: some View {
        if vertical {
            HStack(spacing: 3) {
                StockLibraryDimensionShape(vertical: true)
                    .stroke(Theme.accent.opacity(0.7), lineWidth: 1)
                    .frame(width: compact ? 5 : 7)
                Text(text)
                    .font(.system(size: compact ? 9 : 10.5, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .contentTransition(.numericText())
            }
        } else {
            ZStack {
                StockLibraryDimensionShape(vertical: false)
                    .stroke(Theme.accent.opacity(0.7), lineWidth: 1)
                    .frame(height: compact ? 5 : 7)
                Text(text)
                    .font(.system(size: compact ? 9 : 10.5, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .background(.regularMaterial, in: Capsule())
                    .contentTransition(.numericText())
            }
        }
    }
}

private struct StockLibraryDimensionShape: Shape {
    let vertical: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if vertical {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        return path
    }
}

// MARK: - Karte im Raster

/// Karte eines Etikettenformats: maßstäbliche Miniatur, Name, Größe, Kategorie und Erkennungsart.
/// Die Auswahlmarkierung gleitet per `matchedGeometryEffect` zwischen den Karten.
struct StockLibraryCard: View {
    let stock: LabelStock
    let isSelected: Bool
    let fits: Bool
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    init(stock: LabelStock, isSelected: Bool, fits: Bool, namespace: Namespace.ID, reduceMotion: Bool,
         onSelect: @escaping () -> Void, onEdit: @escaping () -> Void,
         onDuplicate: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.stock = stock
        self.isSelected = isSelected
        self.fits = fits
        self.namespace = namespace
        self.reduceMotion = reduceMotion
        self.onSelect = onSelect
        self.onEdit = onEdit
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
    }

    private var sizeText: String {
        let mm = tr("%@ × %@ mm", stock.widthMM.formatted(.number.precision(.fractionLength(0...1))),
                    stock.heightMM.formatted(.number.precision(.fractionLength(0...1))))
        return mm
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                StockLibraryLabelArt(stock: stock, maxSize: CGSize(width: 112, height: 74), compact: true)
                    .scaleEffect(hovering && !reduceMotion ? 1.05 : 1)
                    .frame(maxWidth: .infinity, minHeight: 116, maxHeight: 116)

                VStack(alignment: .leading, spacing: 3) {
                    Text(stock.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    Text(sizeText)
                        .font(Theme.Typography.codeSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: PrintPrefsSymbols.symbol(for: stock.category))
                        Text(tr(stock.category.displayName))
                            .lineLimit(1)
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.violet : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((isSelected ? Theme.violet.opacity(0.14) : Theme.subtleFill), in: Capsule())

                    Spacer(minLength: 0)

                    if !fits {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                            .help(tr("Passt nicht auf diesen Drucker"))
                    }
                    Image(systemName: PrintPrefsSymbols.symbol(for: stock.tracking))
                        .foregroundStyle(.secondary)
                        .help(tr(stock.tracking.displayName))
                }
                .font(.system(size: 12))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .labelWerkGlass(cornerRadius: Theme.Metrics.corner, tint: isSelected ? Theme.violet : nil)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous)
                        .strokeBorder(Theme.brandGradient, lineWidth: 2.5)
                        .shadow(color: Theme.violet.opacity(0.45), radius: 8)
                        .matchedGeometryEffect(id: "selectedStock", in: namespace)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Theme.violet)
                        .shadow(color: Theme.violet.opacity(0.4), radius: 4)
                        .padding(9)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else if stock.isCustom {
                    Text(tr("Eigenes"))
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.magenta)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.magenta.opacity(0.14), in: Capsule())
                        .padding(9)
                }
            }
            .opacity(fits ? 1 : 0.62)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .cardHoverEffect()
        .onHover { inside in hovering = inside }
        .animation(reduceMotion ? nil : Motion.spring, value: hovering)
        .contextMenu {
            if !isSelected {
                Button(action: onSelect) {
                    Label(tr("Auswählen"), systemImage: "checkmark.circle")
                }
            }
            if stock.isCustom {
                Button(action: onEdit) {
                    Label(tr("Bearbeiten …"), systemImage: "pencil")
                }
            }
            Button(action: onDuplicate) {
                Label(stock.isCustom ? tr("Duplizieren …") : tr("Als eigenes Format duplizieren …"),
                      systemImage: "plus.square.on.square")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(stock.sizeDescription, forType: .string)
            } label: {
                Label(tr("Maße kopieren"), systemImage: "doc.on.doc")
            }
            if stock.isCustom {
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label(tr("Löschen …"), systemImage: "trash")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("%@, %@", stock.name, sizeText))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Kachel „Eigenes Format anlegen“ mit gestricheltem Rahmen.
struct StockLibraryAddTile: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Theme.brandGradient)
                        .frame(width: 46, height: 46)
                        .shadow(color: Theme.violet.opacity(0.4), radius: hovering ? 10 : 5, y: 3)
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(hovering && !reduceMotion ? 90 : 0))
                }
                Text(tr("Eigenes Format anlegen"))
                    .font(.system(size: 13, weight: .semibold))
                Text(tr("Breite, Länge, Lücke und Erkennung frei wählen"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 214)
            .background {
                RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous)
                    .fill(hovering ? Theme.accent.opacity(0.07) : Theme.subtleFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(hovering ? 0.7 : 0.35),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) { hovering = inside }
        }
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }
}
