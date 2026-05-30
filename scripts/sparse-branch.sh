#!/bin/bash
#
# Creates sparse-checkout worktrees for development branches (in parallel).
#
# Usage: sparse-branch.sh [--full|--sparse|--min] [--update] [--prefix PREFIX] [--base BASE] <name>...
#
# Multiple names are created in parallel after a single shared fetch.
#
# Customize for your repo via environment:
#   SPARSE_PATTERNS_FILE  Path to a git sparse-checkout patterns file (used in
#                         sparse mode). Defaults to a minimal "everything except
#                         node_modules/.git" pattern.
#   SPARSE_EXTRA_PATHS    Space-separated paths to add after the initial sparse
#                         checkout (e.g., config/lint files your pre-commit hooks
#                         need). Skipped in --min mode.
#   SPARSE_SYMLINK_DIRS   Space-separated relative paths to symlink from the main
#                         worktree (e.g., virtualenvs, build caches). node_modules
#                         is always symlinked when present.
#

set -e

full=false
sparse=false
min=false
update=false
custom_prefix=""
base="origin/master"
names=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --full) full=true ;;
        --sparse) sparse=true ;;
        --min) min=true ;;
        --update) update=true ;;
        --prefix)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                echo "❌ --prefix requires a value" >&2; exit 1
            fi
            custom_prefix="$2"; shift ;;
        --base)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                echo "❌ --base requires a value" >&2; exit 1
            fi
            base="$2"; shift ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) names+=("$1") ;;
    esac
    shift
done

usage() {
    cat >&2 << EOF
Usage: $(basename "$0") [--full|--sparse|--min] [--update] [--prefix PREFIX] [--base BASE] <name>...
  Creates <prefix><name> worktree at ../<name> for each name. Multiple names
  are processed in parallel after a single shared fetch.
  --full    Full checkout
  --sparse  Sparse checkout (default)
  --min     Minimal checkout (root files + symlinks only)
  --prefix  Override branch prefix (default: 'initials/' from git user.name)
  --base    Base branch for new worktrees (default: origin/master)
  --update  Update existing worktree symlinks (preserves mode unless --full/--sparse/--min specified)
  If <name> contains '/' (e.g., 'team/foo'), the prefix is extracted from it.
EOF
    exit 1
}

# Derive default branch_prefix once for --update bare invocation
default_prefix() {
    if [[ -n "$custom_prefix" ]]; then
        echo "$custom_prefix"
    else
        local p
        p=$(git config user.name 2>/dev/null | awk '{print tolower(substr($1,1,1) substr($2,1,1))}')
        echo "${p:-dev}/"
    fi
}

