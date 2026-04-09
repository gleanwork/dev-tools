# /pr skeleton

Extract an architectural skeleton (**target ~10%** of new code) for review. **Skeleton PRs are never merged** - they exist purely to help reviewers understand the architecture before diving into the full implementation.

**Always report actual percentage** in PR descriptions (e.g., "107 lines / 1762 = 6.1%").

## The Problem

Coding is 100x faster with AI, but reviewing isn't. For large extracted PRs (500+ lines), reviewers shouldn't have to wade through boilerplate to find the architectural decisions.

## The Solution

**Aggressively strip boilerplate from NEW CODE ONLY** (imports, build rules, types, validation) to reveal the reviewable core:

- Key decisions and WHY they were made
- Risks and pitfalls - security, perf, race conditions, edge cases
- Control flow - how components connect
- Integration points - calls to external systems/APIs
- New dependencies that may have duplication
- Architectural patterns being introduced

**Critical insight**: Pre-existing code must stay intact. Only skeleton-ize the NEW code being added. Otherwise, a PR that adds 50 lines to a 1000-line file would show -950 lines of "deleted" code in the skeleton diff - defeating the entire purpose.

---

## ⛔ SAFETY: Parent Branch is READ-ONLY

**CRITICAL**: The original/parent branch and worktree are **READ-ONLY** for this command. NEVER delete, modify, or recreate them.

### What this command MAY do:

- Delete and recreate the **skeleton** branch (`*-skeleton`)
- Delete and recreate the **skeleton** worktree (`*-skeleton` directory)
- Push to the **skeleton** remote branch

### What this command must NEVER do:

- Delete the original branch (e.g., `jd/auth-refactor`)
- Delete the original worktree (e.g., `../auth-refactor`)
- Push to or modify the original remote branch
- Run `git branch -D` on any non-skeleton branch
- Run `git worktree remove` on any non-skeleton worktree

### Validation pattern (REQUIRED before any destructive operation):

```bash
# Before deleting ANY branch, verify it ends with "-skeleton"
if [[ ! "${BRANCH_TO_DELETE}" =~ -skeleton$ ]]; then
    echo "ERROR: Refusing to delete non-skeleton branch: ${BRANCH_TO_DELETE}"
    echo "This command only manages skeleton branches."
    exit 1
fi

# Before removing ANY worktree, verify it ends with "-skeleton"
if [[ ! "${WORKTREE_TO_DELETE}" =~ -skeleton$ ]]; then
    echo "ERROR: Refusing to delete non-skeleton worktree: ${WORKTREE_TO_DELETE}"
    echo "This command only manages skeleton worktrees."
    exit 1
fi
```

### On failure: ASK USER, don't auto-recover

If skeleton creation fails (branch exists, worktree conflict, etc.):

1. **STOP** - do not attempt automatic cleanup
2. **REPORT** the specific error to the user
3. **SUGGEST** manual cleanup commands for the **skeleton only**
4. **NEVER** suggest or run commands that touch the original branch/worktree

---

## /pr skeleton

**Usage:**

```
/pr skeleton [<branch-name>|<worktree-dir>] [-- <guidance-text>]
```

**Examples:**

```bash
/pr skeleton                          # Current branch
/pr skeleton jd/auth-refactor          # Specific branch
/pr skeleton ../auth-refactor          # Worktree in another directory
/pr skeleton -- focus on API integration flow
```

**IMPORTANT**: When given a worktree path or branch name, always resolve the PR from THAT branch, not the current directory's branch.

---

## File Classification

Before creating the skeleton, classify each changed file:

| Category          | Condition                       | Skeleton Treatment                             |
| ----------------- | ------------------------------- | ---------------------------------------------- |
| **New file**      | Only additions (deletions=0)    | Skeleton the entire file                       |
| **Modified file** | Both additions and deletions    | Keep master version + add skeleton of new code |
| **Deleted file**  | Only deletions (additions=0)    | Skip entirely (note in commit message)         |
| **Build/Config**  | BUILD.bazel, package.json, etc. | Skip entirely                                  |
| **Tests**         | _\_test._, _.spec._, _.test._   | Skip entirely                                  |

