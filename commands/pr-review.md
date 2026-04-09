# /pr review [pr_number | worktree] [-i]

Code review — noninteractive (all at once) by default, or interactive (file-by-file) with `-i`.

## Usage

- `/pr review 12345` - review specific PR (noninteractive)
- `/pr review` - review PR for current branch (noninteractive)
- `/pr review -i` - review PR for current branch (interactive, file-by-file)
- `/pr review 12345 -i` - review specific PR (interactive)
- `/pr review ../rc_feature-x` - review worktree changes

---

## ⛔ Approval Gate (non-negotiable)

**Do not call `gh api` or post comments in any form until the user has explicitly approved.** This is the single most important rule in this document.

Flow is always: analyze → present findings → **stop and wait for user response** → post only what was approved.

---

## Setup

### Step 1: Determine Target and Pre-load

```bash
gh pr view $PR_NUMBER --json headRefName,baseRefName,author,title,url
gh pr diff $PR_NUMBER  # full diff, not just --stat
```

Read the full diff and all changed files upfront in parallel so everything is in context.

### Step 2: Review Style

Default is noninteractive (all files at once). Print the choice but don't block:

```
**Review style**: noninteractive (all files at once)
```

If `-i` flag was passed, select interactive. Print the choice but don't block:

```
**Review style**: interactive (file-by-file) — via `-i` flag
```

### Step 3: Detect Review Mode

Auto-detect from the PR author (compare against the current `gh` user). Print the inference but **do not pause** — the user can interrupt to correct it, but don't wait for confirmation:

```
**Review mode**: This PR is by @other-user — reviewing as someone else's PR.
  (I'll flag issues and draft comments; you decide what to post.)
  ^— interrupt if this is wrong
```

or

```
**Review mode**: This PR is by you — reviewing your own PR.
  (I'll explain changes; findings listed but not posted.)
  ^— interrupt if this is wrong
```

### Step 4: Context

Silently read relevant context — PR description, linked docs, `design_docs/` files. Don't walk through docs with the user.

---

## Overview

Present files changed, **ordered for understanding** (not alphabetically):

1. Protos/schemas first
2. Constants/configs early
3. Core logic before utilities
4. Implementation before tests
5. Docs/comments last

```
## PR: [title]

**Scope**: X files, +Y/-Z lines

| # | File | Why this order |
|---|------|----------------|
| 1 | api.proto | Defines new message types |
| 2 | handler.py | Core logic change |
| 3 | test_transcription.py | Tests the core |
```

If noninteractive (default): proceed through all files silently.
If interactive (`-i`): `Ready for File 1? (yes / skip to [file] / reorder / done)`

---

## Interactive Mode

For each file:

### 1. Show the Change

Display the diff for each logical chunk:

```
### The Change (Lines N-M)

[diff]

**What**: Before did X, now does Y.
**Why**: [connect to PR goal]
```

### 2. Example Scenario (when helpful)

For non-obvious logic, walk through a concrete case. Keep it tight — input/output, before/after.

### 3. Call Out Issues

Surface issues immediately as you find them, categorized:

```
🔴 **Must-fix**: [one-liner description]
Scenario: [how it fails]
```

or

```
🟡 **Skippable**: [one-liner description]
```

### 4. File Summary

```
| Aspect | Assessment |
|--------|------------|
| Core change | [one-liner] |
| Correctness | ✅ / 🔴 concern about X |

Ready for next file? (yes / questions? / done)
```

**Always pause.** User can ask questions, go back, or continue.

### 5. Interactive Comment Posting (someone else's PR only)

After each file, if issues were found, show each finding with its category, then the **draft comment** underneath. The draft is what actually gets posted — it must be natural, concise human language with no emoji tags or category prefixes:

```
🔴 **Must-fix** @ `file.py:42`: missing null check before deref
> draft: `itemId` can be nil here when the delta has no payload — add a guard

🟡 **Skippable** @ `file.py:78`: could add a test for the empty-list edge case
> draft: nit: empty-list path is untested

Post these? (yes / modify / skip individual)
```

**NEVER post without explicit approval.**

---

## Noninteractive Mode

Review all files silently, then present a single categorized summary.

### Findings Report

Show findings categorized with emoji tags for the user's triage. Each finding also has a **draft comment** — this is what actually gets posted to the PR and must be natural, concise human language with no emoji tags or category prefixes.

