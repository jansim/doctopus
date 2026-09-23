# Interface

A native AppKit/SwiftUI three-pane layout.

## Sidebar

The physical directory tree, the Recent Processing queue — recently filed items
with their confidence badges, the rules or models that were applied, and an
Approved / Needs Review toggle — and Paperless-ngx-style smart views: Tags,
Correspondents, Languages, Document Types. With more than one library open, folders and tags
are grouped under the library that owns them; the smart views span all of them.

### Drag and drop

Dragging documents onto a folder files them there as well, as Finder aliases,
leaving each master where it is. Holding ⌘ moves the master file into the
folder instead, the way ⌘ turns a Finder drag between volumes into a move.

The keys are read while the drag is still in the air rather than once it has
landed: by then they have come up with the mouse button. For as long as a drag
is over a folder, that folder's document count gives way to what letting go
would do — *File Here* or *Move Here* — so ⌘ is visible before it is committed
to. The cursor follows suit: a plain drag carries the copy badge, a ⌘ drag the
plain arrow of a move.

Dropping onto a tag, a Finder tag or a facet assigns it rather than filing
anything.

Dragging documents out of Doctopus hands over the files themselves, so a drop
on Finder, Mail or Preview gets the document; ⌘C copies them the same way, and
Share in the context menu offers the system's share targets.

Dragging one document out of a selection carries the whole selection. In the
gallery the drag says so as it leaves: the page under the pointer carries
Finder's red count of how many documents are going along.

## Centre pane

A high-density list/table with SQLite-backed deep full-text search, token
filters and sort options.

### Review and assign

In Recent Processing and Needs Review the centre pane splits, and the selected
document is reviewed underneath the list.

A document a rule would still change shows that rule's changes in purple above
the rest, each with a checkbox: Apply does the ticked ones — and suppresses the
rule for the document if any were left unticked — and Suppress does none.

On the left, everything that was worked out — title, fields, date, tags and tag
suggestions — is editable in place, or can be discarded in one go; the file is
untouched and Analyze can fill it in again.

Documents are coloured by [how they arrived](Ingestion.md#from-outside-or-from-inside):
green for *New* (imported or scanned), blue for *Already in library*.

On the right, every candidate folder — where it is now, the router's
suggestions with their confidence, where similar documents already live, any
other folder in the library, or a new one — has two controls: *Lives here* (one
folder; the file is moved there) and *Also here* (any number; filed as Finder
aliases). *Lives here* starts on a new document's best suggestion (a chosen
import folder counts as one), and on where the file is now for anything already
in the library. One button applies, approves and moves on (⌘↩).

A PDF's original and optimized versions sit side by side behind a switch, each
openable in Quick Look, with Compare to flip between them; an unoptimized file
is previewed on a throwaway copy. New documents start on *Optimized* and keep
only that; documents already in the library start as they are, and keep their
original on record if optimized.

With several selected, each kind gets its own folder and version choice, a
mixed selection can be treated each by its default, all like new or all like
already in the library, and the outcome is counted in green and blue first.

The same folder picker is available for any document as File In… in the
context menu; it only files, never approves or rewrites.

## Inspector

Full document metadata: extracted dates, assigned tags, the generated summary,
optimization savings, alias mappings, raw text, all metadata.

## Keyboard

Full keyboard navigation with native Quick Look — Space on any file gives an
instant preview with text selection and pagination. Double-click, or ⌘↓, hands
the document to whichever app owns it, the way Finder does.

The sidebar and inspector are shown and hidden from the View menu (⌃⌘S,
⌃⌘I), and the inspector stays as it was left. Libraries appear in File › Open
Recent and in the Dock icon's menu.

Holding ⌥ on its own lights up, in the sidebar, every folder the selected
documents are in — where each master file lives and every folder it is filed
in as an alias. A collapsed folder lights up for whatever it is hiding.
