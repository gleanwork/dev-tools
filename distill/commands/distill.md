# /distill — capture a working-knowledge doc

Turn hard-won session context into a curated, reusable doc: readable enough for a
human to trust, dense enough to hand back to the model as grounding so it stays
anchored in reality instead of hallucinating.

Usage:
- `/distill` — infer the most fitting type from the session, propose it, then write
- `/distill <type>` — write a specific type (see catalog)
- `/distill other <topic>` — open-ended: anything worth offloading that the catalog
  doesn't name

**Suggest, never auto-write.** Propose the doc and the target path; write only after
the user agrees. Taste (is this moment worth a doc?) stays with the user.

## Doc store + naming

Codebase-anchored docs live next to their subsystem in your docs folder
(`docs/<area>/` or `design_docs/<area>/`). Cross-cutting/personal docs live in `~/`.
Match the existing naming in the target folder. Suggested conventions:

- `<topic>_pr_plan.md` — e.g. `auth_pr_plan.md`
- `<topic>_revert_candidates.md` — e.g. `cache_revert_candidates.md`
- `<topic>_followups.md` — e.g. `api_followups.md`

Before writing, scan the target folder (list `*.md` and read their top headings) and
**prefer updating an existing doc over creating a near-duplicate.**

## The two-audience standard

Each doc starts auto-extracted (from code, logs, traces, the session), then gets
iterated until it works two ways at once: curated/scannable for a human, and dense
factual context for the model. Verify every specific claim (numbers, file paths,
symbols) against source — do not ship fabricated specifics.

## Catalog

| type | capture when | filename | core content |
|---|---|---|---|
| `system` | you just mapped how a subsystem actually works | `<area>/<topic>.md` | data flow, components, entry points, invariants, gotchas, file refs |
| `pr-plan` | a branch is many commits deep and PRs must be extracted | `<topic>_pr_plan.md` | per-PR row: source commit → title/desc + log/timing evidence; discard/revert list |
| `revert-list` | about to make a risky change with regression history | `<topic>_revert_candidates.md` | ranked suspects to revert if regressions appear, for binary search |
| `trace-diff` | a failure is probabilistic (works sometimes) | `<topic>_trace_analysis.md` | good run vs bad run lined up step-by-step; root-cause + recs |
| `followups` | deferred work surfaced mid-task | `<topic>_followups.md` | self-contained items, each citing origin PR/review, enough context to act later |
| `debug-playbook` | you found a repeatable way to diagnose a failure class | `<topic>_debugging.md` | exact commands, failure signatures, what "healthy" looks like |
| `code-map` | the model keeps grepping blindly across a large feature | `<area>/code_locations.md` | inventory of where everything lives across languages |
| `eval-probe` | you need to measure a probabilistic model behavior | `<topic>_probe.md` | how to build the probe, scenarios, one-variable-per-iteration method |
| `other <topic>` | none of the above, but future-you/AI will want this context | infer from folder | whatever distills the hard-won understanding; pick a clear structure |

### Templates

Keep templates as scaffolds, not forms — drop sections that don't apply.

`pr-plan`:
```
# <topic> — PR plan
Working doc to extract PRs from <branch>. Source commits:
| commit | summary | PR |
**Not for PR — discard/revert before raising:** <temp/diagnostic commits>
## Background (shared context)
## PR N — <title>  (source, cleanliness, description, impact, test plan)
## Suggested order & dependencies
## Follow-ups (separate issues)
```

`revert-list`:
```
# <change> — revert candidates
Context: <what changed, why regressions are feared>. To binary-search a regression,
revert in this order (most-likely first):
1. <commit/hunk> — <why suspect> — <how to revert> — <what it costs>
```

`trace-diff`:
```
# <topic>: <good> vs <bad>
## Session identifiers  (ids, tokens, instances)
## Timeline — <good run>   /   ## Timeline — <bad run>
## Key differences
## Root cause analysis
## Recommendations
```

`followups`:
```
# <area> — follow-ups
Add items as they come up; each must be self-contained enough to pick up later.
## N. <title>
**Status:** … · **Priority:** … · **Origin:** <PR/review link>
### Problem  /  ### Proposed fix
```
