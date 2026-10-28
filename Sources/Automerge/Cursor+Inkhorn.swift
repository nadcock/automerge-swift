// INKHORN PATCH (not upstream). Converts cursors between Automerge's byte form, which the 0.7.2 FFI
// uses, and the string form, which the Automerge JavaScript API uses. Implemented in Swift so the
// fork can keep the official 0.7.2 release binary. The formats follow automerge 0.7.2
// `rust/automerge/src/cursor.rs` (`to_bytes`, `TryFrom<&[u8]>`, `Display`, `from_str`).
//
// Bytes, version 1:  0x01, then 0x01 (start) | 0x02 (end) |
//                    0x03, uleb128 actor length, actor bytes, uleb128 counter, 0x01 (move before) | 0x02 (move after)
// Bytes, version 0:  0x00, uleb128 actor length, actor bytes, uleb128 counter (always "move after")
// Strings:           "s" | "e" | ["-"] counter "@" lowercase hex actor   ("-" means move before)
//
// This parser is deliberately stricter than Rust's: it rejects trailing bytes, a "+" sign or other
// non-digits in the counter, and an empty actor. Automerge never produces any of these.

/// The error thrown when cursor bytes or a cursor string are not a valid Automerge cursor.
public struct CursorFormatError: Error, Equatable {
    public init() {}
}

enum CursorEncoding {
    private static let version1: UInt8 = 1
    private static let startTag: UInt8 = 1
    private static let endTag: UInt8 = 2
    private static let opTag: UInt8 = 3
    private static let moveBefore: UInt8 = 1
    private static let moveAfter: UInt8 = 2

    /// Returns the string form of cursor bytes, or nil if the bytes are not a valid cursor.
    static func string(fromBytes bytes: [UInt8]) -> String? {
        var reader = ByteReader(bytes)
        guard let version = reader.byte() else { return nil }
        switch version {
        case 0: return versionZeroString(&reader)
        case version1: return versionOneString(&reader)
        default: return nil
        }
    }

    /// Version 0: actor length, actor, counter; always "move after".
    private static func versionZeroString(_ reader: inout ByteReader) -> String? {
        guard let length = reader.uleb128(), let actor = reader.bytes(count: length),
              let counter = reader.uleb128(), reader.isAtEnd
        else { return nil }
        return opString(counter: counter, actor: actor, before: false)
    }

    /// Version 1: a start, end, or op tag; op cursors carry actor, counter, and move.
    private static func versionOneString(_ reader: inout ByteReader) -> String? {
        guard let tag = reader.byte() else { return nil }
        switch tag {
        case startTag: return reader.isAtEnd ? "s" : nil
        case endTag: return reader.isAtEnd ? "e" : nil
        case opTag:
            guard let length = reader.uleb128(), let actor = reader.bytes(count: length),
                  let counter = reader.uleb128(), let move = reader.byte(), reader.isAtEnd,
                  move == moveBefore || move == moveAfter
            else { return nil }
            return opString(counter: counter, actor: actor, before: move == moveBefore)
        default: return nil
        }
    }

    /// Returns version 1 cursor bytes for a cursor string, or nil if the string is not a valid cursor.
    static func bytes(fromString string: String) -> [UInt8]? {
        if string == "s" {
            return [version1, startTag]
        }
        if string == "e" {
            return [version1, endTag]
        }
        var rest = Substring(string)
        let before = rest.hasPrefix("-")
        if before {
            rest = rest.dropFirst()
        }
        guard let separator = rest.firstIndex(of: "@") else { return nil }
        let counterText = rest[..<separator]
        let actorText = rest[rest.index(after: separator)...]
        guard !counterText.isEmpty, counterText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let counter = UInt64(counterText), let actor = hexBytes(actorText), !actor.isEmpty
        else { return nil }
        var bytes: [UInt8] = [version1, opTag]
        appendULEB128(UInt64(actor.count), to: &bytes)
        bytes.append(contentsOf: actor)
        appendULEB128(counter, to: &bytes)
        bytes.append(before ? moveBefore : moveAfter)
        return bytes
    }

    private static func opString(counter: UInt64, actor: [UInt8], before: Bool) -> String {
        let hex = actor.map { Swift.String(format: "%02x", $0) }.joined()
        return "\(before ? "-" : "")\(counter)@\(hex)"
    }

    /// Decodes hex like Rust's `hex::decode`: even length, upper or lower case digits.
    private static func hexBytes(_ text: Substring) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = hexValue(digits[index]), let low = hexValue(digits[index + 1]) else { return nil }
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }

    private static func hexValue(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): return digit - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): return digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): return digit - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func appendULEB128(_ value: UInt64, to bytes: inout [UInt8]) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while remaining != 0
    }
}

private struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool {
        offset == bytes.count
    }

    mutating func byte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func bytes(count: UInt64) -> [UInt8]? {
        guard count <= UInt64(bytes.count - offset) else { return nil }
        let end = offset + Int(count)
        defer { offset = end }
        return Array(bytes[offset ..< end])
    }

    /// Reads an unsigned LEB128 value of at most 10 bytes that fits in 64 bits.
    mutating func uleb128() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while let byte = byte() {
            let payload = UInt64(byte & 0x7F)
            if shift == 63, payload > 1 {
                return nil
            }
            result |= payload << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift > 63 {
                return nil
            }
        }
        return nil
    }
}
