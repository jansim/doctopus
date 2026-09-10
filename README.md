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
- Auto-Routing Engine: Unspecified imports and inbox scans evaluate against a confidence threshold to automatically route into appropriate folders on disk. Every place that fits is kept as a suggestion; the file is only moved when the best one clears the threshold *and* no other place fits about as well — two equally good homes leave it in the Inbox, in Needs Review, until someone picks. Routing never moves a file outside its library:
  - Recent Processing Queue: A dedicated UI section displays recently filed items with confidence badges, applied rules/models, and an "Approved / Needs Review" status toggle.
  - Review & Assign: in Recent Processing and Needs Review the centre pane splits, and the selected document is reviewed underneath the list. On the left, everything that was worked out — title, fields, date, tags and tag suggestions — is editable in place, or can be discarded in one go (the file is untouched and Analyze can fill it in again). On the right, every candidate folder — where it is now, the router's suggestions with their confidence, where similar documents already live, any other folder in the library or a new one — has two controls: *Lives here* (one folder; the file is moved there) and *Also here* (any number; filed as Finder aliases). One button applies, approves and moves on to the next document (⌘↩). The same picker is available for any document as File In… in the context menu.
  - Rules are edited in Settings › Routing: what a rule looks at (text, filename, correspondent or type), its pattern, destination template, tags and confidence, and where it sits in the evaluation order. The editor shows how the pattern will be read, how many documents already in the library it matches, and where a document would land.
- Optimization: Scans and image-heavy PDFs undergo on-device raster optimization and compression without (severely) degrading readability or stripping text layers. (think PDFSqueezer, ImageOptim, ...) Automatic only for files Doctopus brings in itself; anything already in the library is optimized only on request.

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
- Library Container: each indexed folder holds its own index in a `library.doctopus` package inside it (`index.sqlite` + `meta.json`). Finder shows it as a single Doctopus document that opens the library on a double-click; Show Package Contents gets at the files. A library is therefore self-contained and moves with its folder; several can be open at once, and the centre pane merges across them. Document paths are stored relative to the folder.
- Configuration follows the same line: tags, fields, routing rules and ingest settings live in each library, so they travel with it. What describes this Mac rather than a folder — the model backend and its endpoint, OCR concurrency, raster quality, view mode — lives in `UserDefaults`, which also keeps an API key out of a folder somebody might share.
- Index / Metadata Layer (SQLite):
  - documents: File path, file hash, primary directory, size, compression stats, approval status.
  - ocr_content: FTS5 full-text search table with tokenized OCR contents and confidence vectors.
  - metadata: Correspondents, document dates, language, one-sentence LLM summary.
 - tags & document_tags: Relational junction for multi-tag assignment.
 - tag_suggestions: Model-proposed tags awaiting acceptance or dismissal, kept apart from `document_tags` so they never count toward a tag's sidebar total.
 - path_suggestions: Every folder the router considered for a new document, best first — what the review offers, and all there is to go on when it moved nothing.
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
- **Nothing moves uninvited** — the only thing Doctopus ever moves or rewrites on its own is a file it has just brought in itself (a scan, or the copy an import makes), and it only moves one when nobody chose a folder for it. Concretely:
  - Files already in the library are never moved, renamed, optimized or deleted except by an explicit action — even when "imported" again by a drop, which just indexes them in place.
  - Importing or scanning into a chosen folder (the folder's context menu, or with that folder selected) leaves the file there. Imports from outside the library are copied; the original is never touched. A folder dropped in or chosen to import brings in the PDFs and images inside it at any depth, flattened into the destination; the folder itself is left as it was.
  - Routing is skipped below the confidence threshold, when two candidates are about equally good, and for any destination outside the library. The document waits in Needs Review with its candidates kept in `path_suggestions`.
  - Doctopus only deletes an alias it made for a tag, and only if the file at that path is still an alias to that document. Aliases you create by dragging onto a folder are yours.
  - Move to Trash uses the Trash (never a hard delete), keeps the index entry if trashing fails, and asks first when the row is only an alias in the folder being viewed.
  - A library whose `library.doctopus` was deleted is not recreated at launch.
