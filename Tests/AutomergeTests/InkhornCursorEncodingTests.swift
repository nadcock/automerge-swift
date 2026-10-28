@testable import Automerge
import Foundation
import XCTest

/// INKHORN: cursor persistence and the JavaScript string form, checked against the 0.7.2 FFI binary.
final class InkhornCursorEncodingTests: XCTestCase {
    // A fixed actor, so expected strings and bytes are stable.
    let actorHex = "726806b9f076b82bc022caae3027090d"

    func makeDocument(_ value: String = "Hello world") throws -> (Document, ObjId) {
        let doc = Document(textEncoding: .utf16)
        doc.actor = try XCTUnwrap(ActorId(data: XCTUnwrap(Data(hexString: actorHex))))
        let text = try doc.putObject(obj: ObjId.ROOT, key: "text", ty: ObjType.Text)
        try doc.spliceText(obj: text, start: 0, delete: 0, value: value)
        return (doc, text)
    }

    func testFFIBytesAndStringMatchKnownVectors() throws {
        let (doc, text) = try makeDocument()
        let cursor = try doc.cursor(obj: text, position: 6)
        // Bytes observed from the 0.7.2 binary, and the string Automerge JS 3.5.0 returns for the
        // same actor, document, and position (Phase 1 probe).
        XCTAssertEqual(cursor.description, "010310726806B9F076B82BC022CAAE3027090D0802")
        XCTAssertEqual(cursor.stringValue, "8@\(actorHex)")
    }

    func testStringRoundTripMatchesFFIBytes() throws {
        let (doc, text) = try makeDocument()
        let cursor = try doc.cursor(obj: text, position: 6)
        XCTAssertEqual(try Cursor(string: cursor.stringValue).bytes, cursor.bytes)
        XCTAssertEqual(try Cursor(bytes: cursor.bytes), cursor)
    }

    func testMultiByteCounterRoundTrips() throws {
        // Counters above 127 need more than one LEB128 byte.
        let (doc, text) = try makeDocument(String(repeating: "a", count: 20000))
        for position: UInt64 in [0, 125, 126, 127, 200, 16381, 16382, 19999] {
            let cursor = try doc.cursor(obj: text, position: position)
            let restored = try Cursor(string: cursor.stringValue)
            XCTAssertEqual(restored.bytes, cursor.bytes, "position \(position)")
            XCTAssertEqual(try doc.position(obj: text, cursor: restored), position)
        }
    }

    func testJavaScriptStringResolvesInSwift() throws {
        let (doc, text) = try makeDocument()
        let cursor = try Cursor(string: "8@\(actorHex)")
        XCTAssertEqual(try doc.position(obj: text, cursor: cursor), 6)
        try doc.spliceText(obj: text, start: 0, delete: 0, value: ">> ")
        XCTAssertEqual(try doc.position(obj: text, cursor: cursor), 9)
    }

    func testMoveBeforeCursorStringResolves() throws {
        let (doc, text) = try makeDocument()
        let before = try Cursor(string: "-8@\(actorHex)")
        XCTAssertEqual(before.bytes.last, 1)
        XCTAssertEqual(before.stringValue, "-8@\(actorHex)")
        XCTAssertEqual(try doc.position(obj: text, cursor: before), 6)
    }

    func testUppercaseActorParsesToCanonicalLowercase() throws {
        let cursor = try Cursor(string: "8@\(actorHex.uppercased())")
        XCTAssertEqual(cursor.stringValue, "8@\(actorHex)")
    }

    func testEndCursor() throws {
        let (doc, text) = try makeDocument()
        let end = try doc.cursor(obj: text, position: doc.length(obj: text))
        XCTAssertEqual(end.bytes, [1, 2])
        XCTAssertEqual(end.stringValue, "e")
        XCTAssertEqual(try Cursor(string: "e"), end)
    }

    func testStartCursorResolvesToZero() throws {
        let (doc, text) = try makeDocument()
        let start = try Cursor(string: "s")
        XCTAssertEqual(start.bytes, [1, 1])
        XCTAssertEqual(try doc.position(obj: text, cursor: start), 0)
    }

    func testVersionZeroBytesAreReadable() throws {
        let (doc, text) = try makeDocument()
        let actor = try XCTUnwrap(Data(hexString: actorHex))
        let legacy = try Cursor(bytes: [0, UInt8(actor.count)] + [UInt8](actor) + [8])
        XCTAssertEqual(legacy.stringValue, "8@\(actorHex)")
        XCTAssertEqual(try doc.position(obj: text, cursor: legacy), 6)
    }

    func testCursorSurvivesSaveAndLoadThroughString() throws {
        let (doc, text) = try makeDocument()
        let stored = try doc.cursor(obj: text, position: 6).stringValue
        let loaded = Document(textEncoding: .utf16)
        try loaded.merge(other: Document(doc.save()))
        guard case let .Object(loadedText, .Text) = try loaded.get(obj: .ROOT, key: "text") else {
            return XCTFail("missing text")
        }
        XCTAssertEqual(try loaded.position(obj: loadedText, cursor: Cursor(string: stored)), 6)
    }

    func testInvalidBytesThrowBeforeReachingTheFFI() {
        let actor = [UInt8](repeating: 0xAB, count: 16)
        let invalid: [[UInt8]] = [
            [],
            [1],
            [2, 1],
            [1, 9],
            [1, 1, 0], // trailing byte
            [1, 3, 16] + actor, // missing counter and move
            [1, 3, 16] + actor + [8], // missing move
            [1, 3, 16] + actor + [8, 3], // bad move tag
            [1, 3, 17] + actor + [8, 2], // length longer than the data
            [1, 3, 16] + actor + [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 2], // counter overflow
        ]
        for bytes in invalid {
            XCTAssertThrowsError(try Cursor(bytes: bytes), "\(bytes)")
        }
    }

    func testInvalidStringsThrow() {
        let invalid = [
            "", "x", "-", "8", "8@", "@\(actorHex)", "-@\(actorHex)", "+8@\(actorHex)", "8@zz", "8@abc",
            "é8@\(actorHex)", "8.0@\(actorHex)", "--8@\(actorHex)", "18446744073709551616@\(actorHex)",
        ]
        for string in invalid {
            XCTAssertThrowsError(try Cursor(string: string), string)
        }
    }

    func testRandomPositionsRoundTrip() throws {
        var generator = SystemRandomNumberGenerator()
        let (doc, text) = try makeDocument(String(repeating: "word ", count: 2000))
        let length = doc.length(obj: text)
        for _ in 0 ..< 200 {
            let position = UInt64.random(in: 0 ... length, using: &generator)
            let cursor = try doc.cursor(obj: text, position: position)
            XCTAssertEqual(try Cursor(string: cursor.stringValue).bytes, cursor.bytes)
            XCTAssertEqual(try Cursor(bytes: cursor.bytes).stringValue, cursor.stringValue)
        }
    }
}

private extension Data {
    init?(hexString: String) {
        var bytes = [UInt8]()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
