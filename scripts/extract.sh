#!/bin/bash
#
# Extracts specific files or commits to a new branch and creates a PR.
# Idempotent: can be re-run safely, prompts to skip or redo completed steps.
#
# Usage: extract.sh [--min|--full] <name> [desc] [refs...|files...]
#
# Arguments:
#   name    Branch suffix (creates <initials>/<name>)
#   desc    PR title (optional, defaults to first commit's message)
#   refs    Git refs (optional, defaults to HEAD)
#
# Commit mode (preserves original commit messages):
#   extract.sh my-feature                            # HEAD with auto-desc (simplest)
#   extract.sh my-feature "PR title"                 # HEAD with custom title
#   extract.sh my-feature "" HEAD~3..HEAD            # Last 3 commits, auto-desc
#   extract.sh my-feature "" origin/master..HEAD     # All commits since master
#   extract.sh my-feature "" abc1234 def5678         # Multiple specific commits
#   extract.sh my-feature "custom PR title" abc1234  # Override PR title
#
# File mode (copies files, uses provided desc):
#   extract.sh button-bg "fix background color" src/components/Button.css.ts
#
# Flags:
#   --min   Minimal sparse worktree (~5MB), skips pre-commit (faster, for simple changes)
#   --full  Full worktree (~1.5GB), needed for Java/proto changes
#
# Conflict handling:
#   If cherry-pick conflicts, script pauses for you to resolve in another terminal.
#

set -e

# Parse flags
worktree_flag=""
if [[ "$1" == "--min" ]]; then
    worktree_flag="--min"
    shift
elif [[ "$1" == "--full" ]]; then
    worktree_flag="--full"
    shift
fi

# Get the main workspace directory (where this script lives)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
main_workspace="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
main_workspace_name="$(basename "$main_workspace")"

# Change to main workspace so relative paths work correctly
cd "$main_workspace"

# Helper: prompt for rerun or skip
# Usage: prompt_step "step name" "already done condition description"
# Returns 0 to run, 1 to skip
prompt_step() {
    local step_name="$1"
    local condition="$2"
    echo ""
    echo "⚠️  $step_name: $condition"
    read -r -p "   [R]erun (with cleanup) or [S]kip? [r/S] " response
    [[ "$response" == "r" || "$response" == "R" ]]
}

# Commit with retry when pre-commit hooks auto-fix files.
# Hooks like ruff, prettier, eslint may partially fix issues across runs,
# so we re-stage and retry up to max_retries times.
commit_with_retry() {
    local max_retries="$1"
    shift
    for attempt in $(seq 1 "$max_retries"); do
        if git commit "$@"; then
            return 0
        fi
        if git diff --quiet || [[ "$attempt" -eq "$max_retries" ]]; then
            return 1
        fi
        echo "🔄 Pre-commit auto-fixed files, re-staging and retrying... (attempt $((attempt + 1))/$max_retries)"
        git add -u
    done
    return 1
}

