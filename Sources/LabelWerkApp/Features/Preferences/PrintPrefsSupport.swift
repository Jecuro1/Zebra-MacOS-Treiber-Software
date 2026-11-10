import SwiftUI
import LabelWerkKit

// MARK: - Abgleichstand (überdauert Neustarts)

/// Merkt sich je Drucker die zuletzt übertragenen bzw. vom Drucker gelesenen Werte, damit der
/// Abgleich-Hinweis auch nach einem Neustart der App stimmt. Ohne gespeicherten Stand gilt
/// `PrintSettings.default` – jedes eigene Feld zählt dann als „noch nicht gesendet“.
enum PrintPrefsSyncStore {
    private static let defaultsKey = "LabelWerk.PrintPrefs.SyncedSettings"

    static func baseline(for printerID: UUID) -> PrintSettings? {
        load()[printerID.uuidString]
    }

    /// Speichert den Stand von `printerID` und verwirft Einträge von Druckern, die es nicht mehr gibt.
    static func store(_ settings: PrintSettings, for printerID: UUID, knownPrinterIDs: Set<UUID>) {
        var entries = load()
        entries[printerID.uuidString] = settings
        var keep = Set(knownPrinterIDs.map { $0.uuidString })
        keep.insert(printerID.uuidString)
        entries = entries.filter { keep.contains($0.key) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func load() -> [String: PrintSettings] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([String: PrintSettings].self, from: data) else {
            return [:]
        }
        return entries
    }
}

// MARK: - Profil (Import/Export)

/// Einstellungsprofil als JSON – zum Sichern oder Übertragen auf andere Macs/Drucker.
struct PrintPrefsProfile: Codable {
    static let formatIdentifier = "de.labelwerk.print-settings"

    var format: String
    var version: Int
    var exportedAt: Date
    var printerName: String?
    var modelID: String?
    var language: PrinterLanguage?
    var stockID: String?
    var settings: PrintSettings

    init(settings: PrintSettings, printerName: String?, modelID: String?, language: PrinterLanguage?, stockID: String?) {
        self.format = Self.formatIdentifier
        self.version = 1
        self.exportedAt = Date()
        self.printerName = printerName
        self.modelID = modelID
        self.language = language
        self.stockID = stockID
        self.settings = settings
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Vorgeschlagener Dateiname, z. B. „Büro – Druckeinstellungen.json“.
    static func fileName(for printerName: String) -> String {
        let cleaned = printerName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tr("%@ – Druckeinstellungen.json", cleaned.isEmpty ? "LabelWerk" : cleaned)
    }

    /// Liest ein Profil; akzeptiert auch reine `PrintSettings`-JSON-Dateien.
    static func decode(_ data: Data) throws -> PrintPrefsProfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PrintPrefsProfile.self, from: data)
        } catch {
            if let settings = try? decoder.decode(PrintSettings.self, from: data) {
                return PrintPrefsProfile(settings: settings, printerName: nil, modelID: nil, language: nil, stockID: nil)
            }
            throw error
        }
    }
}

// MARK: - Musterbild (Rasterung & Auftragsgröße)

/// Erzeugt ein Graustufen-Musterbild: Tonwertverlauf, schattierte Kugel, textähnliche Zeilen und
/// einen echten Code-128-Barcode. Reine Berechnung – läuft im Hintergrund.
enum PrintPrefsArtwork {
    static func sample(width: Int, height: Int) -> GrayImage {
        let w = max(16, width)
        let h = max(16, height)
        var pixels = [UInt8](repeating: 255, count: w * h)

        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ value: UInt8) {
            let xa = max(0, min(w, x0))
            let xb = max(0, min(w, x1))
            let ya = max(0, min(h, y0))
            let yb = max(0, min(h, y1))
            guard xa < xb, ya < yb else { return }
            for row in ya..<yb {
                let offset = row * w
                for column in xa..<xb { pixels[offset + column] = value }
            }
        }

        let margin = max(2, w / 32)

