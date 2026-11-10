import Foundation
import Testing
import LabelWerkCore
@testable import LabelWerkStatus

@Suite("~HI – Host Identification")
struct HostIdentificationTests {

    @Test("ZD421 (Link-OS)")
    func parsesZD421() throws {
        let id = try HostIdentificationParser.parse(TestSupport.data(Fixtures.hostIdentificationZD421))
        #expect(id == HostIdentification(model: "ZD421-203dpi", firmware: "V84.20.18Z", dotsPerMM: 8, memoryKB: 8192))
        #expect(id.options.isEmpty)
        #expect(id.resolution == .dpi203)
        #expect(id.baseModel == "ZD421")
        #expect(id.optionCodes.isEmpty)
    }

    @Test("ZT410 mit Schneidwerksoption")
    func parsesOptions() throws {
        let id = try HostIdentificationParser.parse(TestSupport.data(Fixtures.hostIdentificationZT410Cutter))
        #expect(id.model == "ZT410-300dpi")
        #expect(id.firmware == "V75.19.15Z")
        #expect(id.dotsPerMM == 12)
        #expect(id.memoryKB == 8176)
        #expect(id.options == "C")
        #expect(id.optionCodes == ["C"])
        #expect(id.resolution == .dpi300)
        #expect(id.baseModel == "ZT410")
    }

    @Test("Ältere Firmware (105SL)")
    func parsesLegacy() throws {
        let id = try HostIdentificationParser.parse(TestSupport.data(Fixtures.hostIdentificationLegacy))
        #expect(id.model == "105SL-200DPI")
        #expect(id.firmware == "V60.13.0.14Z")
        #expect(id.resolution == .dpi203)
        #expect(id.baseModel == "105SL")
    }

    @Test("Mehrere Optionsfelder")
    func parsesMultipleOptions() throws {
        let id = try HostIdentificationParser.parse(TestSupport.data("\u{02}ZT610-600dpi,V75.20.01Z,24,8176KB,C,R\u{03}"))
        #expect(id.options == "C,R")
        #expect(id.optionCodes == ["C", "R"])
        #expect(id.resolution == .dpi600)
    }

    @Test("Mobildrucker und Speicher in MB")
    func parsesMobileAndMegabytes() throws {
        let id = try HostIdentificationParser.parse(TestSupport.data("\u{02}ZQ520,V76.20.05Z,8,256MB\u{03}\r\n"))
        #expect(id.model == "ZQ520")
        #expect(id.memoryKB == 262_144)
        #expect(id.baseModel == "ZQ520")
    }

    @Test("Ohne Rahmung, mit Leerraum")
    func parsesUnframed() throws {
        let id = try HostIdentificationParser.parse(TestSupport.data("  GK420d-203dpi , V61.17.17Z , 8 , 4096KB \r\n"))
        #expect(id == HostIdentification(model: "GK420d-203dpi", firmware: "V61.17.17Z", dotsPerMM: 8, memoryKB: 4096))
    }

    @Test("Fehlende Felder: Auflösung aus dem Modellnamen")
    func infersResolution() throws {
        let short = try HostIdentificationParser.parse(TestSupport.data("ZD620-300dpi,V84.20.18Z"))
        #expect(short.dotsPerMM == 12)
        #expect(short.memoryKB == 0)
        #expect(short.resolution == .dpi300)
        let unknown = try HostIdentificationParser.parse(TestSupport.data("GK420t,V61.17.17Z,,"))
        #expect(unknown.dotsPerMM == 0)
        #expect(unknown.resolution == nil)
    }

    @Test("Kommalose EPL-Kennung")
    func parsesEPLIdentification() throws {
        let id = try HostIdentificationParser.parse(TestSupport.data("UKQ1935HLU       V4.70.1A   \r\n"))
        #expect(id.model == "UKQ1935HLU")
        #expect(id.firmware == "V4.70.1A")
        #expect(id.dotsPerMM == 0)
        let lp = try HostIdentificationParser.parse(TestSupport.data("LP2844 4.29 512K"))
        #expect(lp.model == "LP2844")
        #expect(lp.firmware == "4.29")
        #expect(lp.memoryKB == 512)
    }

    @Test("Speicherangaben", arguments: [
        ("8192KB", Optional(8192)), ("512K", 512), ("4096", 4096), ("8MB", 8192), ("1GB", 1_048_576),
        ("2048 kb", 2048), ("1048576B", 1024), ("ABC", nil), ("", nil), ("12XB", nil),
    ])
    func memoryUnits(text: String, expected: Int?) {
        #expect(HostIdentificationParser.memoryKilobytes(text) == expected)
    }

    @Test("dpi im Modellnamen", arguments: [
        ("ZD421-203dpi", Optional(8)), ("ZT610-600DPI", 24), ("ZD621-300dpi", 12), ("105SL-200DPI", 8),
        ("P1112640-152dpi", 6), ("ZD421", nil), ("dpi", nil), ("ZX-999dpi", nil),
    ])
    func dpiFromModel(model: String, expected: Int?) {
        #expect(HostIdentificationParser.dotsPerMM(fromModel: model) == expected)
    }

    @Test("Fehlerfälle")
    func errors() {
        #expect(TestSupport.parseError { try HostIdentificationParser.parse(Data()) } == .emptyResponse)
        #expect(TestSupport.parseError { try HostIdentificationParser.parse(TestSupport.data("\u{02}\u{03}")) } == .emptyResponse)
        #expect(TestSupport.parseError { try HostIdentificationParser.parse(TestSupport.data("?")) }
                == .unrecognizedFormat("Keine ~HI-Kennung gefunden"))
        #expect(TestSupport.parseError { try HostIdentificationParser.parse(TestSupport.data(",V84.20.18Z,8")) }
                == .invalidField(name: "Modell", value: ",V84.20.18Z,8"))
        #expect(TestSupport.parseError { try HostIdentificationParser.parse(TestSupport.data("ZD421,V84,abc,8192KB")) }
                == .invalidField(name: "Punkte/mm", value: "abc"))
        #expect(TestSupport.parseError { try HostIdentificationParser.parse(TestSupport.data("ZD421,V84,999,8192KB")) }
                == .invalidField(name: "Punkte/mm", value: "999"))
    }

    @Test("Round Trip", arguments: [
        HostIdentification(model: "ZD421-203dpi", firmware: "V84.20.18Z", dotsPerMM: 8, memoryKB: 8192),
        HostIdentification(model: "ZT410-300dpi", firmware: "V75.19.15Z", dotsPerMM: 12, memoryKB: 8176, options: "C"),
        HostIdentification(model: "ZT610-600dpi", firmware: "V75.20.01Z", dotsPerMM: 24, memoryKB: 1, options: "C,R"),
    ])
    func roundTrip(id: HostIdentification) throws {
        #expect(try HostIdentificationParser.parse(id.responseData) == id)
    }

    @Test("Antwortformat")
    func responseFormat() {
        let id = HostIdentification(model: "ZD421-203dpi", firmware: "V84.20.18Z", dotsPerMM: 8, memoryKB: 8192)
        #expect(id.responseText == Fixtures.hostIdentificationZD421)
    }
}
