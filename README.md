<div align="center">
  <img src="Resources/doctopus_detailed.png" width="250"/>
</div>

# doctopus

## Goal

A high-performance, native macOS document management utility inspired by the organizational strengths of tools such as Paperless-ngx, while making the most of the available macOS APIs. The application prioritizes the native file system as the canonical source of truth while leveraging the Continuity scanning feature, Apple Vision OCR, local SQLite indexing, Finder alias linking, and Apple's on-device Foundation models.

## Design

### Architecte
- File-System First: Documents live in standard, human-readable directories (e.g., ~/Docs/Finances/Tax-2026/). The file tree remains fully traversable and legible in Finder without the application running.
- Formats: Native support for PDFs (first-class), alongside JPEG and PNG image assets.
- In-Place Indexing: Pointing the application at an existing directory processes, runs OCR, and indexes files entirely in place. Zero non-consensual directory mutation or file renaming occurs. Single and batch renaming can be triggered on demand via the context menu (e.g. rename file).
- Secondary Folder Presence (Finder Aliases): While every document has exactly one physical master location on disk, membership in additional folders/tags can optionally mirror to disk by automatically generating native macOS Finder Aliases (.alias / bookmark resolution), configurable globally or per-tag.

### Ingestion
- Scan-in-Place (Context Menu): Right-clicking any folder in the app’s tree and choosing Import from iPhone/iPad > Scan Documents forces the scanned output to land directly in that specific folder, bypassing auto-routing.
- Auto-Routing Engine: Unspecified imports and inbox scans evaluate against a confidence threshold to automatically route into appropriate folders on disk:
  - Recent Processing Queue: A dedicated UI section displays recently filed items with confidence badges, applied rules/models, and an "Approved / Needs Review" status toggle.
- Optimization: Scans and image-heavy PDFs undergo on-device raster optimization and compression without (severely) degrading readability or stripping text layers. (think PDFSqueezer, ImageOptim, ...)

### Metadata & Search
- Text Processing Pipeline: Apple Vision framework extracts text representations from PDFs and raster images. This all gets stored in a SQLite DB (see Storage) and indexed for deep full-text search.
- LLM enrichment, from either the Apple on-device model or any OpenAI-compatible API endpoint (LM Studio, Ollama, llama.cpp, vLLM, a hosted API). Both answer the same questions and are interchangeable; enrichment can also be turned off entirely. Summary: Generates a 1–2 sentence semantic document summary.
  - Metadata Discovery: Extracts correspondent/vendor, document category, document language, and intent.
  - Tags & Title Proposal: Recommends standard taxonomy tags and canonical document titles. Proposed tags are staged as suggestions in the inspector rather than assigned outright — click one to accept it, or dismiss it with the × — and never appear in the sidebar until accepted. A suggestion that exactly matches a tag already in use can optionally be accepted automatically (Settings › Intelligence). Rule-based and manually typed tags are assigned immediately, since there is nothing to review.
  - On-Demand Runs: The model pass can be re-triggered by hand for a selection or the whole library, without re-running OCR or touching anything on disk — which is how a library indexed before a model was configured gets caught up, or asked again with a better one.
- Hierarchical Naming Schemes: Flexible string interpolation templates (e.g., {date}_{correspondent}_{title}.{ext}). Fallback chains resolve missing attributes deterministically:
  - e.g. Date Extraction: OCR text date > embedded PDF metadata > EXIF (for images) > file creation date fallback.

### Interface
- Layout: Native AppKit/SwiftUI 3-pane architecture:
  - Sidebar: Physical directory tree, Recent Processing Queue (with review/confidence states), Paperless-ngx-style smart views (Tags, Correspondents, Languages, Document Types). With more than one library open, folders and tags are grouped under the library that owns them; the smart views span all of them.
  - Center Pane: High-density list/table view featuring SQLite-backed deep full-text search, token filters, and sort options.
  - Inspector Pane: Full document metadata inspector (extracted dates, assigned tags, generated LLM summaries, optimization savings, and alias mappings, raw text, all metadata).
- Keyboard-Driven Inspection: Full keyboard navigation with native Quick Look integration—hitting Spacebar on any file presents an instant preview with text selection and pagination.

