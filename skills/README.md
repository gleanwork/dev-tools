# Agent Skills

Skills in the cross-tool `SKILL.md` format: a directory with a `SKILL.md` playbook plus optional
`references/`, `tools/`, and `tests/`. Supported by Claude Code, Codex, Cursor, Glean Tau, and other
agents that load `SKILL.md` directories. Unlike the slash commands in [`../commands/`](../commands/),
a skill is loaded by the agent when the task matches its description, so one install covers every
entry point.

## `pr/`

Full PR lifecycle for working on many changes in parallel, with the primary checkout and small
sparse worktrees treated as interchangeable homes for a branch:

| Command | What it does |
|---------|-------------|
| `start pr REQUEST` | Start a new branch for a request, asking one plain-language question about where it should live |
| `focus pr` / `park pr` | Move a branch into the primary checkout, or out to a branch-scoped sparse worktree |
| `raise pr` | Commit, push, create or update the PR; runs the [pre-raise review](pr/references/pre-raise-review.md) first |
| `fix pr` | Inspect mergeability, review comments (inline, PR-level, and review bodies), and CI; fix with an approval gate; reply to each addressed comment after the push |
| `fix all` | Continuous non-blocking pipeline over your open ready PRs; stacked PRs are fixed root-first and rebased down |
| `ls pr` / `clean pr` | Read-only inventory; reclaim finished checkouts without touching branches or unpushed work |

Safety boundaries: never merges, never force-removes a worktree, never rewrites history without
the approval gate, and asks exactly one question before any branch or worktree move.

[`pr/tools/sweep.py`](pr/tools/sweep.py) is the read-only provider sweep `fix all` uses
(`gh api` REST only). [`pr/tests/prSkillConformance.mjs`](pr/tests/prSkillConformance.mjs) checks the
playbook's dialog structure and invariants: `node skills/pr/tests/prSkillConformance.mjs`.

## Install

```bash
# Claude Code (personal) — or .claude/skills/ inside a project
cp -r skills/pr ~/.claude/skills/pr

# Codex / agents that read ~/.agents/skills
cp -r skills/pr ~/.agents/skills/pr

# Glean Tau
cp -r skills/pr ~/.glean/agent/skills/pr
```

Cursor: copy into `.cursor/skills/pr/` in the project.

## Configuration

| Variable | Used by | Meaning |
|----------|---------|---------|
| `PR_SWEEP_EXTRA_BOTS` | `sweep.py` | Comma-separated extra review-bot logins whose comments may be fixed automatically (any `*[bot]` login is already included) |

## Requirements

`git`, `gh` (authenticated), Python 3 for `sweep.py`, Node 18+ for the conformance test.
