#!/bin/bash
#
# Creates sparse-checkout worktrees for development branches (in parallel).
#
# Usage: sparse-branch.sh [--full|--sparse|--min] [--update] [--prefix PREFIX] [--base BASE] <name>...
#
# Multiple names are created in parallel after a single shared fetch. With --min on
# an existing branch, the worktree is branch-scoped: only the directories the branch
# changes relative to the base, plus the support directories, are checked out.
#
# Customize for your repo via environment:
#   SPARSE_PATTERNS_FILE  Path to a git sparse-checkout patterns file (used in
#                         --sparse mode). Defaults to "everything except
#                         node_modules/.git".
#   SPARSE_SUPPORT_DIRS   Space-separated directories always included in --min
#                         and branch-scoped checkouts (agent rules, CI config,
#                         the helpers your hooks need). Default: ".github".
#   SPARSE_EXTRA_PATHS    Space-separated paths added after a --sparse checkout
#                         (e.g., config/lint files your pre-commit hooks need).
#   SPARSE_SYMLINK_DIRS   Space-separated relative paths to symlink from the main
#                         worktree (e.g., virtualenvs, build caches). node_modules
#                         is always symlinked when present.
#

set -e

SPARSE_SUPPORT_DIRS="${SPARSE_SUPPORT_DIRS:-.github}"

full=false
sparse=false
min=false
update=false
custom_prefix=""
prefix_set=false
base="origin/master"
base_explicit=false
names=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) full=true ;;
    --sparse) sparse=true ;;
    --min) min=true ;;
    --update) update=true ;;
    --prefix)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "❌ --prefix requires a value (use '' for no prefix)" >&2
        exit 1
      fi
      custom_prefix="$2"
      prefix_set=true
      shift
      ;;
    --base)
      if [[ -z "${2:-}" || "$2" == -* ]]; then
        echo "❌ --base requires a value" >&2
        exit 1
      fi
      base="$2"
      base_explicit=true
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *) names+=("$1") ;;
  esac
  shift
done

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--full|--sparse|--min] [--update] [--prefix PREFIX] [--base BASE] <name>...
  Creates <prefix><name> worktree at ../<name> for each name. Multiple names
  are processed in parallel after a single shared fetch.
  --full    Full checkout
  --sparse  Sparse checkout from \$SPARSE_PATTERNS_FILE [default]
  --min     Minimal checkout (root files + support dirs); for an existing branch, scope to its diff from the base
  --prefix  Override branch prefix (default: 'initials/' from git user.name)
  --base    Base branch for new worktrees and --min diffs (default: origin/HEAD, then main/master)
  --update  Update existing worktree symlinks (preserves mode unless --full/--sparse/--min specified)
  If <name> contains '/' (e.g., 'team/foo'), the prefix is extracted from it.
EOF
  exit 1
}

# Convert NUL-delimited git diff paths into cone-mode directories, plus the support directories
# and every ancestor agent-rules directory the branch has (go/.codeagent for go/pkg/x.go).
write_branch_sparse_dirs() {
  local diff_file="$1" output_file="$2" branch_ref="$3" codeagent_file
  codeagent_file=$(mktemp "${TMPDIR:-/tmp}/sparse-branch-codeagent.XXXXXX") || return 1
  temporary_files+=("$codeagent_file")
  git ls-tree -r -d -z --name-only "$branch_ref" | tr '\0' '\n' | grep -E '(^|/)\.(codeagent|cursor|claude|agents)$' >"$codeagent_file" || true
  python3 -c '
import os
import posixpath
import sys

with open(sys.argv[1], "rb") as source:
    changed_paths = {os.fsdecode(path) for path in source.read().split(b"\0") if path}
with open(sys.argv[3], "rb") as source:
    codeagent_dirs = {os.fsdecode(line) for line in source.read().split(b"\n") if line}

directories = set(sys.argv[4].split())
for path in changed_paths:
    normalized = posixpath.normpath(path)
    if path.startswith("/") or normalized == ".." or normalized.startswith("../"):
        raise SystemExit("diff contains a path outside the repository")
    directory = posixpath.dirname(normalized)
    if directory:
        directories.add(directory)
    ancestor = directory
    while ancestor:
        for rules_dir in (".codeagent", ".cursor", ".claude", ".agents"):
            if posixpath.join(ancestor, rules_dir) in codeagent_dirs:
                directories.add(posixpath.join(ancestor, rules_dir))
        ancestor = posixpath.dirname(ancestor)

selected = []
for directory in sorted(directories, key=lambda item: (item.count("/"), item)):
    if not any(directory.startswith(parent + "/") for parent in selected):
        selected.append(directory)
with open(sys.argv[2], "wb") as output:
    for directory in selected:
        output.write(os.fsencode(directory) + b"\0")
' "$diff_file" "$output_file" "$codeagent_file" "$SPARSE_SUPPORT_DIRS"
}

