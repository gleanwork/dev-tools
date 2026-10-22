#!/bin/bash
#
# Frees disk space.
#
# Usage: freespace.sh [-n] [-f]
#
# Modes:
#   (default)   Cheap to delete, cheap to recover (safe for daily use):
#               - Build caches (every primary checkout + linked worktrees): .swc,
#                 storybook-static, .next, .turbo, __pycache__, .mypy_cache,
#                 .pytest_cache, .ruff_cache
#               - node_modules in secondary worktrees (non-symlinked)
#               - App caches: ~/Library/Caches/{Xcode,VSCode,Cursor,Chrome,Chrome Beta,
#                 Arc,Firefox,Brave,Edge,Opera,OpenAI Atlas,ChatGPT,Claude Desktop,
#                 Granola+Loom updaters,Zoom,JetBrains,pip,virtualenv,Homebrew,go-build,
#                 gopls,pnpm,Yarn,electron,Playwright,bazelisk,colima,mise,helm,...}
#               - Loose ~/Library/Caches files over 100 MB untouched for 180 days
#                 (not com.apple.*), e.g. a requests-cache DB from a one-off script
#               - Application Support/Caches/*-updater (Loom, etc.) + Edge updater
#               - Cursor App Support (Cache, CachedData, logs, Partitions, WebStorage,
#                 GPUCache, CachedProfilesData) — workspaceStorage + History are -f only
#                 since they hold per-workspace UI state and Local-History recovery
#               - VSCode App Support safe caches (Cache, CachedData, CachedExtensionVSIXs,
#                 logs, Crashpad, WebStorage, GPUCache)
#               - Chromium safe caches for Chrome + Chrome Beta (OptGuideOnDeviceModel,
#                 extensions_crx_cache, Snapshots, optimization_guide_model_store,
#                 Crashpad, component_crx_cache, GraphiteDawnCache, GrShaderCache,
#                 ShaderCache)
#               - Electron app caches (Cache, Code Cache, GPUCache, Service Worker
#                 cache, Crashpad, logs) for Slack (incl. sandbox container), Claude,
#                 Claude (3P), Granola, Loom, Highlight, OpenAI Atlas, ChatGPT,
#                 Cluely, Slapdash, Dropbox Dash, Mighty, Microsoft Edge, Brave
#               - Windsurf App Support safe caches (Cache, CachedData, logs, GPUCache, etc.)
#               - Project dev caches: PROJECT_CACHE_DIRS, relative to each primary
#                 checkout (e.g. a local search index that repopulates on restart)
#               - Service logs: truncate *.log files over 100 MB under
#                 LOG_TRUNCATE_DIRS (truncation keeps the inode valid for running
#                 services)
#               - gcloud CLI logs (~/.config/gcloud/logs)
#               - System: ~/.Trash, ~/.cache/*, and /tmp + $TMPDIR entries untouched
#                 for 3 days (keeps sockets, com.apple.*, and paths a running
#                 process names or holds open)
#               - ~/Library/Logs/* (third-party only: Webex, Spark, Zoom, Loom,
#                 Claude, CoreSimulator, Glean, Docker; preserves Apple subsystems)
#               - Toolchains: mise prune (versions no tracked config uses) and
#                 versioned rustup toolchains that are not the default, active in
#                 a checkout, or installed by mise
#               - Quick restore (~30s): brew cleanup, ~/.npm/_cacache, idle
#                 ~/.npm/_npx entries, ~/.yarn/berry/cache (kept when a checkout
#                 uses Yarn Plug'n'Play)
#               - Misc: uv cache, bazel java logs, git temp packs
#               - Git: worktree prune, remove prunable worktrees (refuses if dirty),
#                 git gc (default prune window — keeps reflog recovery for ~2 weeks)
#               - All linked-worktree Bazel output bases (preserves every repository's
#                 main output base and the shared disk cache)
#               - Bazel output bases left by an interrupted
#                 `bazel clean --expunge_async` (<name>_tmp_<pid>_<uuid>)
#               - Bazel's default repository cache (<output_user_root>/cache/repos)
#                 once ~/.bazelrc sends every command to a shared one
#                 (`common --repository_cache=...`)
#
#   -f          Deep clean — expensive to recover:
#               - Docker: images, containers, volumes (docker system prune -a)
#               - Colima: fstrim each running profile after the Docker prune so
#                 the sparse VM disk shrinks on the host (keeps the VM and its
#                 settings; stopped profiles are reported, not touched)
#               - iOS Simulator: ~/Library/Developer/CoreSimulator (user)
#               - iOS Simulator runtimes not booted for 365 days (read from
#                 CoreSimulator's images.plist, deleted with `xcrun simctl
#                 runtime delete`; never-booted runtimes are kept)
#               - System CoreSimulator Caches flagged as a sudo follow-up target
#                 if root-owned
#               - Android emulators (AVDs) with no file modified for 365 days
#               - Claude Desktop + Claude (3P) vm_bundles (regenerate on next
#                 code-execution session)
#               - pre-commit hook envs (~/.cache/pre-commit; auto-recreate next commit)
#               - Cursor/VSCode workspaceStorage + History (per-workspace tabs/state +
#                 Local History recovery for unversioned edits — opt-in only)
#               - Primary-checkout node_modules and virtual environments are
#                 PRESERVED (bounded size, slow to reinstall); linked-worktree
#                 node_modules are handled by the default cleanup
#               - Gradle cache, Maven cache
#               - ALL of ~/.cache/bazel: every primary checkout's output base, the
#                 shared disk cache, and repository_cache. The next build is a
#                 cold rebuild and external deps are re-downloaded.
#               - Legacy Bazel root contents (/private/var/tmp/_bazel_$USER)
#               - Go module cache (go clean -modcache, slow to re-download)
#               - pnpm store (~/Library/pnpm/store)
#               - git gc --aggressive --prune=now (thorough repack, slow,
#                 drops dangling commits — reflog recovery is lost for pruned refs)
#

# Best-effort cleanup: keep going past per-op failures (missing dirs, perms,
# stale paths). Each safe_rm/safe_rm_pattern handles its own errors. Switching
# to `set -e` would abort the whole run on any single rm failure, which is the
# opposite of what we want for a disk-recovery script.
set +e

# Configuration — override via environment
MAIN_WORKSPACE="${FREESPACE_MAIN_WORKSPACE:-}"
BAZEL_ROOT="${BAZEL_ROOT:-/private/var/tmp/_bazel_$USER}"
WORKTREE_PARENT="${FREESPACE_WORKTREE_PARENT:-$HOME/workspace}"
# Project-specific caches, relative to each primary checkout (space-separated).
# Example: PROJECT_CACHE_DIRS=".opensearch python/venv_backup"
PROJECT_CACHE_DIRS="${PROJECT_CACHE_DIRS:-}"
# Directories whose *.log files over LOG_TRUNCATE_THRESHOLD_KB (default 100 MB)
# are truncated in place rather than deleted, so a running process keeps writing.
# Example: LOG_TRUNCATE_DIRS="$HOME/.devdock"
LOG_TRUNCATE_DIRS="${LOG_TRUNCATE_DIRS:-}"
LOG_TRUNCATE_THRESHOLD_KB="${LOG_TRUNCATE_THRESHOLD_KB:-102400}"
AVD_HOME="${ANDROID_AVD_HOME:-${ANDROID_USER_HOME:-$HOME/.android}/avd}"
TEMP_MIN_AGE_DAYS=3       # /tmp, $TMPDIR, npx entries untouched this long are stale
STALE_CACHE_FILE_DAYS=180 # loose ~/Library/Caches files untouched this long
SIM_UNUSED_DAYS=365       # -f: iOS runtimes / Android emulators unused this long
# `bazel clean --expunge_async` renames <output_base> to <name>_tmp_<pid>_<uuid>.
EXPUNGE_LEFTOVER_RE='_tmp_([0-9]+)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# Parse arguments
dry_run=false
full=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n | --dry-run) dry_run=true ;;
    -f | --full) full=true ;;
    -nf | -fn)
      dry_run=true
      full=true
      ;;
    -h | --help)
      cat <<'EOF'
Usage: freespace.sh [-n] [-f]

