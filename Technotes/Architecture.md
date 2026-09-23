# Architecture

One SwiftPM executable target, no third-party dependencies, layered so that
each directory only knows about the ones below it.

| Directory | What lives there |
| --- | --- |
| `Sources/Doctopus/Core` | The library format, the SQLite store, the models, search, naming |
| `Sources/Doctopus/Intel` | The two model backends and the local classifier |
| `Sources/Doctopus/Ingest` | Scanning, OCR, the deterministic analyzer, optimization, routing, indexing, the file watcher |
| `Sources/Doctopus/UI` | The SwiftUI panes |
| `Sources/Doctopus/App` | The entry point and `AppModel`, which is what the panes talk to |
| `Sources/Doctopus/Checks` | The headless check suites — see [Testing](Testing.md) |

## Store and AppModel

One `Store` actor owns each library's database connection, which is why there
is no locking anywhere else in the app. Paths are stored relative to the library
folder and translated to absolute `URL`s at the `Store` boundary, so nothing
above `Store` deals in relative paths and nothing below it in absolute ones.

`AppModel` is the main-actor coordinator between the panes and the background
actors. Views only ever read it; every mutation funnels through an action on it,
so there is exactly one place where "disk changed" becomes "UI changed". It
aggregates the open libraries — a `Library` never talks to the UI directly.

`Store` only reads and writes the index and its own container. Moving,
renaming or restoring a document's file is the `Indexer`'s, and every such
move goes through one place there, which updates the row, prunes the folder
left behind, logs the event and keeps the tag aliases in step.

Both types are split by subject rather than kept in one file: `Store+Queries`,
`AppModel+Import`, and so on.

## Documents on disk

Documents live in ordinary directories — `~/Docs/Finances/Tax-2026/` — and
indexing an existing one restructures nothing and renames nothing. Renaming,
single or batch, is something you ask for. The full contract is
[File safety](FileSafety.md); [Storage](Storage.md) has the library layout.

Every document has exactly one physical master location. Membership in further
folders or tags can mirror to disk as native Finder aliases, configurable
globally or per tag, and the generated ones are registered in the index so they
can be pruned when a tag changes.

PDFs are first-class; JPEG and PNG are supported alongside them.

## Reacting to the disk

FSEvents drives a debounced reconcile. A file that disappears is marked missing
rather than deleted, so when it reappears elsewhere it is relinked by SHA-256
and keeps its tags, metadata and OCR text. Rows stay claimable for thirty days,
and a row whose file is in the Trash is never forgotten at all.
