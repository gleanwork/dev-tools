# dev-tools

Developer productivity tools for AI-assisted workflows: an agent skill and slash commands for PR lifecycle management, a PR dashboard, and shell scripts for worktree management and disk cleanup.

## What's here

### [`skills/`](skills/)

Agent skills in the cross-tool `SKILL.md` format (Claude Code, Codex, Cursor, Glean Tau). Copy a skill directory into `~/.claude/skills/`, `~/.agents/skills/`, or your agent's equivalent.

| Skill | What it does |
|-------|-------------|
| [`pr`](skills/pr/) | Full PR lifecycle for many parallel changes: `start pr`, `focus pr`, `park pr`, `raise pr`, `fix pr`, `fix all`, `ls pr`, `clean pr`. Branch-scoped sparse worktrees, a pre-raise review checklist, three-source comment handling, stacked-PR fixing, and an approval gate before every mutation. Ships with a provider sweep script and a 103-check conformance test. |

### [`commands/`](commands/)

Markdown instructions that AI coding agents (Cursor, Claude Code) execute as slash commands. Drop them into your project's `.cursor/commands/`, `.codeagent/commands/`, or equivalent. This is the older, explicit-invocation format; the `pr` skill above supersedes the `/pr` commands for agents that load skills.

| Command | What it does |
|---------|-------------|
| [`/pr create`](commands/pr-create.md) | Cherry-pick commits into a clean PR branch, auto-name, resolve reviewers by first name, run pre-commit, babysit until green |
| [`/pr review`](commands/pr-review.md) | Walk through a PR file-by-file (ordered for understanding), post inline comments with approval gate |
| [`/pr fix`](commands/pr-fix.md) | Find CI failures, diagnose, fix, push, test locally in parallel, iterate until green |
| [`/pr comments`](commands/pr-comments.md) | Go through reviewer comments one-by-one, propose fixes, wait for approval before applying and replying |
| [`/pr skeleton`](commands/pr-skeleton.md) | Extract a ~10% architectural skeleton of large PRs for reviewers |
| [`/git mergetool`](commands/git-mergetool.md) | Resolve merge conflicts by analyzing who changed what from base, using timeline-based reasoning |

### [`scripts/`](scripts/)

Standalone tools you run directly.

| Script | What it does |
|--------|-------------|
| [`pr-dash.py`](scripts/pr-dash.py) | Local PR dashboard and inbox — tracks PRs, reviews owed, worktree status, CI state across one or more repos. Flask app with vim keys; GitHub-quota aware. |
| [`freespace.sh`](scripts/freespace.sh) | macOS disk space cleanup — build caches, app/Electron/browser caches, linked-worktree Bazel output bases, stale temp files, Colima VM disk, git gc. Safe mode + deep clean (`-f`: Docker, simulators, toolchains, `node_modules`). |
| [`sparse-branch.sh`](scripts/sparse-branch.sh) | Create sparse-checkout worktrees. `--sparse`, `--min`, `--full`; `--min` on an existing branch checks out only the directories the branch changes. Multiple names in parallel, `--base`, `--prefix`. |
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

### Skill (for Claude Code / Codex / Cursor / Glean Tau)

```bash
cp -r skills/pr ~/.claude/skills/pr      # Claude Code
cp -r skills/pr ~/.agents/skills/pr      # Codex and others

# Then in your AI agent:
# start pr add a retry to the upload client
# raise pr
# fix all
```

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
scripts/sparse-branch.sh my-feature   # create sparse worktree
scripts/sparse-branch.sh --min my-branch   # branch-scoped checkout of an existing branch
scripts/sparse-branch.sh feat-a feat-b feat-c   # create several in parallel
scripts/extract.sh my-fix "Fix the bug" HEAD   # extract commit to PR
```

## Dependencies

- **Skills**: Any AI coding agent that loads `SKILL.md` directories (Claude Code, Codex, Cursor, Glean Tau); `gh`, `git`, Python 3
- **Commands**: Any AI coding agent that supports markdown command files (Cursor, Claude Code)
- **pr-dash.py**: Python 3, Flask, `gh` (GitHub CLI), `git`
- **Shell scripts**: `gh`, `git`, `pre-commit` (for extract.sh)

## Customization

Every project-specific path is an environment variable; nothing needs editing in place.

### freespace.sh

- `FREESPACE_MAIN_WORKSPACE` — repo root whose Bazel output base and `node_modules` are preserved (defaults to the git toplevel)
- `BAZEL_ROOT` — legacy bazel output-base root (defaults to `/private/var/tmp/_bazel_$USER`)
- `PROJECT_CACHE_DIRS` — space-separated dirs relative to each checkout to delete (e.g. a local search index)
- `LOG_TRUNCATE_DIRS` — space-separated dirs whose `*.log` files over `LOG_TRUNCATE_THRESHOLD_KB` (default 100 MB) get truncated in place

### sparse-branch.sh

- `SPARSE_PATTERNS_FILE` — path to a custom sparse-checkout patterns file
- `SPARSE_SUPPORT_DIRS` — directories always included in `--min` and branch-scoped checkouts (default `.github`)
- `SPARSE_EXTRA_PATHS` — space-separated paths your pre-commit hooks need
- `SPARSE_SYMLINK_DIRS` — directories to symlink from the main worktree (e.g., virtualenvs, build caches)

### pr-dash.py and sweep.py

- `PR_DASH_REPOS` — extra repos to aggregate; `PR_DASH_BOTS` / `PR_SWEEP_EXTRA_BOTS` — your org's review-bot logins

## Upstream

These tools are maintained in Glean's internal monorepo and synced here with project-specific paths generalized. [`SYNC.md`](SYNC.md) records the path map and the generalization rules.

## License

Apache 2.0