        // 1. Horizontaler Tonwertverlauf (schwarz → weiß)
        let rampTop = margin
        // Bei sehr flachen, breiten Etiketten kann der Rand höher sein als das Etikett.
        let rampBottom = max(rampTop, min(h, margin + max(4, h * 18 / 100)))
        let rampWidth = max(1, w - 2 * margin)
        for row in rampTop..<rampBottom {
            let offset = row * w
            for column in margin..<(w - margin) {
                let t = Double(column - margin) / Double(rampWidth)
                pixels[offset + column] = UInt8(max(0, min(255, Int(t * 255))))
            }
        }

        // 2. Schattierte Kugel mit Kantenglättung
        let radius = Double(min(w, h)) * 0.21
        let cx = Double(w) * 0.25
        let cy = Double(h) * 0.56
        let lightX = cx - radius * 0.38
        let lightY = cy - radius * 0.42
        let yStart = max(0, Int(cy - radius) - 1)
        let yEnd = min(h, Int(cy + radius) + 2)
        let xStart = max(0, Int(cx - radius) - 1)
        let xEnd = min(w, Int(cx + radius) + 2)
        if yStart < yEnd && xStart < xEnd {
            for row in yStart..<yEnd {
                for column in xStart..<xEnd {
                    let dx = Double(column) + 0.5 - cx
                    let dy = Double(row) + 0.5 - cy
                    let distance = (dx * dx + dy * dy).squareRoot()
                    let coverage = max(0, min(1, radius - distance + 0.5))
                    if coverage <= 0 { continue }
                    let lx = Double(column) - lightX
                    let ly = Double(row) - lightY
                    let shade = max(0, min(1, (lx * lx + ly * ly).squareRoot() / (radius * 1.55)))
                    let tone = 250 - shade * 235
                    let index = row * w + column
                    let base = Double(pixels[index])
                    let mixed = base * (1 - coverage) + tone * coverage
                    pixels[index] = UInt8(max(0, min(255, Int(mixed.rounded()))))
                }
            }
        }

        // 3. Textähnliche Zeilen (Überschrift + Fließtext)
        let textLeft = Int(Double(w) * 0.52)
        let textRight = w - margin * 2
        let lineHeight = max(2, h * 4 / 100)
        var cursorY = max(rampBottom + lineHeight * 2, Int(Double(h) * 0.30))
        var seed: UInt32 = 0x5EED
        func nextRandom() -> Int {
            seed = seed &* 1_103_515_245 &+ 12_345
            return Int((seed >> 16) & 0x7FFF)
        }
        if textRight > textLeft {
            fill(textLeft, cursorY, textLeft + (textRight - textLeft) * 7 / 10, cursorY + lineHeight * 2, 0)
            cursorY += lineHeight * 3
            let textBottom = Int(Double(h) * 0.78)
            for line in 0..<7 {
                if cursorY + lineHeight >= textBottom { break }
                let lineEnd = line == 6 ? textLeft + (textRight - textLeft) / 2 : textRight
                var x = textLeft
                while x < lineEnd {
                    let word = lineHeight * (2 + nextRandom() % 6)
                    let end = min(lineEnd, x + word)
                    fill(x, cursorY, end, cursorY + lineHeight, 35)
                    x = end + lineHeight
                }
                cursorY += lineHeight * 2
            }
        }

        // 4. Code 128 unten
        let modules = PrintPrefsSampleCodes.barcodeModules
        if !modules.isEmpty {
            let available = max(1, w - margin * 4)
            let moduleWidth = max(1, available / (modules.count + 20))
            let total = moduleWidth * modules.count
            let left = (w - total) / 2
            let top = Int(Double(h) * 0.82)
            let bottom = h - margin
            for (index, dark) in modules.enumerated() where dark {
                fill(left + index * moduleWidth, top, left + (index + 1) * moduleWidth, bottom, 0)
            }
        }

        return GrayImage(width: w, height: h, pixels: pixels)
    }
}

// MARK: - Beispielcodes für Vorschauen

