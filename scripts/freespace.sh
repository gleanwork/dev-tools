#!/bin/bash
#
# Frees disk space.
#
# Usage: freespace.sh [-n] [-f] [-d N | --stale-days=N]
#
# Modes:
#   (default)   Cheap to delete, cheap to recover (safe for daily use):
#               - Build caches (main + worktrees): .swc, storybook-static, .next, .turbo
#                 __pycache__, .mypy_cache, .pytest_cache, .ruff_cache
#               - App caches: ~/Library/Caches/{Xcode,VSCode,Cursor,Chrome,Chrome Beta,
#                 Arc,Firefox,Brave,Edge,Opera,OpenAI Atlas,ChatGPT,Claude Desktop,
#                 Granola+Loom updaters,Zoom,JetBrains,pip,virtualenv,Homebrew,go-build,
#                 gopls,pnpm,Yarn,electron,Playwright,bazelisk,colima,mise,helm,...}
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
#                 Granola, Loom, Highlight, OpenAI Atlas, ChatGPT, Cluely, Slapdash,
#                 Dropbox Dash, Mighty, Microsoft Edge, Brave
#               - Windsurf App Support safe caches (Cache, CachedData, logs, GPUCache, etc.)
#               - gcloud CLI logs (~/.config/gcloud/logs)
#               - Project-specific dev caches (customize below)
#               - System: ~/.Trash, /tmp/*, ~/.cache/*
#               - ~/Library/Logs/* (third-party only: Webex, Spark, Zoom, Loom,
#                 Claude, CoreSimulator, Docker; preserves Apple subsystems)
#               - Quick restore (~30s): brew cleanup, ~/.npm/_cacache
#               - Misc: uv cache, bazel java logs, git temp packs
#               - Git: worktree prune, remove prunable worktrees (refuses if dirty),
#                 git gc (default prune window — keeps reflog recovery for ~2 weeks)
#               - Bazel output bases for orphan workspaces or worktrees untouched 3+ days
#                 (preserves main workspace's base and the shared disk cache).
#                 Override the staleness window with --stale-days=N; --stale-days=0
#                 removes every non-main output base (emergency disk recovery).
#
#   -d N        Override staleness window for non-main bazel output bases
#               (default 3). --stale-days=0 deletes every non-main output base
#               regardless of age — emergency disk recovery without nuking the
#               shared content-addressed cache.
#
#   -f          Deep clean — expensive to recover:
#               - Colima default profile: delete to reclaim host disk space
#                 (loses all Docker state for the default profile; named
#                 profiles are left alone and reported separately. User
#                 restarts manually with `colima start` — note: custom
#                 CPU/RAM/disk config resets to defaults)
#               - Docker: images, containers, volumes (docker system prune -a)
#               - iOS Simulator: ~/Library/Developer/CoreSimulator (user)
#               - System CoreSimulator (/Library/Developer/CoreSimulator) flagged
#                 as a sudo follow-up target if root-owned
#               - Claude Desktop vm_bundles (regenerate on next code-execution session)
#               - mise installs (~/.local/share/mise/installs; `mise install` re-fetches)
#               - pre-commit hook envs (~/.cache/pre-commit; auto-recreate next commit)
#               - Cursor/VSCode workspaceStorage + History (per-workspace tabs/state +
#                 Local History recovery for unversioned edits — opt-in only)
#               - Non-main bazel outputs in /var/tmp/_bazel_* (preserves main workspace)
#               - node_modules in main workspace (requires: pnpm install)
#               - Python virtualenvs (requires: re-create)
#               - node_modules in worktrees if not symlinked
#               - Gradle cache, Maven cache
#               - ~/.cache/bazel (disk cache)
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

# Configuration — override these via environment or edit below
MAIN_WORKSPACE="${MAIN_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/workspace")}"
BAZEL_ROOT="${BAZEL_ROOT:-/private/var/tmp/_bazel_$USER}"
WORKTREE_PARENT="${WORKTREE_PARENT:-$(dirname "$MAIN_WORKSPACE")}"

# Oversized log truncation (opt-in). Set LOG_TRUNCATE_DIRS to a space-separated
# list of directories; any *.log over LOG_TRUNCATE_THRESHOLD_KB (default 100 MB)
# is truncated in place rather than deleted, so a running process keeps writing.
LOG_TRUNCATE_DIRS="${LOG_TRUNCATE_DIRS:-}"
LOG_TRUNCATE_THRESHOLD_KB="${LOG_TRUNCATE_THRESHOLD_KB:-102400}"

