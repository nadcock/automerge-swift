// INKHORN PATCH (not upstream). Public wrappers for block functions that exist in the 0.7.2 FFI
// binary but have no Swift API. Upstream equivalents are proposed in automerge/automerge-swift#249.

/// The error thrown when a block index does not fit the FFI's 32-bit index.
public struct BlockIndexOutOfRangeError: Error, Equatable {
    public init() {}
}

extension Document {
    /// INKHORN: inserts a block marker into a text object at `index` and returns the block's map object.
    ///
    /// Set the block's `type`, `parents`, `attrs`, and `isEmbed` on the returned map, matching the
    /// shape the Automerge JavaScript API uses.
    public func splitBlock(obj: ObjId, index: UInt64) throws -> ObjId {
        guard let index = UInt32(exactly: index) else { throw BlockIndexOutOfRangeError() }
        return try inkhornLockedFFI { try ObjId(bytes: $0.splitBlock(obj: obj.bytes, index: index)) }
    }

    /// INKHORN: removes the block marker at `index` from a text object.
    public func joinBlock(obj: ObjId, index: UInt64) throws {
        guard let index = UInt32(exactly: index) else { throw BlockIndexOutOfRangeError() }
        try inkhornLockedFFI { try $0.joinBlock(obj: obj.bytes, index: index) }
    }
}
