# dev-tools

Developer productivity tools for AI-assisted workflows: agent commands for PR lifecycle management, a PR dashboard, and shell scripts for worktree management and disk cleanup.

## What's here

### [`commands/`](commands/)

Markdown instructions that AI coding agents (Cursor, Claude Code) execute as slash commands. Drop them into your project's `.cursor/commands/`, `.codeagent/commands/`, or equivalent.

| Command | What it does |
|---------|-------------|
| [`/pr create`](commands/pr-create.md) | Cherry-pick commits into a clean PR branch, auto-name, resolve reviewers by first name, run pre-commit |
| [`/pr review`](commands/pr-review.md) | Walk through a PR file-by-file (ordered for understanding), post inline comments with approval gate |
| [`/pr fix`](commands/pr-fix.md) | Find CI failures, diagnose, fix, push, test locally in parallel, iterate until green |
| [`/pr comments`](commands/pr-comments.md) | Go through reviewer comments one-by-one, propose fixes, wait for approval before applying and replying |
| [`/pr skeleton`](commands/pr-skeleton.md) | Extract a ~10% architectural skeleton of large PRs for reviewers |
| [`/git mergetool`](commands/git-mergetool.md) | Resolve merge conflicts by analyzing who changed what from base, using timeline-based reasoning |

### [`scripts/`](scripts/)

Standalone tools you run directly.

| Script | What it does |
|--------|-------------|
| [`pr-dash.py`](scripts/pr-dash.py) | Local PR dashboard and inbox — tracks PRs, reviews owed, worktree status, CI state. Flask app with vim keys. |
| [`freespace.sh`](scripts/freespace.sh) | macOS disk space cleanup — build caches, app/Electron/browser caches, stale bazel output bases, Colima VM disk, system temp, git gc. Safe mode + deep clean (`-f`) + `--stale-days N`. |
| [`sparse-branch.sh`](scripts/sparse-branch.sh) | Create sparse-checkout worktrees. Three modes: `--sparse`, `--min`, `--full`. Accepts multiple names (created in parallel) and `--base`. |
| [`extract.sh`](scripts/extract.sh) | Extract commits or files to a new branch and create a PR in one shot. |
| [`make-pr.sh`](scripts/make-pr.sh) | Create or update a draft PR from the current branch. |

### [`distill/`](distill/)

A small system that watches your coding sessions and suggests when to capture a reusable doc for your AI — a command + an always-on rule + a `stop` hook. Suggest-only.

| Piece | What it does |
|-------|-------------|
| [`commands/distill.md`](distill/commands/distill.md) | The writer: a doc-type catalog (system, pr-plan, revert-list, trace-diff, followups, …) + templates |
| [`rules/distillation.md`](distill/rules/distillation.md) | Always-on: watches the session and suggests `/distill <type>` at the right moment |
| [`hooks/distill-detect.sh`](distill/hooks/distill-detect.sh) | Deterministic backstop: nudges toward a pr-plan when a branch drifts too far ahead of base |

## Quick start

### Commands (for Cursor / Claude Code)

```bash
# Copy to your project
cp commands/*.md your-project/.cursor/commands/
# or
cp commands/*.md your-project/.codeagent/commands/

# Then in your AI agent:
# /pr create
# /pr review 12345
# /pr fix
```

### PR Dashboard

```bash
pip install flask
python scripts/pr-dash.py
# Open http://127.0.0.1:8765
```

### Scripts

```bash
# Add to PATH or run directly
scripts/freespace.sh             # clean disk (dry run: -n, deep clean: -f)
scripts/freespace.sh --stale-days 0   # also drop every non-main bazel output base
scripts/sparse-branch.sh my-feature   # create sparse worktree
scripts/sparse-branch.sh feat-a feat-b feat-c   # create several in parallel
scripts/extract.sh my-fix "Fix the bug" HEAD   # extract commit to PR
```

## Dependencies

- **Commands**: Any AI coding agent that supports markdown command files (Cursor, Claude Code)
- **pr-dash.py**: Python 3, Flask, `gh` (GitHub CLI), `git`
- **Shell scripts**: `gh`, `git`, `pre-commit` (for extract.sh)

## Customization

### freespace.sh

Set `MAIN_WORKSPACE` to your repo root (defaults to `git rev-parse --show-toplevel`). The script has clearly marked sections for project-specific paths — search for "Add project-specific" comments.

- `BAZEL_ROOT` — bazel output-base root (defaults to `/private/var/tmp/_bazel_$USER`)
- `--stale-days N` — drop non-main bazel output bases untouched for N+ days (default 3); `--stale-days 0` drops every non-main base (emergency mode, keeps the shared disk cache)
- `LOG_TRUNCATE_DIRS` — space-separated dirs whose `*.log` files over `LOG_TRUNCATE_THRESHOLD_KB` (default 100 MB) get truncated in place

### sparse-branch.sh

- `SPARSE_PATTERNS_FILE` — path to a custom sparse-checkout patterns file
- `SPARSE_EXTRA_PATHS` — space-separated paths your pre-commit hooks need
- `SPARSE_SYMLINK_DIRS` — directories to symlink from the main worktree (e.g., virtualenvs, build caches)

## License

Apache 2.0
