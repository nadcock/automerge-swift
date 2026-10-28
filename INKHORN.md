# Inkhorn fork of automerge-swift

This branch (`inkhorn`) is Inkhorn's fork of automerge-swift, based on the **0.7.2** release. It uses the official 0.7.2 release XCFramework (same URL and checksum as upstream), so it contains no Rust changes.

## What it adds

- `Document.splitBlock(obj:index:)` and `Document.joinBlock(obj:index:)`: wrappers over block functions already in the 0.7.2 FFI.
- `Cursor.bytes` (public), `Cursor(bytes:)`, `Cursor(string:)`, and `Cursor.stringValue`: persistable cursors, with the string form the Automerge JavaScript API uses. Bytes and strings are validated in Swift, because the 0.7.2 FFI unwraps cursor bytes and would crash on invalid input.
- Tests: `InkhornCursorEncodingTests` and `InkhornRegressionTests`.
- Cherry-picked from upstream `main`: cd2b9b7 (pins actors in `testMarkPatches`, which fails at random on 0.7.2).

All changes are marked `INKHORN` in the source.

## Releases

Tags are `0.7.2-inkhorn.N`. Inkhorn pins an exact tag.

## Upstream

The equivalent upstream work is automerge/automerge-swift#249 (blocks and spans), #250 (load with text encoding), plus cursor persistence. The fork is dropped once upstream releases equivalents.
