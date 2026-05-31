#!/bin/bash
# Stop hook: backstop detector for "distillation" moments.
#
# Deterministic-only. Fires on the one mechanical signal an agent is most likely
# to miss: the current branch is many commits ahead of the base branch, so a
# pr-plan distillation is probably overdue. Suggest-only, throttled per branch,
# fails open. Semantic detection (system/trace-diff/followups/...) is handled by
# the always-on distillation rule, not here.
#
# Works as a Cursor or Claude Code `stop` hook (reads workspace_roots[0] or cwd).
# Tunables (env): DISTILL_AHEAD_THRESHOLD=12, DISTILL_THROTTLE=86400,
# DISTILL_PLAN_FRESH_DAYS=7, DISTILL_DOC_ROOT=design_docs, DISTILL_BASE_BRANCH=auto.

INPUT=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# --- Loop guards ---
LOOP_COUNT=$(echo "$INPUT" | jq -r '.loop_count // 0' 2>/dev/null || echo 0)
[ "$LOOP_COUNT" -gt 0 ] 2>/dev/null && exit 0
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

PROJECT_DIR=$(echo "$INPUT" | jq -r '.workspace_roots[0] // .cwd // empty' 2>/dev/null || echo "")
[ -z "$PROJECT_DIR" ] && exit 0
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# --- Resolve base branch: env override, else origin/HEAD, else main/master ---
BASE_BRANCH=${DISTILL_BASE_BRANCH:-}
if [ -z "$BASE_BRANCH" ]; then
  BASE_BRANCH=$(git -C "$PROJECT_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
fi
if [ -z "$BASE_BRANCH" ]; then
  for b in main master; do
    git -C "$PROJECT_DIR" rev-parse --verify "$b" >/dev/null 2>&1 && BASE_BRANCH="$b" && break
  done
fi
[ -z "$BASE_BRANCH" ] && exit 0
git -C "$PROJECT_DIR" rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1 || exit 0

BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ] || [ "$BRANCH" = "$BASE_BRANCH" ]; then exit 0; fi

AHEAD=$(git -C "$PROJECT_DIR" rev-list --count "${BASE_BRANCH}..HEAD" 2>/dev/null || echo 0)
THRESHOLD=${DISTILL_AHEAD_THRESHOLD:-12}
[ "$AHEAD" -ge "$THRESHOLD" ] 2>/dev/null || exit 0

# --- Dedupe: stay quiet if a pr-plan was touched recently (already on it) ---
DOC_ROOT=${DISTILL_DOC_ROOT:-design_docs}
FRESH_DAYS=${DISTILL_PLAN_FRESH_DAYS:-7}
if [ "$FRESH_DAYS" -gt 0 ] 2>/dev/null && [ -d "$PROJECT_DIR/$DOC_ROOT" ]; then
  RECENT_PLAN=$(find "$PROJECT_DIR/$DOC_ROOT" -maxdepth 3 -name '*_pr_plan.md' -mtime -"$FRESH_DAYS" 2>/dev/null | head -1)
  [ -n "$RECENT_PLAN" ] && exit 0
fi

# --- Throttle: at most once per branch per DISTILL_THROTTLE seconds ---
STATE_DIR="$HOME/.cursor/hooks-state"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
SAFE_BRANCH=$(echo "$BRANCH" | tr '/ ' '__')
STATE_FILE="$STATE_DIR/distill-${SAFE_BRANCH}.json"
NOW=$(date +%s)
THROTTLE=${DISTILL_THROTTLE:-86400}

if [ -f "$STATE_FILE" ]; then
  LAST=$(jq -r '.last_suggest_ts // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  [ $((NOW - LAST)) -lt "$THROTTLE" ] && exit 0
fi

jq -n --argjson ts "$NOW" --arg branch "$BRANCH" '{last_suggest_ts: $ts, branch: $branch}' > "$STATE_FILE" 2>/dev/null || true

MSG="This branch (${BRANCH}) is ${AHEAD} commits ahead of ${BASE_BRANCH}. Suggest to the user (one line, do not auto-run): consider '/distill pr-plan' to capture per-PR descriptions with evidence before the branch grows further. First scan ${DOC_ROOT}/ for an existing *_pr_plan.md and update it instead of duplicating. Do not interrupt active work."

jq -n --arg msg "$MSG" '{followup_message: $msg}'
exit 0