# Parse arguments
dry_run=false
full=false
# Staleness window for non-main bazel output bases. 3 days catches a long
# weekend / short vacation worth of inactive worktrees without surprising
# anyone who built earlier this week. Override with -d / --stale-days; set
# 0 for emergency cleanup of every non-main output base.
stale_days=3

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) dry_run=true ;;
        -f|--full) full=true ;;
        -nf|-fn) dry_run=true; full=true ;;
        -d|--stale-days)
            shift
            stale_days="$1"
            ;;
        --stale-days=*) stale_days="${1#*=}" ;;
        -h|--help)
            cat << 'EOF'
Usage: freespace.sh [-n] [-f] [-d N | --stale-days=N]

Modes:
  (default)   Cheap to delete, cheap to recover (safe for daily use):
              - Build caches: .swc, storybook-static, .next, .turbo, __pycache__, etc
              - App caches: ~/Library/Caches/{Xcode,VSCode,Cursor,Chrome,Chrome Beta,
                Firefox,Brave,Edge,Opera,Atlas,ChatGPT,Claude,JetBrains,...}
              - Updater caches: Granola/Loom/Edge updaters
              - Cursor/VSCode App Support pure caches (Cache, CachedData, logs, etc)
                — workspaceStorage + History are -f only (recovery surfaces)
              - Chromium safe caches (Chrome+Beta)
              - Electron app caches: Slack (incl sandbox), Claude, Granola, Loom,
                Highlight, Atlas, ChatGPT, Cluely, Slapdash, Dropbox Dash, Mighty,
                Edge, Brave
              - Windsurf App Support safe caches
              - gcloud logs, ~/.Trash, /tmp/*, ~/.cache/* (preserves pre-commit)
              - ~/Library/Logs (3rd-party app logs only; preserves Apple)
              - Bazel java logs, git temp packs
              - Quick restore (~30s): brew cleanup, ~/.npm/_cacache
              - Git: worktree prune, remove prunable worktrees (refuses if dirty),
                git gc (default prune window — keeps reflog recovery for ~2 weeks)
              - Bazel output bases for orphan or 3+ day stale worktrees
                (preserves main's base and shared disk cache)

  -d N        Override staleness window for non-main bazel output bases
  --stale-days=N (default 3). --stale-days=0 deletes all non-main output bases
              regardless of age — emergency disk recovery, preserves the shared
              content-addressed cache so rebuilds re-link rather than re-fetch.

  -f          Deep clean — expensive to recover:
              - Docker: images, containers, volumes (docker system prune -a)
              - Colima default profile, iOS Simulator, non-main bazel output bases
              - Claude vm_bundles, mise installs, ~/.cache/pre-commit
              - Cursor/VSCode workspaceStorage + History (per-workspace state +
                Local History — recovery surfaces, not pure caches)
              - System /Library/Developer/CoreSimulator (flagged for sudo)
              - node_modules, virtualenvs, Gradle, Maven, pnpm store
              - ~/.cache/bazel, go modcache
              - git gc --aggressive

  -n          Dry run — preview everything (default + deep) without deleting
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
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
        du -sk "$path" 2>/dev/null | cut -f1
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
        size_str="$(( kb / 1024 ))M"
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
    while ps -p "$pid" > /dev/null 2>&1; do
        printf "\r  ${DIM}%s %s${RESET}  " "${spinstr:$i:1}" "$msg"
        i=$(( (i + 1) % ${#spinstr} ))
        sleep $delay
    done
    # Clear the spinner line
    printf "\r%*s\r" $((${#msg} + 10)) ""
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
        # Try simple rm first
        if rm -rf "$path" 2>/dev/null; then
            echo -e "  ${GREEN}✓${RESET} $desc ${GREEN}$size_str${RESET}"
            freed_total=$((freed_total + size_kb))
            ((items_deleted++))
        else
            # Bazel sets dirs read-only; fix permissions then retry
            chmod -R u+w "$path" 2>/dev/null
            chflags -R nouchg "$path" 2>/dev/null
            if rm -rf "$path" 2>/dev/null; then
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
        if { > "$path"; } 2>/dev/null; then
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
            rm -rf "$base/$sub" 2>/dev/null
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
    [[ -d "$base" ]] || { echo -e "  ${DIM}· $label (not installed)${RESET}"; ((items_skipped++)); return; }

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

    while IFS= read -r -d '' file; do
        local size_kb
        size_kb=$(get_size "$file")
        total_kb=$((total_kb + size_kb))
        count=$((count + 1))

        if ! $dry_run; then
            rm -rf "$file" 2>/dev/null
        fi
    done < <(find "$base" -mindepth 1 -name "$pattern" -print0 2>/dev/null)

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

get_worktrees() {
    for dir in "$WORKTREE_PARENT"/*/; do
        [[ -d "$dir" ]] || continue
        [[ "$dir" == "$MAIN_WORKSPACE/" ]] && continue
        if [[ -f "${dir}.git" ]]; then
            echo "$dir"
        fi
    done
}

