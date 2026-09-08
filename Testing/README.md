# Testing

`makefixtures.swift` generates a small demo library of realistic documents —
German and English invoices, a bank statement, a payslip, a tax assessment, a
lease — into `DemoLibrary/`. Two of them are deliberately rasterized with **no
text layer**, so they exercise the Vision OCR path rather than the PDF
text-layer fast path.

```bash
swift Testing/makefixtures.swift Testing/DemoLibrary
```

Then run the two check suites. The first scans, OCRs, analyzes, indexes and
queries without opening a window; the second hosts the real panes in an
off-screen window and drives them with synthetic events, which is the only way
hit testing and thumbnail rendering can be checked. Both exit non-zero on
failure, and both run in CI on every push.

```bash
Scripts/build.sh
build/Doctopus.app/Contents/MacOS/Doctopus --selftest Testing/DemoLibrary
build/Doctopus.app/Contents/MacOS/Doctopus --uitest Testing/DemoLibrary build/snapshots
```

Passing a directory to `--uitest` writes PNGs of the panes there, which is a
quick way to eyeball a layout change; CI keeps them as build artifacts.

Continuity Camera cannot be checked this way — it needs a real iPhone or iPad
in the room. `--scantest` reports which devices the system is offering, and
`--scantest fire` starts a capture and reports what comes back.

To try the demo library in the real app:

```bash
build/Doctopus.app/Contents/MacOS/Doctopus --add-root Testing/DemoLibrary && open build/Doctopus.app
```

`DemoLibrary/` is generated and git-ignored.