Modes:
  (default)   Cheap to delete, cheap to recover (safe for daily use):
              - Build caches: .swc, storybook-static, .next, .turbo, __pycache__, etc
              - App caches: ~/Library/Caches/{Xcode,VSCode,Cursor,Chrome,Chrome Beta,
                Firefox,Brave,Edge,Opera,Atlas,ChatGPT,Claude,JetBrains,...}
              - Loose ~/Library/Caches files over 100M untouched for 180 days
              - Updater caches: Granola/Loom/Edge updaters
              - Cursor/VSCode App Support pure caches (Cache, CachedData, logs, etc)
                — workspaceStorage + History are -f only (recovery surfaces)
              - Chromium safe caches (Chrome+Beta)
              - Electron app caches: Slack (incl sandbox), Claude, Claude (3P),
                Granola, Loom, Highlight, Atlas, ChatGPT, Cluely, Slapdash,
                Dropbox Dash, Mighty, Edge, Brave
              - Windsurf App Support safe caches
              - PROJECT_CACHE_DIRS, gcloud logs, ~/.Trash, ~/.cache/*
                (preserves pre-commit)
              - /tmp and $TMPDIR entries untouched for 3 days and not in use
              - ~/Library/Logs (3rd-party app logs only; preserves Apple)
              - Bazel java logs, git temp packs
              - Toolchains: mise prune, unused versioned rustup toolchains
              - Quick restore (~30s): brew cleanup, ~/.npm/_cacache, idle
                ~/.npm/_npx entries, ~/.yarn/berry/cache (unless Plug'n'Play)
              - Git: worktree prune, remove prunable worktrees (refuses if dirty),
                git gc (default prune window — keeps reflog recovery for ~2 weeks)
              - All linked-worktree Bazel output bases and node_modules (preserves
                every repository's main worktree, its output base, and shared cache)
              - Leftovers of an interrupted `bazel clean --expunge_async`
              - Bazel's default repository cache, once ~/.bazelrc points every
                command at a shared one (common --repository_cache)
              - Repo-scoped cleanup covers every primary checkout found under
                ~/workspace, whatever directory freespace is invoked from

  -f          Deep clean — expensive to recover:
              - Docker: images, containers, volumes (docker system prune -a)
              - Colima: fstrim running VMs so the host disk image shrinks
              - iOS Simulator devices, and runtimes not booted for 365 days
              - Android emulators with no file modified for 365 days
              - Claude + Claude (3P) vm_bundles, ~/.cache/pre-commit
              - Cursor/VSCode workspaceStorage + History (per-workspace state +
                Local History — recovery surfaces, not pure caches)
              - System CoreSimulator Caches (flagged for sudo)
              - Keeps primary node_modules + venvs; Gradle, Maven, pnpm store
              - ALL of ~/.cache/bazel (every primary output base, the disk cache
                and repository_cache), legacy Bazel root, go modcache
              - git gc --aggressive

  -n          Dry run — preview everything (default + deep) without deleting
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done

# Dry-run always previews everything
if $dry_run; then
  full=true
fi

# Stats
freed_total=0
items_deleted=0
items_skipped=0
items_failed=0

# Colors and symbols
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
RESET='\033[0m'

DISK_TOTAL_KB=$(df -k ~ | tail -1 | awk '{print $2}')

get_size() {
  local path="$1"
  if [[ -e "$path" ]]; then
    if command -v dust >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      dust -j -P -d 0 -o k "$path" 2>/dev/null | jq .size | sed -E 's/"|K//g'
    else
      du -sk "$path" 2>/dev/null | cut -f1
    fi
  else
    echo 0
  fi
}

format_size() {
  local kb=$1
  local size_str
  if [[ $kb -ge 1048576 ]]; then
    size_str=$(printf "%.1fG" "$(echo "scale=1; $kb / 1048576" | bc)")
  elif [[ $kb -ge 1024 ]]; then
    size_str="$((kb / 1024))M"
  elif [[ $kb -gt 0 ]]; then
    size_str="${kb}K"
  else
    echo "0"
    return
  fi
  local pct
  pct=$(awk "BEGIN {printf \"%.1f\", $kb * 100 / $DISK_TOTAL_KB}")
  echo "$size_str ($pct%)"
}

# Progress spinner for long operations
spin() {
  local pid=$1
  local msg="${2:-}"
  local delay=0.1
  local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while ps -p "$pid" >/dev/null 2>&1; do
    printf "\r  ${DIM}%s %s${RESET}  " "${spinstr:$i:1}" "$msg"
    i=$(((i + 1) % ${#spinstr}))
    sleep $delay
  done
  # Clear the spinner line
  printf "\r%*s\r" $((${#msg} + 10)) ""
}

rm_or_rmz() {
  if command -v rmz >/dev/null 2>&1; then
    rmz "$@"
  else
    rm -rf "$@"
  fi
}

safe_rm() {
  local path="$1"
  local desc="$2"
  local size_kb
  size_kb=$(get_size "$path")

  if [[ $size_kb -eq 0 ]]; then
    echo -e "  ${DIM}· $desc (empty)${RESET}"
    ((items_skipped++))
    return
  fi

  local size_str
  size_str=$(format_size "$size_kb")

  if $dry_run; then
    echo -e "  ${BLUE}○${RESET} $desc ${YELLOW}$size_str${RESET}"
    freed_total=$((freed_total + size_kb))
    ((items_deleted++))
  else
    # Try simple rm/rmz first
    if rm_or_rmz "$path" 2>/dev/null; then
      echo -e "  ${GREEN}✓${RESET} $desc ${GREEN}$size_str${RESET}"
      freed_total=$((freed_total + size_kb))
      ((items_deleted++))
    else
      # Bazel sets dirs read-only; fix permissions then retry
      chmod -R u+w "$path" 2>/dev/null
      chflags -R nouchg "$path" 2>/dev/null
      if rm_or_rmz "$path" 2>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} $desc ${GREEN}$size_str${RESET} (fixed perms)"
        freed_total=$((freed_total + size_kb))
        ((items_deleted++))
      else
        echo -e "  ${RED}✗${RESET} $desc ${RED}$size_str${RESET} (need sudo)"
        ((items_failed++))
      fi
    fi
  fi
}

# Truncates a file to zero bytes without deleting it. Safe to use on files that
# may be held open by running processes (truncation preserves the inode, so the
# writing process keeps its file descriptor and continues writing; the freed
# space is reclaimed immediately by the OS).
safe_truncate() {
  local path="$1"
  local desc="$2"
  local size_kb
  size_kb=$(get_size "$path")

  if [[ $size_kb -eq 0 ]]; then
    echo -e "  ${DIM}· $desc (empty)${RESET}"
    ((items_skipped++))
    return
  fi

  local size_str
  size_str=$(format_size "$size_kb")

  if $dry_run; then
    echo -e "  ${BLUE}○${RESET} $desc ${YELLOW}$size_str${RESET}"
    freed_total=$((freed_total + size_kb))
    ((items_deleted++))
  else
    # Wrap the redirect in a brace group so the outer `2>/dev/null` also
    # silences bash's own "cannot open" message (bash emits that to stderr
    # before any redirection placed inline after `>"$path"` takes effect).
    if { >"$path"; } 2>/dev/null; then
      echo -e "  ${GREEN}✓${RESET} $desc ${GREEN}$size_str${RESET} (truncated)"
      freed_total=$((freed_total + size_kb))
      ((items_deleted++))
    else
      echo -e "  ${RED}✗${RESET} $desc ${RED}$size_str${RESET} (permission denied)"
      ((items_failed++))
    fi
  fi
}

# Cleans the Chromium-style cache subdirs that virtually every Electron app
# drops under Application Support/<app>/. Excludes anything that holds user
# state (Local Storage, IndexedDB, Cookies, Preferences, Partitions, Sessions,
# Service Worker registration data — Service Worker/CacheStorage on the other
# hand is just HTTP cache so it's listed below).
clean_electron_app() {
  local label="$1"
  local base="$2"
  [[ -d "$base" ]] || return

  # Subdirs that browsers/Electron treat as expendable cache. Order matters
  # only for output. Each is silently skipped when absent.
  local subs=(
    "Cache"
    "Code Cache"
    "GPUCache"
    "DawnGraphiteCache"
    "DawnWebGPUCache"
    "GraphiteDawnCache"
    "GrShaderCache"
    "ShaderCache"
    "Shared Dictionary"
    "Crashpad"
    "Service Worker/CacheStorage"
    "Service Worker/ScriptCache"
    "logs"
  )
  local total_kb=0
  local sub size_kb
  for sub in "${subs[@]}"; do
    [[ -d "$base/$sub" ]] || continue
    size_kb=$(get_size "$base/$sub")
    total_kb=$((total_kb + size_kb))
    if ! $dry_run; then
      rm_or_rmz "$base/$sub" 2>/dev/null
    fi
  done

  if [[ $total_kb -eq 0 ]]; then
    echo -e "  ${DIM}· $label (empty)${RESET}"
    ((items_skipped++))
  else
    local size_str
    size_str=$(format_size "$total_kb")
    if $dry_run; then
      echo -e "  ${BLUE}○${RESET} $label ${YELLOW}$size_str${RESET}"
    else
      echo -e "  ${GREEN}✓${RESET} $label ${GREEN}$size_str${RESET}"
    fi
    freed_total=$((freed_total + total_kb))
    ((items_deleted++))
  fi
}

# Chromium-profile safe caches: bigger model/snapshot dirs that aren't part of
# the Electron list above. Used for both Chrome and Chrome Beta.
clean_chromium_profile() {
  local label="$1"
  local base="$2"
  [[ -d "$base" ]] || {
    echo -e "  ${DIM}· $label (not installed)${RESET}"
    ((items_skipped++))
    return
  }

  safe_rm "$base/OptGuideOnDeviceModel" "$label ML model"
  safe_rm "$base/optimization_guide_model_store" "$label optimization models"
  safe_rm "$base/Snapshots" "$label Snapshots"
  safe_rm "$base/extensions_crx_cache" "$label extensions cache"
  safe_rm "$base/component_crx_cache" "$label component cache"
  safe_rm "$base/Crashpad" "$label Crashpad"
  safe_rm "$base/GraphiteDawnCache" "$label GraphiteDawnCache"
  safe_rm "$base/GrShaderCache" "$label GrShaderCache"
  safe_rm "$base/ShaderCache" "$label ShaderCache"
}

safe_rm_pattern() {
  local base="$1"
  local pattern="$2"
  local desc="$3"

  if [[ ! -d "$base" ]]; then
    return
  fi

  local total_kb=0
  local count=0

  # -H: follow a symlinked base (e.g. /tmp -> /private/tmp); plain find lists
  # nothing there. -prune: a matching directory is counted and removed as a
  # whole, so never descend into it and count its contents a second time.
  while IFS= read -r -d '' file; do
    local size_kb
    size_kb=$(get_size "$file")
    total_kb=$((total_kb + size_kb))
    count=$((count + 1))

    if ! $dry_run; then
      rm_or_rmz "$file" 2>/dev/null
    fi
  done < <(find -H "$base" -mindepth 1 -name "$pattern" -prune -print0 2>/dev/null)

  if [[ $count -gt 0 ]]; then
    local size_str
    size_str=$(format_size "$total_kb")
    if $dry_run; then
      echo -e "  ${BLUE}○${RESET} $desc ${DIM}($count)${RESET} ${YELLOW}$size_str${RESET}"
    else
      echo -e "  ${GREEN}✓${RESET} $desc ${DIM}($count)${RESET} ${GREEN}$size_str${RESET}"
    fi
    freed_total=$((freed_total + total_kb))
    ((items_deleted++))
  else
    echo -e "  ${DIM}· $desc (none)${RESET}"
    ((items_skipped++))
  fi
}

# Deletes top-level entries of a scratch directory (/tmp, $TMPDIR, npx cache)
# that look abandoned. An entry is kept when anything inside it changed in the
# last <days> days, when it holds a socket or FIFO (agents, IPC listeners), when
# a running process names its path or holds a file in it open, or when its name
# matches one of the extra glob patterns (system-owned entries). Entries owned
# by other users are skipped.
clean_stale_entries() {
  local base="$1"
  local desc="$2"
  local days="$3"
  shift 3
  local physical
  physical=$(cd "$base" 2>/dev/null && pwd -P) || return
  base="${base%/}"

  local procs open entry name keep_glob size_kb short
  local total_kb=0
  local count=0
  procs=$(ps -axww -o command= 2>/dev/null)
  # Top-level names a process holds open (files, cwd, mapped libraries). lsof
  # prints resolved paths, so match against the physical base.
  open=$(lsof -nP -Fn 2>/dev/null | awk -v p="n$physical/" \
    'index($0, p) == 1 { s = substr($0, length(p) + 1); sub("/.*", "", s); print s }' | sort -u)
  # /tmp and /var are symlinks into /private; processes may use either form.
  short="${physical#/private}"

  while IFS= read -r -d '' entry; do
    name="${entry#"$physical"/}"
    for keep_glob in "$@"; do
      # shellcheck disable=SC2053 # intentional glob match
      [[ "$name" == $keep_glob ]] && continue 2
    done
    [[ "$procs" == *"$physical/$name"* || "$procs" == *"$short/$name"* || "$procs" == *"$base/$name"* ]] && continue
    [[ $'\n'"$open"$'\n' == *$'\n'"$name"$'\n'* ]] && continue
    [[ -n $(find "$entry" \( -mmin "-$((days * 1440))" -o -type s -o -type p \) -print -quit 2>/dev/null) ]] && continue

    size_kb=$(get_size "$entry")
    if ! $dry_run; then
      rm_or_rmz "$entry" 2>/dev/null
      [[ -e "$entry" || -L "$entry" ]] && continue
    fi
    total_kb=$((total_kb + size_kb))
    count=$((count + 1))
  done < <(find "$physical" -mindepth 1 -maxdepth 1 -user "$USER" -print0 2>/dev/null)

  if [[ $count -gt 0 ]]; then
    local size_str
    size_str=$(format_size "$total_kb")
    if $dry_run; then
      echo -e "  ${BLUE}○${RESET} $desc ${DIM}($count)${RESET} ${YELLOW}$size_str${RESET}"
    else
      echo -e "  ${GREEN}✓${RESET} $desc ${DIM}($count)${RESET} ${GREEN}$size_str${RESET}"
    fi
    freed_total=$((freed_total + total_kb))
    ((items_deleted++))
  else
    echo -e "  ${DIM}· $desc (none untouched for ${days}d)${RESET}"
    ((items_skipped++))
  fi
}

# Prints the last value a bazelrc gives `<command> --<flag>` (last one wins, as
# in Bazel), with a leading ~ expanded. Config-specific lines (build:macos) are
# ignored. Prints nothing when the flag is not set.
bazelrc_flag_value() {
  local rc="$1"
  local command="$2"
  local flag="$3"
  local value
  [[ -f "$rc" ]] || return
  value=$(sed -nE "s/^[[:space:]]*${command}[[:space:]](.*[[:space:]])?--${flag}[=[:space:]]\"?([^\"[:space:]]+).*/\2/p" "$rc" | tail -1)
  [[ -n "$value" ]] && printf '%s\n' "${value/#\~/$HOME}"
}

