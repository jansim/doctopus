# Testing

`makefixtures.swift` generates a small demo library of realistic documents —
German and English invoices, a bank statement, a payslip, a tax assessment, a
lease — into `DemoLibrary/`. Two of them are deliberately rasterized with **no
text layer**, so they exercise the Vision OCR path rather than the PDF
text-layer fast path.

```bash
swift Testing/makefixtures.swift Testing/DemoLibrary
```

Then run the headless pipeline check, which scans, OCRs, analyzes, indexes and
queries without opening a window:

```bash
Scripts/build.sh && build/Doctopus.app/Contents/MacOS/Doctopus --selftest Testing/DemoLibrary
```

To try the demo library in the real app:

```bash
build/Doctopus.app/Contents/MacOS/Doctopus --add-root Testing/DemoLibrary && open build/Doctopus.app
```

`DemoLibrary/` is generated and git-ignored.
