# Nothing moves uninvited

The only thing Doctopus ever moves or rewrites on its own is a file it has just
brought in itself — a scan, or the copy an import makes — and it only moves one
when nobody chose a folder for it. Concretely:

- Files already in the library are never moved, renamed, optimized or deleted
  except by an explicit action, even when "imported" again by a drop, which
  just indexes them in place.
- Importing or scanning into a chosen folder (the folder's context menu, or
  with that folder selected) leaves the file there. Imports from outside the
  library are copied; the original is never touched. A folder dropped in or
  chosen to import brings in the PDFs and images inside it at any depth,
  flattened into the destination; the folder itself is left as it was.
- Routing is skipped below the confidence threshold, when two candidates are
  about equally good, and for any destination outside the library. The document
  waits in Needs Review with its candidates kept in `path_suggestions`.
- Doctopus only deletes an alias it made for a tag, and only if the file at
  that path is still an alias to that document. An alias you made by dragging
  onto a folder (a drag with ⌘ held moves the master rather than making one)
  goes when you delete it, or when it is the placement the document itself
  moves into.
- Move to Trash uses the Trash, never a hard delete, and keeps the index entry
  if trashing fails.
- Every file change made from the window — a move, a rename, filing, an alias,
  Move to Trash — is taken back by Edit › Undo (⌘Z), which reverses that change
  alone, not whatever was filed since.
- Deleting a row that is in the folder being viewed only as an alias deletes
  that alias and nothing else — the document it points at is elsewhere and is
  not what was deleted — and Undo writes the alias back.
- A document that is itself filed in another folder by hand does not reach the
  Trash either: it moves to the nearest of those folders, taking that alias's
  place. Undo puts both back, the document where it was and the alias it
  replaced.
- Tag mirrors in `Tags/` are never promoted this way — they are a view of the
  library, not a home — and neither is a placement outside the library root.
- A library whose `library.doctopus` was deleted is not recreated at launch.
