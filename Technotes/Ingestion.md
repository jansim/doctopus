# Ingestion

## From outside, or from inside

What Doctopus may do to a file depends on one thing: whether the file came from
outside the library or was already in it. What it does to the index — read it,
suggest metadata and folders, queue it for review — is the same either way.

| | From outside | Already inside |
| --- | --- | --- |
| Where it comes from | An import (drop, Import, a folder of files) or a scan | Put there in Finder, noticed by the watcher or a reindex, or dropped onto the app from within the library |
| The file | A new file in the library: a copy of an import, the capture itself for a scan | Stays exactly where it is |
| OCR, metadata, model pass | Yes | Yes |
| Suggested folders | Yes | Yes |
| Moved or renamed by the rules | Only when no folder was chosen | Never |
| Optimized | Yes | Only if chosen in the review |
| Needs Review | Yes | Yes |

**From outside.** Doctopus writes a new file into the library and owns it, so it
gets the whole treatment: optimized, read, given suggested folders and — unless
a folder was chosen (its context menu, or with it selected) — dropped in the
Inbox and routed (see [Routing](#routing)). A scan is the same pathway as an
import; the only difference is where the bytes start. An import is copied and
its original, outside the library, is never touched. A scan's capture has no
original: Doctopus writes it to a temporary file and moves that in. A file whose
contents are already in the library is skipped as a duplicate either way.

**Already inside.** A file that was already in the library folder is new to
the index but not to the disk, and it is still the user's. It is read, analyzed and, if a model is
configured, sent through it; it gets suggested folders and waits in Needs
Review. Its path is never changed: not by routing, not by a rule's rename, and
not by the review, which starts on the folder it is in. Optimization is a
switch in the review, left on the original until someone picks otherwise.

The very first pass over a newly opened library is the exception to Needs
Review: that is the existing archive rather than something that just arrived,
so it is indexed without queuing every document for a look.

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
Review with the suggestions on offer. An import or scan into a chosen folder
has that folder put first, so approving it as it stands keeps it there.

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

A rule written after the fact, or a file moved by hand, leaves documents the
rules would still change. These get a purple Rules badge, and the inspector
names the rule and its changes with Apply and Suppress. Suppressing marks the
document as an outlier: the rule stops pointing it out, Apply to Existing and
reprocessing skip it, and the inspector keeps it listed, muted, so it can be
undone. The Rules table counts each rule's outliers and lists them.

Such documents also wait in Needs Review, approved or not, with each pending
change ticked. Applying with some unticked applies the rest — the rule cut down
to those actions — and then suppresses the rule for that document, so what was
left is never pointed out again. Which documents a rule would still change is
worked out in memory, so the app hands the list to the Needs Review query.

Matching reads every document's text, so the store keeps each answer until the
text, filename, correspondent, type or a rule's conditions change. What a
match would change is compared against the index fresh on every pass.

Documents awaiting review are routed again when a rule changes, re-applying
its tags and metadata, and when a field or date is corrected by hand, so the
suggested folders follow — a misread year fixed in review moves the suggested
`Finances/Invoices/{year}` with it. A folder chosen when the document came in
stays first. Neither moves a file; filing is still the review's decision.

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
request: Optimize in the context menu, or the review's *Optimized* version,
which it never starts on for such a file.

## Naming

Flexible string interpolation templates — `{date}_{correspondent}_{title}.{ext}`
— with fallback chains that resolve missing attributes deterministically. Dates,
for instance: OCR text date, then embedded PDF metadata, then EXIF for images,
then the file creation date.
