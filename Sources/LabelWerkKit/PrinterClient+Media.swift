import Foundation
import LabelWerkCore
import LabelWerkStatus
import LabelWerkTransport

// MARK: - Erkannte Etikettengröße

/// Die Etikettengröße, die ein Drucker meldet – wie der Windows-Treiber ZDesigner sie anzeigt:
/// Breite = eingestellte Druckbreite (`ezpl.print_width`, z. B. 832 Punkte = 104 mm beim ZD421 mit
/// 203 dpi), Länge = eingestellte bzw. beim Kalibrieren gemessene Etikettenlänge (`zpl.label_length`,
/// sonst Feld `dddd` von `~HS`).
public struct DetectedMedia: Codable, Hashable, Sendable {
    /// Woher die Etikettenlänge stammt.
    public enum LengthSource: String, Codable, Hashable, Sendable {
        /// SGD `zpl.label_length`.
        case sgd
        /// Statusantwort `~HS` (Etikettenlänge in Punkten).
        case hostStatus
    }

    /// Druckbreite in Punkten.
    public var widthDots: Int
    /// Etikettenlänge in Punkten.
    public var lengthDots: Int
    public var resolution: Resolution
    /// Medientyp laut Drucker (`ezpl.media_type`; `nil` = nicht gemeldet).
    public var tracking: MediaTracking?
    /// Druckverfahren laut Drucker (`ezpl.print_method`; `nil` = nicht gemeldet).
    public var mediaType: MediaType?
    public var lengthSource: LengthSource

    public init(widthDots: Int, lengthDots: Int, resolution: Resolution, tracking: MediaTracking? = nil,
                mediaType: MediaType? = nil, lengthSource: LengthSource = .sgd) {
        self.widthDots = widthDots
        self.lengthDots = lengthDots
        self.resolution = resolution
        self.tracking = tracking
        self.mediaType = mediaType
        self.lengthSource = lengthSource
    }

    /// Breite in mm, auf ein rundes Maß gerastet (``LabelSizing/millimeters(fromDots:resolution:)``),
    /// z. B. 104.
    public var widthMM: Double { LabelSizing.millimeters(fromDots: widthDots, resolution: resolution) }
    /// Höhe in mm, gerastet, z. B. 76,2.
    public var heightMM: Double { LabelSizing.millimeters(fromDots: lengthDots, resolution: resolution) }
    /// „104 × 76,2 mm“.
    public var sizeText: String { LabelSizing.sizeText(widthMM: widthMM, heightMM: heightMM) }
    /// Größe als Etikettengröße einer Warteschlange.
    public var labelSize: QueueLabelSize { QueueLabelSize(widthMM: widthMM, heightMM: heightMM) }
}

extension PrinterClient {

    /// SGD-Variablen für ``readMediaSize()``.
    static let mediaVariables: [String] = [
        SGD.Variable.printWidth, labelLengthVariable, SGD.Variable.mediaType, SGD.Variable.printMethod,
        SGD.Variable.resolution, SGD.Variable.mediaKind, SGD.Variable.senseMode,
    ]

    /// Eingestellte Etikettenlänge in Punkten (`^LL`, nach dem Kalibrieren die gemessene Länge).
    static let labelLengthVariable = "zpl.label_length"

    /// Liest die eingestellte Etikettengröße des Druckers (nur ZPL-Drucker mit Rückkanal).
    ///
    /// * Breite: SGD `ezpl.print_width`, sonst die Druckbreite aus der letzten Identifikation bzw. des
    ///   erkannten Katalogmodells.
    /// * Länge: SGD `zpl.label_length`, sonst die Etikettenlänge aus `~HS`.
    /// * Medientyp: `ezpl.media_type` (`gap/notch`, `mark`, `continuous`), sonst `media.type`
    ///   `journal` bzw. `media.sense_mode`; Druckverfahren aus `ezpl.print_method`.
    /// * Auflösung: `head.resolution.in_dpi`, sonst letzte Identifikation, sonst `~HI`.
    ///
    /// - Returns: `nil` bei EPL/CPCL, Verbindungen ohne Rückkanal, keiner verwertbaren Antwort oder
    ///   fehlender Breite bzw. Länge (z. B. Endlosmaterial ohne eingestellte Länge). Wirft nie –
    ///   ein Abbruch der Aufgabe liefert ebenfalls `nil`.
    public func readMediaSize() async -> DetectedMedia? {
        guard language == .zpl, supportsBidirectional else { return nil }
        return try? await guarded { try await self.collectMediaSize() }
    }

    func collectMediaSize() async throws -> DetectedMedia? {
        let capabilities = try await resolveCapabilities(knownAlive: false)
        var sgd: [String: String] = [:]
        if capabilities.sgd {
            sgd = (try? await fetchVariables(Self.mediaVariables)) ?? [:]
        }
        func value(_ name: String) -> String? {
            guard let raw = sgd[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw != "?" else {
                return nil
            }
            return raw
        }
        func positive(_ name: String) -> Int? {
            SGDValueMapping.integer(value(name)).flatMap { $0 > 0 ? $0 : nil }
        }

        var hostStatus: HostStatus?
        let hs = try await exchange(ZPL.hostStatus().description, operation: "Statusabfrage (~HS)",
                                    isComplete: ResponseFraming.hostStatusComplete)
        if !hs.isEmpty { hostStatus = try? HostStatusParser.parse(hs) }

        var resolution = positive(SGD.Variable.resolution).flatMap(Resolution.init(dpi:)) ?? lastIdentity?.resolution
        if resolution == nil {
            let hi = try await exchange(ZPL.hostIdentification().description, operation: "Identifikation (~HI)",
                                        isComplete: ResponseFraming.etxComplete)
            if !hi.isEmpty { resolution = (try? HostIdentificationParser.parse(hi))?.resolution }
        }
        guard let resolution else { return nil }

        let width = positive(SGD.Variable.printWidth)
            ?? lastIdentity?.printWidthDots.flatMap { $0 > 0 ? $0 : nil }
            ?? lastIdentity?.matchedModel?.printWidthDots(resolution)
        var length = positive(Self.labelLengthVariable)
        var source = DetectedMedia.LengthSource.sgd
        if length == nil, let dots = hostStatus?.labelLengthDots, dots > 0 {
            length = dots
            source = .hostStatus
        }

        var tracking = value(SGD.Variable.mediaType).flatMap(SGDValueMapping.mediaTracking(sgd:))
        if tracking == nil {
            if value(SGD.Variable.mediaKind)?.lowercased() == "journal" {
                tracking = .continuous
            } else if let sense = value(SGD.Variable.senseMode)?.lowercased() {
                if sense.contains("bar") || sense.contains("mark") {
                    tracking = .blackMark
                } else if sense.contains("gap") {
                    tracking = .gap
                }
            }
        }
        let mediaType = value(SGD.Variable.printMethod).flatMap(SGDValueMapping.mediaType(sgd:))

        guard let width, let length else { return nil }
        return DetectedMedia(widthDots: width, lengthDots: length, resolution: resolution, tracking: tracking,
                             mediaType: mediaType, lengthSource: source)
    }
}
