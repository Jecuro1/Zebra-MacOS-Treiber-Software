import Foundation

/// Vorlagen des ZPL-Designers. Jede Vorlage wird für das Zieletikett (Größe & Auflösung) neu
/// berechnet: Ränder, Schriftgrößen, Barcode-Module und QR-Vergrößerung passen sich an, Texte
/// werden in ihre Spalte eingepasst. Umlaute laufen über `^CI28` (UTF-8).
enum DesignerTemplate: String, CaseIterable, Identifiable {
    case shipping
    case product
    case priceTag
    case address
    case assetTag
    case shelf
    case businessCard
    case barcodeSheet
    case blank

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shipping: return tr("Versandetikett")
        case .product: return tr("Produktetikett")
        case .priceTag: return tr("Preisschild")
        case .address: return tr("Adressetikett")
        case .assetTag: return tr("Inventar-Etikett")
        case .shelf: return tr("Lagerplatz")
        case .businessCard: return tr("Visitenkarte")
        case .barcodeSheet: return tr("Barcode-Testblatt")
        case .blank: return tr("Neues Etikett")
        }
    }

    var subtitle: String {
        switch self {
        case .shipping: return tr("Absender, Empfänger, Code 128 & QR-Code")
        case .product: return tr("EAN-13, Preis & Mindesthaltbarkeit")
        case .priceTag: return tr("Aktionspreis mit Rabatt-Plakette")
        case .address: return tr("Absenderzeile, Empfänger & Frankierfeld")
        case .assetTag: return tr("Asset-Tag mit QR-Code")
        case .shelf: return tr("Regaletikett mit großem Text & Code 128")
        case .businessCard: return tr("Kontaktdaten mit vCard-QR-Code")
        case .barcodeSheet: return tr("Alle Symbologien & Lineal zur Druckbildprüfung")
        case .blank: return tr("Leeres Grundgerüst mit Größe & UTF-8")
        }
    }

    var systemImage: String {
        switch self {
        case .shipping: return "shippingbox"
        case .product: return "tag"
        case .priceTag: return "eurosign.circle"
        case .address: return "envelope"
        case .assetTag: return "qrcode"
        case .shelf: return "archivebox"
        case .businessCard: return "person.crop.rectangle"
        case .barcodeSheet: return "barcode.viewfinder"
        case .blank: return "doc.badge.plus"
        }
    }

    /// Erzeugt das vollständige Format `^XA … ^XZ` für die Etikettengeometrie.
    func zpl(geometry: DesignerLabelGeometry, date: Date = Date()) -> String {
        var builder = DesignerZPLBuilder(geometry: geometry)
        switch self {
        case .shipping: Self.shipping(&builder, date: date)
        case .product: Self.product(&builder, date: date)
        case .priceTag: Self.priceTag(&builder)
        case .address: Self.address(&builder)
        case .assetTag: Self.assetTag(&builder, date: date)
        case .shelf: Self.shelf(&builder)
        case .businessCard: Self.businessCard(&builder)
        case .barcodeSheet: Self.barcodeSheet(&builder)
        case .blank: Self.blank(&builder)
        }
        return builder.document(title: title + " – LabelWerk")
    }

    // MARK: - Hilfen

    private typealias Z = DesignerZPLBuilder

    /// Lokalisiertes Datum (z. B. 09.11.2026).
    static func displayDate(_ date: Date, addingDays days: Int = 0) -> String {
        let shifted = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("ddMMyyyy")
        return formatter.string(from: shifted)
    }

    /// Kompaktes Datum für Kennungen (JJJJMMTT).
    static func compactDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    static func year(_ date: Date) -> String {
        String(Calendar.current.component(.year, from: date))
    }

    /// Millimeterwert mit einer Nachkommastelle im Gebietsschema des Benutzers.
    static func millimeters(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    // MARK: - Versandetikett

    private static func shipping(_ b: inout DesignerZPLBuilder, date: Date) {
        let g = b.geometry
        let W = g.widthDots, H = g.heightDots, m = g.margin
        let cw = W - 2 * m, ch = H - 2 * m
        let thin = max(2, g.dots(0.3))
        let heavy = max(3, g.dots(0.8))
        func part(_ fraction: Double) -> Int { Int(Double(ch) * fraction) }

        b.box(x: m / 2, y: m / 2, width: W - m, height: H - m, thickness: thin, rounding: 1)

        // Kopfband (weiß auf schwarz)
        var y = m
        let header = max(20, part(0.08))
        let pad = max(4, header / 4)
        b.fill(x: m, y: y, width: cw, height: header, rounding: 1)
        b.textStack([(tr("PAKET"), 1)], x: m + pad, y: y + header * 16 / 100, width: cw / 2 - pad,
                    height: header * 68 / 100, reverse: true)
        b.textStack([(tr("EXPRESS · 1/1"), 1)], x: m + cw / 2, y: y + header * 28 / 100, width: cw / 2 - pad,
                    height: header * 46 / 100, justification: "R", reverse: true)
        y += header + part(0.025)

        // Absender
        let sender = part(0.12)
        b.textStack([(tr("ABSENDER"), 0.7),
                     (tr("LabelWerk GmbH · Versand"), 1),
                     (tr("Musterstraße 12 · 10115 Berlin"), 1)],
                    x: m, y: y, width: cw, height: sender)
        y += sender + part(0.012)
        b.horizontalLine(x: m, y: y, length: cw, thickness: thin)
        y += thin + part(0.018)

        // Empfänger
        let recipient = part(0.29)
        b.textStack([(tr("EMPFÄNGER"), 0.55),
                     (tr("Erika Mustermann"), 1.2),
                     (tr("Hauptstraße 5"), 1.0),
                     (tr("80331 MÜNCHEN"), 1.45),
                     (tr("DEUTSCHLAND"), 0.8)],
                    x: m, y: y, width: cw, height: recipient, spacing: 0.2)
        y += recipient + part(0.012)
        b.horizontalLine(x: m, y: y, length: cw, thickness: heavy)
        y += heavy + part(0.018)

        // Sendungsnummer als Code 128
        let trackingBlock = part(0.215)
        let caption = max(10, trackingBlock * 13 / 100)
        b.text(tr("SENDUNGSNUMMER"), x: m, y: y, height: Z.fittedHeight(tr("SENDUNGSNUMMER"), maxWidth: cw, preferred: caption))
        let tracking = "LW" + compactDate(date) + "0001DE"
        let module = Z.clamp(cw / Z.code128Modules(tracking), 1, 4)
        let codeWidth = Z.code128Modules(tracking) * module
        let barTop = y + caption + caption / 2
        let barHeight = max(16, y + trackingBlock - barTop - Z.interpretationHeight(module: module))
        b.code128(tracking, x: m + max(0, (cw - codeWidth) / 2), y: barTop, height: barHeight, module: module)
        y += trackingBlock + part(0.012)
        b.horizontalLine(x: m, y: y, length: cw, thickness: thin)
        y += thin + part(0.018)

        // Fuß: Sendungsdaten + QR-Code
        let footer = H - m - y
        guard footer > 24 else { return }
        let qrData = "https://example.com/sendung/" + tracking
        let modules = Z.qrModules(qrData)
        let magnification = Z.clamp(min(footer, cw * 40 / 100) / (modules + 2), 1, 10)
        let qrSize = magnification * modules
        b.qr(qrData, x: W - m - qrSize, y: y + max(0, (footer - qrSize) / 2), magnification: magnification)
        let infoWidth = cw - qrSize - g.dots(3)
        if infoWidth > g.dots(14) {
            b.textStack([(tr("Gewicht: 2,4 kg"), 1),
                         (tr("Service: Express 24 h"), 1),
                         (tr("Datum:") + " " + displayDate(date), 1),
                         (tr("Referenz: Bestellung 4711"), 1)],
                        x: m, y: y, width: infoWidth, height: footer, spacing: 0.32)
        }
    }

    // MARK: - Produktetikett

    private static func product(_ b: inout DesignerZPLBuilder, date: Date) {
        let g = b.geometry
        let W = g.widthDots, H = g.heightDots, m = g.margin
        let cw = W - 2 * m, ch = H - 2 * m
        let thin = max(2, g.dots(0.3))
        func part(_ fraction: Double) -> Int { Int(Double(ch) * fraction) }

        b.box(x: m / 2, y: m / 2, width: W - m, height: H - m, thickness: thin, rounding: 2)
        let landscape = g.isLandscape
        let head = part(landscape ? 0.44 : 0.32)
        b.textStack([(tr("LABELWERK MANUFAKTUR"), 0.55),
                     (tr("Bio-Bergkäse"), 1.6),
                     (tr("würzig · 12 Monate gereift"), 0.7)],
                    x: m, y: m, width: cw, height: head, spacing: 0.22)
        var y = m + head + part(0.03)
        b.horizontalLine(x: m, y: y, length: cw, thickness: thin)
        y += thin + part(0.035)

        let rest = H - m - y
        let bestBefore = tr("Mindestens haltbar bis") + " " + displayDate(date, addingDays: 60)
        let priceItems: [(text: String, weight: Double)] = [
            (tr("4,99 €"), 2.2),
            (tr("250 g · 19,96 €/kg"), 0.62),
            (bestBefore, 0.55),
        ]
        if landscape {
            let eanWidth = cw * 56 / 100
            let priceWidth = cw - eanWidth - g.dots(3)
            ean(&b, x: m, y: y, width: eanWidth, height: rest)
            b.textStack(priceItems, x: m + cw - priceWidth, y: y, width: priceWidth, height: rest,
                        justification: "R", spacing: 0.18)
        } else {
            let priceHeight = rest * 42 / 100
            b.textStack(priceItems, x: m, y: y, width: cw, height: priceHeight, justification: "R", spacing: 0.18)
            let eanTop = y + priceHeight + part(0.03)
            ean(&b, x: m, y: eanTop, width: cw, height: H - m - eanTop)
        }
    }

    /// EAN-13 zentriert in einer Fläche (Platz für die führende Ziffer links).
    private static func ean(_ b: inout DesignerZPLBuilder, x: Int, y: Int, width: Int, height: Int) {
        let module = Z.clamp(width / 110, 1, 4)
        let leading = 9 * module
        let symbolWidth = 95 * module
        let barHeight = max(16, height - Z.interpretationHeight(module: module))
        b.ean13("400638133393", x: x + leading + max(0, (width - leading - symbolWidth) / 2), y: y,
                height: barHeight, module: module)
    }

    // MARK: - Preisschild

    private static func priceTag(_ b: inout DesignerZPLBuilder) {
        let g = b.geometry
        let W = g.widthDots, H = g.heightDots, m = g.margin
        let cw = W - 2 * m, ch = H - 2 * m
        func part(_ fraction: Double) -> Int { Int(Double(ch) * fraction) }

        // Kopfband
        let band = max(20, part(0.16))
        let pad = max(4, band / 4)
        b.fill(x: m, y: m, width: cw, height: band, rounding: 1)
        b.textStack([(tr("ANGEBOT"), 1)], x: m + pad, y: m + band * 16 / 100, width: cw * 45 / 100,
                    height: band * 68 / 100, reverse: true)
        b.textStack([(tr("NUR DIESE WOCHE"), 1)], x: m + cw / 2, y: m + band * 28 / 100, width: cw / 2 - pad,
                    height: band * 44 / 100, justification: "R", reverse: true)

        // Produkt, alter und neuer Preis, Plakette
        let top = m + band + part(0.04)
        let bottom = part(0.2)
        let info = max(24, H - m - bottom - part(0.03) - top)
        let badge = max(24, min(cw * 28 / 100, info * 80 / 100))
        let textWidth = cw - badge - g.dots(3)
        let nameHeight = info * 38 / 100
        b.textStack([(tr("Espresso-Bohnen"), 1.35), (tr("Single Origin · Arabica · 1 kg"), 0.6)],
                    x: m, y: top, width: textWidth, height: nameHeight, spacing: 0.2)
        let oldTop = top + nameHeight + info * 4 / 100
        let oldText = tr("statt 23,99 €")
        let oldHeight = Z.fittedHeight(oldText, maxWidth: textWidth, preferred: info * 13 / 100)
        b.text(oldText, x: m, y: oldTop, height: oldHeight)
        let oldWidth = min(textWidth, Z.estimatedWidth(oldText, height: oldHeight))
        b.horizontalLine(x: m, y: oldTop + oldHeight * 45 / 100, length: oldWidth, thickness: max(2, oldHeight / 9))
        let priceTop = oldTop + oldHeight + info * 3 / 100
        b.textStack([(tr("17,99 €"), 1)], x: m, y: priceTop, width: textWidth, height: max(12, top + info - priceTop))

        let badgeX = m + cw - badge
        let badgeY = top + (info - badge) / 2
        b.circle(x: badgeX, y: badgeY, diameter: badge, thickness: badge / 2 + 1)
        let badgeText = tr("-25 %")
        let badgeTextHeight = Z.fittedHeight(badgeText, maxWidth: badge * 70 / 100, preferred: badge * 30 / 100)
        b.block([badgeText], x: badgeX, y: badgeY + (badge - badgeTextHeight) / 2, width: badge,
                height: badgeTextHeight, justification: "C", reverse: true)

        // Fuß: Artikelnummer als Code 128 + Hinweise
        let footY = H - m - bottom
        b.horizontalLine(x: m, y: footY - part(0.015), length: cw, thickness: max(1, g.dots(0.2)))
        let code = "4711-0815"
        let module = Z.clamp((cw * 45 / 100) / Z.code128Modules(code), 1, 3)
        let barHeight = max(12, bottom - Z.interpretationHeight(module: module) - part(0.01))
        b.code128(code, x: m, y: footY + part(0.005), height: barHeight, module: module)
        let noteWidth = cw - Z.code128Modules(code) * module - g.dots(3)
        if noteWidth > g.dots(12) {
            b.textStack([(tr("Preis inkl. MwSt."), 1), (tr("Grundpreis 17,99 €/kg"), 1)],
                        x: m + cw - noteWidth, y: footY + bottom * 12 / 100, width: noteWidth,
                        height: bottom * 72 / 100, justification: "R")
        }
    }

    // MARK: - Adressetikett

    private static func address(_ b: inout DesignerZPLBuilder) {
        let g = b.geometry
        let W = g.widthDots, H = g.heightDots, m = g.margin
        let cw = W - 2 * m, ch = H - 2 * m
        func part(_ fraction: Double) -> Int { Int(Double(ch) * fraction) }

        let bar = max(g.dots(1), cw / 70)
        b.fill(x: m, y: m, width: bar, height: ch)
        let x0 = m + bar + max(g.dots(2), cw / 30)
        let width = W - m - x0

        // Absenderzeile (unterstrichen)
        let senderBlock = part(0.13)
        let senderText = tr("LabelWerk GmbH · Musterstraße 12 · 10115 Berlin")
        let senderHeight = Z.fittedHeight(senderText, maxWidth: width, preferred: senderBlock * 70 / 100)
        b.text(senderText, x: x0, y: m, height: senderHeight)
        b.horizontalLine(x: x0, y: m + senderHeight + max(2, senderHeight / 5),
                         length: min(width, Z.estimatedWidth(senderText, height: senderHeight)),
                         thickness: max(1, g.dots(0.2)))

        // Frankierfeld
        let top = m + senderBlock + part(0.08)
        let stampWidth = min(width * 24 / 100, ch * 34 / 100)
        let stampHeight = stampWidth * 80 / 100
        let showsStamp = stampWidth >= g.dots(9)
        if showsStamp {
            let stampX = W - m - stampWidth
            b.box(x: stampX, y: top, width: stampWidth, height: stampHeight, thickness: max(2, g.dots(0.35)), rounding: 1)
            let lineHeight = Z.fittedHeight(tr("bezahlt"), maxWidth: stampWidth * 76 / 100, preferred: stampWidth * 20 / 100)
            let spacing = lineHeight / 4
            b.block([tr("Entgelt"), tr("bezahlt")], x: stampX, y: top + max(0, (stampHeight - 2 * lineHeight - spacing) / 2),
                    width: stampWidth, height: lineHeight, lineSpacing: spacing, justification: "C")
        }

        // Empfänger
        let recipientWidth = showsStamp ? width - stampWidth - g.dots(3) : width
        b.textStack([(tr("Herrn"), 0.75),
                     (tr("Max Mustermann"), 1.15),
                     (tr("c/o Lagerhalle 3"), 0.9),
                     (tr("Lindenallee 7"), 0.95),
                     (tr("50667 KÖLN"), 1.25)],
                    x: x0, y: top, width: recipientWidth, height: H - m - top, spacing: 0.2)
    }

    // MARK: - Inventar-Etikett

    private static func assetTag(_ b: inout DesignerZPLBuilder, date: Date) {
        let g = b.geometry
        let W = g.widthDots, H = g.heightDots, m = g.margin
        let cw = W - 2 * m, ch = H - 2 * m
        func part(_ fraction: Double) -> Int { Int(Double(ch) * fraction) }

        b.box(x: m / 2, y: m / 2, width: W - m, height: H - m, thickness: max(2, g.dots(0.5)), rounding: 2)
        let band = max(20, part(0.2))
        b.fill(x: m, y: m, width: cw, height: band, rounding: 1)
        b.textStack([(tr("EIGENTUM DER LABELWERK GMBH"), 1)], x: m + g.dots(1), y: m + band * 22 / 100,
                    width: cw - g.dots(2), height: band * 56 / 100, justification: "C", reverse: true)

        let top = m + band + part(0.05)
        let body = H - m - top
        let assetID = "INV-" + year(date) + "-00421"
        let url = "https://example.com/inventar/" + assetID
        let modules = Z.qrModules(url)
        let items: [(text: String, weight: Double)] = [
            (tr("INVENTAR-NR."), 0.5),
            (assetID, 1.25),
            (tr("MacBook Pro 14 Zoll"), 0.75),
            (tr("Kostenstelle 4711 · IT"), 0.6),
            (tr("Geprüft:") + " " + displayDate(date), 0.6),
        ]
        if cw >= body * 8 / 10 {
            // QR-Code links, Angaben rechts
            let magnification = Z.clamp(min(body, cw * 38 / 100) / (modules + 1), 1, 10)
            let size = magnification * modules
            b.qr(url, x: m, y: top + max(0, (body - size) / 2), magnification: magnification)
            let textX = m + size + max(g.dots(3), cw / 25)
            b.textStack(items, x: textX, y: top, width: W - m - textX, height: body, spacing: 0.2)
        } else {
            // Hochformat: QR-Code oben, Angaben darunter
            let magnification = Z.clamp(min(body * 45 / 100, cw) / (modules + 1), 1, 10)
            let size = magnification * modules
            b.qr(url, x: m + max(0, (cw - size) / 2), y: top, magnification: magnification)
            let textTop = top + size + part(0.04)
            b.textStack(items, x: m, y: textTop, width: cw, height: H - m - textTop, justification: "C", spacing: 0.2)
        }
    }

    // MARK: - Lagerplatz

    private static func shelf(_ b: inout DesignerZPLBuilder) {
        let g = b.geometry
        let W = g.widthDots, H = g.heightDots, m = g.margin
        let cw = W - 2 * m, ch = H - 2 * m
        func part(_ fraction: Double) -> Int { Int(Double(ch) * fraction) }

        let band = max(20, part(0.15))
        let pad = max(4, band / 4)
        b.fill(x: m, y: m, width: cw, height: band, rounding: 1)
        b.textStack([(tr("LAGERPLATZ"), 1)], x: m + pad, y: m + band * 20 / 100, width: cw / 2 - pad,
                    height: band * 60 / 100, reverse: true)
        b.textStack([(tr("ZONE A"), 1)], x: m + cw / 2, y: m + band * 20 / 100, width: cw / 2 - pad,
                    height: band * 60 / 100, justification: "R", reverse: true)

        let top = m + band + part(0.04)
        let codeArea = part(0.24)
        let main = max(24, H - m - codeArea - part(0.04) - top)
        let arrowWidth = min(cw * 20 / 100, main * 70 / 100)
        let textWidth = cw - arrowWidth - g.dots(4)
        b.textStack([("A-03-12", 3.2), (tr("Gang A · Regal 03 · Fach 12"), 0.75)],
                    x: m, y: top, width: textWidth, height: main, spacing: 0.12)
        b.arrowUp(x: m + cw - arrowWidth, y: top + main * 4 / 100, width: arrowWidth, height: main * 92 / 100)

        let codeTop = H - m - codeArea
        let data = "A0312"
        let module = Z.clamp(cw / Z.code128Modules(data), 1, 5)
        let width = Z.code128Modules(data) * module
        b.code128(data, x: m + max(0, (cw - width) / 2), y: codeTop,
                  height: max(16, codeArea - Z.interpretationHeight(module: module)), module: module)
    }

    // MARK: - Visitenkarte

    private static func businessCard(_ b: inout DesignerZPLBuilder) {
        let g = b.geometry
        let W = g.widthDots, H = g.heightDots, m = g.margin
        let cw = W - 2 * m, ch = H - 2 * m
        func part(_ fraction: Double) -> Int { Int(Double(ch) * fraction) }

        let bar = max(g.dots(1.2), cw / 45)
        b.fill(x: m, y: m, width: bar, height: ch)
        let x0 = m + bar + max(g.dots(3), cw / 22)
        let width = W - m - x0

        let head = part(0.44)
        b.textStack([(tr("Erika Mustermann"), 1.35), (tr("Leitung Logistik"), 0.72), (tr("LabelWerk GmbH"), 0.85)],
                    x: x0, y: m, width: width, height: head, spacing: 0.22)
        let lineY = m + head + part(0.05)
        b.horizontalLine(x: x0, y: lineY, length: max(g.dots(8), width * 35 / 100), thickness: max(2, g.dots(0.4)))

        let contactTop = lineY + part(0.07)
        let contactHeight = H - m - contactTop
        let vcard = "MECARD:N:Mustermann,Erika;ORG:LabelWerk GmbH;TEL:+49301234567;"
            + "EMAIL:erika.mustermann@example.com;URL:https://example.com;;"
        let modules = Z.qrModules(vcard)
        let magnification = Z.clamp(min(contactHeight + part(0.12), width * 34 / 100) / (modules + 1), 1, 10)
        let qrSize = magnification * modules
        b.qr(vcard, x: W - m - qrSize, y: H - m - qrSize, magnification: magnification)
        let contactWidth = W - m - qrSize - g.dots(3) - x0
        if contactWidth > g.dots(12) {
            b.textStack([(tr("Tel. +49 30 1234567"), 1), ("erika.mustermann@example.com", 1), ("www.example.com", 1)],
                        x: x0, y: contactTop, width: contactWidth, height: contactHeight, spacing: 0.3)
        }
    }

    // MARK: - Barcode-Testblatt

    private enum SheetSymbol: CaseIterable {
        case code128, code39, ean13, ean8, upcA, interleaved, qr, dataMatrix, pdf417

        var caption: String {
            switch self {
            case .code128: return tr("Code 128")
            case .code39: return tr("Code 39")
            case .ean13: return tr("EAN-13")
            case .ean8: return tr("EAN-8")
            case .upcA: return tr("UPC-A")
            case .interleaved: return tr("Interleaved 2 of 5")
            case .qr: return tr("QR-Code")
            case .dataMatrix: return tr("DataMatrix")
            case .pdf417: return tr("PDF417")
            }
        }
    }

    private static func barcodeSheet(_ b: inout DesignerZPLBuilder) {
        let g = b.geometry
        let W = g.widthDots, H = g.heightDots, m = g.margin
        let cw = W - 2 * m, ch = H - 2 * m
        func part(_ fraction: Double) -> Int { Int(Double(ch) * fraction) }

        // Kopf
        let band = max(20, part(0.09))
        let pad = max(4, band / 4)
        b.fill(x: m, y: m, width: cw, height: band, rounding: 1)
        b.textStack([(tr("BARCODE-TESTBLATT"), 1)], x: m + pad, y: m + band * 18 / 100, width: cw * 52 / 100,
                    height: band * 64 / 100, reverse: true)
        let info = tr("%d dpi", g.dpi) + " · " + millimeters(g.widthMM) + " × " + millimeters(g.heightMM) + " mm"
        b.textStack([(info, 1)], x: m + cw * 55 / 100, y: m + band * 30 / 100, width: cw * 45 / 100 - pad,
                    height: band * 40 / 100, justification: "R", reverse: true)

        // Raster der Symbologien – Spaltenzahl so wählen, dass Zellen etwa 1,6 : 1 haben.
        let footer = max(24, part(0.1))
        let gridTop = m + band + part(0.03)
        let gridHeight = max(40, H - m - footer - part(0.03) - gridTop)
        let symbols = SheetSymbol.allCases
        var columns = 1
        var bestScore = Double.greatestFiniteMagnitude
        for candidate in 1...4 {
            let rows = (symbols.count + candidate - 1) / candidate
            let aspect = (Double(cw) / Double(candidate)) / (Double(gridHeight) / Double(rows))
            let score = abs(log(aspect / 1.6))
            if score < bestScore { bestScore = score; columns = candidate }
        }
        let rows = (symbols.count + columns - 1) / columns
        let cellWidth = cw / columns
        let cellHeight = gridHeight / rows
        let cellPad = max(4, min(cellWidth, cellHeight) / 14)
        let captionHeight = Z.clamp(cellHeight * 16 / 100, 10, g.dots(3))
        for (index, symbol) in symbols.enumerated() {
            let cx = m + (index % columns) * cellWidth
            let cy = gridTop + (index / columns) * cellHeight
            b.box(x: cx, y: cy, width: cellWidth, height: cellHeight, thickness: 1, rounding: 1)
            b.text(symbol.caption, x: cx + cellPad, y: cy + cellPad,
                   height: Z.fittedHeight(symbol.caption, maxWidth: cellWidth - 2 * cellPad, preferred: captionHeight))
            let sx = cx + cellPad
            let sy = cy + cellPad + captionHeight + cellPad / 2
            let sw = max(8, cellWidth - 2 * cellPad)
            let sh = max(8, cellHeight - 2 * cellPad - captionHeight - cellPad / 2)
            sheetSymbol(&b, symbol, x: sx, y: sy, width: sw, height: sh)
        }

        // Millimeter-Lineal
        let rulerTop = H - m - footer
        let dpmm = g.dotsPerMM
        let millimeterCount = max(0, cw / dpmm)
        let tick = max(1, dpmm / 6)
        let numberHeight = Z.clamp(footer * 30 / 100, 10, g.dots(2.5))
        b.horizontalLine(x: m, y: rulerTop, length: millimeterCount * dpmm + tick, thickness: max(1, g.dots(0.25)))
        for index in 0...millimeterCount {
            let length: Int
            if index % 10 == 0 {
                length = footer * 45 / 100
            } else if index % 5 == 0 {
                length = footer * 30 / 100
            } else {
                length = footer * 16 / 100
            }
            let x = m + index * dpmm
            b.verticalLine(x: x, y: rulerTop, length: max(2, length), thickness: tick)
            if index % 10 == 0 {
                let label = String(index)
                let labelWidth = Z.estimatedWidth(label, height: numberHeight)
                let labelX = min(max(m, x - labelWidth / 2), W - m - labelWidth)
                b.text(label, x: labelX, y: rulerTop + footer * 52 / 100, height: numberHeight)
            }
        }
    }

    private static func sheetSymbol(_ b: inout DesignerZPLBuilder, _ symbol: SheetSymbol,
                                    x: Int, y: Int, width: Int, height: Int) {
        func linear(modules: Int, maxModule: Int = 3) -> (module: Int, x: Int, height: Int) {
            let module = Z.clamp(width / max(1, modules), 1, maxModule)
            let symbolWidth = modules * module
            let barHeight = max(8, height - Z.interpretationHeight(module: module))
            return (module, x + max(0, (width - symbolWidth) / 2), barHeight)
        }
        /// EAN/UPC: Die Balken beginnen nach der Ruhezone (`quiet` Module, dort steht die erste
        /// Klarschriftziffer). Ist die Zelle zu schmal, rücken die Balken in die Ruhezone, damit
        /// das Symbol (`core` Module) nicht über den Zellrand hinausragt.
        func barsX(_ fit: (module: Int, x: Int, height: Int), quiet: Int, core: Int) -> Int {
            max(x, min(fit.x + quiet * fit.module, x + width - core * fit.module))
        }
        switch symbol {
        case .code128:
            let data = "LabelWerk-128"
            let fit = linear(modules: Z.code128Modules(data))
            b.code128(data, x: fit.x, y: y, height: fit.height, module: fit.module)
        case .code39:
            let data = "LW39"
            let fit = linear(modules: Z.code39Modules(data))
            b.code39(data, x: fit.x, y: y, height: fit.height, module: fit.module)
        case .ean13:
            let fit = linear(modules: 110)
            b.ean13("400638133393", x: barsX(fit, quiet: 9, core: 95), y: y, height: fit.height, module: fit.module)
        case .ean8:
            let fit = linear(modules: 81)
            b.ean8("1234567", x: barsX(fit, quiet: 7, core: 67), y: y, height: fit.height, module: fit.module)
        case .upcA:
            let fit = linear(modules: 113)
            b.upcA("03600029145", x: barsX(fit, quiet: 9, core: 95), y: y, height: fit.height, module: fit.module)
        case .interleaved:
            let digits = "12345678"
            let fit = linear(modules: Z.interleavedModules(digits))
            b.interleaved2of5(digits, x: fit.x, y: y, height: fit.height, module: fit.module)
        case .qr:
            let data = "https://example.com/labelwerk"
            let modules = Z.qrModules(data)
            let magnification = Z.clamp(min(width, height) / (modules + 2), 1, 10)
            let size = modules * magnification
            b.qr(data, x: x + max(0, (width - size) / 2), y: y, magnification: magnification)
        case .dataMatrix:
            let data = "LabelWerk 2026"
            let modules = Z.dataMatrixModules(data)
            let module = Z.clamp(min(width, height) / (modules + 2), 1, 12)
            let size = modules * module
            b.dataMatrix(data, x: x + max(0, (width - size) / 2), y: y + max(0, (height - size) / 2), module: module)
        case .pdf417:
            let module = Z.clamp(width / 130, 1, 3)
            let rowHeight = Z.clamp(height / 10, 2, module * 4)
            let symbolWidth = 120 * module
            b.pdf417("LabelWerk PDF417", x: x + max(0, (width - symbolWidth) / 2), y: y, module: module,
                     rowHeight: rowHeight, columns: 3)
        }
    }

    // MARK: - Neues Etikett

    private static func blank(_ b: inout DesignerZPLBuilder) {
        let g = b.geometry
        let H = g.heightDots, m = g.margin
        let cw = g.widthDots - 2 * m, ch = H - 2 * m
        let text = tr("Neues Etikett")
        let height = Z.fittedHeight(text, maxWidth: cw, preferred: Z.clamp(ch / 6, 14, g.dots(10)))
        b.block([text], x: m, y: (H - height) / 2, width: cw, height: height, justification: "C")
    }
}
