# Coding guidelines

What this codebase already does, written down so it keeps doing it.
[Architecture](Architecture.md) explains the design these rules protect;
this note is only the rules.

## Priorities

1. **No data loss.** The documents are the user's, they predate Doctopus, and
   they have to survive it. [File safety](FileSafety.md) is not a list of
   preferences.
2. **No crashes.**
3. Then performance, then everything else.

## Dependencies

None. Not "few" — none. SQLite is the system C API, PDFs are PDFKit, OCR is
Vision, the models are `FoundationModels` and one hand-rolled HTTP request.
Adding a package is a decision to argue for, not a convenience.

## Files

A file has one subject and its name says what that is. When a type outgrows one
file it is split by subject into extensions — `Store+Queries`, `AppModel+Import`
— never into `Foo2` or `FooMore`. Past ~500 lines, look for the seam.

Swift keeps stored properties in the class body, so a type split this way keeps
its state in the main file, labelled with the extension that drives each group.

Layer directories only depend downward — `Core`, then `Intel`, then `Ingest`,
then `App` and `UI`. The one exception is a typed-in date field, which `Core`
reads with the analyzer's date reader. Nothing in the app depends on `Checks`.

## Concurrency

Every rule here follows from one decision, that each library's database
connection belongs to a single `Store` actor: no locks anywhere else, no shared
mutable state between libraries, and `AppModel` as the only bridge to the UI.
Don't add a second path from a pane to a `Store`.

## Comments

Say why, not what. The code already says what it does; a comment earns its place
by recording a reason — the constant that needed a real device to pick, the
ladder step a local endpoint would not answer. Commentary that restates the line
below it gets deleted. A doc comment on a type says what it owns, and what it
must not touch.

## Checks

A change to the ingest pipeline comes with a `--selftest` assertion; a change to
a pane that can be driven headlessly comes with a `--uitest` one. Both suites
must stay green — they are the whole test story, so a skipped check is a gap
with nothing behind it.