# Physical path when the directory exists, else the path without a trailing /.
physical_path() {
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "${1%/}"
}

# Prints the version part of a versioned rustup toolchain name
# (1.94.0-aarch64-apple-darwin -> 1.94.0); nothing for stable/nightly/custom.
rust_version() {
  [[ "$1" =~ ^([0-9]+\.[0-9]+(\.[0-9]+)?)(-|$) ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

get_repository_roots() {
  local dir current_repo

  current_repo=$(git rev-parse --show-toplevel 2>/dev/null) || true
  [[ -n "$current_repo" && -e "$current_repo/.git" ]] && printf '%s\n' "$current_repo"

  for dir in "$WORKTREE_PARENT"/*/; do
    [[ -d "$dir" ]] || continue
    [[ -e "${dir}.git" ]] && printf '%s\n' "${dir%/}"
  done
}

get_main_worktree_for_repo() {
  git -C "$1" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree / { print substr($0, 10); exit }'
}

get_primary_worktrees() {
  local repo
  while IFS= read -r repo; do
    get_main_worktree_for_repo "$repo"
  done < <(get_repository_roots) | sort -u
}

get_worktrees() {
  local repo
  while IFS= read -r repo; do
    git -C "$repo" worktree list --porcelain 2>/dev/null \
      | awk 'BEGIN { seen = 0 } /^worktree / { if (seen++ > 0) print substr($0, 10) "/" }'
  done < <(get_repository_roots) | sort -u
}

get_script_main_worktree() {
  local current_repo main_worktree
  current_repo=$(git rev-parse --show-toplevel 2>/dev/null) || true
  if [[ -n "$current_repo" ]]; then
    main_worktree=$(get_main_worktree_for_repo "$current_repo")
    [[ -n "$main_worktree" ]] && printf '%s\n' "$main_worktree"
  fi
}

display_worktree_path() {
  local path="${1%/}"
  if [[ "$path" == "$HOME/"* ]]; then
    printf '~/%s\n' "${path#"$HOME/"}"
  else
    printf '%s\n' "$path"
  fi
}

is_primary_worktree() {
  local path primary
  [[ -d "$1" ]] || return 1
  path=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  while IFS= read -r primary; do
    [[ -n "$primary" ]] || continue
    primary=$(cd "$primary" 2>/dev/null && pwd -P) || continue
    [[ "$path" == "$primary" ]] && return 0
  done <<<"$PRIMARY_WORKTREES"
  return 1
}

# Resolve one repository's bazel output_base. Symlink targets are resolved
# physically, so a relative link (e.g. ../../x/.bazel/out in a sibling worktree)
# lands on the real output base instead of a path assembled from the link text.
get_repo_output_base() {
  local repo="$1"
  [[ -n "$repo" && -d "$repo" ]] || return

  # Try convenience symlinks before invoking bazel (which is slow and can fail).
  # .bazel/out -> <output_base>/execroot/_main/bazel-out          (up 3)
  # .bazel/bin -> <output_base>/execroot/_main/bazel-out/<cfg>/bin (up 5)
  # bazel-out  -> <output_base>/execroot/_main/bazel-out          (up 3)
  local link resolved ob levels i
  for entry in ".bazel/out:3" ".bazel/bin:5" "bazel-out:3"; do
    link="${entry%:*}"
    levels="${entry##*:}"
    [[ -L "$repo/$link" ]] || continue
    resolved=$(cd "$repo/$link" 2>/dev/null && pwd -P) || continue
    [[ -n "$resolved" ]] || continue
    ob="$resolved"
    for ((i = 0; i < levels; i++)); do
      ob=$(dirname "$ob")
    done
    [[ -d "$ob" ]] && {
      echo "$ob"
      return
    }
  done

  # Fall back to asking bazel, but only for real bazel workspaces: otherwise
  # this would start a bazel server once per non-bazel repository.
  [[ -e "$repo/WORKSPACE" || -e "$repo/WORKSPACE.bazel" || -e "$repo/MODULE.bazel" ]] || return
  (cd "$repo" && bazel info output_base 2>/dev/null) || true
}

# True when the path is the output base of some primary checkout. Those are the
# build state actually in use, so default mode preserves them.
is_primary_output_base() {
  local candidate="$1" ob
  [[ -n "$candidate" ]] || return 1
  while IFS= read -r ob; do
    [[ -n "$ob" ]] || continue
    [[ "$candidate" == "$ob" ]] && return 0
  done <<<"$PRIMARY_OUTPUT_BASES"
  return 1
}

# Repo-scoped cleanup runs over every primary checkout discovered under
# WORKTREE_PARENT (plus the invoking repository), so the result does not depend
# on which directory freespace was started from. FREESPACE_MAIN_WORKSPACE
# narrows the run to a single repository.
if [[ -n "$MAIN_WORKSPACE" ]]; then
  PRIMARY_WORKTREES=$(get_main_worktree_for_repo "$MAIN_WORKSPACE")
  [[ -n "$PRIMARY_WORKTREES" ]] || PRIMARY_WORKTREES="$MAIN_WORKSPACE"
else
  PRIMARY_WORKTREES=$(get_primary_worktrees)
  # Put the invoking repository first so its git gc runs before the others.
  script_primary=$(get_script_main_worktree)
  if [[ -n "$script_primary" ]]; then
    PRIMARY_WORKTREES=$(printf '%s\n%s\n' "$script_primary" "$PRIMARY_WORKTREES" \
      | awk 'NF && !seen[$0]++')
  fi
fi

if [[ -z "$PRIMARY_WORKTREES" ]]; then
  echo "freespace: no git repository found in $WORKTREE_PARENT or the current directory" >&2
  echo "freespace: cd into a repository, or set FREESPACE_WORKTREE_PARENT /" >&2
  echo "freespace: FREESPACE_MAIN_WORKSPACE to point at one explicitly." >&2
  exit 1
fi

primary_count=$(printf '%s\n' "$PRIMARY_WORKTREES" | grep -c '[^[:space:]]')

# Collect each primary's output base once; reused for preservation checks and
# for discovering which bazel roots to scan.
PRIMARY_OUTPUT_BASES=""
while IFS= read -r primary_repo; do
  [[ -n "$primary_repo" ]] || continue
  primary_ob=$(get_repo_output_base "$primary_repo")
  [[ -n "$primary_ob" && -d "$primary_ob" ]] || continue
  PRIMARY_OUTPUT_BASES="${PRIMARY_OUTPUT_BASES}${primary_ob}"$'\n'
done <<<"$PRIMARY_WORKTREES"

# Count linked worktrees
worktree_count=$(get_worktrees | wc -l | tr -d ' ')

# Header
start_time=$SECONDS
echo ""
if $dry_run && $full; then
  echo -e "🔍 ${YELLOW}DRY RUN (full)${RESET} - showing what would be deleted"
elif $dry_run; then
  echo -e "🔍 ${YELLOW}DRY RUN${RESET} - showing what would be deleted"
elif $full; then
  echo -e "🧹 ${GREEN}Deep cleaning disk space...${RESET}"
else
  echo -e "🧹 ${GREEN}Cleaning disk space...${RESET}"
fi
echo ""

# Show disk before
disk_info=$(df -h ~ | tail -1)
avail_before=$(echo "$disk_info" | awk '{print $4}')
pct_before=$(echo "$disk_info" | awk '{gsub(/%/,"",$5); print $5}')
echo -e "💾 Disk: ${YELLOW}$pct_before%${RESET} full (${avail_before} available)"
echo ""

# ═══════════════════════════════════════════════════════════════════
echo -e "━━━ ${BLUE}Bazel${RESET} ${DIM}(secondary worktree builds first, java logs after)${RESET}"

# Per-worktree bazel output bases (~/.cache/bazel/_userroot/<hash>/ when
# ~/.bazelrc sets --output_user_root, /private/var/tmp/_bazel_$USER/<hash>/ on
# default Bazel). Each one is identified
# by DO_NOT_BUILD_HERE, which records the workspace path. Preserve the main
# workspace's output base and the shared cache/ and install/ directories.
# Bazel output bases re-link from the preserved disk cache, so recovery is one
# extra incremental build rather than a from-scratch rebuild.
if ! $dry_run; then
  echo -e "  ${DIM}shutting down bazel...${RESET}"
  pkill -9 -f "bazel.*_bazel_$USER" 2>/dev/null || true
  while IFS= read -r repo; do
    [[ -n "$repo" && -x "$repo/tools/mybazel.sh" ]] || continue
    "$repo/tools/mybazel.sh" shutdown 2>/dev/null </dev/null || true
  done <<<"$PRIMARY_WORKTREES"
  sleep 1
fi

# Scan the output_user_root of every primary checkout (repos can use different
# bazel layouts) plus the legacy root, deduped.
bazel_roots=()
legacy_is_separate=true
while IFS= read -r ob_entry; do
  [[ -n "$ob_entry" ]] || continue
  ob_root=$(dirname "$ob_entry")
  [[ "$ob_root" == "$BAZEL_ROOT" ]] && legacy_is_separate=false
  root_known=false
  for known_root in ${bazel_roots[@]+"${bazel_roots[@]}"}; do
    [[ "$known_root" == "$ob_root" ]] && {
      root_known=true
      break
    }
  done
  $root_known || bazel_roots+=("$ob_root")
done <<<"$PRIMARY_OUTPUT_BASES"
$legacy_is_separate && bazel_roots+=("$BAZEL_ROOT")

ob_count=0
ob_freed=0

for bazel_root in "${bazel_roots[@]}"; do
  [[ -d "$bazel_root" ]] || continue

  for ob in "$bazel_root"/*/; do
    ob="${ob%/}"
    is_primary_output_base "$ob" && continue
    ws=$(cat "$ob/DO_NOT_BUILD_HERE" 2>/dev/null)

    if [[ "$(basename "$ob")" =~ $EXPUNGE_LEFTOVER_RE ]]; then
      # `bazel clean --expunge_async` renames the output base to this name and
      # deletes it in the background. When that delete never finishes (sleep,
      # reboot, crash), the copy stays forever. DO_NOT_BUILD_HERE still names
      # the primary checkout (or is already gone), so match on the name and
      # skip only while the Bazel server or the background rm is alive.
      expunge_pid="${BASH_REMATCH[1]}"
      ps -p "$expunge_pid" >/dev/null 2>&1 && continue
      pgrep -f "$ob" >/dev/null 2>&1 && continue
      wsname=$(basename "${ws:-$ob}")
      short="pid $expunge_pid"
      reason="interrupted clean"
    else
      # Only real output bases have DO_NOT_BUILD_HERE; skips cache/, install/, etc.
      [[ -f "$ob/DO_NOT_BUILD_HERE" ]] || continue
      is_primary_worktree "$ws" && continue
      wsname=$(basename "$ws")
      short=$(basename "$ob" | cut -c1-8)
      reason="worktree"
      [[ ! -d "$ws" ]] && reason="orphan"
    fi

    size_kb=$(get_size "$ob")
    size_str=$(format_size "$size_kb")

    if $dry_run; then
      echo -e "  ${BLUE}○${RESET} $wsname ${DIM}($short, $reason)${RESET} ${YELLOW}$size_str${RESET}"
      ob_freed=$((ob_freed + size_kb))
      ((ob_count++))
    else
      chmod -R u+w "$ob" 2>/dev/null
      chflags -R nouchg "$ob" 2>/dev/null
      if rm_or_rmz "$ob" 2>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} $wsname ${DIM}($short, $reason)${RESET} ${GREEN}$size_str${RESET}"
        ob_freed=$((ob_freed + size_kb))
        ((ob_count++))
      else
        echo -e "  ${RED}✗${RESET} $wsname ${DIM}($short, $reason)${RESET} ${RED}$size_str${RESET} (need sudo)"
        ((items_failed++))
      fi
    fi
  done

  safe_rm_pattern "$bazel_root" "java.log.*" "java logs"
done

if $full && $legacy_is_separate && [[ -d "$BAZEL_ROOT" ]]; then
  # The legacy root can contain shared cache/install entries without
  # DO_NOT_BUILD_HERE. Keep this broad sweep behind -f.
  for legacy_entry in "$BAZEL_ROOT"/*/; do
    legacy_entry="${legacy_entry%/}"
    is_primary_output_base "$legacy_entry" && continue
    [[ -e "$legacy_entry/DO_NOT_BUILD_HERE" ]] && continue
    safe_rm "$legacy_entry" "legacy Bazel $(basename "$legacy_entry")"
  done
fi

if [[ $ob_count -gt 0 ]]; then
  freed_total=$((freed_total + ob_freed))
  ((items_deleted += ob_count))
  echo -e "  ${DIM}── $ob_count output base(s), $(format_size "$ob_freed") total${RESET}"
else
  echo -e "  ${DIM}· no secondary-worktree output bases${RESET}"
  ((items_skipped++))
fi

# Bazel's default repository cache is <output_user_root>/cache/repos. Once
# ~/.bazelrc sends every command to a shared cache (`common --repository_cache`),
# nothing uses the default one. Output
# bases may still link external repos into its contents/; Bazel sees the missing
# target and fetches those repos again (into the shared cache) on next use.
# Without that global line, worktrees (no .bazelrc.user) and commands that skip
# `build` options (query, mod) still use the default cache, so keep it.
bazel_user_root=$(bazelrc_flag_value "$HOME/.bazelrc" startup output_user_root)
default_repo_cache="${bazel_user_root:-$BAZEL_ROOT}/cache/repos"
shared_repo_cache=$(bazelrc_flag_value "$HOME/.bazelrc" common repository_cache)
if [[ -d "$default_repo_cache" && -n "$shared_repo_cache" && "$shared_repo_cache" != *%* ]]; then
  default_repo_cache=$(physical_path "$default_repo_cache")
  shared_repo_cache=$(physical_path "$shared_repo_cache")
  if [[ "$shared_repo_cache/" != "$default_repo_cache/"* ]]; then
    safe_rm "$default_repo_cache" "duplicate default repository cache"
  fi
elif [[ -d "$default_repo_cache" ]]; then
  while IFS= read -r repo; do
    [[ -n "$(bazelrc_flag_value "$repo/.bazelrc.user" build repository_cache)" ]] || continue
    echo -e "  ${YELLOW}!${RESET} default repository cache ${YELLOW}$(format_size "$(get_size "$default_repo_cache")")${RESET} ${DIM}(kept: worktrees still use it; set a shared `common --repository_cache` in ~/.bazelrc)${RESET}"
    ((items_skipped++))
    break
  done <<<"$PRIMARY_WORKTREES"
fi

# ═══════════════════════════════════════════════════════════════════
echo -e "━━━ ${BLUE}Build Caches${RESET} ${DIM}(auto-regenerate)${RESET}"

# Repo-scoped build caches, for every primary checkout.
while IFS= read -r repo; do
  [[ -n "$repo" && -d "$repo" ]] || continue
  tag=""
  [[ $primary_count -gt 1 ]] && tag=" ($(basename "$repo"))"

  safe_rm_pattern "$repo/.git/objects/pack" "tmp_pack_*" "git temp packs$tag"

  # Stale .git/index.stash.* — leftovers from interrupted stash/rebase/autostash.
  # Top-level only (no recursion); harmless to delete.
  stash_count=0
  stash_freed=0
  for f in "$repo"/.git/index.stash.*; do
    [[ -f "$f" ]] || continue
    sz=$(get_size "$f")
    stash_freed=$((stash_freed + sz))
    ((stash_count++))
    $dry_run || rm_or_rmz "$f" 2>/dev/null
  done
  if [[ $stash_count -gt 0 ]]; then
    sz_str=$(format_size "$stash_freed")
    if $dry_run; then
      echo -e "  ${BLUE}○${RESET} stale .git/index.stash.*$tag ${DIM}($stash_count)${RESET} ${YELLOW}$sz_str${RESET}"
    else
      echo -e "  ${GREEN}✓${RESET} stale .git/index.stash.*$tag ${DIM}($stash_count)${RESET} ${GREEN}$sz_str${RESET}"
    fi
    freed_total=$((freed_total + stash_freed))
    ((items_deleted++))
  else
    echo -e "  ${DIM}· stale .git/index.stash.*$tag (none)${RESET}"
    ((items_skipped++))
  fi

  safe_rm "$repo/storybook-static" "storybook-static$tag"
  safe_rm "$repo/.swc" ".swc$tag"
  safe_rm "$repo/.mypy_cache" ".mypy_cache$tag"
  safe_rm "$repo/.pytest_cache" ".pytest_cache$tag"
  safe_rm "$repo/.ruff_cache" ".ruff_cache$tag"
  safe_rm "$repo/.next" ".next$tag"
  safe_rm "$repo/.turbo" ".turbo$tag"

  # __pycache__ directories (skips node_modules, .git, and virtualenvs)
  if [[ -d "$repo" ]]; then
    pycache_size=0
    pycache_count=0
    while IFS= read -r -d '' dir; do
      size=$(get_size "$dir")
      pycache_size=$((pycache_size + size))
      pycache_count=$((pycache_count + 1))
      if ! $dry_run; then
        rm_or_rmz "$dir" 2>/dev/null
      fi
    done < <(find "$repo" -type d \( -name node_modules -o -name .git -o -name .venv -o -name venv \) -prune -o -type d -name "__pycache__" -print0 2>/dev/null)

    if [[ $pycache_count -gt 0 ]]; then
      size_str=$(format_size "$pycache_size")
      if $dry_run; then
        echo -e "  ${BLUE}○${RESET} __pycache__$tag ${DIM}($pycache_count dirs)${RESET} ${YELLOW}$size_str${RESET}"
      else
        echo -e "  ${GREEN}✓${RESET} __pycache__$tag ${DIM}($pycache_count dirs)${RESET} ${GREEN}$size_str${RESET}"
      fi
      freed_total=$((freed_total + pycache_size))
      ((items_deleted++))
    else
      echo -e "  ${DIM}· __pycache__$tag (none)${RESET}"
      ((items_skipped++))
    fi
  fi
done <<<"$PRIMARY_WORKTREES"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}App Caches${RESET} ${DIM}(~/Library/Caches)${RESET}"

safe_rm "$HOME/Library/Caches/com.apple.dt.Xcode" "Xcode"
safe_rm "$HOME/Library/Caches/com.microsoft.VSCode" "VSCode"
safe_rm "$HOME/Library/Caches/com.todesktop.230313mzl4w4u92" "Cursor"
safe_rm "$HOME/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt" "Cursor ShipIt"
safe_rm "$HOME/Library/Caches/Google" "Google"
safe_rm "$HOME/Library/Caches/com.google.Chrome" "Chrome"
safe_rm "$HOME/Library/Caches/com.google.Chrome.beta" "Chrome Beta"
safe_rm "$HOME/Library/Caches/Arc" "Arc"
safe_rm "$HOME/Library/Caches/Firefox" "Firefox"
safe_rm "$HOME/Library/Caches/Mozilla" "Mozilla"
safe_rm "$HOME/Library/Caches/BraveSoftware" "Brave"
safe_rm "$HOME/Library/Caches/com.operasoftware.Opera" "Opera"
safe_rm "$HOME/Library/Caches/com.microsoft.edgemac" "Edge"
safe_rm "$HOME/Library/Caches/com.openai.atlas" "OpenAI Atlas"
safe_rm "$HOME/Library/Caches/com.openai.chat" "ChatGPT"
safe_rm "$HOME/Library/Caches/com.anthropic.claudefordesktop" "Claude Desktop"
safe_rm "$HOME/Library/Caches/com.anthropic.claudefordesktop.ShipIt" "Claude Desktop ShipIt"
safe_rm "$HOME/Library/Caches/@granolaelectron-updater" "Granola updater"
safe_rm "$HOME/Library/Caches/loom-updater" "Loom updater"
safe_rm "$HOME/Library/Caches/us.zoom.xos" "Zoom"
safe_rm "$HOME/Library/Caches/pip" "pip"
safe_rm "$HOME/Library/Caches/pip-tools" "pip-tools"
safe_rm "$HOME/Library/Caches/virtualenv" "virtualenv"
safe_rm "$HOME/Library/Caches/Homebrew" "Homebrew"
safe_rm "$HOME/Library/Caches/JetBrains" "JetBrains"
safe_rm "$HOME/Library/Caches/go-build" "go-build"
safe_rm "$HOME/Library/Caches/gopls" "gopls"
safe_rm "$HOME/Library/Caches/goimports" "goimports"
safe_rm "$HOME/Library/Caches/pnpm" "pnpm"
safe_rm "$HOME/Library/Caches/Yarn" "Yarn"
safe_rm "$HOME/Library/Caches/node-gyp" "node-gyp"
safe_rm "$HOME/Library/Caches/electron" "electron"
safe_rm "$HOME/Library/Caches/ms-playwright" "Playwright"
safe_rm "$HOME/Library/Caches/bazelisk" "bazelisk"
safe_rm "$HOME/Library/Caches/colima" "colima"
safe_rm "$HOME/Library/Caches/mise" "mise"
safe_rm "$HOME/Library/Caches/helm" "helm"
safe_rm "$HOME/Library/Caches/Coursier" "Coursier"
safe_rm "$HOME/Library/Caches/typescript" "typescript"
safe_rm "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt" "VSCode ShipIt"

# Big loose files at the top of ~/Library/Caches that nothing has written for
# months, e.g. a requests-cache SQLite DB left by a one-off script. Apps must
# tolerate losing anything in Caches; Apple's own com.apple.* files are kept.
stale_cache_count=0
while IFS= read -r -d '' stale_cache; do
  safe_rm "$stale_cache" "stale file: $(basename "$stale_cache")"
  ((stale_cache_count++))
done < <(find "$HOME/Library/Caches" -mindepth 1 -maxdepth 1 -type f -size +100M \
  -mtime "+$STALE_CACHE_FILE_DAYS" ! -name 'com.apple.*' -print0 2>/dev/null)
if [[ $stale_cache_count -eq 0 ]]; then
  echo -e "  ${DIM}· stale files over 100M (none untouched for ${STALE_CACHE_FILE_DAYS}d)${RESET}"
  ((items_skipped++))
fi

# Updater download caches living under Application Support/Caches/. Stick to
# the *-updater / *Updater naming convention so we never silently nuke
# something a future macOS subsystem or buggy app drops here.
if [[ -d "$HOME/Library/Application Support/Caches" ]]; then
  shopt -s nullglob
  for upd in "$HOME/Library/Application Support/Caches"/*-updater \
    "$HOME/Library/Application Support/Caches"/*Updater; do
    [[ -d "$upd" ]] || continue
    safe_rm "$upd" "AppSupport updater: $(basename "$upd")"
  done
  shopt -u nullglob
fi
safe_rm "$HOME/Library/Application Support/Microsoft/EdgeUpdater" "Edge updater"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Cursor/VSCode App Support${RESET} ${DIM}(editor caches)${RESET}"

safe_rm "$HOME/Library/Application Support/Cursor/Cache" "Cursor Cache"
safe_rm "$HOME/Library/Application Support/Cursor/CachedData" "Cursor CachedData"
safe_rm "$HOME/Library/Application Support/Cursor/CachedExtensionVSIXs" "Cursor CachedVSIXs"
safe_rm "$HOME/Library/Application Support/Cursor/logs" "Cursor logs"
safe_rm "$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb.backup" "Cursor state backup"
# workspaceStorage (per-workspace UI state: open tabs, search history, breakpoints)
# and History (Cursor Local History — file-level edit recovery for unversioned saves)
# are recovery surfaces, not pure caches. Moved to -f.
safe_rm "$HOME/Library/Application Support/Cursor/Partitions" "Cursor Partitions"
safe_rm "$HOME/Library/Application Support/Cursor/WebStorage" "Cursor WebStorage"
safe_rm "$HOME/Library/Application Support/Cursor/GPUCache" "Cursor GPUCache"
safe_rm "$HOME/Library/Application Support/Cursor/CachedProfilesData" "Cursor CachedProfilesData"
safe_rm "$HOME/Library/Application Support/Code/Cache" "VSCode Cache"
safe_rm "$HOME/Library/Application Support/Code/CachedData" "VSCode CachedData"
safe_rm "$HOME/Library/Application Support/Code/CachedExtensionVSIXs" "VSCode CachedVSIXs"
safe_rm "$HOME/Library/Application Support/Code/logs" "VSCode logs"
safe_rm "$HOME/Library/Application Support/Code/Crashpad" "VSCode Crashpad"
safe_rm "$HOME/Library/Application Support/Code/WebStorage" "VSCode WebStorage"
safe_rm "$HOME/Library/Application Support/Code/GPUCache" "VSCode GPUCache"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Chromium browsers${RESET} ${DIM}(safe caches, keeps profile data)${RESET}"

clean_chromium_profile "Chrome" "$HOME/Library/Application Support/Google/Chrome"
clean_chromium_profile "Chrome Beta" "$HOME/Library/Application Support/Google/Chrome Beta"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Electron apps${RESET} ${DIM}(Cache, Code Cache, GPUCache, logs)${RESET}"

# Each app's user state (chats, cookies, preferences) is preserved — only the
# regenerable Cache/Code Cache/GPUCache/Service Worker HTTP cache is removed.
clean_electron_app "Slack" "$HOME/Library/Application Support/Slack"
clean_electron_app "Slack (sandbox)" "$HOME/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack"
clean_electron_app "Claude Desktop" "$HOME/Library/Application Support/Claude"
clean_electron_app "Claude Desktop (3P)" "$HOME/Library/Application Support/Claude-3p"
clean_electron_app "Granola" "$HOME/Library/Application Support/Granola"
clean_electron_app "Loom" "$HOME/Library/Application Support/Loom"
clean_electron_app "Highlight" "$HOME/Library/Application Support/Highlight"
clean_electron_app "OpenAI Atlas" "$HOME/Library/Application Support/com.openai.atlas"
clean_electron_app "ChatGPT" "$HOME/Library/Application Support/com.openai.chat"
clean_electron_app "Cluely" "$HOME/Library/Application Support/cluely"
clean_electron_app "Slapdash" "$HOME/Library/Application Support/Slapdash"
clean_electron_app "Dropbox Dash" "$HOME/Library/Application Support/Dropbox Dash"
clean_electron_app "Mighty" "$HOME/Library/Application Support/Mighty"
clean_electron_app "Microsoft Edge" "$HOME/Library/Application Support/Microsoft Edge"
clean_electron_app "Brave" "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}App Support${RESET} ${DIM}(Windsurf caches)${RESET}"

safe_rm "$HOME/Library/Application Support/Windsurf/Cache" "Windsurf Cache"
safe_rm "$HOME/Library/Application Support/Windsurf/CachedData" "Windsurf CachedData"
safe_rm "$HOME/Library/Application Support/Windsurf/CachedExtensionVSIXs" "Windsurf CachedVSIXs"
safe_rm "$HOME/Library/Application Support/Windsurf/logs" "Windsurf logs"
safe_rm "$HOME/Library/Application Support/Windsurf/GPUCache" "Windsurf GPUCache"
safe_rm "$HOME/Library/Application Support/Windsurf/WebStorage" "Windsurf WebStorage"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}System${RESET} ${DIM}(Trash, temp files, app logs)${RESET}"

safe_rm "$HOME/.Trash" "Trash"
# Temp dirs: only entries untouched for TEMP_MIN_AGE_DAYS, so running jobs keep
# their files. macOS only empties these on reboot. Per-user com.apple.* and
# TemporaryItems entries belong to system services and are left alone.
clean_stale_entries "/tmp" "temp files (/tmp)" "$TEMP_MIN_AGE_DAYS" 'com.apple.*'
user_temp_dir=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)
if [[ -n "$user_temp_dir" ]]; then
  clean_stale_entries "$user_temp_dir" "user temp files (\$TMPDIR)" "$TEMP_MIN_AGE_DAYS" \
    'com.apple.*' 'TemporaryItems'
fi

# Third-party app logs only. Apple's own subsystems own most ~/Library/Logs/
# entries (DiagnosticReports, CrashReporter, com.apple.* …) and we leave those
# alone so users keep crash history. Allowlist the noisy chatty apps.
for log in "Webex Meetings" "SparkMacDesktop" "CoreSimulator" "Claude" "Claude-3p" \
  "zoom.us" "Loom" "webexmta" "Glean" "Docker Desktop" \
  "SiriTTSService" "ZoomPhone" "Microsoft Teams Helper (Renderer)" \
  "@granolaelectron-updater" "loom-updater" "AtlasUpdateHelper.log"; do
  [[ -e "$HOME/Library/Logs/$log" ]] || continue
  safe_rm "$HOME/Library/Logs/$log" "log: $log"
done

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Worktrees${RESET} ${DIM}($worktree_count found)${RESET}"

while IFS= read -r wt; do
  wt_name=$(display_worktree_path "$wt")
  wt_freed=0

  for cache in storybook-static .swc .mypy_cache .pytest_cache .ruff_cache .next .turbo .opensearch node_modules; do
    [[ "$cache" == "node_modules" && -L "${wt}${cache}" ]] && continue
    if [[ -e "${wt}${cache}" ]]; then
      size_kb=$(get_size "${wt}${cache}")
      if [[ $size_kb -gt 0 ]]; then
        wt_freed=$((wt_freed + size_kb))
        if ! $dry_run; then
          rm_or_rmz "${wt}${cache}" 2>/dev/null
        fi
      fi
    fi
  done

  if [[ $wt_freed -gt 0 ]]; then
    size_str=$(format_size "$wt_freed")
    if $dry_run; then
      echo -e "  ${BLUE}○${RESET} $wt_name ${YELLOW}$size_str${RESET}"
    else
      echo -e "  ${GREEN}✓${RESET} $wt_name ${GREEN}$size_str${RESET}"
    fi
    freed_total=$((freed_total + wt_freed))
    ((items_deleted++))
  else
    echo -e "  ${DIM}· $wt_name (clean)${RESET}"
    ((items_skipped++))
  fi
done < <(get_worktrees)

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Git${RESET} ${DIM}(compact & prune)${RESET}"

while IFS= read -r repo; do
  [[ -n "$repo" && -d "$repo/.git" ]] || continue
  tag=""
  [[ $primary_count -gt 1 ]] && tag=" ($(basename "$repo"))"

  # Prune stale worktree metadata
  prune_output=$(git -C "$repo" worktree prune --dry-run 2>/dev/null </dev/null)
  if [[ -n "$prune_output" ]]; then
    if $dry_run; then
      echo -e "  ${BLUE}○${RESET} worktree prune$tag (stale refs)"
    else
      git -C "$repo" worktree prune 2>/dev/null </dev/null
      echo -e "  ${GREEN}✓${RESET} worktree prune$tag"
    fi
    ((items_deleted++))
  else
    echo -e "  ${DIM}· worktree prune$tag (nothing stale)${RESET}"
    ((items_skipped++))
  fi

  # Remove prunable worktrees (git marks these automatically when the branch is gone).
  # Intentionally NOT using --force: that silently discards uncommitted changes and
  # untracked files. Plain `worktree remove` refuses on a dirty tree, which is the
  # safety net we want — the user can investigate and force manually if appropriate.
  while IFS= read -r line; do
    if [[ "$line" == *"prunable"* ]]; then
      wt_path=$(echo "$line" | awk '{print $1}')
      wt_branch=$(echo "$line" | sed 's/.*\[\(.*\)\].*/\1/' | sed 's/ prunable//')
      wt_size_kb=$(get_size "$wt_path")
      size_str=$(format_size "$wt_size_kb")

      if $dry_run; then
        echo -e "  ${BLUE}○${RESET} remove prunable: $wt_branch ${YELLOW}$size_str${RESET}"
        freed_total=$((freed_total + wt_size_kb))
        ((items_deleted++))
      else
        if git -C "$repo" worktree remove "$wt_path" 2>/dev/null </dev/null; then
          echo -e "  ${GREEN}✓${RESET} removed prunable: $wt_branch ${GREEN}$size_str${RESET}"
          freed_total=$((freed_total + wt_size_kb))
          ((items_deleted++))
        else
          echo -e "  ${YELLOW}!${RESET} skipped prunable: $wt_branch ${YELLOW}$size_str${RESET} ${DIM}(dirty — review then: git worktree remove --force '$wt_path')${RESET}"
          ((items_skipped++))
        fi
      fi
    fi
  done < <(git -C "$repo" worktree list 2>/dev/null </dev/null)

  # git gc to compact .git object store
  git_size_before=$(get_size "$repo/.git")
  git_size_str=$(format_size "$git_size_before")

  if $dry_run; then
    echo -e "  ${BLUE}○${RESET} git gc$tag (.git is $git_size_str)"
  else
    if $full; then
      # -f is opt-in to the cliff: --prune=now drops dangling objects
      # immediately, so dangling commits from recent reset/rebase/stash
      # drop are unrecoverable via reflog.
      git -C "$repo" gc --aggressive --prune=now 2>/dev/null </dev/null &
      gc_pid=$!
      spin "$gc_pid" "git gc --aggressive$tag (this takes a while)"
    else
      # Default mode honors gc.pruneExpire (2 weeks): recent dangling
      # commits stay reachable via reflog for normal recovery flows.
      git -C "$repo" gc 2>/dev/null </dev/null &
      gc_pid=$!
      spin "$gc_pid" "git gc$tag"
    fi
    wait "$gc_pid"

    git_size_after=$(get_size "$repo/.git")
    gc_freed=$((git_size_before - git_size_after))
    if [[ $gc_freed -gt 0 ]]; then
      gc_freed_str=$(format_size "$gc_freed")
      echo -e "  ${GREEN}✓${RESET} git gc$tag ${GREEN}$gc_freed_str${RESET} freed (.git: $git_size_str → $(format_size "$git_size_after"))"
      freed_total=$((freed_total + gc_freed))
    else
      echo -e "  ${GREEN}✓${RESET} git gc$tag (.git already compact: $git_size_str)"
    fi
    ((items_deleted++))
  fi
done <<<"$PRIMARY_WORKTREES"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Dev Caches${RESET} ${DIM}(~/.cache, PROJECT_CACHE_DIRS)${RESET}"

if [[ -n "$PROJECT_CACHE_DIRS" ]]; then
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    tag=""
    [[ $primary_count -gt 1 ]] && tag=" ($(basename "$repo"))"
    for cache_rel in $PROJECT_CACHE_DIRS; do
      safe_rm "$repo/${cache_rel#/}" "${cache_rel#/}$tag"
    done
  done <<<"$PRIMARY_WORKTREES"
fi
safe_rm "$HOME/.cache/uv" "uv cache"
# gcloud writes one log file per CLI invocation under ~/.config/gcloud/logs/<date>/.
# Pure write-only output (not a cache); deleted dir is recreated on next gcloud call.
safe_rm "$HOME/.config/gcloud/logs" "gcloud logs"
for cache_dir in "$HOME/.cache"/*; do
  [[ -d "$cache_dir" ]] || continue
  cache_name=$(basename "$cache_dir")
  # Skip bazel (-f mode) and uv (handled above)
  case "$cache_name" in
    bazel | uv | pre-commit) continue ;;
  esac
  safe_rm "$cache_dir" "cache/$cache_name"
done

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Service logs${RESET} ${DIM}(truncate oversized *.log under LOG_TRUNCATE_DIRS)${RESET}"

# Truncate *.log files over LOG_TRUNCATE_THRESHOLD_KB. Truncation (not deletion)
# keeps the inode valid so a running service can keep writing without reopening
# the file. The freed space is reclaimed immediately.
if [[ -n "$LOG_TRUNCATE_DIRS" ]]; then
  log_trunc_count=0
  for log_dir in $LOG_TRUNCATE_DIRS; do
    [[ -d "$log_dir" ]] || continue
    while IFS= read -r -d '' logfile; do
      log_kb=$(get_size "$logfile")
      if [[ $log_kb -gt $LOG_TRUNCATE_THRESHOLD_KB ]]; then
        safe_truncate "$logfile" "$(basename "$(dirname "$logfile")")/$(basename "$logfile")"
        ((log_trunc_count++))
      fi
    done < <(find "$log_dir" -name "*.log" -print0 2>/dev/null)
  done
  if [[ $log_trunc_count -eq 0 ]]; then
    echo -e "  ${DIM}· no logs over $((LOG_TRUNCATE_THRESHOLD_KB / 1024))M${RESET}"
    ((items_skipped++))
  fi
else
  echo -e "  ${DIM}· LOG_TRUNCATE_DIRS not set${RESET}"
  ((items_skipped++))
fi

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Colima VM disk${RESET} ${DIM}(container runtime backing store)${RESET}"

# Colima stores Docker's Linux VM disk as a sparse image under
# ~/.colima/_lima/_disks/<instance>/datadisk. The host file grows as Docker
# writes and shrinks only when the VM trims freed blocks (fstrim). -f prunes
# Docker and then trims each running profile; the VM and its settings stay.
COLIMA_DISKS="$HOME/.colima/_lima/_disks"
if [[ -d "$COLIMA_DISKS" ]]; then
  colima_total_kb=0
  colima_disk_count=0
  for disk_dir in "$COLIMA_DISKS"/*/; do
    [[ -d "$disk_dir" ]] || continue
    [[ -f "${disk_dir}datadisk" ]] || continue
    disk_kb=$(get_size "${disk_dir}datadisk")
    colima_total_kb=$((colima_total_kb + disk_kb))
    ((colima_disk_count++))
  done
  if [[ $colima_total_kb -gt 0 ]]; then
    size_str=$(format_size "$colima_total_kb")
    if $full; then
      # The Deep Clean section below prunes and trims; don't suggest -f.
      echo -e "  ${YELLOW}!${RESET} $colima_disk_count disk image(s) ${YELLOW}$size_str${RESET} ${DIM}(pruned and trimmed in Deep Clean below)${RESET}"
    else
      echo -e "  ${YELLOW}!${RESET} $colima_disk_count disk image(s) ${YELLOW}$size_str${RESET} ${DIM}(run with -f to prune Docker and trim the VM disk)${RESET}"
    fi
    ((items_skipped++))
  else
    echo -e "  ${DIM}· colima disks (empty or no datadisk found)${RESET}"
    ((items_skipped++))
  fi
else
  echo -e "  ${DIM}· colima not installed${RESET}"
  ((items_skipped++))
fi

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Toolchains${RESET} ${DIM}(versions nothing references)${RESET}"

# mise prune removes tool versions that no tracked mise config still asks for.
if command -v mise >/dev/null 2>&1; then
  mise_prune_out=$(mise prune --dry-run 2>&1 </dev/null)
  mise_versions=$(printf '%s\n' "$mise_prune_out" | grep -cE '[[:space:]]uninstall$')
  mise_kb=0
  while IFS= read -r mise_path; do
    mise_kb=$((mise_kb + $(get_size "${mise_path/#\~/$HOME}")))
  done < <(printf '%s\n' "$mise_prune_out" | sed -nE 's/.*[[:space:]]remove[[:space:]]+(.+)$/\1/p')
  if [[ $mise_versions -eq 0 ]]; then
    echo -e "  ${DIM}· mise prune (no unused versions)${RESET}"
    ((items_skipped++))
  elif $dry_run; then
    echo -e "  ${BLUE}○${RESET} mise prune ${DIM}($mise_versions)${RESET} ${YELLOW}$(format_size "$mise_kb")${RESET}"
    freed_total=$((freed_total + mise_kb))
    ((items_deleted++))
  elif mise prune --yes >/dev/null 2>&1 </dev/null; then
    echo -e "  ${GREEN}✓${RESET} mise prune ${DIM}($mise_versions)${RESET} ${GREEN}$(format_size "$mise_kb")${RESET}"
    freed_total=$((freed_total + mise_kb))
    ((items_deleted++))
  else
    echo -e "  ${RED}✗${RESET} mise prune failed ${DIM}(run: mise prune)${RESET}"
    ((items_failed++))
  fi
fi

# rustup keeps every toolchain it installs, and mise's `rust = "latest"` adds
# one per release. Remove versioned toolchains (1.94.0-<host>) that are not the
# rustup default, not active in a primary checkout (rust-toolchain file, mise
# env), and not installed by mise. Channel (stable, nightly) and linked
# toolchains are never touched.
if command -v rustup >/dev/null 2>&1; then
  rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
  rust_default=$(rustup default 2>/dev/null </dev/null | awk '{ print $1 }')
  rust_used=" " # versions in use other than through the default fallback
  for mise_rust in "${MISE_DATA_DIR:-$HOME/.local/share/mise}"/installs/rust/*; do
    [[ -e "$mise_rust" ]] && rust_used="$rust_used$(basename "$mise_rust") "
  done
  while IFS= read -r repo; do
    [[ -d "$repo" ]] || continue
    active_line=$(cd "$repo" && rustup show active-toolchain 2>/dev/null </dev/null)
    [[ "$active_line" == *"(default)"* ]] && continue
    rust_used="$rust_used$(rust_version "${active_line%% *}") "
  done <<<"$PRIMARY_WORKTREES"
  rust_default_version=$(rust_version "$rust_default")

  rust_found=false
  while IFS= read -r toolchain; do
    toolchain_version=$(rust_version "$toolchain")
    [[ -n "$toolchain_version" && ! -L "$rustup_home/toolchains/$toolchain" ]] || continue
    [[ "$rust_used" == *" $toolchain_version "* ]] && continue
    if [[ "$toolchain_version" == "$rust_default_version" ]]; then
      # Only the default keeps it. Point at what checkouts use instead.
      rust_target=$(tr ' ' '\n' <<<"$rust_used" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
      [[ -n "$rust_target" ]] || continue
      echo -e "  ${YELLOW}!${RESET} rust $toolchain ${YELLOW}$(format_size "$(get_size "$rustup_home/toolchains/$toolchain")")${RESET} ${DIM}(kept as rustup default; to free it: rustup default $rust_target)${RESET}"
      ((items_skipped++))
      continue
    fi
    rust_found=true
    toolchain_kb=$(get_size "$rustup_home/toolchains/$toolchain")
    if $dry_run; then
      echo -e "  ${BLUE}○${RESET} rust $toolchain ${YELLOW}$(format_size "$toolchain_kb")${RESET}"
    elif rustup toolchain uninstall "$toolchain" >/dev/null 2>&1 </dev/null; then
      echo -e "  ${GREEN}✓${RESET} rust $toolchain ${GREEN}$(format_size "$toolchain_kb")${RESET}"
    else
      echo -e "  ${RED}✗${RESET} rust $toolchain ${DIM}(run: rustup toolchain uninstall $toolchain)${RESET}"
      ((items_failed++))
      continue
    fi
    freed_total=$((freed_total + toolchain_kb))
    ((items_deleted++))
  done < <(rustup toolchain list 2>/dev/null </dev/null | awk '{ print $1 }')
  if ! $rust_found; then
    echo -e "  ${DIM}· rust toolchains (none unused)${RESET}"
    ((items_skipped++))
  fi
fi

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Quick Restore${RESET} ${DIM}(~30s to regenerate)${RESET}"

# Homebrew cleanup (--prune=all removes old Cellar versions too)
if command -v brew &>/dev/null; then
  if $dry_run; then
    brew_out=$(brew cleanup -n --prune=all 2>&1 || true)
    if echo "$brew_out" | grep -q "Would remove"; then
      # Extract the size estimate
      brew_size=$(echo "$brew_out" | grep -o 'approximately [0-9.]*[GMK]B' | tail -1 || echo "")
      echo -e "  ${BLUE}○${RESET} brew cleanup ${YELLOW}${brew_size:+(~$brew_size)}${RESET}"
      ((items_deleted++))
    else
      echo -e "  ${DIM}· brew cleanup (nothing to clean)${RESET}"
      ((items_skipped++))
    fi
  else
    echo -e "  ${DIM}Running brew cleanup...${RESET}"
    brew_out=$(brew cleanup --prune=all 2>&1 || true)
    if echo "$brew_out" | grep -q "Removing\|Pruning"; then
      brew_size=$(echo "$brew_out" | grep -o 'approximately [0-9.]*[GMK]B\|[0-9.]*[GMK]B' | tail -1 || echo "")
      echo -e "  ${GREEN}✓${RESET} brew cleanup ${GREEN}${brew_size:+($brew_size freed)}${RESET}"
      ((items_deleted++))
    else
      echo -e "  ${DIM}· brew cleanup (nothing to clean)${RESET}"
      ((items_skipped++))
    fi
  fi
else
  echo -e "  ${DIM}· brew (not installed)${RESET}"
  ((items_skipped++))
fi

safe_rm "$HOME/.npm/_cacache" "npm cache"
# npx keeps one install per package set. MCP servers often run from here, so
# entries a running process names or holds open (or recently used) are kept.
clean_stale_entries "$HOME/.npm/_npx" "npx cache" "$TEMP_MIN_AGE_DAYS"
# Yarn Plug'n'Play projects load packages straight from this cache, so deleting
# it breaks them until `yarn install`. Keep it when a checkout uses PnP.
if [[ -n $(find "$WORKTREE_PARENT" -maxdepth 3 \( -name node_modules -o -name .git \) -prune \
  -o -name .pnp.cjs -print -quit 2>/dev/null) ]]; then
  echo -e "  ${DIM}· Yarn Berry global cache (kept: a checkout uses Plug'n'Play)${RESET}"
  ((items_skipped++))
else
  safe_rm "$HOME/.yarn/berry/cache" "Yarn Berry global cache"
fi

# ═══════════════════════════════════════════════════════════════════
if $full; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "━━━ ${YELLOW}Deep Clean${RESET} ${DIM}(-f only · expensive to recover)${RESET}"

  # Docker
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    if ! $dry_run; then
      echo -e "  ${DIM}Running docker system prune...${RESET}"
      docker system prune -a --force 2>/dev/null | tail -2
      echo -e "  ${DIM}Running docker volume prune...${RESET}"
      docker volume prune -a --force 2>/dev/null | tail -1
      echo -e "  ${GREEN}✓${RESET} Docker cleanup complete"
      ((items_deleted++))
    else
      echo -e "  ${BLUE}○${RESET} docker prune ${YELLOW}(reclaimable: see docker system df)${RESET}"
      ((items_deleted++))
    fi
  else
    echo -e "  ${DIM}· Docker not running${RESET}"
    ((items_skipped++))
  fi

  # Colima: after the Docker prune above, trim each running VM so the freed
  # blocks go back to macOS. The disk image is sparse, so fstrim shrinks the
  # host file while the VM, its CPU/RAM/disk settings, and anything Docker
  # still uses stay intact. Stopped profiles can't be trimmed; report them.
  # The dry run can't know what the prune will free, so it adds nothing.
  if [[ -d "$COLIMA_DISKS" ]] && command -v colima &>/dev/null; then
    colima_profiles=$(colima list 2>/dev/null </dev/null | awk 'NR > 1 { print $1, $2 }')
    [[ -n "$colima_profiles" ]] || {
      echo -e "  ${DIM}· colima (no profiles)${RESET}"
      ((items_skipped++))
    }
    while read -r colima_profile colima_status; do
      [[ -n "$colima_profile" ]] || continue
      colima_instance="colima"
      [[ "$colima_profile" != "default" ]] && colima_instance="colima-$colima_profile"
      colima_disk="$COLIMA_DISKS/$colima_instance/datadisk"
      disk_before_kb=$(get_size "$colima_disk")
      disk_str=$(format_size "$disk_before_kb")

      if [[ "$colima_status" != "Running" ]]; then
        echo -e "  ${YELLOW}!${RESET} colima $colima_profile ${DIM}($colima_status, disk $disk_str: start it and rerun -f to trim, or: colima delete -p $colima_profile)${RESET}"
        ((items_skipped++))
      elif $dry_run; then
        echo -e "  ${BLUE}○${RESET} colima trim $colima_profile ${DIM}(disk $disk_str; frees what the Docker prune releases)${RESET}"
        ((items_deleted++))
      elif colima ssh -p "$colima_profile" -- sudo fstrim -a </dev/null >/dev/null 2>&1; then
        disk_after_kb=$(get_size "$colima_disk")
        trimmed_kb=$((disk_before_kb > disk_after_kb ? disk_before_kb - disk_after_kb : 0))
        echo -e "  ${GREEN}✓${RESET} colima trim $colima_profile ${GREEN}$(format_size "$trimmed_kb")${RESET} ${DIM}(disk $disk_str → $(format_size "$disk_after_kb"))${RESET}"
        freed_total=$((freed_total + trimmed_kb))
        ((items_deleted++))
      else
        echo -e "  ${RED}✗${RESET} colima trim $colima_profile failed ${DIM}(to reclaim it all: colima delete -p $colima_profile)${RESET}"
        ((items_failed++))
      fi
    done <<<"$colima_profiles"
  elif [[ -d "$COLIMA_DISKS" ]]; then
    echo -e "  ${DIM}· colima command not found — skipping VM disk reclaim${RESET}"
    ((items_skipped++))
  else
    echo -e "  ${DIM}· colima not installed${RESET}"
    ((items_skipped++))
  fi

  safe_rm "$HOME/Library/Developer/CoreSimulator" "iOS Simulator"

  # Claude Desktop's sandboxed code-execution VMs. Regenerate on demand the
  # next time you run a Claude Code session that needs them.
  safe_rm "$HOME/Library/Application Support/Claude/vm_bundles" "Claude vm_bundles"
  safe_rm "$HOME/Library/Application Support/Claude-3p/vm_bundles" "Claude (3P) vm_bundles"

  # mise installs are not wiped here: default mode's `mise prune` already drops
  # versions nothing uses, and wiping the rest only forces re-downloads.

  # pre-commit hook envs auto-recreate on next `git commit`.
  safe_rm "$HOME/.cache/pre-commit" "pre-commit envs"

  # iOS Simulator runtimes (7-8G each) are managed by CoreSimulator; deleting
  # their files by hand leaves simctl with broken entries, so deletion goes
  # through simctl. Candidates come from CoreSimulator's own images.plist:
  # runtimes whose lastUsedAt is older than SIM_UNUSED_DAYS. Never-booted
  # runtimes have no lastUsedAt and are kept, as simctl itself does. Reading
  # the plist matters: starting CoreSimulator after a macOS update makes it
  # rebuild dyld caches for every runtime (3G+ each), so only a real -f run
  # with something to delete talks to simctl.
  sim_plist="/Library/Developer/CoreSimulator/Images/images.plist"
  if [[ -r "$sim_plist" ]] && command -v xcrun >/dev/null 2>&1; then
    sim_cutoff=$(($(date +%s) - SIM_UNUSED_DAYS * 86400))
    sim_count=$(plutil -extract images raw -o - "$sim_plist" 2>/dev/null)
    sim_ids=()
    sim_names=()
    sim_kbs=()
    for ((i = 0; i < ${sim_count:-0}; i++)); do
      sim_last_used=$(plutil -extract "images.$i.lastUsedAt" raw -o - "$sim_plist" 2>/dev/null) || continue
      sim_last_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$sim_last_used" +%s 2>/dev/null) || continue
      [[ $sim_last_epoch -lt $sim_cutoff ]] || continue
      sim_id=$(plutil -extract "images.$i.uuid" raw -o - "$sim_plist" 2>/dev/null) || continue
      sim_image=$(plutil -extract "images.$i.path.relative" raw -o - "$sim_plist" 2>/dev/null)
      sim_image="${sim_image#file://}"
      sim_bytes=$(stat -f %z "${sim_image//%20/ }" 2>/dev/null)
      sim_bundle=$(plutil -extract "images.$i.runtimeInfo.bundlePath.relative" raw -o - "$sim_plist" 2>/dev/null)
      sim_ids+=("$sim_id")
      sim_names+=("$(basename "${sim_bundle//%20/ }" .simruntime)")
      sim_kbs+=($((${sim_bytes:-0} / 1024)))
    done
    if [[ ${#sim_ids[@]} -eq 0 ]]; then
      echo -e "  ${DIM}· iOS Simulator runtimes (none unused for ${SIM_UNUSED_DAYS}d)${RESET}"
      ((items_skipped++))
    fi
    for ((i = 0; i < ${#sim_ids[@]}; i++)); do
      sim_desc="iOS Simulator runtime ${sim_names[i]:-${sim_ids[i]}} (unused ${SIM_UNUSED_DAYS}d+)"
      sim_str=$(format_size "${sim_kbs[i]}")
      if $dry_run; then
        echo -e "  ${BLUE}○${RESET} $sim_desc ${YELLOW}$sim_str${RESET}"
      elif xcrun simctl runtime delete "${sim_ids[i]}" >/dev/null 2>&1 </dev/null; then
        echo -e "  ${GREEN}✓${RESET} $sim_desc ${GREEN}$sim_str${RESET}"
      else
        echo -e "  ${RED}✗${RESET} $sim_desc ${DIM}(retry: xcrun simctl runtime delete ${sim_ids[i]})${RESET}"
        ((items_failed++))
        continue
      fi
      freed_total=$((freed_total + sim_kbs[i]))
      ((items_deleted++))
    done
  fi

  # Root-owned dyld caches that CoreSimulator rebuilds on demand. safe_rm
  # honors dry-run for the rare writable case; the sudo hint is useful in
  # dry-run too.
  sysdir="/Library/Developer/CoreSimulator/Caches"
  sys_size=$(get_size "$sysdir")
  if [[ $sys_size -gt 0 && -w "$sysdir" ]]; then
    safe_rm "$sysdir" "system: CoreSimulator Caches"
  elif [[ $sys_size -gt 0 ]]; then
    echo -e "  ${YELLOW}!${RESET} system: CoreSimulator Caches ${YELLOW}$(format_size "$sys_size")${RESET} ${DIM}(root-owned, run: sudo rm -rf \"$sysdir\")${RESET}"
    ((items_skipped++))
  fi

  # Android emulators (AVDs) not run for SIM_UNUSED_DAYS. The emulator rewrites
  # files in its .avd directory on every boot, so "nothing modified in that
  # window" means unused for that long; a running emulator always has fresh
  # files. Any recent file keeps the AVD.
  for avd in "$AVD_HOME"/*.avd; do
    [[ -d "$avd" ]] || continue
    avd_name=$(basename "$avd" .avd)
    if [[ -n $(find "$avd" -mmin "-$((SIM_UNUSED_DAYS * 1440))" -print -quit 2>/dev/null) ]]; then
      echo -e "  ${DIM}· Android emulator $avd_name (used within ${SIM_UNUSED_DAYS}d, kept)${RESET}"
      ((items_skipped++))
      continue
    fi
    safe_rm "$avd" "Android emulator $avd_name (unused ${SIM_UNUSED_DAYS}d+)"
    # Drop the matching .ini too, or Android Studio lists a broken device.
    if ! $dry_run && [[ ! -e "$avd" ]]; then
      rm -f "$AVD_HOME/$avd_name.ini"
    fi
  done

  # Secondary-worktree Bazel outputs and node_modules are cleaned above;
  # the legacy root's shared cache/install entries are cleaned above only in
  # this expensive mode; this section is reserved for main-workspace targets.

  # Editor state: per-workspace UI (open tabs, search history, breakpoints)
  # and Local History (file-level edit recovery for unversioned saves). Both
  # are recovery surfaces — kept out of default mode, opt-in via -f only.
  safe_rm "$HOME/Library/Application Support/Cursor/User/workspaceStorage" "Cursor workspaceStorage"
  safe_rm "$HOME/Library/Application Support/Cursor/User/History" "Cursor History"
  safe_rm "$HOME/Library/Application Support/Code/User/workspaceStorage" "VSCode workspaceStorage"
  safe_rm "$HOME/Library/Application Support/Code/User/History" "VSCode History"

  safe_rm "$HOME/.gradle/caches" "Gradle cache"
  safe_rm "$HOME/.m2/repository" "Maven cache"
  safe_rm "$HOME/Library/pnpm/store" "pnpm store"
  safe_rm "$HOME/.cache/bazel" "bazel disk cache"

  # Go module cache
  go_modcache="$HOME/go/pkg/mod"
  if [[ -d "$go_modcache" ]]; then
    go_size=$(get_size "$go_modcache")
    if [[ $go_size -gt 0 ]]; then
      size_str=$(format_size "$go_size")
      if $dry_run; then
        echo -e "  ${BLUE}○${RESET} go module cache ${YELLOW}$size_str${RESET}"
      else
        echo -e "  ${DIM}Cleaning go module cache...${RESET}"
        if command -v go &>/dev/null; then
          go clean -modcache 2>/dev/null
        else
          rm_or_rmz "$go_modcache" 2>/dev/null
        fi
        echo -e "  ${GREEN}✓${RESET} go module cache ${GREEN}$size_str${RESET}"
      fi
      freed_total=$((freed_total + go_size))
      ((items_deleted++))
    fi
  fi

  echo -e "  ${DIM}restore: next bazel build is cold and re-downloads external deps · everything else auto-recovers${RESET}"
fi

# ═══════════════════════════════════════════════════════════════════
# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

disk_info_after=$(df -h ~ | tail -1)
avail_after=$(echo "$disk_info_after" | awk '{print $4}')
pct_after=$(echo "$disk_info_after" | awk '{gsub(/%/,"",$5); print $5}')
freed_str=$(format_size "$freed_total")

if $dry_run; then
  echo -e "📊 Would free: ${YELLOW}$freed_str${RESET}"
  echo -e "   ${DIM}$items_deleted items to delete, $items_skipped already clean${RESET}"
else
  echo -e "📊 Freed: ${GREEN}$freed_str${RESET}"
  echo -e "   ${DIM}$items_deleted deleted, $items_skipped skipped"
  if [[ $items_failed -gt 0 ]]; then
    echo -e "   ${RED}$items_failed failed (may need sudo)${RESET}"
  fi
  echo -e "${RESET}"
  echo -e "💾 Disk: ${YELLOW}$pct_before%${RESET} → ${GREEN}$pct_after%${RESET} full ($avail_before → ${GREEN}$avail_after${RESET})"
fi

elapsed=$((SECONDS - start_time))
if [[ $elapsed -ge 60 ]]; then
  elapsed_str="$((elapsed / 60))m $((elapsed % 60))s"
else
  elapsed_str="${elapsed}s"
fi
echo -e "   ${DIM}completed in $elapsed_str${RESET}"

if ! $full; then
  # Show what -f would target (existence checks only, no du)
  echo ""
  declare -a full_targets=()
  command -v docker &>/dev/null && full_targets+=("Docker")
  [[ -d "$COLIMA_DISKS" ]] && full_targets+=("Colima disk trim")
  [[ -d "$HOME/Library/Developer/CoreSimulator" ]] && full_targets+=("iOS Simulator")
  [[ -d "/Library/Developer/CoreSimulator/Images" ]] && full_targets+=("iOS runtimes (unused ${SIM_UNUSED_DAYS}d+ only)")
  compgen -G "$AVD_HOME/*.avd" >/dev/null && full_targets+=("Android emulators (unused ${SIM_UNUSED_DAYS}d+ only)")

  [[ -d "$HOME/.gradle/caches" ]] && full_targets+=("Gradle")
  [[ -d "$HOME/.m2/repository" ]] && full_targets+=("Maven")
  [[ -d "$HOME/Library/pnpm/store" ]] && full_targets+=("pnpm store")
  [[ -d "$HOME/.cache/bazel" ]] && full_targets+=("~/.cache/bazel")
  [[ -d "$BAZEL_ROOT" ]] && $legacy_is_separate && full_targets+=("legacy Bazel root")
  [[ -d "$HOME/go/pkg/mod" ]] && full_targets+=("go modcache")
  [[ -d "$HOME/Library/Application Support/Claude/vm_bundles" ]] && full_targets+=("Claude vm_bundles")
  [[ -d "$HOME/Library/Application Support/Claude-3p/vm_bundles" ]] && full_targets+=("Claude (3P) vm_bundles")
  [[ -d "$HOME/.cache/pre-commit" ]] && full_targets+=("pre-commit envs")
  [[ -d "/Library/Developer/CoreSimulator/Caches" ]] && full_targets+=("CoreSimulator Caches (sudo)")

  if [[ ${#full_targets[@]} -gt 0 ]]; then
    target_list=$(
      IFS=', '
      echo "${full_targets[*]}"
    )
    echo -e "💡 ${YELLOW}-f${RESET} targets present: ${DIM}$target_list${RESET}"
    echo -e "   ${DIM}Run with ${RESET}${YELLOW}-f${RESET}${DIM} to delete${RESET}"
  else
    echo -e "💡 ${DIM}No -f targets present — already clean${RESET}"
  fi
fi

if $dry_run; then
  echo ""
  echo -e "ℹ️  ${DIM}Dry run complete. Run without -n to execute.${RESET}"
fi
echo ""
