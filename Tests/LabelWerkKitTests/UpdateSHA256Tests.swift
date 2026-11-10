import Foundation
import Testing
@testable import LabelWerkKit

/// SHA-256 in reinem Swift (Prüfung geladener Update-Pakete).
@Suite("Update-Dienst: SHA-256")
struct UpdateSHA256Tests {

    /// Testvektoren aus NIST FIPS 180-4 / CAVS („SHA-256 Examples“, SHA256ShortMsg).
    static let vectors: [(String, String)] = [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
         "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"),
    ]

    @Test("NIST-Testvektoren")
    func nistVectors() {
        for (message, expected) in Self.vectors {
            #expect(SHA256Hasher.hexDigest(Data(message.utf8)) == expected, "„\(message)“")
        }
        // CAVS SHA256ShortMsg: Len = 8, Msg = d3
        #expect(SHA256Hasher.hexDigest(Data([0xD3]))
                == "28969cdfa74a12c82f3bad960b0b000aca2ac329deea5c2328ebc6f2ba9802c1")
        // CAVS SHA256ShortMsg: Len = 16, Msg = 11af
        #expect(SHA256Hasher.hexDigest(Data([0x11, 0xAF]))
                == "5ca7133fa735326081558ac312c620eeca9970d1e70a4b95533d956f072d1f98")
        #expect(SHA256Hasher.digest(Data("abc".utf8)).count == SHA256Hasher.byteCount)
    }

    @Test("Eine Million „a“ (NIST), in ungleichen Stücken eingespeist")
    func millionA() {
        let expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        let all = Data(repeating: 0x61, count: 1_000_000)
        #expect(SHA256Hasher.hexDigest(all) == expected)
        var hasher = SHA256Hasher()
        var offset = 0
        var step = 1
        while offset < all.count {
            let end = min(all.count, offset + step)
            hasher.update(all[offset..<end])
            offset = end
            step = step % 997 + 13
        }
        #expect(hasher.hexDigest() == expected)
    }

    @Test("Blockgrenzen: Stückweise = am Stück für 0…200 Bytes")
    func blockBoundaries() {
        var bytes: [UInt8] = []
        for length in 0...200 {
            let data = Data(bytes)
            let whole = SHA256Hasher.hexDigest(data)
            for split in [0, 1, length / 2, max(0, length - 1), length] where split <= length {
                var hasher = SHA256Hasher()
                hasher.update(data.prefix(split))
                hasher.update(data.dropFirst(split))
                #expect(hasher.hexDigest() == whole, "Länge \(length), Teilung \(split)")
            }
            bytes.append(UInt8(truncatingIfNeeded: length &* 31 &+ 7))
        }
        // 55, 56 und 64 Bytes sind die heiklen Fälle der Auffüllung (Werte aus Pythons hashlib).
        #expect(SHA256Hasher.hexDigest(Data(repeating: 0x61, count: 55))
                == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        #expect(SHA256Hasher.hexDigest(Data(repeating: 0x61, count: 56))
                == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        #expect(SHA256Hasher.hexDigest(Data(repeating: 0x61, count: 64))
                == "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
    }

    @Test("Zwischenstand: finalize verändert den Hasher nicht")
    func finalizeIsNonDestructive() {
        var hasher = SHA256Hasher()
        hasher.update(Data("ab".utf8))
        _ = hasher.finalize()
        hasher.update(Data("c".utf8))
        #expect(hasher.hexDigest() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("Datei stückweise hashen")
    func fileDigest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lw-sha-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var data = Data(count: 3 * 65_536 + 17)
        for index in data.indices { data[index] = UInt8(truncatingIfNeeded: index &* 2_654_435_761 >> 7) }
        let file = directory.appendingPathComponent("paket.pkg")
        try data.write(to: file)
        #expect(try SHA256Hasher.hexDigest(ofFileAt: file, chunkSize: 4096) == SHA256Hasher.hexDigest(data))
        #expect(try SHA256Hasher.hexDigest(ofFileAt: file) == SHA256Hasher.hexDigest(data))
        let empty = directory.appendingPathComponent("leer.pkg")
        try Data().write(to: empty)
        #expect(try SHA256Hasher.hexDigest(ofFileAt: empty) == Self.vectors[0].1)
        #expect(throws: (any Error).self) {
            try SHA256Hasher.hexDigest(ofFileAt: directory.appendingPathComponent("fehlt.pkg"))
        }
    }
}
