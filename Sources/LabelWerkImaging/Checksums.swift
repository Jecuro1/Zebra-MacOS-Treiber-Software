import CZlib
import Foundation

/// CRC-16-Prüfsummen.
public enum CRC16 {
    /// CRC-16/XMODEM: Polynom 0x1021, Startwert 0, keine Reflexion, kein End-XOR.
    ///
    /// Wird von Zebra für die Prüfsumme hinter `:Z64:`/`:B64:`-Daten verwendet (berechnet über
    /// die Base64-Zeichen). Prüfwert: `"123456789"` → `0x31C3`.
    public static func xmodem<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        // Schneller Pfad für zusammenhängenden Speicher ([UInt8], Data, String.UTF8View …).
        if let fast = bytes.withContiguousStorageIfAvailable({ update(0, $0) }) {
            return fast
        }
        var crc: UInt16 = 0
        let table = xmodemTable
        for byte in bytes {
            crc = (crc << 8) ^ table[Int(UInt8(truncatingIfNeeded: crc >> 8) ^ byte)]
        }
        return crc
    }

    /// Setzt eine laufende CRC-Berechnung mit weiteren Bytes fort.
    static func update(_ start: UInt16, _ buffer: UnsafeBufferPointer<UInt8>) -> UInt16 {
        var crc = start
        xmodemTable.withUnsafeBufferPointer { table in
            for byte in buffer {
                crc = (crc << 8) ^ table[Int(UInt8(truncatingIfNeeded: crc >> 8) ^ byte)]
            }
        }
        return crc
    }

    /// Tabelle für die byteweise Berechnung (MSB zuerst).
    static let xmodemTable: [UInt16] = (0..<256).map { index -> UInt16 in
        var crc = UInt16(index) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
        return crc
    }

    /// Formatiert eine CRC als vier Großbuchstaben-Hexziffern (z. B. `31C3`).
    static func hex4(_ value: UInt16) -> String {
        let digits: [UInt8] = Array("0123456789ABCDEF".utf8)
        let chars = [
            digits[Int(value >> 12) & 0xF], digits[Int(value >> 8) & 0xF],
            digits[Int(value >> 4) & 0xF], digits[Int(value) & 0xF],
        ]
        return String(decoding: chars, as: UTF8.self)
    }
}

/// CRC-32 (ISO-HDLC, wie PNG und zlib) – intern über zlib berechnet.
enum CRC32 {
    static func checksum(_ bytes: UnsafeBufferPointer<UInt8>, start: UInt32 = 0) -> UInt32 {
        var crc = uLong(start)
        var offset = 0
        // zlib verarbeitet uInt-Längen; große Puffer stückweise.
        while offset < bytes.count {
            let chunk = min(bytes.count - offset, 1 << 30)
            crc = crc32(crc, bytes.baseAddress! + offset, uInt(chunk))
            offset += chunk
        }
        return UInt32(truncatingIfNeeded: crc)
    }

    static func checksum(_ bytes: [UInt8], start: UInt32 = 0) -> UInt32 {
        bytes.withUnsafeBufferPointer { checksum($0, start: start) }
    }
}

/// Adler-32 (zlib-Prüfsumme) – intern über zlib berechnet.
enum Adler32 {
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { buf -> UInt32 in
            var value = adler32(0, nil, 0)
            var offset = 0
            while offset < buf.count {
                let chunk = min(buf.count - offset, 1 << 30)
                value = adler32(value, buf.baseAddress! + offset, uInt(chunk))
                offset += chunk
            }
            return UInt32(truncatingIfNeeded: value)
        }
    }
}
