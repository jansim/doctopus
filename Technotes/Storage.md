# Storage

## The library container

Each indexed folder holds its index in a `library.doctopus` package inside it:

```
~/Docs/                     the folder you pointed Doctopus at
  library.doctopus/
    index.sqlite
    meta.json
    lock
    backups/
      index-2026-09-25T140512Z.sqlite
  Finances/
    Tax-2026/
      2026-01-14_finanzamt_bescheid.pdf
```

`meta.json` records the library format version and the app version that last
wrote it, and the index records its schema version. A library from a newer
Doctopus is refused with a reason if either is ahead, rather than opened and
written back missing whatever it did not know about. Each migration commits
together with its version, so an interrupted upgrade resumes where it stopped.
`meta.json` also holds the library's id, which is its identity: one that is
there but will not read is refused with a reason rather than replaced, and only
a library with no `meta.json` at all is given a new one.

## Backups

The documents survive the index, but nothing else does: tags beyond Finder
tags, fields, notes, correspondents, reviews and history exist only in
`index.sqlite`. So while a library is open its index is copied into
`backups/` once a day, through SQLite's backup API, as one consistent,
standalone file. The last seven are kept.

A copy is only taken of an index that passes `PRAGMA quick_check`. One that
fails is said, once, and no backup is taken, so damage never pushes the last
good copies out. Verify Library runs the same check.

View › Restore Index puts one back through the open connection, after first
copying the index as it is into `backups/before-restore-…`, which pruning
never touches. An index too damaged to open at all is offered its newest
backup when the library is opened; the damaged files are moved into
`backups/damaged-…`, never deleted. Either way no document is moved or
changed, and the scan that follows picks up files added since.

## One Mac at a time

`lock` keeps a library open in one Doctopus at a time: two writers on one
index — a second copy of the app, or a second Mac on a shared or synced folder
— interleave their writes and can corrupt it. The app `flock`s the file, which
is exact between processes on one Mac, and writes into it which Mac holds it,
renewed every minute, which is what reaches another Mac through Dropbox or
iCloud. Another Mac's record counts until it has gone five minutes unrenewed,
so a Mac that crashed or went to sleep gives the library up by itself.
Closing a library clears the record. The check suites and command-line modes
open the index without it.

A library in iCloud Drive, Dropbox, OneDrive, Google Drive or another File
Provider folder is warned about on opening and in Verify Library: a syncing
service can copy `index.sqlite` and its write-ahead log at different moments,
and another Mac can end up with a pair that never existed together.

Finder shows the package as a single Doctopus document that opens the library
on a double-click; Show Package Contents gets at the files.

## Where configuration lives

Configuration follows the same line as the documents: whatever describes the
folder travels with the folder.

| In the library | In `UserDefaults` |
| --- | --- |
| Tags, fields, routing rules, ingest settings | Model backend and endpoint, OCR concurrency, raster quality, view mode |

Keeping the second group out of the library is also what keeps an API key out
of a folder somebody might share.

Settings badges every section with its side of this split (`ScopeBadge`), and
the library side is always the front window's.

## The index

The system SQLite C API directly (`import SQLite3`), WAL, cached prepared
statements. FTS5 with `unicode61 remove_diacritics 2`.

| Table | What it holds |
| --- | --- |
| `documents` | File path, the file system's `file_id` for it (so a move is followed even when the bytes changed), file hash and the pre-optimization `original_hash` (so a re-import of the original still matches), primary directory, size, compression stats, approval status, `deleted_at` for a document in the Trash that can still be put back, `auto_name` for the name the naming template last gave the file, and `name_suppressed` for a name the template is to leave alone |
| `doc_fts` | FTS5 search table keyed by `rowid = documents.id`, one column per searchable surface — title, correspondent, type, tags, field values, notes, filename, body — with `bm25()` weights so a title hit outranks a body hit. Reading one document's text is a single indexed lookup |
| `metadata` | Document dates (as days, at the UTC start of them), language, amount, the one-sentence summary, and the entity ids for correspondent and type |
| `entities` | One row per correspondent or document type, with its icon, colour and an optional identifying pattern. Renaming is one `UPDATE`; renaming onto an existing name is a merge |
| `date_candidates` | Every date found in a document, not just the one that won, so the review can offer the runner-up as a chip |
| `notes` | One free-text note per document for what no field models — "cancelled by phone on the 4th" — indexed with the document's own text |
| `tags`, `document_tags` | Relational junction for multi-tag assignment. Tags nest up to five deep, and assigning a child attaches every ancestor |
| `tag_suggestions` | Model-proposed tags awaiting acceptance or dismissal, kept apart from `document_tags` so they never count toward a tag's sidebar total |
| `path_suggestions` | Every folder the router considered for a new document, best first — what the review offers, and all there is to go on when it moved nothing |
| `events`, `processing` | `events` is the append-only record of what happened to a document, never trimmed, and the inspector's History — where it came from (scanned, imported from a path, or already in the library at one), what the pipeline did to it, and what somebody changed by hand afterwards. Hand edits made less than five minutes apart, with nothing else logged in between, fold into one `edited` row, one line of `detail` per change. `processing` is the bounded recency view the review reads, holding only which event is on show and whether it has been signed off; a hand edit never enters it |
| `finder_tags` | Index of the Finder's own tags, which live on the files themselves |
| `value_icons` | Per-value icons for the fields whose values are still strings; a correspondent or type keeps its icon on its own row, where a rename cannot orphan it |
| `aliases` | Registry of the Finder aliases a document is filed under in other folders, so unfiling, promotion and Undo act on exactly those and nothing else |