get_main_bazel_output_base() {
    [[ -d "$MAIN_WORKSPACE" ]] || return

    # Try the bazel-out convenience symlink before invoking bazel (which is slow
    # and can fail). bazel-out -> <output_base>/execroot/_main/bazel-out (up 3).
    local target ob i
    if [[ -L "$MAIN_WORKSPACE/bazel-out" ]]; then
        target=$(readlink "$MAIN_WORKSPACE/bazel-out" 2>/dev/null)
        if [[ -n "$target" ]]; then
            ob="$target"
            for ((i=0; i<3; i++)); do
                ob=$(dirname "$ob")
            done
            [[ -d "$ob" ]] && { echo "$ob"; return; }
        fi
    fi

    (cd "$MAIN_WORKSPACE" && bazel info output_base 2>/dev/null) || true
}

# Some Bazel setups point --output_user_root somewhere other than
# /private/var/tmp/_bazel_$USER. Derive the real root from main's output_base
# parent so this script works regardless of layout.
get_actual_bazel_root() {
    local mob
    mob=$(get_main_bazel_output_base)
    if [[ -n "$mob" && -d "$mob" ]]; then
        dirname "$mob"
    else
        echo "$BAZEL_ROOT"
    fi
}

# Count worktrees
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
echo -e "━━━ ${BLUE}Build Caches${RESET} ${DIM}(auto-regenerate)${RESET}"

safe_rm_pattern "$MAIN_WORKSPACE/.git/objects/pack" "tmp_pack_*" "git temp packs"

# Stale .git/index.stash.* — leftovers from interrupted stash/rebase/autostash.
# Top-level only (no recursion); harmless to delete.
stash_count=0
stash_freed=0
for f in "$MAIN_WORKSPACE"/.git/index.stash.*; do
    [[ -f "$f" ]] || continue
    sz=$(get_size "$f")
    stash_freed=$((stash_freed + sz))
    ((stash_count++))
    $dry_run || rm -f "$f" 2>/dev/null
done
if [[ $stash_count -gt 0 ]]; then
    sz_str=$(format_size "$stash_freed")
    if $dry_run; then
        echo -e "  ${BLUE}○${RESET} stale .git/index.stash.* ${DIM}($stash_count)${RESET} ${YELLOW}$sz_str${RESET}"
    else
        echo -e "  ${GREEN}✓${RESET} stale .git/index.stash.* ${DIM}($stash_count)${RESET} ${GREEN}$sz_str${RESET}"
    fi
    freed_total=$((freed_total + stash_freed))
    ((items_deleted++))
else
    echo -e "  ${DIM}· stale .git/index.stash.* (none)${RESET}"
    ((items_skipped++))
fi

# Add project-specific build artifacts here:
# safe_rm "$MAIN_WORKSPACE/your_venv_backup" "venv backup"
safe_rm "$MAIN_WORKSPACE/storybook-static" "storybook-static"
safe_rm "$MAIN_WORKSPACE/.swc" ".swc"
safe_rm "$MAIN_WORKSPACE/.mypy_cache" ".mypy_cache"
safe_rm "$MAIN_WORKSPACE/.pytest_cache" ".pytest_cache"
safe_rm "$MAIN_WORKSPACE/.ruff_cache" ".ruff_cache"
safe_rm "$MAIN_WORKSPACE/.next" ".next"
safe_rm "$MAIN_WORKSPACE/.turbo" ".turbo"

# __pycache__ directories
pycache_size=0
pycache_count=0
while IFS= read -r -d '' dir; do
    size=$(get_size "$dir")
    pycache_size=$((pycache_size + size))
    pycache_count=$((pycache_count + 1))
    if ! $dry_run; then
        rm -rf "$dir" 2>/dev/null
    fi
done < <(find "$MAIN_WORKSPACE" -type d -name "__pycache__" -not -path "*/node_modules/*" -not -path "*/.git/*" -print0 2>/dev/null)

