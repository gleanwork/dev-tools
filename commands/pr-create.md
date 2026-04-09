# /pr create — cherry-pick to PR

Usage: `/pr create [--here|--wt] [args...]` where each arg is either a commit hash or a reviewer name

Goal: create a clean PR branch off master from cherry-picked commits, run checks, and open a draft PR. No confirm, just do when steps are unambiguous. Pause on cherry-pick conflicts or ambiguous reviewer matches.

## Modes

**Cherry-pick mode** (default): creates a new branch off master, cherry-picks commits, pushes, and opens PR. Operates in the current checkout.

**Worktree mode** (`--wt`): same as cherry-pick mode, but creates a temporary worktree via `sparse-branch.sh` (see `scripts/`) so the main checkout is never touched. Multiple `--wt` calls can run in parallel since each gets its own worktree. Worktree is removed on success.

**Direct mode** (`--here`): pushes the current branch as-is and opens a PR from it. Use from worktrees or purpose-built branches where the branch itself is the PR.

### `--here` constraints
- Commit hash args are **incompatible** with `--here` — error out. If you want to select specific commits, drop `--here`.
- Refuse if on `master` or `main`.
- If a PR already exists for this branch (`gh pr list --head <branch>`), warn and print the existing PR URL instead of creating a duplicate.

### `--wt` constraints
- `--here` and `--wt` are **mutually exclusive** — error out if both specified.

## Argument parsing

Classify each arg by shape, not position:
- `--here` → enable direct mode
- `--wt` → enable worktree mode
- Hex-only string (7-40 chars, `^[0-9a-f]{7,40}$`) → commit hash candidate. Validate with `git rev-parse --verify`; if it fails, reclassify as a reviewer name
- Everything else → reviewer name (first name, last name, or GitHub handle substring)
- No args at all → cherry-pick `HEAD`, no reviewers

## 1. Resolve commits and reviewers

Runs in the main checkout — no directory change needed.

- Commits: use identified hashes, or `HEAD` if none provided (ignored in direct mode — all commits ahead of master are included)
- Read commit message(s): `git log --format='%s%n%n%b' -1 <hash>`
- In direct mode: `git log --format='%s%n%n%b' origin/master..HEAD` for all commits ahead of master
- Reviewers: resolve each name to a GitHub handle:
  - Detect org: `ORG=$(gh repo view --json owner -q .owner.login)`
  - `gh api /orgs/$ORG/members --paginate -q '.[].login' | rg -i '<name>'`
  - One match → use it. Multiple → disambiguate via `git log --all --format='%an' -- <changed-files>`. Still ambiguous → ask user

## 2. Branch and worktree setup

Skip this entire step in direct mode.

### Derive branch slug
- Derive a 2-word slug from the first commit's subject (rarely 3 if 2 is ambiguous)
  - Strip `[tag]` prefix, pick the most descriptive noun+noun or verb+noun pair
  - `[search] Fix 'Stopped generating' in history` → `search-history-fix`
  - `[search] Add keyboard nav to results` → `search-keyboard-nav`
  - `Refactor auth token refresh logic` → `auth-token-refresh`
  - Fall back to changed file paths if subject is too generic
- Branch prefix: derive from the user's initials (first + last name, lowercase). E.g. "Jane Doe" → `jd/`, "Alex Smith" → `as/`
- Full branch name: `<initials>/<slug>` (e.g. `jd/search-history-fix`)
- Verify name is free locally and remotely (note: `git branch --list` always exits 0, check output instead): `git branch --list <name> | rg -q .` and `git ls-remote --heads origin <name> | rg -q .`. If taken, append `-v2` or a more descriptive word

### Create branch

**Default (cherry-pick) mode:**
- `git fetch origin master`
- `git checkout -b <initials>/<slug> origin/master`

**Worktree mode (`--wt`):**
- `sparse-branch.sh <slug>` — pass the slug only, no prefix (the script derives `<initials>/` from `git config user.name`). This handles fetch, worktree creation at `../<slug>`, branch off `origin/master`, sparse checkout, and symlinks. (See `scripts/sparse-branch.sh`.)
- All subsequent steps (3–5) execute inside `../<slug>`

## 3. Cherry-pick

Skip this entire step in direct mode.

- In `--wt` mode: working directory is `../<slug>`
- `git cherry-pick <hash1> [hash2 ...]`
- On conflict: show conflicted files and pause for user input

## 4. Pre-submit checks

- In `--wt` mode: working directory is `../<slug>`
- `pre-commit run --files <changed-files>` — fix issues, re-run until clean
- Precommit may autofix; stage fixes and re-commit if needed
- Never `--no-verify`
- Changed files: `git diff --name-only origin/master...HEAD`

## 5. Push and create PR

- In `--wt` mode: working directory is `../<slug>`
- `git push -u origin <branch>`
- Base the PR description on the cherry-picked commit message(s) and the diff
- Single commit: use its subject as the title, its body as the description seed
- Multiple commits: synthesize a title, list each commit's purpose
- Follow your project's PR template and conventions
- If no reviewers: create as `--draft`
- If reviewers provided: create as ready for review with `--reviewer <handle1>,<handle2>,...`

## 6. Worktree cleanup (`--wt` only)

Skip in default and direct modes.

- On success: `git worktree remove ../<slug>` (branch remains — it's the PR branch on origin)
- On unrecoverable error: leave the worktree for debugging, tell user to clean up with `git worktree remove ../<slug>`

## Examples

```
/pr create                             # cherry-pick HEAD in current checkout → draft PR
/pr create 436d191d202f 148ee1489f3d   # cherry-pick specific commits → draft PR
/pr create elijah chak piyush          # cherry-pick HEAD + reviewer(s) → ready-for-review PR
/pr create 436d191d202f elijah         # cherry-pick specific commit + reviewer → ready-for-review PR
/pr create --wt                        # cherry-pick HEAD via worktree → draft PR (main checkout untouched)
/pr create --wt 436d191d202f elijah    # cherry-pick in worktree + reviewer → ready-for-review PR
/pr create --here                      # push current branch as-is → draft PR (no branch/worktree)
/pr create --here elijah chak          # push current branch + reviewer(s) → ready-for-review PR
/pr create --here 436d191d202f         # ERROR: commit hashes incompatible with --here
/pr create --here --wt                 # ERROR: --here and --wt are mutually exclusive
```
