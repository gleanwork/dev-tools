# Syncing with upstream

The scripts and the `pr` skill are generalized copies of tools that are maintained privately and
synced here. This file records which pieces have an upstream and what gets rewritten on the way out,
so a re-sync is mechanical and nothing project-specific leaks.

## What has an upstream

| Here | Status |
|------|--------|
| `scripts/` (all five) | active upstream; synced from its default branch |
| `skills/pr/` | active upstream; synced from its HEAD |
| `commands/` | upstream removed 2026-09 (superseded by the skill); this repo is the only home |
| `distill/` | this repo is the only home |

Last sync: 2026-10-22.

## Procedure

1. Copy the upstream file over the local one.
2. Apply the generalization rules below. Afterwards grep the file for the upstream project's name,
   repo names, internal directory names, people, and the maintainer's branch prefix. The only
   acceptable product-name hit is the "Glean" desktop app in `freespace.sh`'s Electron-cache list.
3. `bash -n` every shell script; `python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())'`
   for Python; `node skills/pr/tests/prSkillConformance.mjs` for the skill.
4. Update the relevant README for new flags or variables.
5. Update "Last sync" above.

## Generalization rules

### All files
- Project paths, branch prefixes (`si/`), people's names, and product names in examples become
  neutral ones (`jd/`, `Jane Doe`, `[search]`, `api.proto`).
- References to internal rule files, slash commands, or onboarding scripts become "your
  project's ..." or the behavior they stand for, inline.

### `freespace.sh`
- `BAZEL_ROOT` overridable via environment.
- Project cache dirs inside a checkout → `PROJECT_CACHE_DIRS` (space-separated, relative).
- Service-log truncation of a fixed directory → `LOG_TRUNCATE_DIRS` / `LOG_TRUNCATE_THRESHOLD_KB`.
- `__pycache__` scan covers the whole checkout, pruning `node_modules`, `.git`, `venv`, `.venv`.
- Project-only post-cleanup steps (e.g. generated-stub fixes) are dropped.

### `sparse-branch.sh`
- Hard-coded support directories → `SPARSE_SUPPORT_DIRS` (default `.github`), used by both the
  `--min` pattern block and the branch-scoped Python helper.
- The sparse pattern heredoc → `SPARSE_PATTERNS_FILE`, with an "everything except
  `node_modules`/`.git`" default.
- Pre-commit dependency `sparse-checkout add` list → `SPARSE_EXTRA_PATHS`.
- Per-project symlinks (virtualenv, build caches, bazel entries) → `SPARSE_SYMLINK_DIRS`;
  `node_modules` stays always-on.
- Agent-rules directory scan recognizes `.codeagent`, `.cursor`, `.claude`, `.agents`.

### `extract.sh`, `make-pr.sh`
- Branch prefix derived from `git config user.name`, overridable with `BRANCH_PREFIX`.
- Commit-body insertion marker → `PR_BODY_MARKER` (default `**Description**:`).
- `main_workspace` from `git rev-parse --show-toplevel`, not the script's location.
- Org-specific protected-branch patterns removed from the `master`/`main` guard.

### `pr-dash.py`
- `_DEFAULT_EXTRA_REPOS` is empty; `PR_DASH_REPOS` adds repos.
- Org review bots leave `known_bots`; `PR_DASH_BOTS` adds them back per install.

### `skills/pr/`
- Host-specific frontmatter (`x_*` metadata, `user-invocable`) dropped; keep `name`,
  `description`, `disable-model-invocation`.
- Host tool names stay as examples only ("for example `ask_clarifying_question`"); a named host
  appears only when describing a documented host behavior (asset path resolution).
- Asset path list includes `~/.agents/skills`, `~/.glean/agent/skills`, `~/.claude/skills`.
- Project-specific examples in `references/pre-raise-review.md` neutralized.
- `tools/sweep.py` bot list: org bots → `PR_SWEEP_EXTRA_BOTS`.
- The conformance test must still pass; update it when the skill text it asserts on is
  intentionally reworded.