if [[ $pycache_count -gt 0 ]]; then
    size_str=$(format_size "$pycache_size")
    if $dry_run; then
        echo -e "  ${BLUE}○${RESET} __pycache__ ${DIM}($pycache_count dirs)${RESET} ${YELLOW}$size_str${RESET}"
    else
        echo -e "  ${GREEN}✓${RESET} __pycache__ ${DIM}($pycache_count dirs)${RESET} ${GREEN}$size_str${RESET}"
    fi
    freed_total=$((freed_total + pycache_size))
    ((items_deleted++))
else
    echo -e "  ${DIM}· __pycache__ (none)${RESET}"
    ((items_skipped++))
fi

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
safe_rm_pattern "/tmp" "*" "temp files"

# Third-party app logs only. Apple's own subsystems own most ~/Library/Logs/
# entries (DiagnosticReports, CrashReporter, com.apple.* …) and we leave those
# alone so users keep crash history. Allowlist the noisy chatty apps.
for log in "Webex Meetings" "SparkMacDesktop" "CoreSimulator" "Claude" \
           "zoom.us" "Loom" "webexmta" "Docker Desktop" \
           "SiriTTSService" "ZoomPhone" "Microsoft Teams Helper (Renderer)" \
           "@granolaelectron-updater" "loom-updater" "AtlasUpdateHelper.log"; do
    [[ -e "$HOME/Library/Logs/$log" ]] || continue
    safe_rm "$HOME/Library/Logs/$log" "log: $log"
done

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Worktrees${RESET} ${DIM}($worktree_count found)${RESET}"

for wt in $(get_worktrees); do
    wt_name=$(basename "$wt")
    wt_freed=0

    for cache in storybook-static .swc .mypy_cache .pytest_cache .ruff_cache .next .turbo; do
        if [[ -e "${wt}${cache}" ]]; then
            size_kb=$(get_size "${wt}${cache}")
            if [[ $size_kb -gt 0 ]]; then
                wt_freed=$((wt_freed + size_kb))
                if ! $dry_run; then
                    rm -rf "${wt}${cache}" 2>/dev/null
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
done

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Git${RESET} ${DIM}(compact & prune)${RESET}"

if [[ -d "$MAIN_WORKSPACE/.git" ]]; then
    # Prune stale worktree metadata
    prune_output=$(git -C "$MAIN_WORKSPACE" worktree prune --dry-run 2>/dev/null)
    if [[ -n "$prune_output" ]]; then
        if $dry_run; then
            echo -e "  ${BLUE}○${RESET} worktree prune (stale refs)"
        else
            git -C "$MAIN_WORKSPACE" worktree prune 2>/dev/null
            echo -e "  ${GREEN}✓${RESET} worktree prune"
        fi
        ((items_deleted++))
    else
        echo -e "  ${DIM}· worktree prune (nothing stale)${RESET}"
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
                if git -C "$MAIN_WORKSPACE" worktree remove "$wt_path" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${RESET} removed prunable: $wt_branch ${GREEN}$size_str${RESET}"
                    freed_total=$((freed_total + wt_size_kb))
                    ((items_deleted++))
                else
                    echo -e "  ${YELLOW}!${RESET} skipped prunable: $wt_branch ${YELLOW}$size_str${RESET} ${DIM}(dirty — review then: git worktree remove --force '$wt_path')${RESET}"
                    ((items_skipped++))
                fi
            fi
        fi
    done < <(git -C "$MAIN_WORKSPACE" worktree list 2>/dev/null)

    # git gc to compact .git object store
    git_size_before=$(get_size "$MAIN_WORKSPACE/.git")
    git_size_str=$(format_size "$git_size_before")

    if $dry_run; then
        echo -e "  ${BLUE}○${RESET} git gc (.git is $git_size_str)"
    else
        if $full; then
            # -f is opt-in to the cliff: --prune=now drops dangling objects
            # immediately, so dangling commits from recent reset/rebase/stash
            # drop are unrecoverable via reflog.
            git -C "$MAIN_WORKSPACE" gc --aggressive --prune=now 2>/dev/null &
            gc_pid=$!
            spin "$gc_pid" "git gc --aggressive (this takes a while)"
        else
            # Default mode honors gc.pruneExpire (2 weeks): recent dangling
            # commits stay reachable via reflog for normal recovery flows.
            git -C "$MAIN_WORKSPACE" gc 2>/dev/null &
            gc_pid=$!
            spin "$gc_pid" "git gc"
        fi
        wait "$gc_pid"

        git_size_after=$(get_size "$MAIN_WORKSPACE/.git")
        gc_freed=$((git_size_before - git_size_after))
        if [[ $gc_freed -gt 0 ]]; then
            gc_freed_str=$(format_size "$gc_freed")
            echo -e "  ${GREEN}✓${RESET} git gc ${GREEN}$gc_freed_str${RESET} freed (.git: $git_size_str → $(format_size "$git_size_after"))"
            freed_total=$((freed_total + gc_freed))
        else
            echo -e "  ${GREEN}✓${RESET} git gc (.git already compact: $git_size_str)"
        fi
        ((items_deleted++))
    fi