---

## What to KEEP vs REMOVE (for NEW code only)

### KEEP (the reviewable core)

- **Function signatures** with meaningful parameter names
- **Call sites** - WHERE functions are called, WITH WHAT arguments
- **Integration points** - external API calls with their arguments
- **Control flow** - the path from input to output
- **Architectural decision comments** - WHY choices were made
- **Risk annotations** - `// RISK:` security, perf, races, failure modes

### REMOVE (boilerplate that obscures)

- **Import statements** - always remove from new code
- **Type declarations** - unless complex domain types
- **Validation details** - summarize as `// validate X, Y, Z`
- **Error handling boilerplate** - replace with `// handle error`
- **Logging** - not architecturally relevant
- **CSS/styling** - delete or 1-line stub

### SIMPLIFICATION PATTERN

**Before** (20 lines of validation):

```go
if request.Body != nil {
    err, bodyBytes := handlers_base.ReadRequestBody(request)
    if err == nil && len(bodyBytes) > cMaxRequestBodySize {
        return qe_core.NewResponse_OnlyStatus(
            handlers_base.WriteBadRequestError(ctx, writer,
                "request body exceeds maximum size of 1MB",
                util.Errorf("request body size %d exceeds max %d", ...),
            ),
        )
    }
}
```

**After** (skeleton):

```go
// Validate: body size < 1MB
```

---

## Workflow

### 1. Resolve target branch and PR (CRITICAL)

**Bug prevention**: Always resolve branch/PR from the TARGET, not current directory.

```bash
# Parse argument: could be branch name, worktree path, or empty (current)
TARGET_ARG="$1"

if [[ -z "${TARGET_ARG}" ]]; then
    # No argument - use current directory
    ORIGINAL_BRANCH=$(git branch --show-current)
    ORIGINAL_PR_NUMBER=$(gh pr view --json number -q .number)
elif [[ -d "${TARGET_ARG}" ]]; then
    # It's a directory path - cd into worktree to get branch/PR
    ORIGINAL_BRANCH=$(cd "${TARGET_ARG}" && git branch --show-current)
    ORIGINAL_PR_NUMBER=$(cd "${TARGET_ARG}" && gh pr view --json number -q .number)
else
    # It's a branch name - find PR by branch
    ORIGINAL_BRANCH="${TARGET_ARG}"
    ORIGINAL_PR_NUMBER=$(gh pr list --head "${ORIGINAL_BRANCH}" --json number -q '.[0].number')
fi

# Validate we found a PR
if [[ -z "${ORIGINAL_PR_NUMBER}" ]]; then
    echo "ERROR: No PR found for branch ${ORIGINAL_BRANCH}"
    exit 1
fi

echo "Creating skeleton for PR #${ORIGINAL_PR_NUMBER} (branch: ${ORIGINAL_BRANCH})"
```

### 2. Classify files from the PR

```bash
# Get file stats from the PR (not local diff)
gh pr view ${ORIGINAL_PR_NUMBER} --json files -q '.files[] | "\(.path) +\(.additions) -\(.deletions)"'
```

Classify into:

- `NEW_FILES` - files with deletions=0 (and not tests/build files)
- `MODIFIED_FILES` - files with both additions>0 and deletions>0
- `DELETED_FILES` - files with additions=0 (skip these)
- `SKIP_FILES` - tests, BUILD.bazel, lock files, CSS

### 3. Create clean skeleton worktree (CRITICAL - prevents master drift)

**Bug prevention**: Do NOT use sparse checkout. Start from fresh master, create directories manually, add only skeleton files.

**⛔ SAFETY**: Only delete branches/worktrees ending in `-skeleton`. Validate before ANY destructive operation.