```
## Review: [PR title]

### 🔴 Must-fix
| # | File:Line | Issue | Draft comment |
|---|-----------|-------|---------------|
| 1 | `core.py:42` | Missing null check — `itemId` can be nil on empty deltas | `itemId` can be nil on empty deltas — add a nil guard |
| 2 | `cache.py:18` | Race: concurrent calls overwrite `_pending` without lock | concurrent calls can overwrite `_pending` — needs a lock |

### 🟡 Skippable
| # | File:Line | Issue | Draft comment |
|---|-----------|-------|---------------|
| 1 | `core.py:90` | Could add a test for the timeout path | nit: timeout path is untested |
| 2 | `helper.ts:15` | Intermediate var `tmp` could be inlined | nit: `tmp` could be inlined |

### ✅ No issues
- `proto/api.proto`
- `test_handler.py`
```

If **no issues found**, say so and stop.

### After presenting findings

- **Own PR**: Leave the list as-is. Done.
- **Someone else's PR**: Ask for approval before posting anything:

```
Post these as inline review comments? You can:
- **yes** — post all
- **skip N** — drop specific items by number
- **modify N** — reword a specific draft
- **done** — post nothing
```

**NEVER post without explicit approval.**

---

## Comment Style

**Review output** (shown to the user) uses 🔴/🟡/✅ tags and category labels for quick triage.

**Draft comments** (posted to the PR) must be completely different — natural, concise human language. No emoji prefixes, no "must-fix:"/"skippable:" tags. Write like a colleague leaving a review:

- **Concise**: one or two sentences max. No essays. No "consider whether you might want to think about..."
- **Actionable**: say what's wrong and what to do, or flag it as a question
- **Human**: severity is obvious from word choice and context, not from tags

Good:
> `itemId` can be nil here — add a nil guard before the deref

Good (nit):
> nit: this intermediate variable could be inlined

Bad:
> 🔴 must-fix: `itemId` can be nil here — add a nil guard before the deref

Bad:
> I noticed that in this section of the code, the variable `itemId` is being used without first checking whether it might be nil. This could potentially lead to a nil pointer dereference in production if the delta happens to arrive without a payload. It would be advisable to add a guard check before this line to ensure...

## Comment Placement (use only after user approves)

**Precondition**: You have presented findings and the user has responded with approval (e.g. "yes", "post all"). If this has not happened, STOP — go back and present findings first.

**Always post inline at the specific line.** Never use PR-level comments. For every finding, identify the exact file and line to anchor the comment on.

```bash
gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments \
  -f body="comment" -f path="file.py" \
  -f commit_id="$(gh pr view $PR_NUMBER --json headRefOid -q .headRefOid)" \
  -F line=$LINE
```

If a finding spans multiple lines, pick the most relevant one.

---

## Final Summary

```
## Review Complete

| File | Key Change | Status |
|------|------------|--------|
| core.py | Auth refactor | 🔴 1 must-fix |
| helper.ts | Cache layer | 🟡 1 skippable |
| proto/api.proto | Schema | ✅ |

**Overall**: [1-2 sentences]
```

---

## Critical Review Mindset

Don't just explain — actively look for problems:

### State & Lifecycle
- Cleanup symmetry: if state is set, is it reset?
- Lifecycle consistency: does state survive scenarios it shouldn't?
- Guard completeness: missing re-entrancy protection?

### Edge Cases & Races
- Concurrent calls: orphaned promises, overwritten callbacks?
- Ordering assumptions: what if events arrive out of order?
- Partial failures: is state consistent if step 3 of 5 fails?

### Missing Pieces
- What's NOT in the diff that should be?
- Defensive gaps: missing timeouts, size limits, null checks?

### Design
- Is there a simpler approach?
- Hidden assumptions about the environment?

---

## Guidelines

- **Concise over verbose** — short, direct comments. No filler.
- **Two voices** — use 🔴/🟡/✅ tags in review output for the user; draft comments posted to the PR are natural human language, no tags
- **NEVER post without approval** — always confirm first
- **Always inline** — never PR-level comments, always find the right line
- **Explain the why**, not just the what
- **Be critical** — find problems, don't narrate
- **Think holistically** — how does this interact with the rest of the system?
- **Pause in interactive mode** — never proceed without user confirmation
