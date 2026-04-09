#!/bin/bash
#
# Creates a sparse-checkout worktree for development branches.
#
# Usage: sparse-branch.sh [--full|--sparse|--min] [--update] [--prefix PREFIX] <name|prefix/name> [base-branch]
#

set -e

full=false
sparse=false
min=false
update=false
custom_prefix=""
name=""
base="origin/master"

# Parse arguments
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
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [[ -z "$name" ]]; then
                name="$1"
            else
                base="$1"
            fi
            ;;
    esac
    shift
done

# Derive branch prefix: --prefix > prefix/name syntax > git user initials
if [[ -n "$custom_prefix" ]]; then
    branch_prefix="$custom_prefix"
elif [[ "$name" == */* ]]; then
    branch_prefix="${name%%/*}/"
    name="${name#*/}"
else
    branch_prefix=$(git config user.name 2>/dev/null | awk '{print tolower(substr($1,1,1) substr($2,1,1))}')
    branch_prefix="${branch_prefix:-dev}/"
fi

# If --update without name, derive from current branch
if $update && [[ -z "$name" ]]; then
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ "$current_branch" == "${branch_prefix}"* ]]; then
        name="${current_branch#$branch_prefix}"
    else
        echo "❌ Not on a ${branch_prefix}* branch and no name provided" >&2
        echo "   Current branch: $current_branch" >&2
        exit 1
    fi
fi

if [[ "$name" == "${branch_prefix}"* ]]; then
    branch="$name"
    name="${name#"$branch_prefix"}"
else
    branch="${branch_prefix}${name}"
fi
worktree_dir="../$name"

# Validate input - name required for new worktrees
if [[ -z "$name" ]]; then
    echo "Usage: $(basename "$0") [--full|--sparse|--min] [--update] [--prefix PREFIX] <name> [base-branch]" >&2
    echo "  Creates ${branch_prefix}<name> worktree at ../<name>" >&2
    echo "  --full    Full checkout (~1.5GB)" >&2
    echo "  --sparse  Sparse checkout (~150MB, Go/Python/TypeScript) [default]" >&2
    echo "  --min     Minimal checkout (~5MB, symlinks only)" >&2
    echo "  --prefix  Override branch prefix (default: 'initials/' from git user.name)" >&2
    echo "  If <name> contains '/' (e.g., 'team/foo'), the prefix is extracted from it." >&2
    echo "  --update  Update existing worktree symlinks (preserves mode unless --full/--sparse/--min specified)" >&2
    exit 1
fi

# Check if branch already exists (locally or as remote tracking)
branch_exists=false
branch_local=false
branch_remote_only=false
if git show-ref --verify --quiet "refs/heads/$branch"; then
    branch_exists=true
    branch_local=true
elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    branch_exists=true
    branch_remote_only=true
fi

existing_worktree=false
if $branch_exists && [[ -d "$worktree_dir" ]]; then
    existing_worktree=true
    if ! $update; then
        echo "ℹ️  Branch '$branch' and worktree already exist. Use --update to refresh symlinks." >&2
        echo "   Or specify a different name to create a new worktree." >&2
        exit 1
    fi
    echo "🔄 Updating existing worktree at $worktree_dir..."
fi

if ! $existing_worktree; then
    if $branch_exists; then
        if [[ -d "$worktree_dir" ]]; then
            echo "❌ Directory '$worktree_dir' exists but is not a worktree for '$branch'" >&2
            exit 1
        fi
    else
        # New branch - find available worktree name (append -2, -3, etc. if needed)
        suffix=""
        counter=1
        while [[ -d "$worktree_dir$suffix" ]]; do
            ((counter++))
            suffix="-$counter"
        done
        worktree_dir="$worktree_dir$suffix"
        [[ -n "$suffix" ]] && branch="$branch$suffix"
    fi

    # Fetch latest
    echo "⏳ Fetching origin..."
    if ! git fetch origin master; then
        echo "❌ Failed to fetch origin/master" >&2
        exit 1
    fi
    if $branch_remote_only; then
        git fetch origin "$branch" 2>/dev/null || true
    fi

    # Create worktree
    if $full; then
        echo "🌳 Creating full worktree..."
    else
        if $min; then mode_label="minimal"; else mode_label="sparse"; fi
        echo "🌳 Creating $mode_label worktree..."
    fi

    wt_cmd=(git worktree add)
    $full || wt_cmd+=(--no-checkout)
    if $branch_local; then
        wt_cmd+=("$worktree_dir" "$branch")
    elif $branch_remote_only; then
        wt_cmd+=(-b "$branch" "$worktree_dir" "origin/$branch")
    else
        wt_cmd+=(-b "$branch" "$worktree_dir" "$base")
    fi
    if ! "${wt_cmd[@]}"; then
        echo "❌ Failed to create worktree" >&2
        exit 1
    fi
fi