```bash
SHORT_NAME=$(echo ${ORIGINAL_BRANCH} | sed 's/^[^/]*\///')
INITIALS=$(echo ${ORIGINAL_BRANCH} | cut -d'/' -f1)
SKELETON_BRANCH="${INITIALS}/${SHORT_NAME}-skeleton"
SKELETON_DIR="../${SHORT_NAME}-skeleton"

# ⛔ SAFETY CHECK: Verify skeleton naming before proceeding
if [[ ! "${SKELETON_BRANCH}" =~ -skeleton$ ]]; then
    echo "ERROR: Internal error - skeleton branch name doesn't end with -skeleton: ${SKELETON_BRANCH}"
    exit 1
fi
if [[ ! "${SKELETON_DIR}" =~ -skeleton$ ]]; then
    echo "ERROR: Internal error - skeleton dir doesn't end with -skeleton: ${SKELETON_DIR}"
    exit 1
fi

# ⛔ SAFETY CHECK: Verify we're not about to touch the original branch
if [[ "${SKELETON_BRANCH}" == "${ORIGINAL_BRANCH}" ]]; then
    echo "ERROR: Skeleton branch name equals original branch - refusing to proceed"
    exit 1
fi

git fetch origin master

# If skeleton worktree exists, remove it (ONLY skeleton, validated above)
if [[ -d "${SKELETON_DIR}" ]]; then
    echo "Removing existing skeleton worktree: ${SKELETON_DIR}"
    git worktree remove "${SKELETON_DIR}" --force 2>/dev/null || rm -rf "${SKELETON_DIR}"
    git worktree prune
fi

# Delete old skeleton branch if exists (ONLY skeleton, validated above)
if git show-ref --verify --quiet "refs/heads/${SKELETON_BRANCH}"; then
    echo "Removing existing skeleton branch: ${SKELETON_BRANCH}"
    git branch -D "${SKELETON_BRANCH}"
fi

# Create fresh skeleton branch from master
git branch "${SKELETON_BRANCH}" origin/master

# Create worktree (full checkout, not sparse)
git worktree add "${SKELETON_DIR}" "${SKELETON_BRANCH}"
cd "${SKELETON_DIR}"
```

**If this step fails**: Do NOT attempt to delete the original branch/worktree. Report the error and let the user manually clean up the skeleton artifacts only.

### 4. Create skeleton files (only new files, not from worktree)

**Bug prevention**: Create directories and files manually. Do NOT copy from sparse checkout.

```bash
# For each NEW file, create directory and skeleton file
for file in ${NEW_FILES}; do
    mkdir -p $(dirname "$file")
    # Write skeleton content directly (AI transforms the code)
done

# IMPORTANT: Only git add the specific skeleton files
git add ${NEW_FILES}
# Do NOT use: git add -A (this would include unwanted files)
```

### 5. Transform each file to skeleton

For each NEW file:

1. **Delete all imports**
2. **Keep function signatures** (can simplify parameter types)
3. **Keep call sites** showing what calls what
4. **Keep integration points** with arguments
5. **Replace boilerplate** with `// ...` comments
6. **Add WHY comments** for key decisions
7. **Add RISK comments** for pitfalls (security, perf, races, edge cases)

---

## Handling Modified Files

This is the critical part that prevents massive deletion diffs.

**Goal**: Show what's being ADDED without showing what's being DELETED.

**Approach**: Keep the master version intact, then append a clearly-marked skeleton section showing only the new code.

**Format for modified files**:

```python
# ... (file content from master stays exactly as-is) ...

# ============================================================
# SKELETON: New code added in this PR (full impl: #12345)
# ============================================================

# NEW: endpoint handler for search suggestions
def handle_search_suggestions(request):
    # Validate: request body < 1MB
    # Call: suggestions.generate(context, user_prefs)
    # RISK: 30s timeout may be too long for mobile
    pass
```

**Why this works**:

- Skeleton diff only shows the small appended section
- Pre-existing code doesn't appear as deleted
- Reviewer sees the architectural skeleton without noise
- Clear visual separation between old and new

### 6. Commit and push (no hooks)

**Bug prevention**: Only add skeleton files explicitly, never `git add -A`.

```bash
# Calculate actual percentage
SKELETON_LINES=$(wc -l ${NEW_FILES} | tail -1 | awk '{print $1}')
ORIGINAL_LINES=$(gh pr view ${ORIGINAL_PR_NUMBER} --json additions -q .additions)
ACTUAL_PERCENT=$(echo "scale=1; ${SKELETON_LINES} * 100 / ${ORIGINAL_LINES}" | bc)

# CRITICAL: Only add the skeleton files, not everything in worktree
git add ${NEW_FILES}
# Verify no extra files: git status should show only skeleton files

git commit --no-verify -m "[SKELETON] ${ORIGINAL_PR_TITLE} (${ACTUAL_PERCENT}% of impl)

Architectural skeleton for review.
Full implementation: #${ORIGINAL_PR_NUMBER} (${ORIGINAL_LINES} lines)
Skeleton: ${SKELETON_LINES} lines (${ACTUAL_PERCENT}%)

NOT FOR MERGE - review artifact only."

git push --no-verify -u origin ${SKELETON_BRANCH}
```

### 7. Create PRs with bidirectional links

**Skeleton PR body:**

```markdown
## ⚠️ NOT FOR MERGE - Review Artifact Only

Architectural skeleton: **${SKELETON_LINES} lines (${ACTUAL_PERCENT}%)** of full implementation.
**Full implementation**: #${ORIGINAL_PR_NUMBER} (${ORIGINAL_LINES} lines)

**Files included**:
| File | Lines | Description |
|------|-------|-------------|
| [file1] | [N] | [brief description] |

**Files skipped** (see full PR):

- Deleted files: [list]
- Build/config changes: [list]
```

**Update original PR description** - add skeleton link **at the very top** of the PR body (not as a comment):

```markdown
## 🏗️ Architectural Skeleton Available

**For reviewers**: Start with the architectural skeleton for a quick overview:
👉 **#${SKELETON_PR_NUMBER}** - Skeleton PR (${ACTUAL_PERCENT}% of implementation: ${SKELETON_LINES} of ${ORIGINAL_LINES} lines)

The skeleton shows only NEW code being added:

- New files: fully skeletonized
- Modified files: master version + skeleton appendix of additions
- Deleted/build/test files: skipped (review in full PR)

After reviewing the skeleton, return here for the full implementation.

---

[rest of original PR description]
```

---

## Example: Modified File

**Scenario**: PR modifies `server.py` (983 deletions, 8 additions)

**OLD approach** (wrong): Replace entire file with stub → diff shows -983 lines deleted

**NEW approach** (correct): Keep master version, append skeleton of new code only

**Skeleton file content**:

```python
# server.py - master version (983 lines)
# ... entire original file content stays here unchanged ...

# ============================================================
# SKELETON: New code added in this PR (full impl: #12345)
# ============================================================

# NEW: Search suggestions endpoint integration
# Routes to: features/suggestions.py
@app.post("/api/suggestions")
async def suggestions_endpoint(request):
    # Delegates to new suggestions module
    pass
```

**Skeleton diff**: Only shows ~10 lines added (the appendix), not 983 lines deleted.

---

## Example: New File

**Scenario**: PR adds `features/suggestions.py` (174 additions)

**Treatment**: Skeleton-ize the entire file (same as before)

```python
# features/suggestions.py
# No imports - skeleton only

class SuggestionGenerator:
    # WHY: Separate from autocomplete for different context handling

    def generate(self, context, user_prefs):
        # Call: LLM with context-specific prompt template
        # RISK: Token limits may truncate long conversation context
        pass

    def _build_prompt(self, context):
        # Includes: last N messages, user preferences, time context
        pass
```

