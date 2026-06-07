# AGENTS.md

Guidance for any AI agent working in this repo — both **implementers** (Claude
Code, Codex, etc. that write code and open PRs) and **automated reviewers**
(Codex, Gemini). Humans are welcome to read it too.

PicoDocs is a Swift package that imports and converts documents (PDF, ePub,
DOCX, XLSX, HTML, RTF, CSV, Markdown…) into LLM-ready Markdown for RAG.

---

## Build & test

```sh
swift build      # build the library
swift test       # run the Swift Testing suite (Tests/PicoDocsTests)
```

**This package does not build on Linux.** It links Apple-only frameworks
(PDFKit, UniformTypeIdentifiers, etc.), so a Linux container cannot compile it.
**CI is the authoritative build/test signal** — `.github/workflows/ci.yml` runs
`swift build` + `swift test` on `macos-15` with the latest stable Xcode (Swift 6).
If you are working in a Linux environment, do **not** claim a local build or test
pass; rely on CI and say so.

`PicoDocsExample/` is a separate Xcode app project; `swift build` does not build it.

## Architecture

Pipeline: **fetch** (`Fetchers/`) → **detect** (`Detection/ContentTypeDetector`)
→ **convert** (`Converters/`) → **render** (`Renderers/DocumentRenderer`).

- **Detection runs once** and is stamped into `StreamInfo`; converters trust it
  and never re-sniff.
- **Converters** conform to `DocumentConverter` and are registered in
  `DocumentConverterRegistry` by priority (`.specific` beats `.generic`). Each
  converter emits **canonical Markdown** as `DocumentSection`s (`ConverterResult`).
  Converters **never branch on output format.**
- The **renderer** owns export to Markdown / HTML / plaintext / XML / CSV, derived
  from that canonical Markdown.
- **Strict failure:** a converter that accepts an input and then fails **throws** —
  it does not silently fall back to `PlainTextConverter`. A corrupt `.docx` must
  surface as an error, not degrade to plain text.
- Public API: `@Observable PicoDocument` wraps the stateless `PicoDocs` engine
  entry points.

## Conventions

- **Swift 6, full concurrency.** Types crossing actor boundaries are `Sendable`;
  conversion runs **off the main actor** (no `@MainActor` on the engine). Use
  `Task.checkCancellation()` in per-item loops.
- **Pure Swift parsing.** No `NSAttributedString`, no `WKWebView`/JavaScript — the
  legacy engine used both and they were deliberately removed. Don't reintroduce them.
- **Gate Apple frameworks** with `#if canImport(...)` (e.g. `PDFConverter` is behind
  `#if canImport(PDFKit)`) so the package still compiles where they're absent.
- **Dependencies are CoreXLSX, SwiftSoup, ZIPFoundation only.** Don't add new ones
  without strong justification (EPUBKit / Zip / AEXML were intentionally dropped).
- **Tests use Swift Testing** (`@Test` / `#expect`), with fixtures in
  `Tests/PicoDocsTests/Resources/`. Keep the `ContentTypeDetector` regression guard
  for issue #2 (content-based detection of docx/xlsx/epub via ZIP central-directory
  subtyping — they must not be misclassified as XML).

---

## How we work: PRs and the review loop

1. **Plan first, then run autonomously.** For anything beyond a trivial change,
   post a plan that splits the work into small, independently reviewable PRs and
   wait for the maintainer's approval. **That approval is the only checkpoint** —
   once approved, carry the plan through every phase without pausing to ask
   "should I continue?". Only stop for the maintainer when a decision is
   architecturally significant or genuinely ambiguous, a review comment can be read
   more than one way, or you are blocked.

2. **Keep PRs small and, when dependent, stacked.** If a phase depends on a PR that
   isn't merged yet, branch the next PR off that branch (not `main`) and note
   "stacked on #N" in the body — don't idle waiting for a merge.

3. **Anchor everything to the latest commit SHA.** A review of a superseded commit
   is stale. The only signal that counts is a review of the current head.

4. **Iterate until the review loop closes** (see "Definition of done"). After each
   push, the reviewers run again. If no review of the current head SHA appears
   within ~10 minutes, re-trigger it (`@codex review`); after a second nudge with
   no response, tell the maintainer.

5. **Record a disposition for every finding** and reply on the thread so the flow
   is followable. Use one of:
   - `FIXED <sha>` — addressed in that commit.
   - `ALREADY-FIXED in <sha>` — a review that lagged behind a newer push.
   - `WON'T-FIX (reason)` — intentional; also leave a brief code comment so the
     decision is visible in-source on the next round.
   - `DEFERRED to #N` — tracked in a follow-up PR or issue.
   Judge each finding against the actual code and CI before acting — reviewers are
   sometimes wrong, duplicated, or already addressed by a later commit.

6. **Batch fixes:** address a whole review round in one commit and push once, rather
   than a push per finding (fewer review passes, less API-rate pressure).

### Definition of done (all must hold for the **current** head SHA)

- CI is green.
- Codex has reviewed this exact SHA and has **no open actionable findings** — i.e.
  it reacted 👍. (A "Codex Review" comment *existing* is not approval.)
- Every review thread is replied-to / resolved.
- Gemini has no open findings. (Gemini Code Assist is being retired in 2026 — don't
  hard-block on it if it stops responding.)

### Merging is the maintainer's job

`main` is protected: a PR merges only with **green CI and a human merge.** **Agents
never merge and never approve PRs, and never enable auto-merge.** When a PR reaches
"done", post a short "ready for your merge" summary (what changed, review rounds,
any deferrals) and move on to the next phase.

---

## For automated reviewers (Codex / Gemini)

- **What matters most here:** correctness and **content fidelity** — this is a
  document → Markdown library for RAG, so silently dropping, duplicating, or
  corrupting content (and broken round-trips) is the highest-severity class of bug.
  Then: Swift 6 concurrency / `Sendable` correctness, and **security of parsing
  untrusted documents** (zip-slip / path traversal, XML entity expansion, resource
  exhaustion). Then performance.
- **PRs are small and frequently stacked.** Code may reference callers or wiring
  that arrive in a later PR. If the description says the change is additive / "wired
  in #M" / "stacked on #N", **don't flag the not-yet-wired code as dead or unused.**
- **Respect recorded dispositions.** Once the author marks a point `WON'T-FIX` or
  `DEFERRED to #N` (or a nearby code comment documents an intentional decision),
  **don't re-raise it** on later pushes unless the surrounding code changed.
- **Anchor to the reviewed commit.** Re-review the latest pushed SHA and don't
  repeat findings already fixed in a newer commit.
- **Signal done with a 👍 reaction** when you have no remaining actionable findings —
  the author's loop watches for that reaction. Reserve change requests for
  substantive issues; this package can't be built on Linux, so don't ask for changes
  premised on a local build you didn't run.
