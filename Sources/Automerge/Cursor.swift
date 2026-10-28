import enum AutomergeUniffi.Position

typealias FfiPosition = AutomergeUniffi.Position

/// A opaque type that represents a stable location of the character following the location reference at creation within an array or text object that adjusts with insertions and deletions to
/// maintain its relative position.
///
/// Create a cursor using ``Document/cursor(obj:position:)``, or ``Document/cursor(obj:position:heads:)`` to place a
/// cursor at the point in time indicated by the `heads` parameter.
/// Retrieve the position of the cursor reference from the document using ``Document/position(obj:cursor:)``, or use
/// ``Document/position(obj:cursor:heads:)`` to get the position at a previous point in time.
///
/// INKHORN: to keep a cursor outside the document, store its ``bytes`` or its ``stringValue`` and
/// recreate it with ``init(bytes:)`` or ``init(string:)``. The string form is the one the Automerge
/// JavaScript API uses, so cursors can be shared between Swift and JavaScript peers.
public struct Cursor: Equatable, Hashable, Sendable {
    /// The cursor's serialized bytes.
    public let bytes: [UInt8]

    /// Creates a cursor from bytes that Automerge itself returned.
    init(validatedBytes: [UInt8]) {
        bytes = validatedBytes
    }

    /// INKHORN: creates a cursor from the bytes of a cursor you stored earlier.
    ///
    /// The bytes are validated in Swift before they ever reach the FFI, because the 0.7.2 FFI
    /// converts cursor bytes with `unwrap()` and would crash the process on invalid input.
    ///
    /// - Parameter bytes: The value of ``bytes`` from an existing cursor.
    /// - Throws: ``CursorFormatError`` if the bytes are not a valid cursor.
    public init(bytes: [UInt8]) throws {
        guard CursorEncoding.string(fromBytes: bytes) != nil else { throw CursorFormatError() }
        self.bytes = bytes
    }

    /// INKHORN: creates a cursor from its string form.
    ///
    /// - Parameter string: The value of ``stringValue`` from an existing cursor, or a cursor string
    ///   from the Automerge JavaScript API, such as `"8@726806b9f076b82bc022caae3027090d"`.
    /// - Throws: ``CursorFormatError`` if the string is not a valid cursor.
    public init(string: String) throws {
        guard let bytes = CursorEncoding.bytes(fromString: string) else { throw CursorFormatError() }
        self.bytes = bytes
    }

    /// INKHORN: the cursor's string form, identical to the cursor strings the Automerge
    /// JavaScript API uses.
    public var stringValue: String {
        // Bytes come from Automerge or were validated by `init(bytes:)`, so this always succeeds.
        CursorEncoding.string(fromBytes: bytes) ?? description
    }
}

extension Cursor: CustomStringConvertible {
    /// The bytes that describe the cursor.
    public var description: String {
        bytes.map { Swift.String(format: "%02hhx", $0) }.joined().uppercased()
    }
}

/// An umbrella type that represents a location within an array or text object.
///
/// ### See Also
/// - ``Document/cursor(obj:position:)``
/// - ``Document/cursor(obj:position:heads:)``
public enum Position {
    /// A stable location character or array position that follows that location regardless of Document changes.
    case cursor(Cursor)
    /// An absolute index position within an array or text object.
    case index(UInt64)
}

extension Position {
    func toFfi() -> FfiPosition {
        switch self {
        case let .cursor(cursor):
            return .cursor(position: cursor.bytes)
        case let .index(index):
            return .index(position: index)
        }
    }
}
