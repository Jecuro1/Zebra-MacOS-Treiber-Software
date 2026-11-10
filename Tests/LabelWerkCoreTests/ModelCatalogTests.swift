import Foundation
import Testing
@testable import LabelWerkCore

@Suite("Modellkatalog")
struct ModelCatalogTests {
    let catalog = ModelCatalog.shared

    @Test("Eingebetteter Katalog wird geladen")
    func loads() {
        #expect(catalog.schemaVersion >= 1)
        #expect(catalog.models.count >= 60)
        #expect(catalog.stocks.count >= 30)
    }

    @Test("Kennungen sind eindeutig und kleingeschrieben")
    func uniqueIDs() {
        let modelIDs = catalog.models.map(\.id)
        #expect(Set(modelIDs).count == modelIDs.count)
        #expect(modelIDs.allSatisfy { $0 == $0.lowercased() })
        let stockIDs = catalog.stocks.map(\.id)
        #expect(Set(stockIDs).count == stockIDs.count)
    }

    @Test("Jedes Modell ist vollständig beschrieben")
    func modelsAreComplete() {
        for model in catalog.models {
            #expect(catalog.stock(id: model.defaultStock) != nil, "\(model.id): Standardformat \(model.defaultStock) fehlt")
            #expect(!model.resolutions.isEmpty, "\(model.id)")
            #expect(model.supportedResolutions.count == model.resolutions.count, "\(model.id)")
            #expect(model.languages.contains(model.defaultLanguage), "\(model.id)")
            #expect(!model.mediaTypes.isEmpty, "\(model.id)")
            #expect(!model.ieee1284.isEmpty, "\(model.id)")
            #expect(model.printWidthMM > 40 && model.printWidthMM < 220, "\(model.id)")
            #expect(model.maxLabelLengthMM > model.printWidthMM / 2, "\(model.id)")
            for resolution in model.supportedResolutions {
                #expect(model.maxSpeed(resolution) >= 2, "\(model.id) \(resolution)")
                #expect(model.printWidthDots(resolution) > 0)
            }
            #expect(model.displayName.hasPrefix("Zebra "))
            #expect(!model.systemImage.isEmpty)
        }
    }

    @Test("Etikettenformate sind plausibel")
    func stocksArePlausible() {
        for stock in catalog.stocks {
            #expect(stock.widthMM > 5 && stock.widthMM <= 220, "\(stock.id)")
            #expect(stock.heightMM > 5, "\(stock.id)")
            #expect(stock.gapMM >= 0, "\(stock.id)")
            #expect(!stock.name.isEmpty)
            #expect(stock.ppdKeyword.hasPrefix("w"))
        }
        let w4h6 = catalog.stock(id: "w4h6in")
        #expect(w4h6?.widthDots(.dpi203) == 812)
        #expect(w4h6?.heightDots(.dpi203) == 1218)
        #expect(w4h6?.ppdKeyword == "w288h432")
    }

    @Test("Modellsuche nach Kennung (Groß-/Kleinschreibung egal)")
    func lookup() {
        #expect(catalog.model(id: "ZD421T")?.name == "ZD421t")
        #expect(catalog.model(id: "gibtsnicht") == nil)
    }

    @Test("Zuordnung über Produktnamen")
    func matchProductName() throws {
        let zd421 = try #require(catalog.match(productName: "ZD421-203dpi"))
        #expect(zd421.id.hasPrefix("zd421"))
        #expect(zd421.family == "ZD400")
        #expect(catalog.match(productName: "ZTC ZT410-300dpi ZPL")?.id == "zt410")
        #expect(catalog.match(productName: "GK420d")?.id == "gk420d")
        #expect(catalog.match(productName: "GK420t")?.id == "gk420t")
        #expect(catalog.match(productName: "ZT411")?.id == "zt411")
        #expect(catalog.match(productName: "ZT411-600dpi")?.id == "zt411")
        #expect(catalog.match(productName: "Zebra ZD421t")?.id == "zd421t")
        #expect(catalog.match(productName: "ZDesigner ZQ630")?.id == "zq630")
        #expect(catalog.match(productName: "") == nil)
        #expect(catalog.match(productName: "Brother QL-800") == nil)
    }

    @Test("Zuordnung über IEEE-1284-Modellnamen")
    func matchIEEE1284() {
        #expect(catalog.match(ieee1284Model: "ZDesigner GK420t")?.id == "gk420t")
        #expect(catalog.match(ieee1284Model: "zdesigner  gk420t")?.id == "gk420t")
        #expect(catalog.match(ieee1284Model: "Unbekannt 1") == nil)
    }

    @Test("Passende Formate und Kategorien")
    func fittingAndCategories() throws {
        let model = try #require(catalog.model(id: "zd411d"))
        let fitting = catalog.stocks(fitting: model)
        #expect(!fitting.isEmpty)
        #expect(fitting.allSatisfy { $0.widthMM <= model.printWidthMM + 2 })
        #expect(!fitting.contains { $0.id == "w4h6in" })

        let mobile = catalog.models(in: .mobile)
        #expect(!mobile.isEmpty)
        #expect(mobile.allSatisfy { $0.category == .mobile })
        #expect(mobile.map(\.name) == mobile.map(\.name).sorted())
    }

    @Test("Eigener Katalog aus JSON und Fehlerfall")
    func customCatalog() throws {
        let encoder = JSONEncoder()
        struct Payload: Encodable { var schemaVersion: Int; var models: [PrinterModel]; var stocks: [LabelStock] }
        let model = try #require(catalog.model(id: "zd421t"))
        let stock = try #require(catalog.stock(id: model.defaultStock))
        let data = try encoder.encode(Payload(schemaVersion: 7, models: [model], stocks: [stock]))
        let custom = try ModelCatalog(jsonData: data)
        #expect(custom.schemaVersion == 7)
        #expect(custom.models == [model])
        #expect(custom.stocks == [stock])
        #expect(throws: (any Error).self) { try ModelCatalog(jsonData: Data("{\"models\": 1}".utf8)) }

        let direct = ModelCatalog(models: [model], stocks: [])
        #expect(direct.schemaVersion == 1)
        #expect(direct.match(productName: "ZD421t")?.id == "zd421t")
    }

    @Test("Codable-Rundreise eines Modells")
    func modelCodable() throws {
        for model in catalog.models.prefix(10) {
            let decoded = try JSONDecoder().decode(PrinterModel.self, from: JSONEncoder().encode(model))
            #expect(decoded == model)
        }
    }
}

@Suite("Auflösung")
struct ResolutionTests {
    @Test("Umrechnungen")
    func conversions() {
        #expect(Resolution.dpi203.dotsPerMM == 8)
        #expect(Resolution.dpi300.dotsPerMM == 12)
        #expect(Resolution.dpi600.dotsPerMM == 24)
        #expect(Resolution.dpi152.dotsPerMM == 6)
        #expect(Resolution(dotsPerMM: 12) == .dpi300)
        #expect(Resolution(dotsPerMM: 7) == nil)
        #expect(Resolution(dpi: 600) == .dpi600)
        #expect(Resolution.dpi203.dots(fromInches: 4) == 812)
        #expect(Resolution.dpi300.dots(fromMM: 25.4) == 300)
        #expect(Resolution.dpi203.dots(fromPoints: 72) == 203)
        #expect(abs(Resolution.dpi203.mm(fromDots: 203) - 25.4) < 0.0001)
        #expect(Resolution.dpi300.inches(fromDots: 600) == 2)
        #expect(Resolution.allCases.sorted() == [.dpi152, .dpi203, .dpi300, .dpi600])
    }
}
