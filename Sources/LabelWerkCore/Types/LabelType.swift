import Foundation

// MARK: - Etikettentyp

/// Ein Etikettentyp eines Druckers (ARCHITECTURE.md §9 „Etikettentypen“): eigenes Etikettenformat,
/// eigene Abweichungen von den Druckereinstellungen und eine eigene macOS-Warteschlange.
///
/// Im Druckdialog jedes Programms erscheint er als eigener Drucker, z. B. „Zebra ZD421t –
/// Brillenetikett“ – Format und Einstellungen kommen aus LabelWerk, im Dialog ist nichts zu wählen.
/// Alle übrigen Einstellungen folgen dem Drucker (``LabelTypeOverrides``: `nil` = „wie Drucker“).
public struct LabelType: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Anzeigename, z. B. „Brillenetikett“ (Teil der Beschreibung der Warteschlange).
    public var name: String
    /// Etikettenformat (`LabelStock.id`, Katalog oder eigenes Format).
    public var stockID: String
    /// Abweichungen von den Einstellungen des Druckers.
    public var overrides: LabelTypeOverrides
    /// Name der von LabelWerk angelegten CUPS-Warteschlange (`nil`, solange keine angelegt ist). Bleibt
    /// beim Umbenennen gleich (``LabelTypeQueueNaming``); nur diese Warteschlange entfernt LabelWerk
    /// wieder.
    public var queueName: String?

    public init(id: UUID = UUID(), name: String, stockID: String,
                overrides: LabelTypeOverrides = LabelTypeOverrides(), queueName: String? = nil) {
        self.id = id
        self.name = name
        self.stockID = stockID
        self.overrides = overrides
        self.queueName = queueName
    }

    /// Wirksame Einstellungen dieses Typs:
    ///
    /// 1. Grundlage sind die Einstellungen des Druckers (`printerSettings`).
    /// 2. Hat der Typ ein anderes Format als der Drucker (`printerStock`), folgen Medientyp
    ///    (`tracking`, z. B. Endlosmaterial) und Druckmodus (`mediaType`, falls das Format einen nennt)
    ///    dem Format des Typs – so wie die Wahl einer Vorlage unter „Druckeinstellungen › Seite
    ///    einrichten“. Steht der Drucker dort auf „Druckerwert“ und haben beide Formate denselben Wert,
    ///    bleibt „Druckerwert“.
    /// 3. Danach gelten die Abweichungen des Typs (``LabelTypeOverrides/applied(to:)``).
    /// 4. `lwLabelWidth`/`lwLabelHeight` kommen aus dem Format des Typs
    ///    (``PrintSettings/withLabelSize(of:)``, Endlosmaterial ohne Länge).
    ///
    /// `stock == nil` (Format unbekannt): Schritt 2 entfällt, die Größe bleibt unbekannt.
    public func settings(printerSettings: PrintSettings, printerStock: LabelStock?,
                         stock: LabelStock?) -> PrintSettings {
        var s = printerSettings
        if let stock, stock.id != printerStock?.id {
            if s.tracking != nil || stock.tracking != printerStock?.tracking {
                s.tracking = stock.tracking
            }
            if let mediaType = stock.mediaType, s.mediaType != nil || mediaType != printerStock?.mediaType {
                s.mediaType = mediaType
            }
        }
        return overrides.applied(to: s).withLabelSize(of: stock)
    }
}

// MARK: - Abweichungen

/// Abweichungen eines Etikettentyps von den Einstellungen des Druckers. `nil` = „wie Drucker“.
/// Die Typen entsprechen genau den Feldern von ``PrintSettings``.
public struct LabelTypeOverrides: Codable, Hashable, Sendable {
    /// Drehung im Uhrzeigersinn (`lwRotation`; ersetzt auch das ältere `lwRotate180`).
    public var rotation: PrintRotation?
    /// Temperatur 0…30 (`~SD`).
    public var darkness: Int?
    /// Geschwindigkeit in Zoll/s 1…14 (`^PR`).
    public var speed: Int?
    /// Medientyp (`^MN`: Einzeletiketten, Markierungen, Endlos …).
    public var mediaTracking: MediaTracking?
    /// Druckmodus (`^MT`: Thermodirekt/Thermotransfer).
    public var mediaType: MediaType?
    /// Bedienermodus (`^MM`).
    public var printMode: PrintMode?
    /// Versatz oben in Punkten −120…120 (`^LT`).
    public var labelTop: Int?
    /// Versatz links in Punkten −9999…9999 (`^LS`).
    public var labelLeft: Int?
    /// Abreißposition in Punkten −120…120 (`~TA`).
    public var tearOffAdjust: Int?
    public var mirror: Bool?
    public var negative: Bool?
    /// „An Etikett anpassen“ (`lwFitToLabel`).
    public var fitToLabel: LabelFitMode?

