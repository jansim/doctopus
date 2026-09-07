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
- (If available) Apple On-Device LLM: Summary: Generates a 1–2 sentence semantic document summary.
  - Metadata Discovery: Extracts correspondent/vendor, document category, document language, and intent.
  - Tags & Title Proposal: Recommends standard taxonomy tags and canonical document titles.
- Hierarchical Naming Schemes: Flexible string interpolation templates (e.g., {date}_{correspondent}_{title}.{ext}). Fallback chains resolve missing attributes deterministically:
  - e.g. Date Extraction: OCR text date > embedded PDF metadata > EXIF (for images) > file creation date fallback.

### Interface
- Layout: Native AppKit/SwiftUI 3-pane architecture:
  - Sidebar: Physical directory tree, Recent Processing Queue (with review/confidence states), Paperless-ngx-style smart views (Tags, Correspondents, Languages, Document Types).
  - Center Pane: High-density list/table view featuring SQLite-backed deep full-text search, token filters, and sort options.
  - Inspector Pane: Full document metadata inspector (extracted dates, assigned tags, generated LLM summaries, optimization savings, and alias mappings, raw text, all metadata).
- Keyboard-Driven Inspection: Full keyboard navigation with native Quick Look integration—hitting Spacebar on any file presents an instant preview with text selection and pagination.

### Storage
- Canonical Disk Layer: Physical directory hierarchy containing PDFs, JPEGs, PNGs, and optional macOS Finder Aliases. If the disk layer changes, the app has to update accordingly, not show it as errors etc.
- Index / Metadata Layer (SQLite):
  - documents: File path, file hash, primary directory, size, compression stats, approval status.
  - ocr_content: FTS5 full-text search table with tokenized OCR contents and confidence vectors.
  - metadata: Correspondents, document dates, language, one-sentence LLM summary.
 - tags & document_tags: Relational junction for multi-tag assignment.
 - aliases: Registry of generated macOS Finder aliases for automated pruning when tags change.
