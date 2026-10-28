import Automerge
import Foundation
import Testing

// INKHORN regression suite: the Inkhorn Spike 1 behavior tests (blocks, marks, cursors, fork and
// merge, history, save and load), kept so the fork notices any behavior change on rebase.

private func makeTextDoc(_ initial: String = "", encoding: TextEncoding = .utf16) throws -> (Document, ObjId) {
    let doc = Document(textEncoding: encoding)
    let text = try doc.putObject(obj: .ROOT, key: "text", ty: .Text)
    if !initial.isEmpty {
        try doc.spliceText(obj: text, start: 0, delete: 0, value: initial)
    }
    return (doc, text)
}

private func textId(_ doc: Document) throws -> ObjId {
    guard case let .Object(id, .Text) = try doc.get(obj: .ROOT, key: "text") else {
        throw InkhornTestError.missingText
    }
    return id
}

enum InkhornTestError: Error { case missingText, unexpected(String) }

@Suite("Inkhorn 1a Marks")
struct InkhornMarkTests {
    @Test("Formatting marks expand at the end, links do not")
    func expansion() throws {
        let (doc, text) = try makeTextDoc("Hello world")
        try doc.mark(obj: text, start: 0, end: 5, expand: .after, name: "bold", value: .Boolean(true))
        try doc.mark(obj: text, start: 6, end: 11, expand: .none, name: "link", value: .String("https://example.com"))
        // Type at the end of each marked range.
        try doc.spliceText(obj: text, start: 5, delete: 0, value: "X")   // "HelloX world"
        try doc.spliceText(obj: text, start: 12, delete: 0, value: "Y")  // "HelloX worldY"
        let marks = try doc.marks(obj: text)
        let bold = try #require(marks.first { $0.name == "bold" })
        let link = try #require(marks.first { $0.name == "link" })
        #expect(bold.start == 0 && bold.end == 6)
        #expect(link.start == 7 && link.end == 12)
    }

    @Test("Overlapping marks and mark removal with null")
    func overlapAndRemove() throws {
        let (doc, text) = try makeTextDoc("abcdefghij")
        try doc.mark(obj: text, start: 0, end: 6, expand: .after, name: "bold", value: .Boolean(true))
        try doc.mark(obj: text, start: 3, end: 9, expand: .after, name: "italic", value: .Boolean(true))
        try doc.mark(obj: text, start: 2, end: 4, expand: .after, name: "bold", value: .Null)
        let marks = try doc.marks(obj: text).filter { $0.name == "bold" }.map { ($0.start, $0.end) }
        #expect(marks.count == 2)
        #expect(marks.contains { $0 == (0, 2) } && marks.contains { $0 == (4, 6) })
        let atFive = try doc.marksAt(obj: text, position: .index(5)).map(\.name).sorted()
        #expect(atFive == ["bold", "italic"])
    }