### Storage
- Canonical Disk Layer: Physical directory hierarchy containing PDFs, JPEGs, PNGs, and optional macOS Finder Aliases. If the disk layer changes, the app has to update accordingly, not show it as errors etc.
- Library Container: each indexed folder holds its own index in a visible `library.doctopus/` directory inside it (`index.sqlite` + `meta.json`). A library is therefore self-contained and moves with its folder; several can be open at once, and the centre pane merges across them. Document paths are stored relative to the folder.
- Configuration follows the same line: tags, fields, routing rules and ingest settings live in each library, so they travel with it. What describes this Mac rather than a folder — the model backend and its endpoint, OCR concurrency, raster quality, view mode — lives in `UserDefaults`, which also keeps an API key out of a folder somebody might share.
- Index / Metadata Layer (SQLite):
  - documents: File path, file hash, primary directory, size, compression stats, approval status.
  - ocr_content: FTS5 full-text search table with tokenized OCR contents and confidence vectors.
  - metadata: Correspondents, document dates, language, one-sentence LLM summary.
 - tags & document_tags: Relational junction for multi-tag assignment.
 - tag_suggestions: Model-proposed tags awaiting acceptance or dismissal, kept apart from `document_tags` so they never count toward a tag's sidebar total.
- finder_tags: Index of the Finder's own tags, which live on the files themselves.
- value_icons: Per-value icons, so “Invoice” and “Tax” can look different in the sidebar.
 - aliases: Registry of generated macOS Finder aliases for automated pruning when tags change.

---

## Building

No third-party dependencies. Requires Xcode 26 (for the macOS 26 SDK) and runs on macOS 15 or later.

```bash
Scripts/build.sh && open build/Doctopus.app
```

The script compiles the SwiftPM executable, assembles `build/Doctopus.app`, compiles `Resources/doctopus.icon` with `actool` (emitting both a layered `Assets.car` for macOS 26 and a legacy `.icns` used on macOS 15), and ad-hoc signs the bundle.

### Command line

```bash
build/Doctopus.app/Contents/MacOS/Doctopus --selftest Testing/DemoLibrary   # headless pipeline checks
build/Doctopus.app/Contents/MacOS/Doctopus --uitest Testing/DemoLibrary     # headless UI checks
build/Doctopus.app/Contents/MacOS/Doctopus --new-library <folder>           # create <folder>/library.doctopus without the UI
```

Pointing `--selftest` at an API endpoint additionally runs a live enrichment against it, which is the quickest way to verify a server before configuring it in the app:

```bash
DOCTOPUS_LLM_ENDPOINT=http://localhost:1234/v1 DOCTOPUS_LLM_MODEL=qwen3-8b build/Doctopus.app/Contents/MacOS/Doctopus --selftest Testing/DemoLibrary
```

See [Testing/README.md](Testing/README.md) for generating a demo library.

## Implementation notes

- **Storage** — the system SQLite C API directly (`import SQLite3`), WAL, cached prepared statements. FTS5 with `unicode61 remove_diacritics 2`. One `Store` actor owns each library's connection, so there is no locking anywhere else; `AppModel` aggregates across the open libraries. Paths are stored relative to the library folder and translated to absolute `URL`s at the `Store` boundary.
- **OCR** — PDFs are read through their embedded text layer first, which is nearly free; only pages that come back empty are rasterized to grayscale at 200 DPI and sent through Vision. A digital-origin archive is indexed without invoking OCR at all. Per-document provenance (`pdf-layer` / `vision` / `mixed`) is shown in the inspector.
- **Optimization** — a page is only ever rasterized if it has *no* text layer to lose; pages with real text are re-drawn into the output PDF context, which copies their text and vector operators through intact. If the result is not at least 15% smaller, the original is kept byte-for-byte.
- **Disk is the source of truth** — FSEvents drives a debounced reconcile. A file that disappears is marked missing rather than deleted, so when it reappears elsewhere it is relinked by SHA-256 and keeps its tags, metadata and OCR text. Rows stay claimable for seven days.
- **On-device model** — `FoundationModels` is weak-linked and every call site is behind `@available(macOS 26)` plus a runtime availability probe. Where it is unavailable the deterministic analyzer supplies dates, correspondents, types and titles, and the app behaves identically otherwise. Document text never leaves the machine.
- **API model** — one OpenAI-compatible `chat/completions` request shape covers LM Studio, Ollama, llama.cpp, vLLM and hosted APIs, so there is no per-vendor code; the address is normalized however it was pasted, and the request steps down a ladder of `json_schema` → `json_object` → plain text, keeping whichever the endpoint actually answers. Insisting on a schema first is what makes a local reasoning model usable: constrained decoding stops it emitting a thinking trace at all, which on a Gemma-class model is four seconds per document instead of thirty, and no token budget spent on reasoning before the answer starts. Where the ladder does end in plain text, a fenced reply, a chatty preamble and a thinking trace that drafts JSON of its own are all still read correctly. Both backends are asked the same question and produce the same `DocumentInsight`, so routing, tagging and the inspector never know which one ran — only `metadata.source` records it. This backend does send document text to the endpoint you choose, which is why it is never the default, and the API key is stored in Doctopus's own index rather than the Keychain.
- **Nothing moves uninvited** — auto-routing applies to imports and scans only. Files already in your library are never moved or renamed unless you ask, and anything below the confidence threshold stays put and lands in the review queue.