# Derive default branch_prefix once for --update bare invocation
default_prefix() {
  if $prefix_set; then
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

if ! $base_explicit; then
  default_branch_ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  remote_default_branch=$(git ls-remote --symref origin HEAD 2>/dev/null | awk '$1 == "ref:" && $2 ~ /^refs\/heads\// { sub(/^refs\/heads\//, "", $2); print $2; exit }')
  if [[ "$default_branch_ref" == refs/remotes/origin/* ]] && git show-ref --verify --quiet "$default_branch_ref"; then
    base="${default_branch_ref#refs/remotes/}"
  elif [[ -n "$remote_default_branch" ]]; then
    base="origin/$remote_default_branch"
  elif git show-ref --verify --quiet refs/remotes/origin/main; then
    base="origin/main"
  elif git show-ref --verify --quiet refs/remotes/origin/master; then
    base="origin/master"
  fi
fi

# Resolve each name -> (display_name, branch, worktree_dir, locality, existing_wt, branch scope).
# Pre-resolve so we can collide-check across siblings and batch the fetch.
resolved=()
remote_branches_to_fetch=()
chosen_dirs=()
temporary_files=()
primary_path=""
primary_sparse_enabled_before=""
primary_sparse_file=""
primary_sparse_snapshot=""
primary_sparse_file_existed=false

cleanup_temporary_files() {
  local file
  for file in "${temporary_files[@]}"; do
    rm -f "$file"
  done
}
trap cleanup_temporary_files EXIT

capture_primary_sparse_state() {
  [[ -n "$primary_path" ]] && return 0
  primary_path=$(git worktree list --porcelain | sed -n 's/^worktree //p' | head -n 1)
  [[ -n "$primary_path" ]] || return 1
  primary_sparse_enabled_before=$(git -C "$primary_path" config --worktree --bool core.sparseCheckout 2>/dev/null || echo unset)
  primary_sparse_file=$(git -C "$primary_path" rev-parse --path-format=absolute --git-path info/sparse-checkout)
  primary_sparse_snapshot=$(mktemp "${TMPDIR:-/tmp}/sparse-branch-primary.XXXXXX") || return 1
  temporary_files+=("$primary_sparse_snapshot")
  if [[ -f "$primary_sparse_file" ]]; then
    cp "$primary_sparse_file" "$primary_sparse_snapshot" || return 1
    primary_sparse_file_existed=true
  fi
}

verify_primary_sparse_state() {
  [[ -z "$primary_path" ]] && return 0
  local current_enabled
  current_enabled=$(git -C "$primary_path" config --worktree --bool core.sparseCheckout 2>/dev/null || echo unset)
  if [[ "$current_enabled" != "$primary_sparse_enabled_before" ]]; then
    echo "❌ Primary worktree sparse-checkout setting changed unexpectedly." >&2
    return 1
  fi
  if $primary_sparse_file_existed; then
    cmp -s "$primary_sparse_snapshot" "$primary_sparse_file" || {
      echo "❌ Primary worktree sparse-checkout patterns changed unexpectedly." >&2
      return 1
    }
  elif [[ -e "$primary_sparse_file" ]]; then
    echo "❌ Primary worktree sparse-checkout patterns appeared unexpectedly." >&2
    return 1
  fi
}

for raw_name in "${names[@]}"; do
  name="$raw_name"
  if $prefix_set; then
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
  elif $min; then
    remote_branch=$(git ls-remote --heads origin "refs/heads/$branch") || {
      echo "❌ Cannot check whether branch '$branch' exists on origin." >&2
      exit 1
    }
    if [[ -n "$remote_branch" ]]; then
      locality="remote"
      remote_branches_to_fetch+=("$branch")
    fi
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

  scope_base="-"
  scope_sha="-"
  scope_file="-"
  if $min && [[ "$locality" != "new" ]]; then
    if [[ "$(git config --bool extensions.worktreeConfig 2>/dev/null)" != "true" ]]; then
      echo "❌ Branch-scoped sparse checkout requires extensions.worktreeConfig=true." >&2
      echo "   No worktree was created; enable worktree-specific Git config and retry." >&2
      exit 1
    fi
    capture_primary_sparse_state || {
      echo "❌ Cannot snapshot the primary worktree sparse-checkout state." >&2
      exit 1
    }
    scope_base="$base"
    scope_file=$(mktemp "${TMPDIR:-/tmp}/sparse-branch-paths.XXXXXX") || exit 1
    temporary_files+=("$scope_file")
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
  resolved+=("$name|$branch|$worktree_dir|$locality|$existing_wt|$scope_base|$scope_sha|$scope_file")
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

for index in "${!resolved[@]}"; do
  record="${resolved[$index]}"
  IFS='|' read -r name branch worktree_dir locality existing_wt scope_base scope_sha scope_file <<<"$record"
  [[ "$scope_file" == "-" ]] && continue
  branch_ref="$branch"
  [[ "$locality" == "remote" ]] && branch_ref="origin/$branch"
  branch_sha=$(git rev-parse "$branch_ref" 2>/dev/null) || {
    echo "❌ Cannot resolve '$branch_ref' for branch-scoped checkout." >&2
    exit 1
  }
  merge_base=$(git merge-base "$scope_base" "$branch_ref") || {
    echo "❌ Cannot find a merge base between '$scope_base' and '$branch_ref'." >&2
    exit 1
  }
  diff_file=$(mktemp "${TMPDIR:-/tmp}/sparse-branch-diff.XXXXXX") || exit 1
  temporary_files+=("$diff_file")
  git diff --name-only --no-renames -z "$merge_base" "$branch_ref" >"$diff_file" || {
    echo "❌ Cannot diff '$branch_ref' against '$scope_base'." >&2
    exit 1
  }
  if ! write_branch_sparse_dirs "$diff_file" "$scope_file" "$branch_ref"; then
    echo "❌ Cannot derive branch-scoped paths for '$branch'." >&2
    exit 1
  fi
  resolved[$index]="$name|$branch|$worktree_dir|$locality|$existing_wt|$scope_base|$branch_sha|$scope_file"
done

# Phase 1 (serial, fast): create all worktrees up front with --no-checkout.
# `git worktree add` writes upstream tracking to .git/config, which is not
# retry-safe under contention — running these in parallel races on
# .git/config.lock and breaks branch tracking. With --no-checkout the per-call
# cost is ~1s, so serializing here is cheap.
created=()
for record in "${resolved[@]}"; do
  IFS='|' read -r name branch worktree_dir locality existing_wt scope_base scope_sha scope_file <<<"$record"
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
  elif [[ "$scope_file" != "-" ]]; then
    mode_label="branch-scoped"
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
  local scope_base="$6" scope_sha="$7" scope_file="$8"
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
          [[ "$scope_file" != "-" ]] && target_mode="branch-scoped"
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
        if [[ "$existing_wt" == "true" && "$scope_file" != "-" ]] && [[ -n "$(git status --porcelain)" ]]; then
          echo "$tag ❌ Existing worktree has changes; refusing to change its branch-scoped paths." >&2
          exit 1
        fi
        mkdir -p "$git_dir/info"
        if [[ "$scope_file" != "-" ]]; then
          current_sha=$(git rev-parse HEAD)
          if [[ "$current_sha" != "$scope_sha" ]]; then
            echo "$tag ❌ Branch moved from $scope_sha to $current_sha; refusing to apply stale paths." >&2
            exit 1
          fi
          echo "$tag 📦 Applying paths from diff against $scope_base at $scope_sha..."
          git sparse-checkout init --cone
          local -a branch_sparse_dirs=()
          local dir
          while IFS= read -r -d '' dir; do
            branch_sparse_dirs+=("$dir")
          done <"$scope_file"
          if [[ ${#branch_sparse_dirs[@]} -eq 0 ]]; then
            echo "$tag ❌ Branch diff produced no sparse directories." >&2
            exit 1
          fi
          git sparse-checkout set --cone "${branch_sparse_dirs[@]}"
          {
            printf 'base_ref=%s\nbranch_sha=%s\n' "$scope_base" "$scope_sha"
            printf 'path=%s\n' "${branch_sparse_dirs[@]}"
          } >"$git_dir/info/branch-sparse-checkout"
        else
          git sparse-checkout init --no-cone
          if $min; then
            {
              cat <<'MIN_PATTERNS'
# Minimal sparse checkout - root files and support directories

# Root files only
/*
!/**/

# Support directories
MIN_PATTERNS
              for support_dir in $SPARSE_SUPPORT_DIRS; do
                printf '/%s/\n' "${support_dir%/}"
              done
            } >"$git_dir/info/sparse-checkout"
          elif [[ -f "${SPARSE_PATTERNS_FILE:-}" ]]; then
            cp "$SPARSE_PATTERNS_FILE" "$git_dir/info/sparse-checkout"
          else
            cat >"$git_dir/info/sparse-checkout" <<'SPARSE_PATTERNS'
# Default sparse checkout - everything except large generated dirs.
# Customize: set SPARSE_PATTERNS_FILE to a file with your own patterns.
/*
!/node_modules/
!/.git/
SPARSE_PATTERNS
          fi
        fi

        echo "$tag 📦 Checking out files..."
        git checkout

        # Add extra paths needed for pre-commit hooks (skip in min and branch-scoped modes).
        if [[ "$scope_file" == "-" ]] && ! $min && [[ -n "${SPARSE_EXTRA_PATHS:-}" ]]; then
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

    if [[ -d "$main_worktree/node_modules" ]] && [[ ! -e "node_modules" ]]; then
      echo "$tag 🔗 Symlinking node_modules -> $main_rel/node_modules"
      ln -s "$main_rel/node_modules" node_modules
    fi

    # Symlink additional directories or files from the main worktree.
    # Set SPARSE_SYMLINK_DIRS to a space-separated list of relative paths that
    # should be shared between worktrees (e.g., virtualenvs, build caches).
    local symdir symdir_parent
    for symdir in ${SPARSE_SYMLINK_DIRS:-}; do
      symdir="${symdir%/}"
      if [[ -e "$main_worktree/$symdir" ]] && [[ ! -e "$symdir" ]]; then
        symdir_parent=$(dirname "$symdir")
        mkdir -p "$symdir_parent"
        echo "$tag 🔗 Symlinking $symdir"
        if [[ "$symdir_parent" == "." ]]; then
          ln -s "$main_rel/$symdir" "$symdir"
        else
          ln -s "$(python3 -c "import os; print(os.path.relpath('$main_worktree/$symdir', '$PWD/$symdir_parent'))")" "$symdir"
        fi
      fi
    done

    local file_count size mode
    file_count=$(git ls-files | wc -l | tr -d ' ')
    size=$(du -sh . 2>/dev/null | cut -f1)

    if $full; then
      mode="full"
    elif [[ "$scope_file" != "-" ]]; then
      mode="branch-scoped"
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
    if [[ "$scope_file" != "-" ]]; then
      echo "$tag    🔎 Diff base: $scope_base, branch head: $scope_sha"
      echo "$tag    🧾 Sparse paths recorded in $git_dir/info/branch-sparse-checkout"
    fi
    if [[ "$existing_wt" != "true" ]]; then
      if [[ "$scope_file" != "-" ]]; then
        echo "$tag    🎯 Based on branch head: $scope_sha"
      else
        echo "$tag    🎯 Based on: $(git rev-parse --short "$base") $(git log -1 --format=%s "$base" 2>/dev/null)"
      fi
    fi
    echo "$tag    cd $worktree_dir"
  )
}

# Fan out: one background job per worktree that made it through phase 1.
pids=()
for record in "${created[@]}"; do
  IFS='|' read -r name branch worktree_dir locality existing_wt scope_base scope_sha scope_file <<<"$record"
  process_branch "$name" "$branch" "$worktree_dir" "$locality" "$existing_wt" "$scope_base" "$scope_sha" "$scope_file" &
  pids+=($!)
done

exit_code=0
for pid in "${pids[@]}"; do
  wait "$pid" || exit_code=1
done

# If any worktree failed to create in phase 1, surface that as a failure too.
[[ ${#created[@]} -lt ${#resolved[@]} ]] && exit_code=1
verify_primary_sparse_state || exit_code=1
exit $exit_code
