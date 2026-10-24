# PicoDocs

A Swift package for importing and converting documents for Large Language Models (LLMs).

## Audience

Designed for chat clients and LLM server applications that utilize Retrieval-Augmented Generation ([RAG](https://blogs.nvidia.com/blog/what-is-retrieval-augmented-generation/)).

## Key Features

PicoDocs supports and processes a variety of document formats:
- **File Types**: PDF, ePub, DOCX, XLSX, PPTX, HTML, Markdown, Pages, Keynote, and more.
- **Export Options**: Convert documents to HTML, Markdown, and JSON formats for LLM compatibility, with embedded and referenced images.
- **In-place Editing**: Apply an LLM's exact-match find/replace edits to a DOCX while keeping its formatting (see [Editing in place](#editing-in-place-llm-findreplace-formatting-preserved)).
- **Content Cleanup**: Utilizes Readability to clean HTML content, enhancing focus on the main content similar to Safari's Reader View.
- **OCR**: On-device text recognition (Apple Vision) for standalone images and scanned / image-only PDF pages — no model bundle or cloud service. Enabled by default; toggle with `enableOCR`.
- **Unicode Sanitization** *(opt-in)*: On request (`sanitizeUnicode: true`), cleans extracted text for LLM/RAG use — canonical (NFC) normalization, removal of invisible/control characters (zero-width, bidi, soft hyphen, BOM), and folding of Unicode whitespace/line separators to ASCII — while preserving visible typography (and ZWJ/ZWNJ joiners). Off by default while it post-processes generated Markdown; per-converter integration is planned.
- **Multiple Sources**: Reads local files and iCloud files.

## How It Works

There are two main steps: fetching and parsing.

### Fetching
- Load files from disk or download files from iCloud or the web.
- Handle complex file structures (e.g., ePub chapters, Excel sheets) by fetching and organizing them as child documents.
- Support loading all documents within local or iCloud directories as child documents.

### Parsing
- Convert original file contents to LLM-readable formats, such as Markdown, HTML, or CSV.
- PicoDocs can choose the most optimal LLM-readable format for each original file type. For example, Excel sheets will be exported to CSV unless overridden by the developer.

## Supported File Types

- PDF (with on-device OCR fallback for scanned / image-only pages)
- ePub
- DOCX
- HTML/XHTML
- XLSX
- PPTX (one section per slide: title, text, lists, tables, images, speaker notes)
- Pages and Keynote (iWork '13+)
- TXT
- RTF
- Numbers (one section per sheet, tables as Markdown grids)
- MD
- Webloc
- Images (PNG, JPEG, HEIC, …) via OCR

## Installation

To add PicoDocs to your Swift project, use:

```swift
dependencies: [
    .package(url: "https://github.com/picoMLX/PicoDocs.git", .upToNextMajor(from: "1.0.0"))
]
```

## Code Example

```swift
let url = URL(string: "https://electrek.co/2025/01/14/top-10-best-selling-evs-us-2024/")!
let doc = PicoDocument(url: url)
try await doc.fetch()
try await doc.parse()
print(doc.exportedContent)
```

## Exporting (Markdown / LLM output → office files)

PicoDocs can also go the other way: turn LLM Markdown output (or a structured
`ConverterResult`) into a real office file via `PicoDocsEngine.write(...)`.

```swift
// From a Markdown string (e.g. an LLM response):
let docx = try PicoDocsEngine.write(markdown: markdown, to: .docx)
let xlsx = try PicoDocsEngine.write(markdown: markdown, to: .xlsx)
let pptx = try PicoDocsEngine.write(markdown: markdown, to: .pptx)
let rtf  = try PicoDocsEngine.write(markdown: markdown, to: .rtf)   // Apple platforms

// From a structured result (e.g. round-tripping an imported document):
let data = try PicoDocsEngine.write(result, to: .docx)
```

Notes:
- **DOCX/XLSX/PPTX** are written as OOXML (ZIP + XML) on all platforms. **RTF** uses
  `NSAttributedString` and is available on Apple platforms.
- **Pages/Keynote** are intentionally not implemented — writing valid iWork files
  third-party is unsupported (`ExportableFileType.isImplemented == false`); export to
  DOCX/PPTX and let Pages/Keynote import it instead.
- Custom or additional writers can be registered via `DocumentExporterRegistry`,
  mirroring `DocumentConverterRegistry` on the import side.

## Editing in place (LLM find/replace, formatting preserved)

When an LLM needs to *change* an existing document rather than rewrite it,
`PicoDocsEngine.applyEdits(...)` makes surgical edits to the original file. Only
the matched text changes; styles, images and structure stay as they were. That
avoids both the lost formatting and the silent rewording you get from "convert
the whole document, let the model regenerate it, write a new file".

Edits are exact-match find/replace, so the model can only change text it quotes
verbatim. Anything that doesn't match exactly and unambiguously is rejected
rather than guessed at.

```swift
// 1. Show the model the exact text to quote from. Use this, not the Markdown
//    export: it's the string the editor searches, so a verbatim quote matches.
let text = try await PicoDocsEngine.editableText(for: docx, filename: "report.docx")

// 2. Apply the model's edits. The result is a .docx with its formatting intact.
let result = try await PicoDocsEngine.applyEdits([
    TextEdit(find: "Q3 revenue was $4.2M", replace: "Q3 revenue was $4.8M"),
    TextEdit(find: "DRAFT", replace: "FINAL", replaceAll: true),
], to: docx, filename: "report.docx")
// result.data: the edited file. result.applied: replacements per edit, e.g. [1, 3].
```

Notes:
- **DOCX only** for now. Other formats throw `documentTypeNotSupported`. For them,
  the lossy fallback is `convert` → edit the Markdown → `write(...)`, which does
  not keep the original formatting.
- Exact matching limits *where and how much* changes. It does not check that the
  replacement is correct; that stays the caller's job.
- A batch is all-or-nothing, and its edits may not overlap. An edit is rejected
  (`PicoDocsError.editCrossesBoundary`) if it spans a paragraph, tab or line
  break, touches a hyperlink, field, content control or tracked change, or adds a
  tab or line break. The error messages are written so a model can correct its
  next attempt.
- Only `word/document.xml` is rewritten. Every other part of the package is copied
  through byte for byte. Headers, footers, footnotes and text boxes aren't
  editable yet.

## Setup for Apps

### Info.plist Configuration
Add necessary import identifiers to your `Info.plist`.

For sandboxed apps:

### Networking Permissions
Enable `Outgoing Connections (client)` for network access.

### File Access
Ensure the `User Selected Files` capability is set to `read-only` or `read/write`.

Refer to the [example app](PicoDocsExample/) for detailed guidance.

## Apps Using PicoDocs

- **Pico AI Studio**
- **Pico AI Homelab** (coming soon)

Create a PR to include your app here.

## Known Limitations

- **iWork tables**: Tables are reconstructed as Markdown grids — placed inline at their original position in Pages, and with the slide that contains them in Keynote. Text, date/time, Boolean, number, and formula-result cells are decoded. Number, currency and percentage formats are applied (for example `62%` or `$1,234.50`) without rounding away stored digits; other display formats keep the stored value. Formula-error cells without decoded error details render as `#ERROR!`; duration cells currently render as empty.

## License

PicoDocs is released under the MIT license.

Brought to you by Starling Protocol, Inc., creators of Pico AI Homelab, Pico AI Studio, and Flux AI Studio.