/// Echte Codes (Code 128 und QR) für Vorschau-Etiketten – einmalig berechnet.
enum PrintPrefsSampleCodes {
    static let barcodeModules: [Bool] = (try? BarcodeEncoder.code128("LABELWERK"))?.modules ?? []
    static let qrMatrix: BitMatrix? = try? BarcodeEncoder.qr("LabelWerk")

    /// Balken des Code 128, über `rect` verteilt; `widen` simuliert Punktzuwachs (zu hohe Schwärzung).
    static func barcodePath(in rect: CGRect, widen: CGFloat = 0) -> Path {
        var path = Path()
        let modules = barcodeModules
        guard !modules.isEmpty, rect.width > 0, rect.height > 0 else { return path }
        let module = rect.width / CGFloat(modules.count)
        var index = 0
        while index < modules.count {
            if modules[index] {
                var end = index
                while end < modules.count && modules[end] { end += 1 }
                let x = rect.minX + CGFloat(index) * module - widen / 2
                let width = max(0.3, CGFloat(end - index) * module + widen)
                path.addRect(CGRect(x: x, y: rect.minY, width: width, height: rect.height))
                index = end
            } else {
                index += 1
            }
        }
        return path
    }

    /// QR-Code, quadratisch in `rect` zentriert.
    static func qrPath(in rect: CGRect) -> Path {
        var path = Path()
        guard let matrix = qrMatrix, matrix.width > 0, matrix.height > 0, rect.width > 0, rect.height > 0 else {
            return path
        }
        let side = min(rect.width, rect.height)
        let module = side / CGFloat(max(matrix.width, matrix.height))
        let originX = rect.midX - module * CGFloat(matrix.width) / 2
        let originY = rect.midY - module * CGFloat(matrix.height) / 2
        for y in 0..<matrix.height {
            for x in 0..<matrix.width where matrix[x, y] {
                path.addRect(CGRect(x: originX + CGFloat(x) * module, y: originY + CGFloat(y) * module,
                                    width: module + 0.02, height: module + 0.02))
            }
        }
        return path
    }
}

// MARK: - Symbole

/// SF-Symbole für Medien-, Modus- und Kategoriewerte (eigener Namensraum, keine Erweiterungen der
/// Kerntypen, damit es keine Namenskonflikte mit anderen Bereichen gibt).
enum PrintPrefsSymbols {
    static func symbol(for tracking: MediaTracking?) -> String {
        guard let tracking else { return "printer" }
        switch tracking {
        case .gap: return "square.split.1x2"
        case .blackMark: return "square.bottomhalf.filled"
        case .continuous: return "scroll"
        case .autoDetect: return "wand.and.stars"
        case .notch: return "square.split.1x2.fill"
        }
    }

    static func symbol(for type: MediaType?) -> String {
        guard let type else { return "printer" }
        switch type {
        case .directThermal: return "flame"
        case .thermalTransfer: return "film"
        }
    }

    static func symbol(for mode: PrintMode?) -> String {
        guard let mode else { return "printer" }
        switch mode {
        case .tearOff: return "hand.raised"
        case .peelOff: return "square.stack"
        case .cutter: return "scissors"
        case .delayedCut: return "timer"
        case .rewind: return "arrow.triangle.2.circlepath"
        case .applicator: return "hand.point.up.left"
        case .kiosk: return "display"
        case .linerlessPeel: return "square.stack"
        case .linerlessCut, .linerlessDelayedCut: return "scissors"
        case .linerlessRewind: return "arrow.triangle.2.circlepath"
        case .linerlessTear: return "hand.raised"
        }
    }

    static func symbol(for backfeed: BackfeedMode?) -> String {
        guard let backfeed else { return "printer" }
        switch backfeed {
        case .afterPrinting: return "arrow.uturn.backward"
        case .beforePrinting: return "arrow.uturn.forward"
        case .normal: return "arrow.left.arrow.right"
        case .off: return "nosign"
        }
    }

    static func symbol(for category: LabelStock.Category) -> String {
        switch category {
        case .shipping: return "shippingbox"
        case .product: return "tag"
        case .barcode: return "barcode"
        case .address: return "envelope"
        case .receipt: return "doc.plaintext"
        case .jewelry: return "sparkles"
        case .wristband: return "cross.case"
        case .custom: return "square.and.pencil"
        }
    }

