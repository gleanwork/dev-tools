---
alwaysApply: true
---
# Distillation moments — watch and suggest

Watch for moments where hard-won session context is about to be lost. At the end of a
substantial session (or before a risky change), **suggest** capturing it via
`/distill <type>`. Suggest only — never auto-write a doc.

Trigger signals (examples — also flag anything analogous not listed):

| signal in the session | suggest |
|---|---|
| mapped how a subsystem works across many files | `/distill system` |
| branch is many commits deep; PRs will need extracting | `/distill pr-plan` |
| about to make a risky change with regression history | `/distill revert-list` |
| failure is probabilistic; compared a good run vs a bad run | `/distill trace-diff` |
| deferred work / "do later" surfaced mid-task | `/distill followups` |
| found a repeatable way to diagnose a failure class | `/distill debug-playbook` |
| anything else future-you or the model will want as grounding | `/distill other <topic>` |

Before suggesting, scan the relevant docs folder (`docs/<area>/` or
`design_docs/<area>/`: list `*.md`, read their top headings): if a fitting doc exists,
suggest updating it instead of creating a new one. Keep the nudge to one line; do not
interrupt active work to make it.
