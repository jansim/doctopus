# Coding guidelines

What this codebase already does, written down so it keeps doing it.

## Priorities

1. **No data loss.** The documents are the user's, they predate Doctopus, and
   they have to survive it. See [File safety](FileSafety.md): the rules there
   are not preferences.
2. **No crashes.**
3. Then performance, then everything else.

## Dependencies

None. Not "few" — none. SQLite is the system C API, PDF work is PDFKit, OCR is
Vision, the models are `FoundationModels` and one hand-rolled HTTP request.
Adding a package is a decision to be argued for, not a convenience.

## Files

A file has one subject and its name says what that is. When a type outgrows one
file it is split by subject into extensions — `Store+Queries`, `Store+Fields`,
`AppModel+Import` — never into `Foo2` or `FooMore`. Roughly: past ~500 lines,
look for the seam.

Swift keeps stored properties in the class body, so a type split this way keeps
its state in the main file, grouped and labelled with the extension that drives
each group.

Layer directories only depend downward: `UI` and `App` may use `Core`, `Ingest`
and `Intel`; `Core` uses nothing above it. `Checks` is not app code and nothing
in the app depends on it.

## Concurrency

One `Store` actor owns each library's database connection, which is why there
is no locking anywhere else. `AppModel` is `@MainActor` and is the only bridge
between the panes and the background actors: views read it, and every mutation
goes through an action on it, so there is exactly one place where "disk
changed" becomes "UI changed". A `Library` never talks to the UI directly.

## Comments

Say why, not what. The code already says what it does; a comment earns its
place by recording the reason a thing is the way it is — the constant that
needed a real device to pick, the ladder step a local endpoint would not
answer, the case that made a `private(set)` worth keeping. Commentary that
restates the line below it gets deleted.

Doc comments on a type say what it owns and what it must not do.

## Paths and the disk

Paths are stored relative to the library folder and translated to absolute
`URL`s at the `Store` boundary. Nothing above `Store` deals in relative paths,
and nothing below it deals in absolute ones.

Anything that writes to disk states in its doc comment what it may touch.

## Checks

A change to the ingest pipeline comes with a `--selftest` assertion; a change
to a pane that can be driven headlessly comes with a `--uitest` one. Both suites
must stay green — they are the whole test story, so a skipped check is a gap
with nothing behind it.
