---
name: llm-friendly-cli-messages
description: "How to write CLI / tool output, errors, and exit codes that let an LLM self-correct. Distilled from gogcli's message design. Use when building or reviewing a command-line tool, API wrapper, or agent tool whose output an LLM reads — to make failures actionable instead of dead ends."
---

# Writing tool messages that guide an LLM

When an LLM drives a command-line tool (or any tool whose text output it reads),
**the output is the feedback loop.** A bare `Error: 403` is a dead end — the model
retries the same thing or gives up. A message that says *what's wrong and how to
fix it* lets the model correct itself on the next call.

These are the lessons from [`gogcli`](https://github.com/steipete/gogcli) (a
Google Workspace CLI explicitly tuned for LLM use) and from porting them into
SwiftGog. Apply them to any tool an agent will call.

## The one rule

**Every failure message should answer "what do I do now?"** — name the fix (a
flag, a URL, a scope, a corrected input), not just the symptom. If a human would
have to go google the error, the message is incomplete.

## Principles (with before → after)

### 1. Enrich known API errors into actionable hints
Raw upstream errors are noise. Recognize the common, *fixable* ones and append
the fix. Match on the provider's error `reason`/`status`, not brittle prose.

> **Before:** `Error: googleapi: Error 403: PERMISSION_DENIED`
> **After:** `Drive API is not enabled for this project. Enable it at:
> https://console.cloud.google.com/apis/api/drive.googleapis.com/overview — then retry.`

Worth special-casing: *API/feature not enabled* (give the enable URL),
*insufficient scope/permission* (name the scope to grant), *rate limited / quota*
(say "back off and retry"), *not found* (echo the id that wasn't found).

### 2. Distinct exit codes for distinct conditions
Agents and scripts branch on exit codes. Don't collapse everything to `1`. Pick a
small, documented scheme and keep it stable, e.g.:

| code | meaning |
| ---- | ------- |
| 0 | success |
| 1 | general / unclassified runtime error (the fallback when nothing more specific fits) |
| 2 | usage / bad input (the model can fix the command) |
| 3 | refused by policy (a gate; not a retry) |
| 7 | fail-closed: missing/invalid auth or no network (escalate, don't retry) |

The model learns "2 = fix my arguments, 7 = ask the host for auth" far faster
from codes than from prose.

### 3. Fail fast on bad input — with the correction
Validate locally and reject with the fix, instead of forwarding bad input to the
API and surfacing its opaque error.

> **Before (forwarded):** API returns `400: Invalid member key`
> **After (local):** `member-add needs an email address, not an id (an id only works for member-remove)` → exit 2

### 4. Prefix messages with the tool/command name
In a shell or pipeline the model needs to know *which* command failed. Mirror
coreutils: `gog: --max must be between 1 and 500`, like `ls: cannot access 'x'`.

### 5. Structured data to stdout; everything else to stderr
Machine-readable results (ideally JSON behind a `--json` flag) go to **stdout**;
hints, progress, "no results", and errors go to **stderr**. The model can then
`cmd --json | jq …` without the diagnostics corrupting the data stream.

### 6. Signal "empty" explicitly — don't return silence
An empty result is ambiguous (did it work? did the filter match nothing?). Emit a
short `No results` to **stderr**. Crucially, under `--json` still print a valid
empty container (`[]` or `{}`) to **stdout** — silence makes `jq` and JSON
decoders downstream fail on empty input. Also offer a `--fail-empty` flag (exit
non-zero when empty) so a script can branch without parsing the payload.

### 7. Preview and gate mutations
Give destructive/outbound actions a `--dry-run` that prints the exact request
without sending it. Gate the dangerous ones behind an explicit switch. In a
**non-interactive/agent** context there's no human to confirm, so *fail closed*
(refuse unless explicitly enabled) rather than prompting — and don't expose the
"force" switch to the model itself.

### 8. Be deterministic and stable
Agents pattern-match on your text. Keep wording, ordering, and field layout
stable across runs; sort collections; don't interleave randomly-ordered hints.
Treat user-facing strings like an API.

### 9. Never leak secrets in messages
Tokens, keys, and credentials must never appear in output, argv, env, or error
text — an agent will happily echo whatever it sees. Keep them out-of-band.

### 10. Keep hints honest and adapted to *your* model
Copy the *shape* of good messages, not the literal text, when your architecture
differs. gogcli says "run `gog auth add …`"; a tool with host-managed auth should
instead say "the host must grant the scope" — same actionability, correct for the
context.

## Checklist for a new command

- [ ] On every error, the message names a concrete next action.
- [ ] Known upstream errors (not-enabled / scope / rate-limit / not-found) are enriched.
- [ ] Exit codes distinguish usage (2) vs policy (3) vs auth/fail-closed (7).
- [ ] Bad input is rejected locally with the correction, not forwarded.
- [ ] Messages are prefixed with the command name.
- [ ] Data → stdout (JSON option); hints/errors → stderr.
- [ ] Empty results are signalled; `--fail-empty` is available.
- [ ] Mutations have `--dry-run`; destructive ones are gated and fail closed.
- [ ] Output is deterministic and stable.
- [ ] No secret can appear in any message.

## Why it matters

An LLM can't see your code, only your output. Messages written this way turn a
failed call into a *recoverable* one: the model reads the hint, adjusts the flag
or asks the host to enable the API, and the next call succeeds — without a human
in the loop.
