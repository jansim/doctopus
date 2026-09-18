# Architecture

Doctopus is one SwiftPM executable target with no third-party dependencies.
The source is layered, and each layer only knows about the ones below it.

| Directory | What lives there |
| --- | --- |
| `Sources/Doctopus/Core` | The library format, the SQLite store, the models, search |
| `Sources/Doctopus/Ingest` | Scanning, OCR, optimization, routing, indexing, the file watcher |
| `Sources/Doctopus/Intel` | The two model backends and the deterministic analyzer behind them |
| `Sources/Doctopus/UI` | The SwiftUI panes |
| `Sources/Doctopus/App` | The entry point and `AppModel`, which is what the panes talk to |
| `Sources/Doctopus/Checks` | The headless check suites — see [Testing](Testing.md) |

## The file system is the source of truth

Documents live in ordinary, human-readable directories — `~/Docs/Finances/
Tax-2026/`. The tree stays traversable and legible in Finder with the app
closed, and pointing Doctopus at an existing directory indexes it in place:
no directory is restructured, no file is renamed. Renaming, single or batch,
is something you ask for from the context menu.

What Doctopus will and will not touch on its own is the subject of its own
note: [File safety](FileSafety.md).

PDFs are first-class; JPEG and PNG are supported alongside them.

## A library is a folder

Each indexed folder holds its own index, so a library is self-contained and
moves with the folder it describes. Several can be open at once and the centre
pane merges across them. See [Storage](Storage.md) for the container layout
and the schema.

## Store and AppModel

One `Store` actor owns each library's database connection, which is why there
is no locking anywhere else in the app. Paths are stored relative to the
library folder and translated to absolute `URL`s at the `Store` boundary.

`AppModel` is the main-actor coordinator between the panes and the background
actors. Views only ever read it; every mutation funnels through an action on
it, so there is exactly one place where "disk changed" becomes "UI changed".
It aggregates the open libraries — a `Library` never talks to the UI directly.

Both types are large enough to be split by subject rather than kept in one
file: `Store+Queries`, `AppModel+Import` and so on. See
[Coding guidelines](CodingGuidelines.md).

## Secondary placements are Finder aliases

Every document has exactly one physical master location. Membership in further
folders or tags can mirror to disk as native Finder aliases, configurable
globally or per tag, and the generated ones are registered in the index so
they can be pruned when a tag changes.

## Reacting to the disk

FSEvents drives a debounced reconcile. A file that disappears is marked missing
rather than deleted, so when it reappears elsewhere it is relinked by SHA-256
and keeps its tags, metadata and OCR text. Rows stay claimable for thirty days,
and a row whose file is sitting in the Trash is never forgotten at all.
