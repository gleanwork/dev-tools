# Scripts

Standalone developer tools. Run directly from the command line.

## pr-dash.py

Local PR dashboard and inbox. Aggregates your PRs, reviews you owe, and worktree status into a single web view, across one or more repos.

```bash
pip install flask
python pr-dash.py              # http://127.0.0.1:8765
python pr-dash.py --port 9000  # custom port
```

**Features:**
- Reviews you owe float to the top
- Color-coded reviewer status (approved / pending / commented); bot reviewers hidden
- Worktree status: dirty files, unpushed commits, merge conflict warnings
- CI status with links; running checks are polled every 15 s, settled ones cached
- Multi-repo: the current repo plus any listed in `PR_DASH_REPOS`
- GitHub quota aware: GraphQL batching, REST fallbacks, and a cooldown after a rate-limit response
- Incremental search, vim-style key bindings

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `PR_DASH_REPOS` | *(empty)* | Comma-separated extra repos, each `owner/name` or `owner/name=/path/to/checkout` |
| `PR_DASH_BOTS` | *(empty)* | Comma-separated extra bot logins to hide (any `*[bot]`, `*-bot`, `*-ci` login is already a bot) |
| `PR_DASH_DEBUG` | `0` | Verbose logging |
| `PR_DASH_CMD_TIMEOUT` | `30` | Per-command timeout (seconds) |
| `PR_DASH_BATCH_SIZE` | `15` | Branches per GraphQL batch |
| `PR_DASH_PARALLEL` | `4` | Parallel batch workers |
| `PR_DASH_RATE_LIMIT_COOLDOWN` | `900` | Seconds without GitHub calls after a rate-limit response |

**Requires:** Python 3, Flask, `gh` (GitHub CLI), `git`

## freespace.sh

macOS disk space cleanup. Safe mode by default, deep clean with `-f`.

```bash
./freespace.sh        # safe mode: build caches, app caches, system temp, git gc, secondary-worktree Bazel bases
./freespace.sh -f     # deep clean: + Docker, iOS/Android simulators, toolchains, node_modules, virtualenvs
./freespace.sh -n     # dry run: preview everything without deleting (-nf for a deep-clean preview)
```

Safe mode cleans build caches (`.swc`, `.next`, `.turbo`, `__pycache__`, …) in every primary checkout and linked worktree, non-symlinked `node_modules` in secondary worktrees, Electron/browser/app caches, stale `/tmp` and `~/Library/Caches` files, Bazel output bases of linked worktrees and of interrupted expunges, and runs `git gc`. Deep clean adds Docker/Colima, unused iOS runtimes and Android emulators, mise/rustup toolchains, and the main-checkout `node_modules`.

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `FREESPACE_MAIN_WORKSPACE` | auto (git toplevel) | Repo root whose Bazel output base and `node_modules` are preserved |
| `FREESPACE_WORKTREE_PARENT` | `~/workspace` | Where linked worktrees live |
| `BAZEL_ROOT` | `/private/var/tmp/_bazel_$USER` | Legacy Bazel output root |
| `PROJECT_CACHE_DIRS` | *(empty)* | Space-separated dirs relative to each checkout to delete (e.g. a local search index) |
| `LOG_TRUNCATE_DIRS` | *(empty)* | Space-separated dirs whose `*.log` files over the threshold are truncated in place |
| `LOG_TRUNCATE_THRESHOLD_KB` | `102400` | Truncation threshold (100 MB) |

## sparse-branch.sh

Create sparse-checkout worktrees for fast, small branch checkouts. Several names are created in parallel after one shared fetch.

```bash
./sparse-branch.sh my-feature                # sparse worktree at ../my-feature
./sparse-branch.sh feat-a feat-b feat-c      # several, in parallel
./sparse-branch.sh --full my-feature         # full checkout
./sparse-branch.sh --min my-feature          # minimal: root files + support dirs
./sparse-branch.sh --min existing-branch     # branch-scoped: only the dirs the branch changes vs base
./sparse-branch.sh --base origin/release my-fix
./sparse-branch.sh --prefix team/ my-feature # branch team/my-feature
./sparse-branch.sh --update my-feature       # refresh symlinks in an existing worktree
```

Derives the branch prefix from your git username (`Jane Doe` → `jd/my-feature`) unless `--prefix` is given or the name already contains `/`. The base defaults to `origin/HEAD`, then `main`/`master`. `node_modules` is symlinked from the main worktree when present.

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `SPARSE_PATTERNS_FILE` | everything except `node_modules`/`.git` | Sparse-checkout patterns for `--sparse` mode |
| `SPARSE_SUPPORT_DIRS` | `.github` | Dirs always included in `--min` and branch-scoped checkouts (agent rules, hook helpers) |
| `SPARSE_EXTRA_PATHS` | *(empty)* | Paths added after a `--sparse` checkout (lint configs your hooks need) |
| `SPARSE_SYMLINK_DIRS` | *(empty)* | Paths to symlink from the main worktree (virtualenvs, build caches) |

Branch-scoped `--min` requires `git config extensions.worktreeConfig true`.

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

Creates a sparse worktree via `sparse-branch.sh`, cherry-picks commits (or copies files), runs pre-commit, pushes, and opens a draft PR via `make-pr.sh`. Idempotent — can be re-run safely. The first commit's body is inserted into the PR description under `PR_BODY_MARKER` (default `**Description**:`). `BRANCH_PREFIX` overrides the initials-derived prefix.

## make-pr.sh

Create or update a draft PR from the current branch.

```bash
./make-pr.sh "[search] Add conversation loader"
```

If a PR already exists for the branch, updates the title. Otherwise creates a new draft PR using your project's PR template.
