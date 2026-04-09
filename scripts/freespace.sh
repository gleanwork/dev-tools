#!/bin/bash
#
# Frees disk space.
#
# Usage: freespace.sh [-n] [-f]
#
# Modes:
#   (default)   Cheap to delete, cheap to recover (safe for daily use):
#               - Build caches (main + worktrees): .swc, storybook-static, .next, .turbo
#                 __pycache__, .mypy_cache, .pytest_cache, .ruff_cache
#               - App caches: ~/Library/Caches/{Xcode,VSCode,Cursor,Chrome,Arc,JetBrains,
#                 pip,Homebrew,go-build,gopls,pnpm,Yarn,electron,Playwright,bazelisk,...}
#               - Cursor App Support (Cache, CachedData, logs, workspaceStorage, History,
#                 Partitions, WebStorage, GPUCache, CachedProfilesData)
#               - VSCode App Support safe caches (Cache, CachedData, CachedExtensionVSIXs,
#                 logs, Crashpad, WebStorage, GPUCache)
#               - Chrome safe caches (OptGuideOnDeviceModel, extensions_crx_cache,
#                 Snapshots, optimization_guide_model_store, Crashpad, component_crx_cache)
#               - Windsurf App Support safe caches (Cache, CachedData, logs, GPUCache, etc.)
#               - Project-specific dev caches (customize below)
#               - System: ~/.Trash, /tmp/*, ~/.cache/*
#               - Quick restore (~30s): brew cleanup, ~/.npm/_cacache
#               - Misc: uv cache, bazel java logs, git temp packs
#               - Git: worktree prune, remove prunable worktrees, git gc
#               - Post-cleanup: ensures pyright __init__.py stubs in .bazel/bin/com/
#
#   -f          Deep clean — expensive to recover:
#               - Docker: images, containers, volumes (docker system prune -a)
#               - iOS Simulator: ~/Library/Developer/CoreSimulator
#               - Non-main bazel outputs in /var/tmp/_bazel_* (preserves ~/workspace/x)
#               - node_modules in main workspace (requires: pnpm install)
#               - Python virtualenvs (requires: re-create)
#               - node_modules in worktrees if not symlinked
#               - Gradle cache, Maven cache
#               - ~/.cache/bazel (disk cache)
#               - Go module cache (go clean -modcache, slow to re-download)
#               - pnpm store (~/Library/pnpm/store)
#               - git gc --aggressive (thorough repack, slow)
#

set +e

# Configuration — override these via environment or edit below
MAIN_WORKSPACE="${MAIN_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/workspace")}"
BAZEL_ROOT="${BAZEL_ROOT:-/private/var/tmp/_bazel_$USER}"
WORKTREE_PARENT="${WORKTREE_PARENT:-$(dirname "$MAIN_WORKSPACE")}"

# Parse arguments
dry_run=false
full=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) dry_run=true ;;
        -f|--full) full=true ;;
        -nf|-fn) dry_run=true; full=true ;;
        -h|--help)
            cat << 'EOF'
Usage: freespace.sh [-n] [-f]