fi

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Dev Caches${RESET} ${DIM}(~/.cache)${RESET}"

# Add project-specific dev caches here:
# safe_rm "$MAIN_WORKSPACE/.opensearch" "local search data"
safe_rm "$HOME/.cache/uv" "uv cache"
# gcloud writes one log file per CLI invocation under ~/.config/gcloud/logs/<date>/.
# Pure write-only output (not a cache); deleted dir is recreated on next gcloud call.
safe_rm "$HOME/.config/gcloud/logs" "gcloud logs"
for cache_dir in "$HOME/.cache"/*; do
    [[ -d "$cache_dir" ]] || continue
    cache_name=$(basename "$cache_dir")
    # Skip bazel (-f mode) and uv (handled above)
    case "$cache_name" in
        bazel|uv|pre-commit) continue ;;
    esac
    safe_rm "$cache_dir" "cache/$cache_name"
done

# ═══════════════════════════════════════════════════════════════════
# Oversized log truncation (opt-in via LOG_TRUNCATE_DIRS). Truncate, don't
# delete — keeps the inode valid so a running service keeps writing.
if [[ -n "$LOG_TRUNCATE_DIRS" ]]; then
    echo ""
    echo -e "━━━ ${BLUE}Logs${RESET} ${DIM}(truncate oversized service logs)${RESET}"
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
fi

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Bazel${RESET} ${DIM}(stale worktree builds, java logs)${RESET}"

actual_bazel_root=$(get_actual_bazel_root)
main_output_base=$(get_main_bazel_output_base)

safe_rm_pattern "$actual_bazel_root" "java.log.*" "java logs"

# Per-worktree bazel output bases (one per checkout, identified by
# DO_NOT_BUILD_HERE which records the workspace path). Delete two categories:
#   - orphan: workspace path no longer exists (pure waste)
#   - stale:  output base untouched for stale_days+ days (rebuild re-links from
#             the preserved content-addressed cache/, so recovery is fast)
# Always preserves main's output base, the shared cache/ and install/.
# Default 3 days covers a long weekend; --stale-days=0 hits every non-main
# base (emergency mode). Bazel output bases re-link from the preserved disk
# cache so the recovery cost is one extra incremental build, not a
# from-scratch rebuild.
STALE_DAYS="$stale_days"
stale_cutoff=$(( $(date +%s) - STALE_DAYS * 86400 ))
ob_count=0
ob_freed=0

if [[ -d "$actual_bazel_root" ]]; then
    for ob in "$actual_bazel_root"/*/; do
        ob="${ob%/}"
        # Only real output bases have DO_NOT_BUILD_HERE; skips cache/, install/, etc.
        [[ -f "$ob/DO_NOT_BUILD_HERE" ]] || continue
        [[ -n "$main_output_base" && "$ob" == "$main_output_base" ]] && continue

        ws=$(cat "$ob/DO_NOT_BUILD_HERE" 2>/dev/null)
        wsname=$(basename "$ws")
        short=$(basename "$ob" | cut -c1-8)

        reason=""
        if [[ ! -d "$ws" ]]; then
            reason="orphan"
        else
            # command.log is rewritten on every bazel invocation; better signal
            # than dir mtime which can be touched by sandbox/server side effects.
            mtime_src="$ob/command.log"
            [[ -f "$mtime_src" ]] || mtime_src="$ob"
            mtime=$(stat -f %m "$mtime_src" 2>/dev/null || echo 0)
            if [[ $mtime -lt $stale_cutoff ]]; then
                age_days=$(( ($(date +%s) - mtime) / 86400 ))
                reason="stale ${age_days}d"
            fi
        fi

        [[ -z "$reason" ]] && continue

        size_kb=$(get_size "$ob")
        size_str=$(format_size "$size_kb")

        if $dry_run; then
            echo -e "  ${BLUE}○${RESET} $wsname ${DIM}($short, $reason)${RESET} ${YELLOW}$size_str${RESET}"
            ob_freed=$((ob_freed + size_kb))
            ((ob_count++))
        else
            chmod -R u+w "$ob" 2>/dev/null
            chflags -R nouchg "$ob" 2>/dev/null
            if rm -rf "$ob" 2>/dev/null; then
                echo -e "  ${GREEN}✓${RESET} $wsname ${DIM}($short, $reason)${RESET} ${GREEN}$size_str${RESET}"
                ob_freed=$((ob_freed + size_kb))
                ((ob_count++))
            else
                echo -e "  ${RED}✗${RESET} $wsname ${DIM}($short, $reason)${RESET} ${RED}$size_str${RESET} (need sudo)"
                ((items_failed++))
            fi
        fi
    done

    if [[ $ob_count -gt 0 ]]; then
        freed_total=$((freed_total + ob_freed))
        ((items_deleted += ob_count))
        echo -e "  ${DIM}── $ob_count output base(s), $(format_size "$ob_freed") total${RESET}"
    else
        echo -e "  ${DIM}· no orphan or >${STALE_DAYS}d stale output bases${RESET}"
        ((items_skipped++))
    fi