    @Test("Object-valued marks are not supported; JSON-string values are")
    func structuredMarkValues() throws {
        let (doc, text) = try makeTextDoc("see chapter")
        // Marks take ScalarValue only. Structured values (link {url}, footnote {footnoteId}) must be encoded.
        try doc.mark(obj: text, start: 4, end: 11, expand: .none, name: "internalLink",
                     value: .String(#"{"nodeId":"0192f0c0-0000-7000-8000-000000000001"}"#))
        let mark = try #require(try doc.marks(obj: text).first)
        guard case let .String(json) = mark.value else { throw InkhornTestError.unexpected("value") }
        #expect(json.contains("nodeId"))
    }
}

@Suite("Inkhorn 1b Blocks")
struct InkhornBlockTests {
    /// The public Swift API has no splitBlock. Insert a map object into the text sequence instead,
    /// using the same shape automerge JS uses for block markers: { type, parents, attrs }.
    static func insertBlock(_ doc: Document, _ text: ObjId, at index: UInt64, type: String,
                            parents: [String] = [], attrs: [String: ScalarValue] = [:]) throws -> ObjId {
        // insertObject(.Map) into Text throws WrongObjectType in 0.7.2; splitBlock comes from the Inkhorn patch.
        let block = try doc.splitBlock(obj: text, index: index)
        try doc.put(obj: block, key: "type", value: .String(type))
        let parentList = try doc.putObject(obj: block, key: "parents", ty: .List)
        // Matches the JS block shape { type, parents, attrs, isEmbed }; verified against JS in Spike 4.
        try doc.put(obj: block, key: "isEmbed", value: .Boolean(false))
        for (i, parent) in parents.enumerated() {
            try doc.insert(obj: parentList, index: UInt64(i), value: .String(parent))
        }
        let attrMap = try doc.putObject(obj: block, key: "attrs", ty: .Map)
        for (key, value) in attrs {
            try doc.put(obj: attrMap, key: key, value: value)
        }
        return block
    }

    @Test("Block markers via splitBlock, read via values()")
    func insertAndRead() throws {
        let (doc, text) = try makeTextDoc()
        _ = try Self.insertBlock(doc, text, at: 0, type: "heading1")
        try doc.spliceText(obj: text, start: 1, delete: 0, value: "Chapter One")
        _ = try Self.insertBlock(doc, text, at: 12, type: "paragraph")
        try doc.spliceText(obj: text, start: 13, delete: 0, value: "It was dark.")
        let rendered = try doc.text(obj: text)
        #expect(doc.length(obj: text) == 25)
        // get(obj: text, index:) throws WrongObjectType for text objects; values(obj:) exposes block objects.
        #expect(throws: (any Error).self) { try doc.get(obj: text, index: 0) }
        let first = try doc.values(obj: text).first
        guard case let .Object(blockId, .Map) = first else {
            throw InkhornTestError.unexpected("block at 0 was \(String(describing: first))")
        }
        #expect(try doc.get(obj: blockId, key: "type") == .Scalar(.String("heading1")))
        let scalars = rendered.unicodeScalars.map { $0.value }
    }

    @Test("Blocks survive save and load, and are visible in historical views")
    func blocksPersist() throws {
        let (doc, text) = try makeTextDoc()
        _ = try Self.insertBlock(doc, text, at: 0, type: "paragraph")
        try doc.spliceText(obj: text, start: 1, delete: 0, value: "One")
        let before = doc.heads()
        _ = try Self.insertBlock(doc, text, at: 4, type: "sceneBreak")
        let loaded = try Document(doc.save())
        let loadedText = try textId(loaded)
        #expect(loaded.length(obj: loadedText) == 5)
        #expect(loaded.lengthAt(obj: loadedText, heads: before) == 4)
    }

    @Test("Concurrent block type changes converge")
    func concurrentBlockUpdate() throws {
        let (doc, text) = try makeTextDoc()
        let block = try Self.insertBlock(doc, text, at: 0, type: "paragraph")
        try doc.spliceText(obj: text, start: 1, delete: 0, value: "Title")
        let other = doc.fork()
        try doc.put(obj: block, key: "type", value: .String("heading1"))
        try other.put(obj: block, key: "type", value: .String("heading2"))
        try doc.merge(other: other)
        try other.merge(other: doc)
        #expect(try doc.get(obj: block, key: "type") == other.get(obj: block, key: "type"))
    }
}

@Suite("Inkhorn 1c Cursors")
struct InkhornCursorTests {
    @Test("Cursor survives concurrent inserts and deletes before it")
    func survivesRemoteEdits() throws {
        let (doc, text) = try makeTextDoc("The quick brown fox")
        let cursor = try doc.cursor(obj: text, position: 10) // before "brown"
        let remote = doc.fork()
        try remote.spliceText(obj: text, start: 0, delete: 4, value: "A very ")  // "A very quick brown fox"
        try doc.merge(other: remote)
        let pos = try doc.position(obj: text, cursor: cursor)
        let current = try doc.text(obj: text)
        #expect(current.dropFirst(Int(pos)).hasPrefix("brown"))
    }

    @Test("Cursor round trips through its string encoding and works on a loaded copy")
    func cursorEncoding() throws {
        let (doc, text) = try makeTextDoc("abcdef")
        let cursor = try doc.cursor(obj: text, position: 3)
                let stored = cursor.bytes
        let loaded = try Document(doc.save())
        let decoded = try Cursor(bytes: stored)
        let loadedText = try textId(loaded)
        #expect(try loaded.position(obj: loadedText, cursor: decoded) == 3)
    }

    @Test("Cursor whose character was deleted resolves to a neighboring position")
    func deletedTarget() throws {
        let (doc, text) = try makeTextDoc("abcdef")
        let cursor = try doc.cursor(obj: text, position: 3)
        try doc.spliceText(obj: text, start: 2, delete: 3, value: nil) // "abf"
        let pos = try doc.position(obj: text, cursor: cursor)
        #expect(pos <= 3)
    }
}

@Suite("Inkhorn 1d Fork and merge")
struct InkhornForkMergeTests {
    @Test("Concurrent edits on forks merge without loss")
    func concurrentEdits() throws {
        let (doc, text) = try makeTextDoc("Middle")
        let a = doc.fork()
        let b = doc.fork()
        try a.spliceText(obj: text, start: 0, delete: 0, value: "Start ")
        try a.mark(obj: text, start: 0, end: 5, expand: .after, name: "bold", value: .Boolean(true))
        try b.spliceText(obj: text, start: 6, delete: 0, value: " End")
        try a.merge(other: b)
        try b.merge(other: a)
        #expect(try a.text(obj: text) == "Start Middle End")
        #expect(a.heads() == b.heads())
        #expect(try a.marks(obj: text) == b.marks(obj: text))
    }

    @Test("forkAt(heads) produces a historical branch (suggestion fork base)")
    func forkAtHeads() throws {
        let (doc, text) = try makeTextDoc("v1")
        let v1 = doc.heads()
        try doc.spliceText(obj: text, start: 2, delete: 0, value: " v2")
        let fork = try doc.forkAt(heads: v1)
        #expect(try fork.text(obj: text) == "v1")
        try fork.spliceText(obj: text, start: 0, delete: 0, value: "suggested ")
        try doc.merge(other: fork)
        #expect(try doc.text(obj: text) == "suggested v1 v2")
    }

    @Test("mergeWithPatches reports text and mark patches for incremental UI updates")
    func patches() throws {
        let (doc, text) = try makeTextDoc("Hello")
        let remote = doc.fork()
        try remote.spliceText(obj: text, start: 5, delete: 0, value: " there")
        try remote.mark(obj: text, start: 0, end: 5, expand: .after, name: "italic", value: .Boolean(true))
        let patches = try doc.mergeWithPatches(other: remote)
        let kinds = patches.map { patch -> String in
            switch patch.action {
            case .SpliceText: "splice"
            case .Marks: "marks"
            default: "other"
            }
        }
        #expect(kinds.contains("splice"))
        #expect(kinds.contains("marks"))
    }
}

@Suite("Inkhorn 1e History and heads")
struct InkhornHistoryTests {
    @Test("Heads, history, change metadata, and time travel reads")
    func timeTravel() throws {
        let (doc, text) = try makeTextDoc()
        try doc.spliceText(obj: text, start: 0, delete: 0, value: "First draft.")
        doc.commitWith(message: "session 1", timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let h1 = doc.heads()
        try doc.mark(obj: text, start: 0, end: 5, expand: .after, name: "bold", value: .Boolean(true))
        try doc.spliceText(obj: text, start: 0, delete: 12, value: "Second draft.")
        doc.commitWith(message: "session 2")
        #expect(try doc.textAt(obj: text, heads: h1) == "First draft.")
        #expect(try doc.marksAt(obj: text, heads: h1).isEmpty)
        let history = doc.getHistory()
        #expect(history.count >= 2)
        let h1Hash = try #require(h1.first)
        let first = try #require(doc.change(hash: h1Hash))
        #expect(first.message == "session 1")
        #expect(first.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        let diff = doc.difference(from: h1, to: doc.heads())
        #expect(!diff.isEmpty)
    }

    @Test("Restore by writing historical content as a new change")
    func restore() throws {
        let (doc, text) = try makeTextDoc("Original text")
        doc.commitWith(message: "v1")
        let h1 = doc.heads()
        try doc.spliceText(obj: text, start: 0, delete: 8, value: "Changed")
        doc.commitWith(message: "v2")
        let old = try doc.textAt(obj: text, heads: h1)
        try doc.updateText(obj: text, value: old)
        doc.commitWith(message: "restore v1")
        #expect(try doc.text(obj: text) == "Original text")
        #expect(doc.getHistory().count >= 3) // history is kept
    }
}

@Suite("Inkhorn 1f Save, load, incremental")
struct InkhornPersistenceTests {
    @Test("save then incremental change appends load as one document")
    func incremental() throws {
        let (doc, text) = try makeTextDoc("Base")
        var file = doc.save()
        _ = doc.encodeNewChanges()
        try doc.spliceText(obj: text, start: 4, delete: 0, value: " plus more")
        file.append(doc.encodeNewChanges())
        try doc.spliceText(obj: text, start: 0, delete: 0, value: ">> ")
        file.append(doc.encodeNewChanges())
        let loaded = try Document(file)
        #expect(try loaded.text(obj: try textId(loaded)) == ">> Base plus more")
        #expect(loaded.heads() == doc.heads())
    }

    /// Inkhorn's store frames and checksums appended chunks because of this behavior (versioning.md 2.2).
    @Test("Truncated trailing chunk makes load throw")
    func truncatedTail() throws {
        let (doc, text) = try makeTextDoc("Base")
        var file = doc.save()
        _ = doc.encodeNewChanges()
        try doc.spliceText(obj: text, start: 4, delete: 0, value: " tail")
        let chunk = doc.encodeNewChanges()
        file.append(chunk.prefix(chunk.count / 2))
        #expect(throws: (any Error).self) { try Document(file) }
    }

    @Test("Loaded documents use which text encoding?")
    func loadedEncoding() throws {
        let (doc, text) = try makeTextDoc("é🇬🇧x", encoding: .utf16)
        #expect(doc.length(obj: text) == 6) // utf16: é=1, flag=4, x=1
        let loaded = try Document(doc.save())
        // 0.7.2 gap (Inkhorn works around it below): loading forgets the UTF-16 encoding.
        #expect(loaded.textEncoding == .unicodeScalar)
        let loadedLength = loaded.length(obj: try textId(loaded))
        #expect(loadedLength == 4) // Unicode scalars: é, two regional indicators, x
        // Workaround A: apply saved bytes into a fresh utf16 document.
        let freshA = Document(textEncoding: .utf16)
        try freshA.applyEncodedChanges(encoded: doc.save())
        // Workaround B: merge the loaded document into a fresh utf16 document.
        let freshB = Document(textEncoding: .utf16)
        try freshB.merge(other: loaded)
        let lengthB = freshB.length(obj: try textId(freshB))
        #expect(freshB.textEncoding == .utf16)
        #expect(lengthB == 6)
        #expect(freshB.heads() == doc.heads())
    }
}
