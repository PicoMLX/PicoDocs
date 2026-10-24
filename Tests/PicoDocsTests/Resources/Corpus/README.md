# Third-party test corpus

Files copied from other projects' public test suites and used by
`CorpusTests.swift`; all are unmodified except the HTML pages marked *trimmed*
below. Each was converted with PicoDocs and compared against a
reference extractor (python-docx / python-pptx / openpyxl, LibreOffice, pandoc,
the upstream project's own expected output). The set favors files that exposed
a crash, a hang, or lost/garbled content, plus representative complex files.

| Path | Source | What it exercises |
| --- | --- | --- |
| `poi/61470.docx` | Apache POI `test-data/document` | Ruby (furigana) runs |
| `poi/Bug54771b.docx` | Apache POI `test-data/document` | Table cells wrapped in content controls |
| `poi/Bug66263-table.docx` | Apache POI `test-data/document` | Table rows wrapped in a content control |
| `poi/tika-3816.docx` | Apache POI `test-data/document` | Drop-down content controls in table cells |
| `poi/deep-table-cell.docx` | Apache POI `test-data/document` | 5,000 nested tables (performance) |
| `poi/clusterfuzz-testcase-minimized-POIXWPFFuzzer-4791943399604224.docx` | Apache POI `test-data/document` | Fuzzed ZIP directory (out-of-range offsets) |
| `poi/clusterfuzz-testcase-minimized-POIXSLFFuzzer-5463285576892416.pptx` | Apache POI `test-data/slideshow` | Fuzzed ZIP directory (out-of-range offsets) |
| `poi/clusterfuzz-testcase-minimized-XLSX2CSVFuzzer-5025401116950528.xlsx` | Apache POI `test-data/spreadsheet` | Fuzzed ZIP directory (out-of-range offsets) |
| `poi/sample-beta.xlsx` | Apache POI `test-data/spreadsheet` | Office 2007 beta dialect: shared-string indexes out of range |
| `poi/60384.xlsx` | Apache POI `test-data/spreadsheet` | LibreOffice export with an empty formatted row 1048576 |
| `poi/bug69769.xlsx` | Apache POI `test-data/spreadsheet` | Shared-string index with trailing whitespace (`<v>2 </v>`) |
| `poi/56511.xlsx` | Apache POI `test-data/spreadsheet` | Rich-text (multi-run) shared strings |
| `tika/testRTFIgnoredControlWord.rtf` | Apache Tika `tika-parser-microsoft-module` test documents | `\*` in the middle of a group |
| `tika/testFontAfterBufferedText.rtf` | Apache Tika `tika-parser-microsoft-module` test documents | Cyrillic via `\fcharset204` in an `\ansicpg1252` file |
| `tika/testRTFWordPadCzechCharacters.rtf` | Apache Tika `tika-parser-microsoft-module` test documents | Czech via `\fcharset238` (WordPad) |
| `tika/testRTFJapanese.rtf` | Apache Tika `tika-parser-microsoft-module` test documents | Shift-JIS via `\fcharset128` (double-byte) |
| `tika/testEPUB.epub` | Apache Tika `tika-parser-miscoffice-module` test documents | EPUB spine, headings, lists |
| `numbers-parser/format-1.numbers`, `format-1.csv` | numbers-parser `tests/data` | Tile rows with wide cell offsets; the CSV it was built from |
| `python-pptx/tbl-cell.pptx` | python-pptx `features/steps/test_files` | Slide tables with merged cells |
| `csv-spectrum/*.csv`, `*.json` | csv-spectrum `csvs/`, `json/` | CSV edge cases with expected records |
| `readability/dev418.html` | Mozilla Readability `test/test-pages/dev418/source.html` | Article extraction, block whitespace; image-only paragraphs and figures |
| `readability/aclu.html` | Mozilla Readability `test/test-pages/aclu/source.html` (trimmed) | Article inside an "unlikely" (`sidebar`) panel: the retry that keeps unlikely nodes |
| `readability/ehow-1.html` | Mozilla Readability `test/test-pages/ehow-1/source.html` (trimmed) | One candidate per step: their common ancestor becomes the article |
| `readability/quanta-1.html` | Mozilla Readability `test/test-pages/quanta-1/source.html` (trimmed) | Paragraphs five levels deep; the article as an only child of its wrapper |
| `readability/mathjax.html` | Mozilla Readability `test/test-pages/mathjax/source.html` (trimmed) | MathJax containers (`CtxtMenu` classes) and their `aria-hidden` render tree |
| `readability/yahoo-2.html` | Mozilla Readability `test/test-pages/yahoo-2/source.html` (trimmed) | A video player's control labels vs. the article (`modalCentered` wrappers, text in `<div>`s) |

The trimmed pages drop what neither the Readability.js port nor its
predecessor reads: `<script>`, `<style>`, inline `<svg>`, `<link>`, comments,
`<meta>` tags other than the title/author/description ones, attributes other
than those the scorer inspects, and indentation outside `<pre>`. Each starts
with a comment saying so, and each still converts to the same Markdown as its
untrimmed source.

## Sources and licenses

- **Apache POI** — https://github.com/apache/poi (commit `b014b071ab8ffe9ec025ae750c52ffdc02eeff27`).
  Apache License 2.0 (`LICENSE-Apache-2.0.txt`).
  NOTICE: Apache POI, Copyright 2003-2026 The Apache Software Foundation. This
  product includes software developed at The Apache Software Foundation
  (https://www.apache.org/).
- **Apache Tika** — https://github.com/apache/tika (commit `867344ffd1309b7e751e197b907fb0dcda19c79e`).
  Apache License 2.0 (`LICENSE-Apache-2.0.txt`).
  NOTICE: Apache Tika, Copyright 2007-2026 The Apache Software Foundation. This
  product includes software developed at The Apache Software Foundation
  (http://www.apache.org/).
- **Mozilla Readability** — https://github.com/mozilla/readability (commit
  `ab4027a8b37669745016869a37a504727992b2ba`). Apache License 2.0 (`LICENSE-Apache-2.0.txt`).
- **numbers-parser** — https://github.com/masaccio/numbers-parser (commit
  `5ec3694082e7003c824bb400eed97bd7e2eb9cd6`). MIT License, Copyright 2021 Jon Connell.
- **python-pptx** — https://github.com/scanny/python-pptx (commit
  `278b47b1dedd5b46ee84c286e77cdfb0bf4594be`). MIT License, Copyright (c) 2013 Steve Canny.
- **csv-spectrum** — https://github.com/max-mapper/csv-spectrum (commit
  `d30e80f8b99d2eecb3778f1d7b9ed1cb425502ec`). BSD-2-Clause, Copyright max ogden.

### MIT License (numbers-parser, python-pptx)

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN
AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### BSD 2-Clause License (csv-spectrum)

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