Modes:
  (default)   Cheap to delete, cheap to recover (safe for daily use):
              - Build caches: .swc, storybook-static, .next, .turbo, __pycache__, etc
              - App caches: ~/Library/Caches/{Xcode,VSCode,Cursor,Chrome,JetBrains,...}
              - Cursor App Support (Cache, CachedData, logs, workspaceStorage, etc)
              - VSCode App Support safe caches, Chrome safe caches
              - Windsurf App Support safe caches
              - ~/.Trash, /tmp/*, ~/.cache/* (preserves pre-commit)
              - Bazel java logs, git temp packs
              - Quick restore (~30s): brew cleanup, ~/.npm/_cacache
              - Git: worktree prune, remove prunable worktrees, git gc

  -f          Deep clean — expensive to recover:
              - Docker: images, containers, volumes (docker system prune -a)
              - iOS Simulator, non-main bazel output bases
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
    if [[ -d "$MAIN_WORKSPACE" ]]; then
        if [[ -L "$MAIN_WORKSPACE/bazel-out" ]]; then
            local target
            target=$(readlink "$MAIN_WORKSPACE/bazel-out" 2>/dev/null)
            if [[ -n "$target" ]]; then
                echo "$(cd "$MAIN_WORKSPACE" && cd "$(dirname "$(dirname "$(dirname "$target")")")" && pwd)" 2>/dev/null || true
                return
            fi
        fi
        (cd "$MAIN_WORKSPACE" && bazel info output_base 2>/dev/null) || true
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
safe_rm "$HOME/Library/Caches/Arc" "Arc"
safe_rm "$HOME/Library/Caches/pip" "pip"
safe_rm "$HOME/Library/Caches/pip-tools" "pip-tools"
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
safe_rm "$HOME/Library/Caches/Coursier" "Coursier"
safe_rm "$HOME/Library/Caches/typescript" "typescript"
safe_rm "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt" "VSCode ShipIt"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "━━━ ${BLUE}Cursor/VSCode App Support${RESET} ${DIM}(editor caches)${RESET}"

safe_rm "$HOME/Library/Application Support/Cursor/Cache" "Cursor Cache"
safe_rm "$HOME/Library/Application Support/Cursor/CachedData" "Cursor CachedData"
safe_rm "$HOME/Library/Application Support/Cursor/CachedExtensionVSIXs" "Cursor CachedVSIXs"
safe_rm "$HOME/Library/Application Support/Cursor/logs" "Cursor logs"
safe_rm "$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb.backup" "Cursor state backup"
safe_rm "$HOME/Library/Application Support/Cursor/User/workspaceStorage" "Cursor workspaceStorage"
safe_rm "$HOME/Library/Application Support/Cursor/User/History" "Cursor History"
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
echo -e "━━━ ${BLUE}Chrome${RESET} ${DIM}(safe caches, keeps profile data)${RESET}"

safe_rm "$HOME/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel" "Chrome ML model"
safe_rm "$HOME/Library/Application Support/Google/Chrome/extensions_crx_cache" "Chrome extensions cache"
safe_rm "$HOME/Library/Application Support/Google/Chrome/Snapshots" "Chrome Snapshots"
safe_rm "$HOME/Library/Application Support/Google/Chrome/optimization_guide_model_store" "Chrome optimization models"
safe_rm "$HOME/Library/Application Support/Google/Chrome/Crashpad" "Chrome Crashpad"
safe_rm "$HOME/Library/Application Support/Google/Chrome/component_crx_cache" "Chrome component cache"

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
echo -e "━━━ ${BLUE}System${RESET} ${DIM}(Trash, temp files)${RESET}"

safe_rm "$HOME/.Trash" "Trash"
safe_rm_pattern "/tmp" "*" "temp files"

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

    # Remove prunable worktrees (git marks these automatically when the branch is gone)
    while IFS= read -r line; do
        if [[ "$line" == *"prunable"* ]]; then
            wt_path=$(echo "$line" | awk '{print $1}')
            wt_branch=$(echo "$line" | sed 's/.*\[\(.*\)\].*/\1/' | sed 's/ prunable//')
            wt_size_kb=$(get_size "$wt_path")
            size_str=$(format_size "$wt_size_kb")

            if $dry_run; then
                echo -e "  ${BLUE}○${RESET} remove prunable: $wt_branch ${YELLOW}$size_str${RESET}"
            else
                if git -C "$MAIN_WORKSPACE" worktree remove --force "$wt_path" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${RESET} removed prunable: $wt_branch ${GREEN}$size_str${RESET}"
                else
                    echo -e "  ${RED}✗${RESET} remove prunable: $wt_branch (failed)"
                    ((items_failed++))
                    wt_size_kb=0
                fi
            fi
            freed_total=$((freed_total + wt_size_kb))
            ((items_deleted++))
        fi
    done < <(git -C "$MAIN_WORKSPACE" worktree list 2>/dev/null)

    # git gc to compact .git object store
    git_size_before=$(get_size "$MAIN_WORKSPACE/.git")
    git_size_str=$(format_size "$git_size_before")

    if $dry_run; then
        echo -e "  ${BLUE}○${RESET} git gc (.git is $git_size_str)"
    else
        if $full; then
            git -C "$MAIN_WORKSPACE" gc --aggressive --prune=now 2>/dev/null &
            gc_pid=$!
            spin "$gc_pid" "git gc --aggressive (this takes a while)"
        else
            git -C "$MAIN_WORKSPACE" gc --prune=now 2>/dev/null &
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
# safe_rm "$MAIN_WORKSPACE/.opensearch" "OpenSearch data"
safe_rm "$HOME/.cache/uv" "uv cache"
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
echo ""
echo -e "━━━ ${BLUE}Bazel${RESET} ${DIM}(java logs)${RESET}"

safe_rm_pattern "$BAZEL_ROOT" "java.log.*" "java logs"

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

    safe_rm "$HOME/Library/Developer/CoreSimulator" "iOS Simulator"

    # Non-main bazel output bases
    if ! $dry_run; then
        echo -e "  ${DIM}shutting down bazel...${RESET}"
        pkill -9 -f "bazel.*_bazel_$USER" 2>/dev/null || true
        "$MAIN_WORKSPACE/tools/mybazel.sh" shutdown 2>/dev/null || true
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

    echo -e "  ${DIM}restore: npm/pnpm install · recreate virtualenvs · everything else auto-recovers${RESET}"
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
