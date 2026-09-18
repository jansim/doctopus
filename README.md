<div align="center">
  <img src="Resources/doctopus_detailed.png" width="250"/>
</div>

# doctopus

A native macOS document manager: point it at a folder and it OCRs, indexes,
tags and files what is inside — without moving anything you did not ask it to.

It takes the organizational ideas of Paperless-ngx and builds them on what
macOS already offers: Continuity Camera, Vision OCR, Finder aliases, SQLite,
and Apple's on-device Foundation models. Documents stay in ordinary folders
that Finder can read with the app closed, and each folder carries its own
index, so a library is self-contained and moves with it.

No third-party dependencies.

- **Scan** a stack of documents straight from an iPhone or iPad without
  coming back to the Mac in between.
- **Search** every word in the archive, including the text OCR found in scans.
- **File** by rules or by what a model read, with everything it proposed
  reviewable before it counts.
- **Never surprised** — nothing already in the library moves, is renamed or is
  deleted without an explicit action.

## Building

Requires Xcode 26, for the macOS 26 SDK. Runs on macOS 15 or later.

```bash
Scripts/build.sh && open build/Doctopus.app
```

The script compiles the SwiftPM executable, assembles `build/Doctopus.app`,
compiles `Resources/doctopus.icon` with `actool` — emitting both a layered
`Assets.car` for macOS 26 and a legacy `.icns` used on macOS 15 — and ad-hoc
signs the bundle.

## Checks

```bash
swift Testing/makefixtures.swift Testing/DemoLibrary
build/Doctopus.app/Contents/MacOS/Doctopus --selftest Testing/DemoLibrary
build/Doctopus.app/Contents/MacOS/Doctopus --uitest Testing/DemoLibrary build/snapshots
```

Two suites, built into the binary and run against a generated demo library:
`--selftest` drives the ingest pipeline headlessly, `--uitest` drives the real
panes in an off-screen window. Both run in CI on every push.
See [Testing](Technotes/Testing.md) for the rest, including the command-line
modes and how to check a model endpoint.

## Technotes

| | |
| --- | --- |
| [Architecture](Technotes/Architecture.md) | How the source is layered, and what a library is |
| [Storage](Technotes/Storage.md) | The `library.doctopus` container and the SQLite schema |
| [File safety](Technotes/FileSafety.md) | Exactly what Doctopus will and will not touch on its own |
| [Ingestion](Technotes/Ingestion.md) | Scanning, routing, OCR, optimization, naming |
| [Intelligence](Technotes/Intelligence.md) | The on-device and API model backends |
| [Interface](Technotes/Interface.md) | The three panes, review, keyboard |
| [Testing](Technotes/Testing.md) | The demo library and the two check suites |
| [Coding guidelines](Technotes/CodingGuidelines.md) | Conventions this codebase holds to |