    public init(rotation: PrintRotation? = nil, darkness: Int? = nil, speed: Int? = nil,
                mediaTracking: MediaTracking? = nil, mediaType: MediaType? = nil, printMode: PrintMode? = nil,
                labelTop: Int? = nil, labelLeft: Int? = nil, tearOffAdjust: Int? = nil, mirror: Bool? = nil,
                negative: Bool? = nil, fitToLabel: LabelFitMode? = nil) {
        self.rotation = rotation
        self.darkness = darkness
        self.speed = speed
        self.mediaTracking = mediaTracking
        self.mediaType = mediaType
        self.printMode = printMode
        self.labelTop = labelTop
        self.labelLeft = labelLeft
        self.tearOffAdjust = tearOffAdjust
        self.mirror = mirror
        self.negative = negative
        self.fitToLabel = fitToLabel
    }

    /// Keine Abweichung – alles wie beim Drucker.
    public var isEmpty: Bool { self == LabelTypeOverrides() }

    /// Anzahl der Abweichungen.
    public var count: Int {
        let values: [Any?] = [rotation, darkness, speed, mediaTracking, mediaType, printMode, labelTop, labelLeft,
                              tearOffAdjust, mirror, negative, fitToLabel]
        return values.filter { $0 != nil }.count
    }

    /// Einstellungen mit diesen Abweichungen (Werte auf gültige Bereiche begrenzt, ``PrintSettings/clamped()``).
    /// Eine Drehung setzt das ältere `rotate180` zurück, damit genau sie gilt
    /// (``PrintSettings/effectiveRotation``).
    public func applied(to settings: PrintSettings) -> PrintSettings {
        var s = settings
        if let rotation {
            s.rotation = rotation
            s.rotate180 = false
        }
        if let darkness { s.darkness = darkness }
        if let speed { s.speed = speed }
        if let mediaTracking { s.tracking = mediaTracking }
        if let mediaType { s.mediaType = mediaType }
        if let printMode { s.printMode = printMode }
        if let labelTop { s.labelTop = labelTop }
        if let labelLeft { s.labelLeft = labelLeft }
        if let tearOffAdjust { s.tearOffAdjust = tearOffAdjust }
        if let mirror { s.mirror = mirror }
        if let negative { s.negative = negative }
        if let fitToLabel { s.fitToLabel = fitToLabel }
        return s.clamped()
    }
}

// MARK: - Tolerantes Dekodieren

extension LabelType {
    /// Pflicht sind Kennung und Format; fehlende oder ungültige übrige Werte (z. B. aus einer neueren
    /// App-Version) erhalten Standardwerte.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        let queue = value(String.self, .queueName)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: value(String.self, .name) ?? "",
            stockID: try c.decode(String.self, forKey: .stockID),
            overrides: value(LabelTypeOverrides.self, .overrides) ?? LabelTypeOverrides(),
            queueName: queue.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

extension LabelTypeOverrides {
    /// Jeder Wert einzeln: Ein unbekannter Wert (z. B. ein neuer Bedienermodus) gilt als „wie Drucker“,
    /// statt den ganzen Typ zu verwerfen.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        self.init(rotation: value(PrintRotation.self, .rotation), darkness: value(Int.self, .darkness),
                  speed: value(Int.self, .speed), mediaTracking: value(MediaTracking.self, .mediaTracking),
                  mediaType: value(MediaType.self, .mediaType), printMode: value(PrintMode.self, .printMode),
                  labelTop: value(Int.self, .labelTop), labelLeft: value(Int.self, .labelLeft),
                  tearOffAdjust: value(Int.self, .tearOffAdjust), mirror: value(Bool.self, .mirror),
                  negative: value(Bool.self, .negative), fitToLabel: value(LabelFitMode.self, .fitToLabel))
    }
}

// MARK: - Warteschlangen

