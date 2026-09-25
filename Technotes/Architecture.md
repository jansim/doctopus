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
so there is exactly one place where "disk changed" becomes "UI changed". There
is one per window, and a window shows at most one library, so every action acts
on that `Library` — a `Library` never talks to the UI directly.

`Workspace` is the one thing the windows share: the model backends, the
app-wide settings, and which window shows which library. It is what keeps a
library to a single window, and so to a single `Store`.

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
rather than deleted, so when it reappears elsewhere it is relinked and keeps its
tags, metadata and OCR text. The watcher and a full scan both match on the file
system's own ID for the file, so a file moved while Doctopus was closed, or
edited on the way, is still recognised. The watcher falls back to the SHA-256,
for volumes whose IDs do not persist and moves that got the file a new one.
Rows stay claimable for thirty days, and a row whose file is in the Trash is
never forgotten at all.

Not seeing a file is only evidence it is gone when the scan could look. A
folder the scan cannot read — no permission, a privacy prompt declined, a share
that dropped out — leaves the documents under it as they were, and a library
that suddenly lists as empty while its index does not is taken for unreadable
rather than emptied. Either is said, and nothing is forgotten until a scan has
seen the whole library.
