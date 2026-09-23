# Ingestion

## Three ways in

How a document reached the library decides what Doctopus may do to the file.
What it may do to the index — read it, suggest metadata and folders, queue it
for review — is the same for all three.

| | Imported from outside | Found inside the library | Scanned |
| --- | --- | --- | --- |
| The file | Copied in; the original is never touched | Stays exactly where it is | Written into the library |
| OCR, metadata, model pass | Yes | Yes | Yes |
| Suggested folders | Yes | Yes | Yes |
| Moved to a suggested folder | Only when no folder was chosen | Never | Only when no folder was chosen |
| Renamed by a rule | Only when no folder was chosen | Never | Only when no folder was chosen |
| Optimized | Yes, the copy | Only if ticked in the review | Yes |
| Needs Review | Yes | Yes | Yes |

**Imported from outside.** A file dropped in or chosen with Import that lives
outside the library is copied in, and only the copy is ever worked on. With a
folder chosen — its context menu, or with it selected — the copy stays there;
otherwise it lands in the Inbox and is routed (see [Routing](#routing)). Either
way it is given suggested folders.

**Found inside the library.** A file that is already somewhere in the library
folder — put there in Finder, noticed by the watcher or a reindex, or dropped
onto the app from within the library — is new to the index but not new to the
disk. It is read, analyzed and, if a model is configured, sent through it; it
gets suggested folders and waits in Needs Review. Its path is never changed:
not by routing, not by a rule's rename, and not by the review, which starts on
the folder it is in. Optimization is a checkbox in the review, off until ticked.

The very first pass over a newly opened library is the exception to Needs
Review: that is the existing archive rather than something that just arrived,
so it is indexed without queuing every document for a look.

**Scanned.** A capture from an iPhone or iPad has no original anywhere else, so
it gets the whole treatment: optimized, read, given suggested folders and — if
it was not scanned into a chosen folder — routed.

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

Every new document — imported, scanned or found in place — is run past the
rules and the derived path, and whatever folders they propose are kept as its
suggestions in `path_suggestions`, best first. Only an unspecified import or
inbox scan is then moved; everything else stays where it is and waits in Needs
Review with the suggestions on offer.

Unspecified imports and inbox scans are routed by the rules first. A rule that
matches is certain, so the file moves to its folder — unless matching rules
name different folders, in which case it stays in the Inbox, in Needs Review,
with every folder on offer until someone picks. When no rule has a folder, a
path derived from the correspondent is used if it clears the confidence
threshold. Routing never moves a file outside its library.

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
the single-valued actions the rule highest in the list wins. Tags,
correspondent and type are applied to every new document. Moving and renaming
only ever happen to a file Doctopus has just brought in without a chosen
folder, or when Apply to Existing is pressed in the editor; for anything else a
rule's folder is only a suggestion.

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

This is automatic only for files Doctopus brings in itself — the copy an
import makes, and a scan. Anything already in the library is optimized only on
request: Optimize in the context menu, or *Optimize when approving* in the
review, which is never ticked by default.

## Naming

Flexible string interpolation templates — `{date}_{correspondent}_{title}.{ext}`
— with fallback chains that resolve missing attributes deterministically. Dates,
for instance: OCR text date, then embedded PDF metadata, then EXIF for images,
then the file creation date.