fi

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Colima VM disk${RESET} ${DIM}(container runtime backing store)${RESET}"

# Colima stores Docker's Linux VM as qcow2 disk image(s) under
# ~/.colima/_lima/_disks/<name>/datadisk. The image allocates space as Docker
# uses it but never shrinks automatically — even after `docker system prune`
# the host file stays large. The only reliable way to reclaim it is to delete
# the VM (handled under -f); the user then restarts colima when they're ready.
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
            # The Deep Clean section below will delete the VM; don't suggest -f.
            echo -e "  ${YELLOW}!${RESET} $colima_disk_count disk image(s) ${YELLOW}$size_str${RESET} ${DIM}(deleted in Deep Clean below)${RESET}"
        else
            echo -e "  ${YELLOW}!${RESET} $colima_disk_count disk image(s) ${YELLOW}$size_str${RESET} ${DIM}(run with -f to delete the VM and reclaim space)${RESET}"
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

    # Colima default-profile deletion: the only reliable way to reclaim the
    # qcow2 host file space. `colima delete --force` (without `-p`) removes
    # only the default profile (stopping it first if running). Any named
    # profiles' disks survive — we report what's left and leave them alone
    # since the user knows their own profile setup.
    #
    # User restarts manually with `colima start` when ready — this avoids
    # surprising them with a forced restart.
    #
    # Caveat: custom CPU/RAM/disk config (set via `colima start -c X -m Y -d Z`
    # or by editing ~/.colima/_lima/colima/lima.yaml) resets to defaults.
    if [[ -d "$COLIMA_DISKS" ]] && command -v colima &>/dev/null; then
        colima_total_kb=0
        for disk_dir in "$COLIMA_DISKS"/*/; do
            [[ -f "${disk_dir}datadisk" ]] && colima_total_kb=$((colima_total_kb + $(get_size "${disk_dir}datadisk")))
        done
        size_str=$(format_size "$colima_total_kb")

        if [[ $colima_total_kb -eq 0 ]]; then
            echo -e "  ${DIM}· colima (no disk images found)${RESET}"
            ((items_skipped++))
        elif $dry_run; then
            # Dry-run can't tell which disks belong to the default profile vs
            # named profiles without invoking `colima list`. Show the upper
            # bound so the projection is at least never short.
            echo -e "  ${BLUE}○${RESET} colima delete default profile ${YELLOW}(up to $size_str)${RESET}"
            freed_total=$((freed_total + colima_total_kb))
            ((items_deleted++))
        else
            echo -e "  ${DIM}deleting default colima profile (loses all Docker state)...${RESET}"
            if colima delete --force 2>/dev/null; then
                # Diff actual disk usage: subtract what's still on disk from
                # the pre-delete total. Named profiles (if any) survive and
                # show up in size_after_kb.
                size_after_kb=0
                for disk_dir in "$COLIMA_DISKS"/*/; do
                    [[ -f "${disk_dir}datadisk" ]] && size_after_kb=$((size_after_kb + $(get_size "${disk_dir}datadisk")))
                done
                actual_freed=$((colima_total_kb - size_after_kb))
                echo -e "  ${GREEN}✓${RESET} default colima profile deleted ${GREEN}$(format_size $actual_freed)${RESET}"
                freed_total=$((freed_total + actual_freed))
                ((items_deleted++))
                if [[ $size_after_kb -gt 0 ]]; then
                    echo -e "  ${YELLOW}!${RESET} ${DIM}$(format_size $size_after_kb) remains in named profile(s); delete with: ${RESET}colima -p <name> delete --force"
                fi
                echo -e "  ${YELLOW}!${RESET} ${DIM}restart when ready: ${RESET}colima start ${DIM}(custom CPU/RAM/disk settings reset to defaults)${RESET}"
            else
                echo -e "  ${RED}✗${RESET} colima delete failed"
                ((items_failed++))
            fi
        fi
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

    # mise-managed language toolchains (Node, Python, Go runtimes per .mise.toml).
    # `mise install` re-downloads what the active project pins; other versions
    # stay gone, which is exactly what we want.
    safe_rm "$HOME/.local/share/mise/installs" "mise installs"

    # pre-commit hook envs auto-recreate on next `git commit`.
    safe_rm "$HOME/.cache/pre-commit" "pre-commit envs"

    # System-level CoreSimulator caches/runtimes (root-owned). Often 30G+ when
    # Xcode has downloaded multiple platform runtimes. safe_rm honors dry-run
    # for the rare writable case; the sudo hint is useful in dry-run too, so
    # this block runs unconditionally.
    for sysdir in "/Library/Developer/CoreSimulator/Caches" "/Library/Developer/CoreSimulator/Images"; do
        [[ -d "$sysdir" ]] || continue
        sys_size=$(get_size "$sysdir")
        [[ $sys_size -gt 0 ]] || continue
        sys_str=$(format_size "$sys_size")
        if [[ -w "$sysdir" ]]; then
            safe_rm "$sysdir" "system: $(basename "$sysdir")"
        else
            echo -e "  ${YELLOW}!${RESET} system: $(basename "$sysdir") ${YELLOW}$sys_str${RESET} ${DIM}(root-owned, run: sudo rm -rf \"$sysdir\")${RESET}"
            ((items_skipped++))
        fi
    done

    # Non-main bazel output bases
    if ! $dry_run; then
        echo -e "  ${DIM}shutting down bazel...${RESET}"
        pkill -9 -f "bazel.*_bazel_$USER" 2>/dev/null || true
        (cd "$MAIN_WORKSPACE" && bazel shutdown 2>/dev/null) || true
        sleep 1
    fi

    main_output_base=$(get_main_bazel_output_base)
    bazel_count=0
    bazel_freed=0

    if [[ -d "$BAZEL_ROOT" ]]; then
        for base_dir in "$BAZEL_ROOT"/*/; do
            [[ -d "$base_dir" ]] || continue
            base_dir="${base_dir%/}"

            if [[ -n "$main_output_base" && "$base_dir" == "$main_output_base" ]]; then
                main_size=$(get_size "$base_dir")
                echo -e "  ${DIM}⊘ main workspace $(format_size "$main_size") (preserved)${RESET}"
                continue
            fi

            size_kb=$(get_size "$base_dir")
            if [[ $size_kb -gt 0 ]]; then
                ((bazel_count++))
                bazel_freed=$((bazel_freed + size_kb))
                short_name=$(basename "$base_dir" | cut -c1-8)
                size_str=$(format_size "$size_kb")

                if $dry_run; then
                    echo -e "  ${BLUE}○${RESET} bazel output ${DIM}$short_name...${RESET} ${YELLOW}$size_str${RESET}"
                else
                    printf "  ⏳ %s... %s " "$short_name" "$size_str"
                    chmod -R u+w "$base_dir" 2>/dev/null
                    chflags -R nouchg "$base_dir" 2>/dev/null
                    if rm -rf "$base_dir" 2>/dev/null; then
                        printf "\r  ${GREEN}✓${RESET} %s... ${GREEN}%s${RESET}        \n" "$short_name" "$size_str"
                    else
                        printf "\r  ${RED}✗${RESET} %s... ${RED}%s${RESET} (need sudo)\n" "$short_name" "$size_str"
                        ((items_failed++))
                        bazel_freed=$((bazel_freed - size_kb))
                    fi
                fi
            fi
        done

        if [[ $bazel_count -gt 0 ]]; then
            freed_total=$((freed_total + bazel_freed))
            ((items_deleted += bazel_count))
            echo -e "  ${DIM}── $bazel_count bazel outputs, $(format_size "$bazel_freed") total${RESET}"
        else
            echo -e "  ${DIM}· no orphaned bazel outputs${RESET}"
            ((items_skipped++))
        fi
    fi

    # Worktree node_modules (non-symlinked)
    for wt in $(get_worktrees); do
        wt_name=$(basename "$wt")
        if [[ -d "${wt}node_modules" && ! -L "${wt}node_modules" ]]; then
            safe_rm "${wt}node_modules" "worktree:$wt_name/node_modules"
        fi
    done

    # Editor state: per-workspace UI (open tabs, search history, breakpoints)
    # and Local History (file-level edit recovery for unversioned saves). Both
    # are recovery surfaces — kept out of default mode, opt-in via -f only.
    safe_rm "$HOME/Library/Application Support/Cursor/User/workspaceStorage" "Cursor workspaceStorage"
    safe_rm "$HOME/Library/Application Support/Cursor/User/History" "Cursor History"
    safe_rm "$HOME/Library/Application Support/Code/User/workspaceStorage" "VSCode workspaceStorage"
    safe_rm "$HOME/Library/Application Support/Code/User/History" "VSCode History"

    safe_rm "$MAIN_WORKSPACE/node_modules" "node_modules"
    # Add project-specific virtualenvs or build outputs here:
    # safe_rm "$MAIN_WORKSPACE/venv" "Python venv"
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
                    rm -rf "$go_modcache" 2>/dev/null
                fi
                echo -e "  ${GREEN}✓${RESET} go module cache ${GREEN}$size_str${RESET}"
            fi
            freed_total=$((freed_total + go_size))
            ((items_deleted++))
        fi
    fi

    echo -e "  ${DIM}restore: pnpm install · recreate virtualenvs · everything else auto-recovers${RESET}"
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

elapsed=$(( SECONDS - start_time ))
if [[ $elapsed -ge 60 ]]; then
    elapsed_str="$(( elapsed / 60 ))m $(( elapsed % 60 ))s"
else
    elapsed_str="${elapsed}s"
fi
echo -e "   ${DIM}completed in $elapsed_str${RESET}"

if ! $full; then
    # Show what -f would target (existence checks only, no du)
    echo ""
    declare -a full_targets=()
    command -v docker &>/dev/null && full_targets+=("Docker")
    [[ -d "$COLIMA_DISKS" ]] && full_targets+=("Colima VM disk")
    [[ -d "$HOME/Library/Developer/CoreSimulator" ]] && full_targets+=("iOS Simulator")

    # Count non-main bazel output bases
    if [[ -d "$BAZEL_ROOT" ]]; then
        bazel_extra=0
        main_ob=$(get_main_bazel_output_base)
        for d in "$BAZEL_ROOT"/*/; do
            [[ -d "$d" ]] || continue
            [[ -n "$main_ob" && "${d%/}" == "$main_ob" ]] && continue
            ((bazel_extra++))
        done
        [[ $bazel_extra -gt 0 ]] && full_targets+=("$bazel_extra bazel output base(s)")
    fi

    [[ -d "$MAIN_WORKSPACE/node_modules" ]] && full_targets+=("node_modules")
    # [[ -d "$MAIN_WORKSPACE/venv" ]] && full_targets+=("venv")
    [[ -d "$HOME/.gradle/caches" ]] && full_targets+=("Gradle")
    [[ -d "$HOME/.m2/repository" ]] && full_targets+=("Maven")
    [[ -d "$HOME/Library/pnpm/store" ]] && full_targets+=("pnpm store")
    [[ -d "$HOME/.cache/bazel" ]] && full_targets+=("~/.cache/bazel")
    [[ -d "$HOME/go/pkg/mod" ]] && full_targets+=("go modcache")
    [[ -d "$HOME/Library/Application Support/Claude/vm_bundles" ]] && full_targets+=("Claude vm_bundles")
    [[ -d "$HOME/.local/share/mise/installs" ]] && full_targets+=("mise installs")
    [[ -d "$HOME/.cache/pre-commit" ]] && full_targets+=("pre-commit envs")
    [[ -d "/Library/Developer/CoreSimulator/Caches" || -d "/Library/Developer/CoreSimulator/Images" ]] && \
        full_targets+=("/Library/Developer/CoreSimulator (sudo)")

    if [[ ${#full_targets[@]} -gt 0 ]]; then
        target_list=$(IFS=', '; echo "${full_targets[*]}")
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
