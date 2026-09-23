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
to. The drag cursor cannot carry that distinction: an operation the drag's
source never offered is refused outright, which would leave the drag nowhere to
land.

Dropping onto a tag, a Finder tag or a facet assigns it rather than filing
anything.

Dragging one document out of a selection carries the whole selection. In the
gallery the drag says so as it leaves: the page under the pointer carries
Finder's red count of how many documents are going along.

## Centre pane

A high-density list/table with SQLite-backed deep full-text search, token
filters and sort options.

### Review and assign

In Recent Processing and Needs Review the centre pane splits, and the selected
document is reviewed underneath the list.

On the left, everything that was worked out — title, fields, date, tags and tag
suggestions — is editable in place, or can be discarded in one go; the file is
untouched and Analyze can fill it in again.

The review colours every document by how it arrived — the same split as
[From outside, or from inside](Ingestion.md#from-outside-or-from-inside). Green
is *New*: imported or scanned, so Doctopus owns the copy and approving files it.
Blue is *Already in library*: the user's own file, which approving leaves where
and as it is. The colour marks the row in the list, the header of the review,
the chosen folder and the approve button.

On the right, every candidate folder — where it is now, the router's
suggestions with their confidence, where similar documents already live, any
other folder in the library, or a new one — has two controls: *Lives here* (one
folder; the file is moved there) and *Also here* (any number; filed as Finder
aliases). For a new document *Lives here* starts on its best suggestion, so
approving without touching it files it there; one imported or scanned into a
chosen folder has that folder as its best suggestion, so it stays. For a
document already in the library it starts on where the file is now, however
confident a suggestion is, so it only moves if someone picks another folder.
One button applies, approves and moves on to the next document (⌘↩).

Below what was worked out, a PDF shows its two versions side by side — the
original and an optimized copy — with a switch between them. Either can be
opened in Quick Look, and Compare opens both so the arrow keys flip between
them. A file that has not been optimized is tried on a throwaway copy to show
what optimizing would make of it; if it would not save enough, there is nothing
to switch to. A new document starts on *Optimized*, and approving keeps only
that; *Original* swaps the original back in. A document already in the library
starts on *Original*, and choosing *Optimized* optimizes it on approval with
its original kept on record so it can still be reverted.

Selecting several documents shows what approving them all would do, per kind:
new ones filed in their best suggestion and kept optimized, ones already in the
library left alone. Each kind's folder and version can be changed, and a mixed
selection can treat them each by its default, all like new, or all like files
already in the library. Before anything happens, each outcome — filed, staying,
optimized, original kept, left as it is — is counted in green and blue.

The same folder picker is available for any document as File In… in the
context menu; it only files, and never approves or rewrites the file.

## Inspector

Full document metadata: extracted dates, assigned tags, the generated summary,
optimization savings, alias mappings, raw text, all metadata.

## Keyboard

Full keyboard navigation with native Quick Look — Space on any file gives an
instant preview with text selection and pagination. Double-click, or ⌘↓, hands
the document to whichever app owns it, the way Finder does.

Holding ⌥ on its own lights up, in the sidebar, every folder the selected
documents are in — where each master file lives and every folder it is filed
in as an alias. A collapsed folder lights up for whatever it is hiding.
