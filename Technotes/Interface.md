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

On the right, every candidate folder — where it is now, the router's
suggestions with their confidence, where similar documents already live, any
other folder in the library, or a new one — has two controls: *Lives here* (one
folder; the file is moved there) and *Also here* (any number; filed as Finder
aliases). *Lives here* always starts on where the file is now, however
confident a suggestion is, so approving without touching it moves nothing. A
file that was not optimized on the way in offers *Optimize when approving*,
unticked. One button applies, approves and moves on to the next document (⌘↩).

The same picker is available for any document as File In… in the context menu.

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