# --update with no name: derive name from current branch
if $update && [[ ${#names[@]} -eq 0 ]]; then
    derived_prefix=$(default_prefix)
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ "$current_branch" == "${derived_prefix}"* ]]; then
        names+=("${current_branch#$derived_prefix}")
    else
        echo "❌ Not on a ${derived_prefix}* branch and no name provided" >&2
        echo "   Current branch: $current_branch" >&2
        exit 1
    fi
fi

[[ ${#names[@]} -eq 0 ]] && usage

# Resolve each name -> (display_name, branch, worktree_dir, locality, existing_wt).
# Pre-resolve so we can collide-check across siblings and batch the fetch.
resolved=()
remote_branches_to_fetch=()
chosen_dirs=()

for raw_name in "${names[@]}"; do
    name="$raw_name"
    if [[ -n "$custom_prefix" ]]; then
        branch_prefix="$custom_prefix"
    elif [[ "$name" == */* ]]; then
        branch_prefix="${name%%/*}/"
        name="${name#*/}"
    else
        branch_prefix=$(git config user.name 2>/dev/null | awk '{print tolower(substr($1,1,1) substr($2,1,1))}')
        branch_prefix="${branch_prefix:-dev}/"
    fi

    if [[ "$name" == "${branch_prefix}"* ]]; then
        branch="$name"
        name="${name#"$branch_prefix"}"
    else
        branch="${branch_prefix}${name}"
    fi
    worktree_dir="../$name"

    locality="new"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        locality="local"
    elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        locality="remote"
        remote_branches_to_fetch+=("$branch")
    fi

    existing_wt=false
    if [[ "$locality" != "new" ]] && [[ -d "$worktree_dir" ]]; then
        existing_wt=true
        if ! $update; then
            echo "ℹ️  Branch '$branch' and worktree at $worktree_dir already exist. Use --update to refresh symlinks." >&2
            echo "   Or specify a different name to create a new worktree." >&2
            exit 1
        fi
    fi

    if [[ "$locality" == "new" ]]; then
        suffix=""
        counter=1
        while :; do
            collide=false
            [[ -d "$worktree_dir$suffix" ]] && collide=true
            for d in "${chosen_dirs[@]}"; do
                [[ "$d" == "$worktree_dir$suffix" ]] && collide=true
            done
            $collide || break
            ((counter++))
            suffix="-$counter"
        done
        worktree_dir="$worktree_dir$suffix"
        [[ -n "$suffix" ]] && branch="$branch$suffix"
    fi

    chosen_dirs+=("$worktree_dir")
    resolved+=("$name|$branch|$worktree_dir|$locality|$existing_wt")
done

# Single shared fetch for all branches.
fetch_args=(origin "${base#origin/}")
for b in "${remote_branches_to_fetch[@]}"; do
    fetch_args+=("$b")
done
echo "⏳ Fetching origin: ${fetch_args[*]:1}"
if ! git fetch "${fetch_args[@]}"; then
    echo "❌ Failed to fetch from origin" >&2
    exit 1
fi

# Phase 1 (serial, fast): create all worktrees up front with --no-checkout.
# `git worktree add` writes upstream tracking to .git/config, which is not
# retry-safe under contention — running these in parallel races on
# .git/config.lock and breaks branch tracking. With --no-checkout the per-call
# cost is ~1s, so serializing here is cheap.
created=()
for record in "${resolved[@]}"; do
    IFS='|' read -r name branch worktree_dir locality existing_wt <<< "$record"
    tag="[$name]"

    if [[ "$existing_wt" == "true" ]]; then
        echo "$tag 🔄 Reusing existing worktree at $worktree_dir"
        created+=("$record")
        continue
    fi

    if [[ "$locality" == "local" || "$locality" == "remote" ]] && [[ -d "$worktree_dir" ]]; then
        echo "$tag ❌ Directory '$worktree_dir' exists but is not a worktree for '$branch'" >&2
        continue
    fi

    mode_label="sparse"
    if $full; then
        mode_label="full"
    elif $min; then
        mode_label="minimal"
    fi
    echo "$tag 🌳 Creating $mode_label worktree at $worktree_dir..."

    # Always --no-checkout: avoids redundant full checkout for non-sparse modes
    # too (we'll `git checkout` later in the parallel phase).
    wt_cmd=(git worktree add --no-checkout)
    if [[ "$locality" == "local" ]]; then
        wt_cmd+=("$worktree_dir" "$branch")
    elif [[ "$locality" == "remote" ]]; then
        wt_cmd+=(-b "$branch" "$worktree_dir" "origin/$branch")
    else
        wt_cmd+=(-b "$branch" "$worktree_dir" "$base")
    fi
    if ! "${wt_cmd[@]}"; then
        echo "$tag ❌ Failed to create worktree" >&2
        continue
    fi
    created+=("$record")
done

# Per-branch configure worker — runs in parallel. Output is line-prefixed with
# [name] so interleaved logs stay legible.
process_branch() {
    local name="$1" branch="$2" worktree_dir="$3" locality="$4" existing_wt="$5"
    local tag="[$name]"

    (
        cd "$worktree_dir" || exit 1
        local git_dir
        git_dir=$(git rev-parse --git-dir)

        if $full && [[ "$existing_wt" == "true" ]]; then
            if git sparse-checkout list &>/dev/null && [[ -f "$git_dir/info/sparse-checkout" ]]; then
                echo "$tag ⚙️  Disabling sparse checkout and checking out all files..."
                git sparse-checkout disable
            fi
        fi

        if $full && [[ "$existing_wt" != "true" ]]; then
            # New full worktree was created with --no-checkout; materialize now.
            echo "$tag 📦 Checking out files (full)..."
            git checkout
        fi

        if ! $full; then
            local sparse_already_enabled=false
            if git sparse-checkout list &>/dev/null && [[ -f "$git_dir/info/sparse-checkout" ]]; then
                sparse_already_enabled=true
            fi

            local mode_explicitly_set=false
            if $sparse || $min; then
                mode_explicitly_set=true
            fi

            local should_configure_sparse=false
            if [[ "$existing_wt" == "true" ]]; then
                if $mode_explicitly_set; then
                    local target_mode="sparse"
                    $min && target_mode="minimal"
                    echo "$tag ⚙️  Reconfiguring to $target_mode checkout..."
                    should_configure_sparse=true
                elif ! $sparse_already_enabled; then
                    # Parallel mode: skip the interactive convert prompt.
                    echo "$tag ℹ️  Existing full worktree; pass --sparse or --min to convert."
                fi
            else
                echo "$tag ⚙️  Configuring sparse checkout..."
                should_configure_sparse=true
            fi

            if $should_configure_sparse; then
                git sparse-checkout init --no-cone

                mkdir -p "$git_dir/info"
                if $min; then
                    cat > "$git_dir/info/sparse-checkout" << 'MIN_PATTERNS'
# Minimal sparse checkout - root files only

# Root files only
/*
!/**/

# Essential directories
/.codeagent/
/.github/
MIN_PATTERNS
                else
                    # Standard sparse checkout — customize for your repo.
                    # If $SPARSE_PATTERNS_FILE exists, use it; otherwise default
                    # to "everything except large generated dirs".
                    if [[ -f "${SPARSE_PATTERNS_FILE:-}" ]]; then
                        cp "$SPARSE_PATTERNS_FILE" "$git_dir/info/sparse-checkout"
                    else
                        cat > "$git_dir/info/sparse-checkout" << 'SPARSE_PATTERNS'
# Default sparse checkout — include everything except large generated dirs.
# Customize: set SPARSE_PATTERNS_FILE to a file with your own patterns.
/*
!/node_modules/
!/.git/
SPARSE_PATTERNS
                    fi
                fi

                echo "$tag 📦 Checking out files..."
                git checkout

                # Add extra files needed for pre-commit hooks (skip in min mode).
                # Set SPARSE_EXTRA_PATHS to a space-separated list of paths your
                # pre-commit hooks depend on (e.g., config files, lint configs).
                if ! $min && [[ -n "${SPARSE_EXTRA_PATHS:-}" ]]; then
                    echo "$tag 🔧 Adding pre-commit dependencies..."
                    # shellcheck disable=SC2086
                    git sparse-checkout add $SPARSE_EXTRA_PATHS 2>/dev/null
                    git checkout 2>/dev/null
                fi
            fi
        fi

        local main_worktree main_rel
        main_worktree=$(git -C "$(git rev-parse --git-common-dir)/.." worktree list --porcelain | head -1 | sed 's/^worktree //')
        main_rel=$(python3 -c "import os; print(os.path.relpath('$main_worktree', '$PWD'))")

        # Symlink node_modules from main workspace (both sparse and full)
        if [[ -d "$main_worktree/node_modules" ]] && [[ ! -e "node_modules" ]]; then
            echo "$tag 🔗 Symlinking node_modules -> $main_rel/node_modules"
            ln -s "$main_rel/node_modules" node_modules
        fi

        # Symlink additional directories from main workspace.
        # Set SPARSE_SYMLINK_DIRS to a space-separated list of relative paths
        # that should be shared between worktrees (e.g., virtualenvs, build caches).
        for symdir in ${SPARSE_SYMLINK_DIRS:-}; do
            if [[ -d "$main_worktree/$symdir" ]] && [[ ! -e "$symdir" ]]; then
                mkdir -p "$(dirname "$symdir")"
                echo "$tag 🔗 Symlinking $symdir"
                ln -s "../${main_rel}/$symdir" "$symdir"
            fi
        done

        local file_count size mode
        file_count=$(git ls-files | wc -l | tr -d ' ')
        size=$(du -sh . 2>/dev/null | cut -f1)

        if $full; then
            mode="full"
        elif $min; then
            mode="minimal"
        elif $sparse; then
            mode="sparse"
        elif [[ -f "$git_dir/info/sparse-checkout" ]] && grep -q "^!/\*\*/\$" "$git_dir/info/sparse-checkout" 2>/dev/null; then
            mode="minimal"
        elif [[ -f "$git_dir/info/sparse-checkout" ]]; then
            mode="sparse"
        else
            mode="full"
        fi

        echo ""
        if [[ "$existing_wt" == "true" ]]; then
            echo "$tag ✅ Updated $mode worktree '$branch'"
        else
            echo "$tag ✅ Created $mode worktree '$branch'"
        fi
        echo "$tag    📍 Location: $worktree_dir"
        echo "$tag    📊 Files: $file_count (~$size)"
        if [[ "$existing_wt" != "true" ]]; then
            echo "$tag    🎯 Based on: $(git rev-parse --short "$base") $(git log -1 --format=%s "$base" 2>/dev/null)"
        fi
        echo "$tag    cd $worktree_dir"
    )
}

# Fan out: one background job per worktree that made it through phase 1.
pids=()
for record in "${created[@]}"; do
    IFS='|' read -r name branch worktree_dir locality existing_wt <<< "$record"
    process_branch "$name" "$branch" "$worktree_dir" "$locality" "$existing_wt" &
    pids+=($!)
done

exit_code=0
for pid in "${pids[@]}"; do
    wait "$pid" || exit_code=1
done

# If any worktree failed to create in phase 1, surface that as a failure too.
[[ ${#created[@]} -lt ${#resolved[@]} ]] && exit_code=1
exit $exit_code
