# AI Agent Commands

Markdown command files for AI coding agents (Cursor, Claude Code). Each file describes a workflow the agent executes when you invoke the corresponding slash command.

## Installation

Copy into your project's command directory:

```bash
cp *.md your-project/.cursor/commands/
# or
cp *.md your-project/.codeagent/commands/
```

## PR Workflow

The `/pr` commands cover the full PR lifecycle:

```
Create  ──→  Review  ──→  Fix CI  ──→  Address Comments  ──→  Merge
  │            │            │              │
  └ pr-create  └ pr-review  └ pr-fix       └ pr-comments
```

[`pr.md`](pr.md) is the router — it dispatches to the appropriate subcommand based on your input.

### `/pr create [--here|--wt] [args...]`

Cherry-pick commits into a clean branch, push, and open a PR. Supports three modes:
- **Default**: cherry-pick onto a fresh `origin/master` branch
- **`--wt`**: same, but in a temporary worktree (main checkout untouched)
- **`--here`**: push the current branch as-is

### `/pr review [pr_number] [-i]`

Code review with an approval gate — the agent never posts comments without your explicit OK.
- **Noninteractive** (default): reviews all files, presents a categorized report, then asks to post
- **Interactive** (`-i`): walks through file-by-file, pausing after each

### `/pr fix [pr_number | ci_url]`

Automated CI failure diagnosis and fixing. Identifies the failure type (build, test, lint, infra), applies the fix, pushes, tests locally in parallel, and iterates until green.

### `/pr comments [pr_number]`

Walks through unaddressed reviewer comments one at a time. For each: shows comment + context, proposes a fix, waits for approval (`yes` / `do` / `skip` / custom reply), applies and responds.

### `/pr skeleton [branch]`

Extracts a ~10% architectural skeleton of large PRs. Strips boilerplate from new code to reveal key decisions, risks, and control flow. Creates a separate non-mergeable PR linked bidirectionally.

## Git Workflow

### `/git mergetool`

Intelligent merge conflict resolution that analyzes file history from both branches. Instead of comparing end states, it reconstructs the timeline of changes and resolves based on direction of change (who actually modified what from the common ancestor).
