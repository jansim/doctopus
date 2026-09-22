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

**What a capture is taken as.** A device offers the same capture in several
forms and lists them in its own order, so the form is chosen by this app's
preference — PDF first — rather than by whichever the device happened to name
first. Every raster form of a multi-page document scan is one page, so taking
the wrong one silently throws the rest away. A capture that arrives as a
multi-image container (a multi-page TIFF, a HEIC sequence) becomes a PDF with
one page per image, never its first image alone. A capture handed over as a
file rather than as bytes is read from that file while it still exists, since
it goes when the pasteboard does.

**Nothing arrives silently short.** A capture that cannot be read is gone — the
pasteboard it came on is discarded moments later, and nothing asks the device
again — so every capture a delivery offered is accounted for against the
documents that reach the library. A shortfall is an alert on a one-off scan,
and pauses a continuous run with `Incomplete` in the toolbar rather than
carrying on into a gap. Each delivery also leaves a record of what was offered,
what was taken and how many pages it held:

```bash
log show --last 1h --predicate 'subsystem == "io.doctopus"'
```

Continuity Camera cannot be checked without a real device in the room; see
[Testing](Testing.md) for `--scantest`. The decoding either side of it —
which form is taken, and how many pages it yields — is checked in `--selftest`.

## Routing

Unspecified imports and inbox scans are routed by the rules first. A rule that
matches is certain, so the file moves to its folder — unless matching rules
name different folders, in which case it stays in the Inbox, in Needs Review,
with every folder on offer until someone picks. When no rule has a folder, a
path derived from the correspondent is used if it clears the confidence
threshold. Routing never moves a file outside its library.

While a document waits in Needs Review, its suggestions are worked out again
whenever a rule, the derived template or one of its own fields changes. That
only ever rewrites `path_suggestions`: the file stays where routing left it.

## Rules

A rule is one or more conditions and one or more actions, in the spirit of a
mail filter. A condition points at the text, the filename, the correspondent or
the document type, says how its pattern is read — any of these words, all of
them, an exact phrase, a regular expression, or roughly this for OCR noise —
and can be inverted, so "an invoice, but not a credit note" is one rule rather
than two. The conditions are joined by *any* or *all*.

Words match whole. A `*` widens one: `rechnung*` also catches
"Rechnungsnummer", `*rechnung` catches "Gehaltsabrechnung", `*rechnung*` both.
Correspondents and types that carry their own pattern are read the same way.

The actions are moving the file, renaming it from a naming template, adding
tags, and setting the correspondent or document type; each kind appears at
most once per rule. Every matching rule applies: tags are combined, and for
the single-valued actions the rule highest in the list wins. Moving and
renaming only ever happen to a file Doctopus has just brought in, or when
Apply to Existing is pressed in the editor.

Rules live in Settings › Rules, per library. The editor shows how many
documents already in the library a rule catches, and where a document would
land and what it would be called.

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
