# distill — capture working knowledge for your AI

A small system that watches your coding sessions and, at the right moment, suggests
turning what you just figured out into a reusable doc: readable enough for a teammate,
dense enough to hand back to the model as grounding so it stays anchored in reality
instead of hallucinating.

It's three coupled pieces:

| piece | file | role |
|---|---|---|
| **rule** | [`rules/distillation.md`](rules/distillation.md) | always-on; watches the session and *suggests* `/distill <type>` at the right moment, including patterns it hasn't seen before |
| **command** | [`commands/distill.md`](commands/distill.md) | the writer; a doc-type catalog + templates so captured docs land in the right place and format |
| **hook** | [`hooks/distill-detect.sh`](hooks/distill-detect.sh) | a deterministic backstop: a `stop` hook that nudges toward a `pr-plan` when a branch drifts too far ahead of the base branch |

Everything is **suggest-only** — it proposes, you decide. Taste (is this moment worth a
doc?) stays with you.

## The doc types it captures

| type | capture when |
|---|---|
| `system` | you just mapped how a subsystem actually works |
| `pr-plan` | a branch is many commits deep and PRs must be extracted |
| `revert-list` | about to make a risky change with regression history |
| `trace-diff` | a failure is probabilistic (works sometimes) |
| `followups` | deferred work surfaced mid-task |
| `debug-playbook` | you found a repeatable way to diagnose a failure class |
| `code-map` | the model keeps grepping blindly across a large feature |
| `eval-probe` | you need to measure a probabilistic model behavior |
| `other <topic>` | none of the above, but future-you/AI will want this context |

## Install (Cursor)

```bash
# run from your project root, with this repo checked out alongside it
cp path/to/distill/commands/distill.md      .cursor/commands/
cp path/to/distill/rules/distillation.md    .cursor/rules/distillation.mdc
cp path/to/distill/hooks/distill-detect.sh  .cursor/hooks/
chmod +x .cursor/hooks/distill-detect.sh
# then merge hooks/hooks.json into your .cursor/hooks.json (add the "stop" entry)
```

Claude Code: put `distill.md` in `.codeagent/commands/` (or `.claude/commands/`) and
`distillation.md` in your rules directory. The hook reads `cwd` too, but emits Cursor's
`followup_message`; for Claude's `stop` format, swap the final line to
`{"decision":"block","reason":"<msg>"}`.

## How the hook behaves

- **Deterministic + suggest-only.** It never writes; it returns a one-line suggestion.
- **Throttled.** At most once per branch per `DISTILL_THROTTLE` seconds (default 24h).
- **Self-silencing.** If you've modified a `*_pr_plan.md` within `DISTILL_PLAN_FRESH_DAYS`
  (default 7), it stays quiet — you're already on it.
- **Fails open.** Any error just exits without blocking your turn.

## Tuning (env vars)

| var | default | meaning |
|---|---|---|
| `DISTILL_AHEAD_THRESHOLD` | `12` | commits ahead of base before it nudges |
| `DISTILL_THROTTLE` | `86400` | min seconds between nudges per branch |
| `DISTILL_PLAN_FRESH_DAYS` | `7` | recent-pr-plan window that silences it |
| `DISTILL_DOC_ROOT` | `design_docs` | docs folder it scans for plans |
| `DISTILL_BASE_BRANCH` | auto | base branch (else `origin/HEAD`, then `main`/`master`) |

## Requirements

`git` and `jq` on PATH (for the hook). The command and rule work with any agent that
supports markdown command/rule files.