/// Namen der macOS-Warteschlangen von Etikettentypen (ARCHITECTURE.md §9 „Etikettentypen“).
///
/// * **Name** (``queueName(baseQueue:typeName:existing:)``): `<Warteschlange des Druckers>_<Kürzel>`,
///   z. B. `Zebra_ZD421t_Brillenetikett` – nur `A–Z a–z 0–9 _ - .` im Kürzel (Umlaute als `ae`, `oe`,
///   `ue`, `ss`), höchstens 127 Bytes, eindeutig ohne Groß-/Kleinschreibung (`_2`, `_3` …). Einmal
///   vergeben, bleibt er (`LabelType.queueName`), auch wenn der Typ umbenannt wird.
/// * **Beschreibung** (``description(printerName:modelName:host:typeName:)``): „Zebra ZD421t –
///   Brillenetikett“ – so heißt der Drucker im Druckdialog.
public enum LabelTypeQueueNaming {
    /// Höchstlänge eines CUPS-Warteschlangennamens in Bytes (`validate_name` in cupsd: < 128).
    public static let maxLength = 127
    /// Trennzeichen zwischen Drucker- und Typkürzel.
    public static let separator = "_"
    /// Kürzel, wenn der Name des Typs kein verwendbares Zeichen enthält.
    public static let fallbackSlug = "Etikettentyp"

    /// Kürzel eines Typnamens: Umlaute umschrieben, Akzente entfernt, alles außer `A–Z a–z 0–9 - .`
    /// wird `_` (mehrere zusammengefasst, nicht am Rand); leer → ``fallbackSlug``.
    public static func slug(_ name: String) -> String {
        let replacements: [Character: String] = [
            "ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue", "ß": "ss", "ẞ": "SS",
        ]
        var transliterated = ""
        for character in name {
            transliterated += replacements[character] ?? String(character)
        }
        let folded = transliterated.folding(options: [.diacriticInsensitive, .widthInsensitive],
                                            locale: Locale(identifier: "en_US_POSIX"))
        var result = ""
        for scalar in folded.unicodeScalars {
            let ok = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == ".")
            if ok {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("_") {
                result += "_"
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_.-"))
        return result.isEmpty ? fallbackSlug : result
    }

    /// Stabiler, eindeutiger Name der Warteschlange eines neuen Typs.
    ///
    /// - Parameters:
    ///   - baseQueue: Warteschlange des Druckers (bzw. der bereinigte Druckername, falls er keine hat).
    ///   - typeName: Name des Typs.
    ///   - existing: vorhandene Warteschlangen und die Namen anderer Typen (ohne die eigene).
    public static func queueName(baseQueue: String, typeName: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        var base = baseQueue.trimmingCharacters(in: .whitespacesAndNewlines)
        base = String(base.unicodeScalars.filter(isLegal).map(Character.init))
        if base.isEmpty { base = "LabelWerk" }
        let slug = slug(typeName)
        var counter = 1
        while true {
            let suffix = counter == 1 ? "" : "\(separator)\(counter)"
            let candidate = compose(base: base, slug: slug, suffix: suffix)
            if !taken.contains(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }

    /// `base_slug_suffix` in höchstens ``maxLength`` Bytes: zuerst wird das Kürzel gekürzt (mindestens
    /// 8 Zeichen bleiben), dann der Druckerteil.
    static func compose(base: String, slug: String, suffix: String) -> String {
        var base = base
        var slug = slug
        func length() -> Int { base.utf8.count + separator.utf8.count + slug.utf8.count + suffix.utf8.count }
        while length() > maxLength, slug.count > 8 { slug.removeLast() }
        while length() > maxLength, base.count > 1 { base.removeLast() }
        while length() > maxLength, slug.count > 1 { slug.removeLast() }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_.-"))
        if slug.isEmpty { slug = "T" }
        return base + separator + slug + suffix
    }

    /// Zeichen, die CUPS in Warteschlangennamen erlaubt (kein Leer-/Steuerzeichen, `/ \ ? ' " # @`).
    static func isLegal(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.value > 0x20, scalar.value != 0x7F else { return false }
        return !"/\\?'\"#@".unicodeScalars.contains(scalar)
    }

    /// Ist `name` ein gültiger CUPS-Warteschlangenname (nicht leer, höchstens ``maxLength`` Bytes, ohne
    /// verbotene Zeichen)?
    public static func isValidQueueName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= maxLength && name.unicodeScalars.allSatisfy(isLegal)
    }

    /// Beschreibung im Druckdialog: „<Drucker> – <Typ>“. Ist der Druckername nur eine Adresse
    /// (``QueueAdoption/isAddressName(_:host:)``), steht dort der Modellname („Zebra ZD421t –
    /// Brillenetikett“); ein leerer Typname ergibt nur den Druckernamen.
    public static func description(printerName: String, modelName: String?, host: String? = nil,
                                   typeName: String) -> String {
        var printer = printerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if printer.isEmpty || QueueAdoption.isAddressName(printer, host: host),
           let model = modelName?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            printer = model
        }
        let type = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if printer.isEmpty { return type }
        if type.isEmpty { return printer }
        return "\(printer) – \(type)"
    }
}
