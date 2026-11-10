import Foundation
import Testing
@testable import LabelWerkStatus

/// Fehlerhafte, abgeschnittene und zufällige Eingaben dürfen nie zum Absturz führen.
/// Werfende Parser müssen ausschließlich `StatusParseError` werfen.
@Suite("Robustheit")
struct RobustnessTests {

    static let fixtures: [String] = [
        Fixtures.hostStatusReady, Fixtures.hostStatusAllFlags, Fixtures.hostStatusPrinting,
        Fixtures.hostStatusMobile, Fixtures.hostQueryGuide, Fixtures.hostQueryClean,
        Fixtures.hostIdentificationZD421, Fixtures.hostIdentificationZT410Cutter,
        Fixtures.configurationZD421, Fixtures.configurationLegacy, Fixtures.directoryFlash,
        Fixtures.directoryGuideRAM, Fixtures.directorySGD, Fixtures.allConfigJSON, Fixtures.allCV,
    ]

    /// Ruft alle Parser auf; meldet einen fremden Fehlertyp als Testfehler.
    static func exerciseAllParsers(_ data: Data) {
        func check<T>(_ name: String, _ body: () throws -> T) {
            do {
                _ = try body()
            } catch is StatusParseError {
                // erwartet
            } catch {
                Issue.record("\(name) warf fremden Fehler: \(error)")
            }
        }
        check("~HS") { try HostStatusParser.parse(data) }
        check("~HQES") { try HostQueryParser.parse(data) }
        check("~HI") { try HostIdentificationParser.parse(data) }
        check("JSON") { try SGDResponseParser.parseJSON(data) }
        _ = SGDResponseParser.parseValue(data)
        let text = String(decoding: data, as: UTF8.self)
        _ = SGDResponseParser.parseAllCV(text)
        _ = ConfigurationLabelParser.parse(text)
        _ = ConfigurationLabelParser.parse(data: data)
        _ = FileDirectoryParser.parseListing(text)
        _ = FileDirectoryParser.parse(data: data)
        _ = StatusInterpreter.meters(fromOdometer: text)
        _ = StatusInterpreter.integer(fromSGD: text)
        _ = StatusInterpreter.celsius(fromSGD: text)
        _ = HostIdentificationParser.memoryKilobytes(text)
    }

    @Test("Zufällige Bytes")
    func randomBytes() {
        var rng = SplitMix64(seed: 0x5EED_1234)
        for _ in 0..<1500 {
            let length = Int(rng.next() % 200)
            let bytes = (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            Self.exerciseAllParsers(Data(bytes))
        }
    }

    @Test("Zufällige Zeichen aus dem Antwortalphabet")
    func randomProtocolCharacters() {
        let alphabet = Array("0123456789ABCDEFabcdef,.:;-+*\"{}[] \t\r\n\u{02}\u{03}\0?ERRORSWARNINGSDIRbytesfreeKBdpi")
        var rng = SplitMix64(seed: 42)
        for _ in 0..<1500 {
            let length = Int(rng.next() % 160)
            let text = String((0..<length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
            Self.exerciseAllParsers(Data(text.utf8))
        }
    }

    @Test("Jede Kürzung jeder Testantwort")
    func everyTruncation() {
        for fixture in Self.fixtures {
            let bytes = Array(fixture.utf8)
            for length in 0...bytes.count {
                Self.exerciseAllParsers(Data(bytes[0..<length]))
            }
        }
    }

    @Test("Zufällige Bytefehler in Testantworten")
    func randomMutations() {
        var rng = SplitMix64(seed: 7)
        for fixture in Self.fixtures {
            let original = Array(fixture.utf8)
            for _ in 0..<150 {
                var bytes = original
                let mutations = 1 + Int(rng.next() % 4)
                for _ in 0..<mutations where !bytes.isEmpty {
                    let index = Int(rng.next() % UInt64(bytes.count))
                    switch rng.next() % 3 {
                    case 0: bytes[index] = UInt8(truncatingIfNeeded: rng.next())
                    case 1: bytes.remove(at: index)
                    default: bytes.insert(UInt8(truncatingIfNeeded: rng.next()), at: index)
                    }
                }
                Self.exerciseAllParsers(Data(bytes))
            }
        }
    }

    @Test("Große Eingaben werden zügig verarbeitet")
    func largeInputs() throws {
        let repeatedConfig = String(repeating: Fixtures.configurationZD421, count: 300)
        let start = Date()
        #expect(ConfigurationLabelParser.parse(repeatedConfig).count == 31 * 300)
        let files = (0..<5_000).map { "*E:FILE\($0).GRF \($0)\r\n" }.joined()
        #expect(FileDirectoryParser.parse(files).count == 5_000)
        let json = "{" + (0..<5_000).map { "\"a.k\($0)\":\"\($0)\"" }.joined(separator: ",") + "}"
        #expect(try SGDResponseParser.parseJSON(TestSupport.data(json)).count == 5_000)
        Self.exerciseAllParsers(Data(repeating: 0x2C, count: 200_000))  // nur Kommas
        Self.exerciseAllParsers(Data(repeating: 0x7B, count: 50_000))   // nur „{“
        #expect(Date().timeIntervalSince(start) < 30)
    }

    @Test("Extreme Zahlenwerte werfen statt überzulaufen")
    func extremeNumbers() {
        let huge = String(repeating: "9", count: 400)
        Self.exerciseAllParsers(Data("\(huge),\(huge),\(huge)\r\n\(huge),0,0,0\r\n".utf8))
        #expect(StatusInterpreter.integer(fromSGD: huge) == nil)
        #expect(StatusInterpreter.meters(fromOdometer: "\(huge) INCHES") == nil)  // unendlich → verworfen
        #expect(HostIdentificationParser.memoryKilobytes("\(huge)KB") == nil)
        #expect(StatusText.integer("-9223372036854775808") == nil)
        #expect(StatusText.hex("FFFFFFFFFFFFFFFFF") == nil)
        #expect(StatusText.decimal("1e400") == nil)
    }
}