# Configure worktree (in subshell to isolate cd)
(
    cd "$worktree_dir" || exit 1

    # Get the actual git directory (worktrees use a different location)
    git_dir=$(git rev-parse --git-dir)

    # Handle --full on existing worktree: disable sparse checkout
    if $full && $existing_worktree; then
        if git sparse-checkout list &>/dev/null && [[ -f "$git_dir/info/sparse-checkout" ]]; then
            echo "⚙️  Disabling sparse checkout and checking out all files..."
            git sparse-checkout disable
        fi
    fi

    # Sparse checkout setup (skip if --full)
    if ! $full; then
        # Check if sparse checkout is already configured
        sparse_already_enabled=false
        if git sparse-checkout list &>/dev/null && [[ -f "$git_dir/info/sparse-checkout" ]]; then
            sparse_already_enabled=true
        fi

        # Check if user explicitly requested a mode change
        mode_explicitly_set=false
        if $sparse || $min; then
            mode_explicitly_set=true
        fi

        # Determine if we should (re)configure sparse checkout
        should_configure_sparse=false
        if $existing_worktree; then
            if $mode_explicitly_set; then
                # Explicit --sparse or --min: reconfigure to requested mode
                target_mode="sparse"
                if $min; then target_mode="minimal"; fi
                echo "⚙️  Reconfiguring to $target_mode checkout..."
                should_configure_sparse=true
            elif ! $sparse_already_enabled; then
                # Existing full worktree, no explicit mode - offer to convert
                echo ""
                echo "📦 This worktree is currently a full checkout (~1.3GB)."
                echo "   Converting to sparse would reduce it to ~150MB."
                echo ""
                read -p "   Convert to sparse checkout? [Y/n] " -n 1 -r
                echo ""
                if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                    echo "⚙️  Converting to sparse checkout..."
                    should_configure_sparse=true
                else
                    echo "   Keeping full checkout."
                fi
            fi
            # else: existing sparse/min worktree, no mode flag - keep as-is
        else
            echo "⚙️  Configuring sparse checkout..."
            should_configure_sparse=true
        fi

        if $should_configure_sparse; then
            git sparse-checkout init --no-cone

            mkdir -p "$git_dir/info"
            if $min; then
                # Minimal mode: only root files and .codeagent
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
                # If $SPARSE_PATTERNS_FILE exists, use it; otherwise use a default.
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

            echo "📦 Checking out files..."
            git checkout

            # Add extra files needed for pre-commit hooks (skip in min mode).
            # Set SPARSE_EXTRA_PATHS to a space-separated list of paths your
            # pre-commit hooks depend on (e.g., config files, lint configs).
            if ! $min && [[ -n "${SPARSE_EXTRA_PATHS:-}" ]]; then
                echo "🔧 Adding pre-commit dependencies..."
                # shellcheck disable=SC2086
                git sparse-checkout add $SPARSE_EXTRA_PATHS 2>/dev/null
                git checkout 2>/dev/null
            fi
        fi
    fi

    # Find the main worktree (first entry in git worktree list)
    main_worktree=$(git -C "$(git rev-parse --git-common-dir)/.." worktree list --porcelain | head -1 | sed 's/^worktree //')
    main_rel=$(python3 -c "import os; print(os.path.relpath('$main_worktree', '$PWD'))")

    # Symlink node_modules from main workspace (both sparse and full)
    if [[ -d "$main_worktree/node_modules" ]] && [[ ! -e "node_modules" ]]; then
        echo "🔗 Symlinking node_modules -> $main_rel/node_modules"
        ln -s "$main_rel/node_modules" node_modules
    fi

    # Symlink additional directories from main workspace.
    # Set SPARSE_SYMLINK_DIRS to a space-separated list of relative paths
    # that should be shared between worktrees (e.g., virtualenvs, build caches).
    for symdir in ${SPARSE_SYMLINK_DIRS:-}; do
        if [[ -d "$main_worktree/$symdir" ]] && [[ ! -e "$symdir" ]]; then
            mkdir -p "$(dirname "$symdir")"
            echo "🔗 Symlinking $symdir"
            ln -s "../${main_rel}/$symdir" "$symdir"
        fi
    done

    # Report stats
    file_count=$(git ls-files | wc -l | tr -d ' ')
    size=$(du -sh . 2>/dev/null | cut -f1)

    # Determine actual mode (detect from sparse-checkout patterns if not explicitly set)
    if $full; then
        mode="full"
    elif $min; then
        mode="minimal"
    elif $sparse; then
        mode="sparse"
    elif [[ -f "$git_dir/info/sparse-checkout" ]] && grep -q "^!/\*\*/\$" "$git_dir/info/sparse-checkout" 2>/dev/null; then
        # Minimal mode has "!/**/" pattern to exclude all subdirs
        mode="minimal"
    elif [[ -f "$git_dir/info/sparse-checkout" ]]; then
        mode="sparse"
    else
        mode="full"
    fi

    echo ""
    if $existing_worktree; then
        echo "✅ Updated $mode worktree '$branch'"
    else
        echo "✅ Created $mode worktree '$branch'"
    fi
    echo "   📍 Location: $worktree_dir"
    echo "   📊 Files: $file_count (~$size)"
    if ! $existing_worktree; then
        echo "   🎯 Based on: $(git rev-parse --short "$base") $(git log -1 --format=%s "$base" 2>/dev/null)"
    fi
    echo ""
    echo "   cd $worktree_dir"
)
