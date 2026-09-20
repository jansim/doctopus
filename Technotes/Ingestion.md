# Ingestion

## Getting documents in

**Drag and drop, or Import.** Files from outside the library are copied in, a
dropped folder is walked to any depth, and nothing outside is moved — see
[File safety](FileSafety.md) for the exact contract.

**Scan in place.** Right-clicking any folder in the tree and choosing Import
from iPhone/iPad › Scan Documents forces the scanned output to land in that
folder, bypassing auto-routing.

**Continuous scanning.** The same menu's *Continuously* submenu starts a run
that asks the device for the next document as soon as one lands, so a stack is
scanned without coming back to the Mac in between. Each round is one document,
which is what the router wants — a multi-page document is the device scanner's
own job and still arrives as a single PDF. The toolbar shows how many have come
in and stops the run with one click.

A run pauses rather than fails when it cannot go on — Doctopus stopped being
the frontmost app (a capture is handed to the key window, so there would be
nowhere to put one), nothing came back, a capture could not be read, or the
device left the room — and keeps its count and its destination, so Resume
(⌥⌘S) picks it up exactly where it was. A capture already in flight when the
run stops is still filed.

Continuity Camera cannot be checked without a real device in the room; see
[Testing](Testing.md) for `--scantest`.

## Routing

Unspecified imports and inbox scans are evaluated against a confidence
threshold. Every place that fits is kept as a suggestion; the file is only
moved when the best one clears the threshold *and* no other place fits about as
well — two equally good homes leave it in the Inbox, in Needs Review, until
someone picks. Routing never moves a file outside its library.

## Rules

A rule is one or more conditions and one or more actions, in the spirit of a
mail filter. A condition points at the text, the filename, the correspondent or
the document type, says how its pattern is read — any of these words, all of
them, an exact phrase, a regular expression, or roughly this for OCR noise —
and can be inverted, so "an invoice, but not a credit note" is one rule rather
than two that cannot say they belong together. The conditions are joined by
*any* or *all*. The actions are filing into a folder, adding tags, and setting
the correspondent or document type; each kind appears at most once, so what a
rule does is never ambiguous.

Rules live in Settings › Rules, per library, in the order they are evaluated.
The first matching rule with a folder decides where a document goes; tags and
metadata from *every* rule that matched are applied, so a rule that only labels
needs no destination at all. The editor shows how each pattern will be read,
how many documents already in the library the whole rule catches, and where a
document would land.

## OCR

PDFs are read through their embedded text layer first, which is nearly free;
only pages that come back empty are rasterized to grayscale at 200 DPI and sent
through Vision. A digital-origin archive is indexed without invoking OCR at
all. Per-document provenance (`pdf-layer` / `vision` / `mixed`) is shown in the
inspector.

Extracted text is stored in the index and used for deep full-text search.

## Optimization

Scans and image-heavy PDFs go through on-device raster optimization and
compression, in the spirit of PDFSqueezer or ImageOptim, without severely
degrading readability or stripping text layers.

A page is only ever rasterized if it has *no* text layer to lose; pages with
real text are re-drawn into the output PDF context, which copies their text and
vector operators through intact. If the result is not at least 15% smaller, the
original is kept byte-for-byte.

This is automatic only for files Doctopus brings in itself. Anything already in
the library is optimized only on request.

## Naming

Flexible string interpolation templates — `{date}_{correspondent}_{title}.{ext}`
— with fallback chains that resolve missing attributes deterministically. Dates,
for instance: OCR text date, then embedded PDF metadata, then EXIF for images,
then the file creation date.
