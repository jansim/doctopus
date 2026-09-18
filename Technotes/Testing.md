# Testing

There is no XCTest bundle. The checks are two suites built into the app binary
and run from the command line against a generated demo library, which is what
lets them drive the real ingest pipeline and the real panes. Both exit non-zero
on failure, and both run in CI on every push. The code lives in
`Sources/Doctopus/Checks`.

## The demo library

`Testing/makefixtures.swift` generates a small library of realistic documents —
German and English invoices, a bank statement, a payslip, a tax assessment, a
lease. Two of them are deliberately rasterized with **no text layer**, so they
exercise the Vision OCR path rather than the PDF text-layer fast path.

```bash
swift Testing/makefixtures.swift Testing/DemoLibrary
```

`DemoLibrary/` is generated and git-ignored, as is any `library.doctopus`.

## Running the checks

```bash
Scripts/build.sh
build/Doctopus.app/Contents/MacOS/Doctopus --selftest Testing/DemoLibrary
build/Doctopus.app/Contents/MacOS/Doctopus --uitest Testing/DemoLibrary build/snapshots
```

`--selftest` scans, OCRs, analyzes, indexes and queries without opening a
window. `--uitest` hosts the real panes in an off-screen window and drives them
with synthetic events, which is the only way hit testing and thumbnail
rendering can be checked. The directory passed to `--uitest` gets PNGs of the
panes written into it, which is a quick way to eyeball a layout change; CI
keeps them as build artifacts.

Each suite copies the fixture library to a temporary folder first and creates
its `library.doctopus` index there, so `DemoLibrary/` itself is never written
to. The checks also write a Finder tag to one fixture and put it back
afterwards.

## Checking a model endpoint

Pointing `--selftest` at an API endpoint additionally runs a live enrichment
against it, which is the quickest way to verify a server before configuring it
in the app:

```bash
DOCTOPUS_LLM_ENDPOINT=http://localhost:1234/v1 DOCTOPUS_LLM_MODEL=qwen3-8b \
  build/Doctopus.app/Contents/MacOS/Doctopus --selftest Testing/DemoLibrary
```

Add `DOCTOPUS_LLM_VISION=1` to send each document's first page as an image too,
which is how a vision model is checked before it is configured in the app.

## Continuity Camera

Scanning needs a real iPhone or iPad in the room and cannot be checked from CI.

```bash
build/Doctopus.app/Contents/MacOS/Doctopus --scantest        # which devices the system is offering
build/Doctopus.app/Contents/MacOS/Doctopus --scantest fire   # start a capture, report what comes back
build/Doctopus.app/Contents/MacOS/Doctopus --scantest loop   # three rounds back to back, timed
```

`loop` is what continuous scanning rests on: whether a device honours a capture
asked for moments after it finished the last one, and how long `scanRearm` has
to wait first. The bookkeeping around those rounds — the counter, and which
interruptions a run resumes from by itself — is plain enough to check in
`--selftest`, and is.

## Other command-line modes

```bash
Doctopus --new-library <folder>   # create <folder>/library.doctopus without the UI
Doctopus --check <folder>         # report on an existing library's integrity
```

`--check` is the same verification the app runs behind Verify Library.