if [[ $# -lt 1 ]]; then
    echo "Usage: $(basename "$0") [--min|--full] <name> [desc] [refs...|files...]" >&2
    echo "  Extracts commits or files to a new branch and creates a PR" >&2
    echo "" >&2
    echo "  name    Branch suffix (creates <initials>/<name>)" >&2
    echo "  desc    PR title (optional, defaults to first commit's message)" >&2
    echo "  refs    Git refs (optional, defaults to HEAD)" >&2
    echo "" >&2
    echo "  --min   Minimal sparse worktree, skips pre-commit (faster)" >&2
    echo "  --full  Full worktree (needed for Java/proto changes)" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $(basename "$0") my-feature                          # HEAD with auto-desc" >&2
    echo "  $(basename "$0") my-feature 'PR title'               # HEAD with custom title" >&2
    echo "  $(basename "$0") my-feature '' HEAD~3..HEAD          # Last 3 commits" >&2
    echo "  $(basename "$0") my-feature 'custom PR title' abc1234  # With custom PR title" >&2
    echo "  $(basename "$0") --min trivial-fix                   # Fast, skip pre-commit" >&2
    echo "  $(basename "$0") my-fix 'fix bug' path/to/file.ts    # File copy mode" >&2
    exit 1
fi

name="$1"
desc="${2:-}"
shift
[[ $# -ge 1 ]] && shift

# Remaining args are either files or commits; default to HEAD if none provided
if [[ $# -eq 0 ]]; then
    args=("HEAD")
else
    args=("$@")
fi

# Detect if all args are git refs/ranges or files
# Handles: HEAD, HEAD~3, abc1234, HEAD~3..HEAD, origin/master..HEAD, etc.
is_commits=false
commits=()
all_are_commits=true

for arg in "${args[@]}"; do
    if [[ "$arg" == *..* ]]; then
        # Range expression like HEAD~3..HEAD - expand to individual commits
        if resolved=$(git rev-list --reverse "$arg" 2>/dev/null) && [[ -n "$resolved" ]]; then
            while IFS= read -r commit; do
                commits+=("$commit")
            done <<< "$resolved"
        else
            all_are_commits=false
            break
        fi
    else
        # Single ref like HEAD, HEAD~3, abc1234
        if resolved=$(git rev-parse --verify "$arg^{commit}" 2>/dev/null); then
            commits+=("$resolved")
        else
            all_are_commits=false
            break
        fi
    fi
done

if $all_are_commits && [[ ${#commits[@]} -gt 0 ]]; then
    is_commits=true
    # If desc is empty, use first commit's subject line
    if [[ -z "$desc" ]]; then
        desc=$(git log -1 --format=%s "${commits[0]}")
        echo "📝 Using commit message as title: $desc"
    fi
    # Capture first commit's body for PR description
    commit_body=$(git log -1 --format=%b "${commits[0]}" | sed '/^$/d')
    if [[ -n "$commit_body" ]]; then
        echo "📝 Will use first commit's body as PR description"
    fi
fi

branch_prefix=$(git config user.name 2>/dev/null | awk '{print tolower(substr($1,1,1) substr($2,1,1))}')
branch_prefix="${branch_prefix:-dev}/"
branch="${branch_prefix}${name}"
worktree_dir="../$name"

# Step 1: Create sparse branch/worktree
run_create_worktree=true
if [[ -d "$worktree_dir" ]]; then
    if prompt_step "Create worktree" "worktree already exists at $worktree_dir"; then
        echo "🧹 Removing existing worktree..."
        git worktree remove --force "$worktree_dir" 2>/dev/null || rm -rf "$worktree_dir"
        git branch -D "$branch" 2>/dev/null || true
    else
        run_create_worktree=false
    fi
fi

if $run_create_worktree; then
    echo "🌳 Creating sparse branch..."
    "$script_dir/sparse-branch.sh" $worktree_flag "$name"
fi

# Work in the new worktree
(
    cd "$worktree_dir" || exit 1

    # Step 2: Cherry-pick or copy files
    commits_ahead=$(git rev-list --count origin/master..HEAD 2>/dev/null || echo "0")
    run_changes=true

    if [[ "$commits_ahead" -gt 0 ]]; then
        if prompt_step "Apply changes" "branch has $commits_ahead commit(s) ahead of origin/master"; then
            echo "🧹 Resetting to origin/master..."
            git reset --hard origin/master
        else
            run_changes=false
        fi
    fi

    if $run_changes; then
        if $is_commits; then
            echo "🍒 Cherry-picking ${#commits[@]} commit(s)..."
            for commit in "${commits[@]}"; do
                echo "   → $commit"
                git_cmd="git"
                if [[ "$worktree_flag" == "--min" ]]; then
                    # Skip hooks in --min mode (cherry-pick doesn't support --no-verify)
                    git_cmd="git -c core.hooksPath=/dev/null"
                fi

                if ! $git_cmd cherry-pick "$commit"; then
                    # Cherry-pick failed, likely a conflict
                    echo ""
                    echo "⚠️  CONFLICT during cherry-pick of $commit"
                    echo ""
                    echo "   Resolve the conflict in another terminal:"
                    echo "   cd $(pwd)"
                    echo ""
                    echo "   Then either:"
                    echo "   - Fix conflicts, 'git add <files>', 'git cherry-pick --continue'"
                    echo "   - Or 'git cherry-pick --abort' to skip this commit"
                    echo ""
                    while true; do
                        read -r -p "   Press [C]ontinue when resolved, [A]bort to stop extraction: " response
                        case "$response" in
                            [cC])
                                git_dir=$(git rev-parse --git-dir)
                                if [[ -d "$git_dir/sequencer" ]] || [[ -f "$git_dir/CHERRY_PICK_HEAD" ]]; then
                                    echo "   ⚠️  Cherry-pick still in progress. Please complete it first."
                                else
                                    echo "   ✓ Continuing..."
                                    break
                                fi
                                ;;
                            [aA])
                                echo "   Aborting extraction."
                                git cherry-pick --abort 2>/dev/null || true
                                exit 1
                                ;;
                            *)
                                echo "   Please enter C or A"
                                ;;
                        esac
                    done
                fi

                # Run pre-commit after successful cherry-pick (unless --min mode)
                if [[ "$worktree_flag" != "--min" ]]; then
                    changed_files=$(git diff --name-only HEAD~1..HEAD 2>/dev/null || echo "")
                    if [[ -n "$changed_files" ]]; then
                        echo "🔍 Running pre-commit on cherry-picked files..."
                        pre-commit run --files $changed_files || true
                        if ! git diff --quiet; then
                            git add -u
                            commit_with_retry 3 --amend --no-edit
                        fi
                    fi
                fi
            done
        else
            echo "📄 Copying files from main workspace..."
            for file in "${args[@]}"; do
                if [[ -f "../$main_workspace_name/$file" ]]; then
                    mkdir -p "$(dirname "$file")"
                    cp "../$main_workspace_name/$file" "$file"
                    git add "$file"
                    echo "   ✓ $file"
                else
                    echo "   ⚠️  File not found: $file" >&2
                fi
            done

            # Run pre-commit on staged files BEFORE committing (skip in --min mode)
            commit_flags=""
            if [[ "$worktree_flag" == "--min" ]]; then
                echo ""
                echo "⚠️  WARNING: Skipping pre-commit checks in --min mode"
                echo "   Minimal worktrees lack dependencies for pre-commit hooks."
                echo "   Ensure changes are pre-commit clean before merging!"
                echo ""
                commit_flags="--no-verify"
            else
                echo "🔍 Running pre-commit on staged files..."
                staged_files=$(git diff --cached --name-only)
                if [[ -n "$staged_files" ]]; then
                    pre-commit run --files $staged_files || true
                    git add -u 2>/dev/null || true
                fi
            fi

            echo "💾 Committing..."
            commit_with_retry 3 $commit_flags -m "$desc"
        fi
    fi

    # Step 3: Pre-commit on all changed files (optional, catches files from cherry-picks)
    # Skip in --min mode
    if [[ "$worktree_flag" != "--min" ]]; then
        run_precommit=true
        echo ""
        read -r -p "🔍 Run pre-commit on all changed files? [Y/n] " response
        if [[ "$response" == "n" || "$response" == "N" ]]; then
            run_precommit=false
        fi

        if $run_precommit; then
            echo "🔍 Running pre-commit on all changes vs origin/master..."
            changed_files=$(git diff --name-only origin/master...HEAD)
            if [[ -n "$changed_files" ]]; then
                pre-commit run --files $changed_files || true

                if ! git diff --quiet; then
                    git add -u
                    commit_with_retry 3 --amend --no-edit
                fi
            fi
        fi
    fi

    # Step 4: Push
    run_push=true
    if git rev-parse --verify "origin/$branch" &>/dev/null; then
        local_sha=$(git rev-parse HEAD)
        remote_sha=$(git rev-parse "origin/$branch" 2>/dev/null || echo "")
        if [[ "$local_sha" == "$remote_sha" ]]; then
            if prompt_step "Push" "remote branch is already up to date"; then
                : # will push anyway (force)
            else
                run_push=false
            fi
        fi
    fi

    if $run_push; then
        echo "⬆️  Pushing..."
        push_flags="--force-with-lease"
        if [[ "$worktree_flag" == "--min" ]]; then
            push_flags="$push_flags --no-verify"
        fi
        git push -u origin "$branch" $push_flags
    fi

    # Step 5: Create PR
    run_pr=true
    if gh pr view &>/dev/null; then
        if prompt_step "Create PR" "PR already exists for this branch"; then
            : # will update PR
        else
            run_pr=false
        fi
    fi

    if $run_pr; then
        echo "📝 Creating/updating PR..."
        "$script_dir/make-pr.sh" "$desc"

        # Inject first commit's body into PR description
        if [[ -n "${commit_body:-}" ]]; then
            echo "📝 Injecting first commit's description into PR body..."
            pr_body_file="/tmp/pr_body_inject_$$.md"
            commit_body_file="/tmp/commit_body_$$.txt"
            gh pr view --json body -q .body > "$pr_body_file"
            printf '%s' "$commit_body" > "$commit_body_file"
            python3 -c "
import sys
body = open(sys.argv[1]).read()
insert = open(sys.argv[2]).read().strip()
marker = '**Description**:\n'
if marker in body:
    body = body.replace(marker, marker + insert + '\n', 1)
open(sys.argv[1], 'w').write(body)
" "$pr_body_file" "$commit_body_file"
            gh pr edit --body-file "$pr_body_file"
            rm -f "$pr_body_file" "$commit_body_file"
        fi
    fi
)

echo ""
echo "✅ Done! Branch $branch extracted and PR created."
