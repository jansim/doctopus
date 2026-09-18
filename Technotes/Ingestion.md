# Ingestion

## Getting documents in

**Drag and drop, or Import.** Files from outside the library are copied in;
the original is never touched. A dropped folder brings in the PDFs and images
inside it at any depth, flattened into the destination.

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

Rules are edited in Settings › Routing: what a rule looks at (text, filename,
correspondent or type), its pattern, destination template, tags and confidence,
and where it sits in the evaluation order. The editor shows how the pattern
will be read, how many documents already in the library it matches, and where a
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
