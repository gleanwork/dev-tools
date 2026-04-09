# Scripts

Standalone developer tools. Run directly from the command line.

## pr-dash.py

Local PR dashboard and inbox. Aggregates your PRs, reviews you owe, and worktree status into a single web view.

```bash
pip install flask
python pr-dash.py          # http://127.0.0.1:8765
python pr-dash.py -p 9000  # custom port
```

**Features:**
- Reviews you owe float to the top
- Color-coded reviewer status (approved / pending / commented)
- Worktree status: dirty files, unpushed commits, merge conflict warnings
- CI status with links (spinner when running, X when failed)
- Adaptive refresh (1 min active, 10 min idle)
- Incremental search, vim-style key bindings
- Batched GraphQL calls for speed with many PRs

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `PR_DASH_DEBUG` | `0` | Verbose logging |
| `PR_DASH_CMD_TIMEOUT` | `30` | Per-command timeout (seconds) |
| `PR_DASH_BATCH_SIZE` | `15` | Branches per GraphQL batch |
| `PR_DASH_PARALLEL` | `4` | Parallel batch workers |

**Requires:** Python 3, Flask, `gh` (GitHub CLI), `git`

## freespace.sh

macOS disk space cleanup. Two modes:

```bash
./freespace.sh        # safe mode: build caches, app caches, system temp, git gc
./freespace.sh -f     # deep clean: + Docker, node_modules, virtualenvs, go modcache
./freespace.sh -n     # dry run: preview everything without deleting
```

Cleans build caches (.swc, .next, .turbo, __pycache__), app caches (Cursor, VSCode, Chrome, Homebrew, pip, pnpm, ...), system temp, git gc, and more. Customizable via `MAIN_WORKSPACE` env var and inline comments.

## sparse-branch.sh

Create sparse-checkout worktrees for faster branch creation.

```bash
./sparse-branch.sh my-feature              # sparse worktree at ../my-feature
./sparse-branch.sh --full my-feature       # full checkout (~1.5GB)
./sparse-branch.sh --min my-feature        # minimal (~5MB, root files only)
./sparse-branch.sh --update my-feature     # update existing worktree symlinks
```

Derives branch prefix from your git username (e.g., "Jane Doe" → `jd/my-feature`). Symlinks `node_modules` from the main worktree to save disk. Customizable sparse patterns via `SPARSE_PATTERNS_FILE` env var.

## extract.sh

Extract commits or files to a new branch and create a PR.

```bash
./extract.sh my-feature                           # HEAD → draft PR
./extract.sh my-feature "PR title"                # HEAD with custom title
./extract.sh my-feature "" HEAD~3..HEAD           # last 3 commits
./extract.sh my-feature "" abc1234 def5678        # specific commits
./extract.sh my-fix "fix bug" path/to/file.ts     # file copy mode
./extract.sh --min trivial-fix                    # skip pre-commit (fast)
```

Creates a sparse worktree via `sparse-branch.sh`, cherry-picks commits (or copies files), runs pre-commit, pushes, and opens a draft PR via `make-pr.sh`. Idempotent — can be re-run safely.

## make-pr.sh

Create or update a draft PR from the current branch.

```bash
./make-pr.sh "[search] Add conversation loader"
```

If a PR already exists for the branch, updates the title. Otherwise creates a new draft PR using your project's PR template.
