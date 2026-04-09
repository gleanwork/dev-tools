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
| [`freespace.sh`](scripts/freespace.sh) | macOS disk space cleanup — build caches, app caches, system temp, git gc. Safe mode + deep clean (`-f`). |
| [`sparse-branch.sh`](scripts/sparse-branch.sh) | Create sparse-checkout worktrees (~500MB instead of ~1.5GB). Three modes: `--sparse`, `--min`, `--full`. |
| [`extract.sh`](scripts/extract.sh) | Extract commits or files to a new branch and create a PR in one shot. |
| [`make-pr.sh`](scripts/make-pr.sh) | Create or update a draft PR from the current branch. |

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
scripts/freespace.sh        # clean disk (dry run: -n)
scripts/sparse-branch.sh my-feature   # create sparse worktree
scripts/extract.sh my-fix "Fix the bug" HEAD   # extract commit to PR
```

## Dependencies

- **Commands**: Any AI coding agent that supports markdown command files (Cursor, Claude Code)
- **pr-dash.py**: Python 3, Flask, `gh` (GitHub CLI), `git`
- **Shell scripts**: `gh`, `git`, `pre-commit` (for extract.sh)

## Customization

### freespace.sh

Set `MAIN_WORKSPACE` to your repo root (defaults to `git rev-parse --show-toplevel`). The script has clearly marked sections for project-specific paths — search for "Add project-specific" comments.

### sparse-branch.sh

- `SPARSE_PATTERNS_FILE` — path to a custom sparse-checkout patterns file
- `SPARSE_EXTRA_PATHS` — space-separated paths your pre-commit hooks need
- `SPARSE_SYMLINK_DIRS` — directories to symlink from the main worktree (e.g., virtualenvs, build caches)

## License

Apache 2.0