    static func symbol(for language: PrinterLanguage) -> String {
        switch language {
        case .zpl: return "chevron.left.forwardslash.chevron.right"
        case .epl: return "text.alignleft"
        case .cpcl: return "doc.text"
        }
    }
}

// MARK: - Formatierung

enum PrintPrefsFormat {
    static func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// Millimeter mit Vorzeichen, z. B. „+2,5“ bzw. „−1,3“.
    static func signed(_ value: Double, digits: Int = 1) -> String {
        let rounded = (value * pow(10, Double(digits))).rounded() / pow(10, Double(digits))
        if rounded > 0 { return "+" + number(rounded, digits: digits) }
        if rounded < 0 { return "−" + number(-rounded, digits: digits) }
        return number(0, digits: digits)
    }

    static func signedInt(_ value: Int) -> String {
        if value > 0 { return "+\(value)" }
        if value < 0 { return "−\(-value)" }
        return "0"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - Fließlayout

/// Ordnet Elemente zeilenweise an und bricht bei Platzmangel um (Chips, Filter).
struct PrintPrefsFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width
            widest = max(widest, x)
            x += spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Auswahl-Chips

/// Auswahl als Chips mit gleitender Markierung (`matchedGeometryEffect`) und hüpfenden Symbolen.
struct PrintPrefsChoiceStrip<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let systemImage: (Value) -> String

    @Namespace private var namespace
    @State private var hovered: Value?
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(options: [Value], selection: Binding<Value>, title: @escaping (Value) -> String,
         systemImage: @escaping (Value) -> String) {
        self.options = options
        self._selection = selection
        self.title = title
        self.systemImage = systemImage
    }

    private var reduceMotion: Bool { systemReduceMotion || model.preferences.reduceMotion }

    var body: some View {
        PrintPrefsFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(options, id: \.self) { option in
                chip(option)
            }
        }
    }

    private func chip(_ option: Value) -> some View {
        let isSelected = option == selection
        let isHovered = hovered == option
        return Button {
            withAnimation(Motion.animation(Motion.spring, reduceMotion: reduceMotion)) {
                selection = option
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage(option))
                    .font(.system(size: 11.5, weight: .semibold))
                    .symbolEffect(.bounce, value: isSelected)
                Text(title(option))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(isHovered ? 0.95 : 0.75))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Theme.brandGradient)
                        .shadow(color: Theme.violet.opacity(0.35), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else {
                    Capsule()
                        .fill(Theme.subtleFill.opacity(isHovered ? 2 : 1))
                        .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion)) {
                if inside {
                    hovered = option
                } else if hovered == option {
                    hovered = nil
                }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Hinweise & Effekte

/// Kurzer Erklärtext mit Symbol.
struct PrintPrefsHint: View {
    let text: String
    var systemImage: String = "info.circle"
    var tint: Color = Color.secondary

    init(_ text: String, systemImage: String = "info.circle", tint: Color = Color.secondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .font(.system(size: 11.5))
    }
}

/// Lässt ein Steuerelement kurz aufleuchten, wenn sich `token` ändert (z. B. nach „Vom Drucker lesen“).
struct PrintPrefsPulse: ViewModifier {
    let token: Int
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 0.0, trigger: token) { view, glow in
                view
                    .background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Theme.teal.opacity(0.14 * glow))
                            .padding(-6)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Theme.teal.opacity(0.9 * glow), lineWidth: 1.5)
                            .padding(-6)
                    }
            } keyframes: { _ in
                CubicKeyframe(1.0, duration: 0.25)
                CubicKeyframe(1.0, duration: 0.7)
                CubicKeyframe(0.0, duration: 0.9)
            }
    }
}

/// Gestaffeltes Einblenden von Karten.
struct PrintPrefsAppear: ViewModifier {
    let index: Int
    let appeared: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 18)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.985, anchor: .top)
            .animation(Motion.animation(Motion.spring.delay(Double(index) * 0.06), reduceMotion: reduceMotion),
                       value: appeared)
    }
}