---

## Quality Checklist

- [ ] **⛔ Parent branch/worktree UNTOUCHED** (verify original still exists after skeleton creation)
- [ ] **PR resolved from TARGET** (worktree/branch arg, not current directory)
- [ ] **Only skeleton files in diff** (no random master drift files)
- [ ] **Actual percentage ~10%** (calculate and report in PR descriptions)
- [ ] Pre-existing code in modified files stays INTACT
- [ ] Only NEW code is skeletonized
- [ ] Modified files have clear `# SKELETON:` section marker
- [ ] Can trace request from entry to response
- [ ] Integration points visible with arguments
- [ ] Key decisions have WHY comments
- [ ] Risks flagged with RISK comments
- [ ] Deleted/build/test files noted in commit message
- [ ] Bidirectional PR links with actual percentages

---

## Key Principles

1. **Never merged** - review artifact only
2. **Pre-existing code stays intact** - only skeleton-ize NEW code
3. **Modified files = master + appendix** - prevents deletion diffs
4. **New files = full skeleton** - strip imports, keep flow
5. **Skip deletions** - they're not architectural additions
6. **No hooks** - use `--no-verify` everywhere
7. **⛔ Parent is READ-ONLY** - NEVER delete/modify original branch or worktree

---

## Common Bugs to Avoid

### Bug 1: Master Drift (random files in skeleton PR)

**Symptom**: Skeleton PR shows unrelated files (digests, java changes, etc.)

**Cause**: Using sparse checkout or `git add -A` includes files from master that were in the worktree.

**Fix**:

- Do NOT use sparse checkout
- Create directories manually with `mkdir -p`
- Only `git add ${NEW_FILES}` - never `git add -A`
- Verify with `git diff origin/master --stat` before pushing

### Bug 2: Wrong PR Linked (linked to current dir's PR, not target)

**Symptom**: Running `/pr skeleton ../auth-refactor` links skeleton to the wrong PR.

**Cause**: Getting PR number from current directory instead of target worktree/branch.

**Fix**:

- If argument is a directory path: `cd` into it to get branch/PR
- If argument is a branch name: use `gh pr list --head <branch>` to find PR
- Always validate: `echo "Creating skeleton for PR #${ORIGINAL_PR_NUMBER}"`

### Bug 3: ⛔ Deleting Parent Branch/Worktree (CATASTROPHIC)

**Symptom**: Original branch (e.g., `jd/auth-refactor`) and its worktree get deleted when skeleton creation fails.

**Cause**: On failure, script attempts "cleanup" that accidentally targets the parent instead of the skeleton. This happens when:

- Skeleton branch already exists but script tries to delete "everything" to retry
- Variable confusion between `ORIGINAL_BRANCH` and `SKELETON_BRANCH`
- Error recovery logic doesn't validate what it's deleting

**Impact**: Loss of uncommitted work, need to recover from remote (if pushed).

**Prevention** (MANDATORY):

1. **Naming validation**: Before ANY `git branch -D` or `git worktree remove`, verify the target ends with `-skeleton`
2. **Variable isolation**: Never reuse variables - `ORIGINAL_BRANCH` and `SKELETON_BRANCH` must be distinct
3. **Fail-safe pattern**: On error, STOP and report - never auto-recover by deleting
4. **Explicit checks**:

```bash
# REQUIRED before any branch deletion
[[ "${BRANCH}" =~ -skeleton$ ]] || { echo "REFUSING to delete non-skeleton: ${BRANCH}"; exit 1; }

# REQUIRED before any worktree removal
[[ "${DIR}" =~ -skeleton$ ]] || { echo "REFUSING to delete non-skeleton: ${DIR}"; exit 1; }
```

**If skeleton already exists**: Ask user to manually delete the old skeleton, or delete it with explicit `-skeleton` validation. NEVER implement "delete everything and retry" logic.
