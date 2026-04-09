# /pr fix [pr_number | worktree | branch | ci_url]

Automated CI failure diagnosis and fixing. Find the breakage, fix it, test locally while CI runs in parallel, iterate until green.

**The goal**: Make fixing CI a delight, not a chore. You diagnose, fix, verify, and iterate—the engineer watches (or walks away). Minimal interruptions, maximum automation.

## Usage

- `/pr fix` - fix CI for current branch's PR
- `/pr fix 12345` - fix CI for specific PR
- `/pr fix ../rc_feature-x` - fix CI in worktree
- `/pr fix https://github.com/<owner>/<repo>/actions/runs/12345` - fix specific CI run
- `/pr fix --watch` - fix current CI, then monitor for new failures

---

## Phase 0: Determine Context

### Step 1: Parse Input

```bash
# No args: use current branch
PR_NUMBER=$(gh pr view --json number -q .number 2>/dev/null)

# Numeric arg: specific PR
PR_NUMBER=$1

# Path arg: worktree - cd there first, then get PR
cd "$1" && PR_NUMBER=$(gh pr view --json number -q .number)

# URL arg: extract run ID and get PR from that run
RUN_ID=$(echo "$1" | grep -oE 'runs/[0-9]+' | cut -d'/' -f2)
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
PR_NUMBER=$(gh api repos/$REPO/actions/runs/$RUN_ID --jq '.pull_requests[0].number')
```

### Step 2: Ensure Correct Context

**Critical**: All work happens in the PR's worktree or branch.

```bash
PR_BRANCH=$(gh pr view $PR_NUMBER --json headRefName -q .headRefName)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Check for existing worktree
WORKTREE=$(git worktree list | grep -E "$PR_BRANCH" | awk '{print $1}')

if [ -n "$WORKTREE" ] && [ "$PWD" != "$WORKTREE" ]; then
  echo "📁 Switching to worktree: $WORKTREE"
  cd "$WORKTREE"
elif [ "$CURRENT_BRANCH" != "$PR_BRANCH" ]; then
  echo "⚠️  Current branch ($CURRENT_BRANCH) != PR branch ($PR_BRANCH)"
  echo "Switch to PR branch? (yes/no/create worktree)"
  # Wait for user input before switching
fi
```

---

## Phase 1: Diagnose CI Failure

### Step 1: Get Latest CI Status

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

# Get all check runs for the PR's head SHA
HEAD_SHA=$(gh pr view $PR_NUMBER --json headRefOid -q .headRefOid)

# Find failed checks
gh api repos/$REPO/commits/$HEAD_SHA/check-runs \
  --jq '.check_runs[] | select(.conclusion == "failure") | {name: .name, id: .id, html_url: .html_url}'
```

### Step 2: Identify Failure Type

Categorize the failure and route to appropriate handler:

| Failure Type | Indicators | Handler |
|--------------|------------|---------|
| **Bazel Build** | "FAILED TO BUILD", compilation errors | `handle_build_failure` |
| **Bazel Test** | Test assertion failures, timeout | `handle_test_failure` |
| **Lint/Format** | ESLint, golint, pre-commit | `handle_lint_failure` |
| **PR Checks** | Missing test, review requirements | `handle_pr_check` |
| **Merge Conflict** | "Merge failed" | `handle_merge_conflict` |
| **Flaky/Infra** | Timeout, OOM, network issues | `handle_infra_issue` |

### Step 3: Fetch Failure Details

```bash
# For Bazel failures - get workflow logs
FAILED_RUN=$(gh run list \
  --commit=$HEAD_SHA --json databaseId,conclusion \
  --jq '.[] | select(.conclusion == "failure") | .databaseId' | head -1)

# Get the "View Failed Test Logs" step output
gh run view $FAILED_RUN --log 2>&1 | grep -A 500 "View Failed Test Logs"

# Alternative: get job summary (often has parsed failure info)
gh run view $FAILED_RUN --json jobs --jq '.jobs[].steps[] | select(.name | test("Failed|Error|Summary")) | .name'
```

---

## Phase 2: Fix the Issue

### Build/Compile Failures

```
### 🔴 Build Failure Detected

**Target**: `//go/core/query:query`
**Error**: undefined: QueryResult
**File**: `go/core/query/handler.go:47`

**Root Cause**: Import missing after refactor

**Fix**:
```go
import "github.com/org/repo/go/proto/query"
```

Applying fix...
```

### Test Failures

```
### 🔴 Test Failure Detected

**Target**: `//go/core/query:query_test`
**Test**: TestQueryHandler_EmptyInput
**Error**: expected nil, got error: "input required"

**Analysis**: Test expects nil error, but new validation rejects empty input.

**Options**:
1. **Update test** (recommended) - Test expectation is stale
2. **Revert validation** - If empty input should be allowed
3. **Skip for now** - Add TODO and skip test

Which approach? (1/2/3)
```

### Lint Failures

Lint failures are often auto-fixable. Proceed without confirmation:

```bash
# Run pre-commit on changed files only
git diff --name-only origin/master...HEAD | xargs pre-commit run --files

# If fixes applied, stage them
git add -u
```

### PR Check Failures

Handle PR-level requirements (not CI test failures):

```
### ⚠️ PR Check Failed: test_coverage_check

**Reason**: New code in `go/core/query/handler.go` lacks test coverage
**Required**: 80% coverage, Current: 65%

**Options**:
1. **Generate test stubs** - Create test file with TODO placeholders
2. **Add coverage skip** - Add `// coverage:ignore` comment (requires justification)
3. **Write tests now** - I'll generate tests for the new functions

Which approach? (1/2/3)

💡 If this is flag-gated/internal code, option 2 with comment "WIP - flag gated" is acceptable.
```

### Merge Conflicts

```
### ⚠️ Merge Conflict with Base Branch

**Conflicting Files**:
- `go/core/query/handler.go` (both modified)
- `BUILD.bazel` (dependency changes)

**Analysis**: Master had a parallel refactor. Conflicts are resolvable.

Attempting automatic resolution...

If conflicts require judgment, I'll pause and show you the options.
```

### Infra/Flaky Failures

```
### 🟡 Infrastructure Issue Detected

**Symptoms**:
- Timeout after 30 minutes
- No compilation or test errors
- Previous runs succeeded with same code

**Diagnosis**: Likely CI infrastructure issue (runner exhaustion, network)

**Actions**:
1. Retrying CI run...
   `gh run rerun $FAILED_RUN --failed`
2. Monitoring for completion...

If retry fails, will escalate with diagnostic info.
```

---

## Phase 3: Commit and Push

### Smart Commit Process

```bash
# Stage fixes
git add -u

# Generate descriptive commit message
COMMIT_MSG="fix ci: [description based on what was fixed]

- Fixed: [specific issue]
- Cause: [root cause]
- Verified: [how we know it's fixed]"

# Attempt commit with pre-commit hooks
git commit -m "$COMMIT_MSG"

# If pre-commit fails and auto-fixes, retry
if [ $? -ne 0 ]; then
  git add -u
  git commit -m "$COMMIT_MSG"
fi

# Push to trigger CI
git push
```

### Parallel Verification Strategy

**Key insight**: Push immediately to start CI, then test locally in parallel.

```
┌─────────────────┐     ┌─────────────────┐
│   Remote CI     │     │   Local Test    │
│   (triggered)   │     │   (parallel)    │
└────────┬────────┘     └────────┬────────┘
         │                       │
         │ ◄─── If local fails, ─┤
         │      we know before   │
         │      CI even starts   │
         │                       │
         ▼                       ▼
    [CI Result]            [Local Result]
```

### Local Verification

```bash
# Run the specific failing target locally
bazel test //path/to:target --test_output=errors

# For multiple failures, run them in parallel
bazel test //path/to:target1 //path/to:target2 --jobs=8

# Quick lint check
pre-commit run --files $(git diff --name-only HEAD~1)
```

---

## Phase 4: Monitor and Iterate

### Wait for CI with Progress

```
### ⏳ Monitoring CI

**Commit**: abc123f - "fix ci: add missing import"
**Push time**: 2 minutes ago

┌──────────────────────────────────────────────────────┐
│ 🟡 Bazel warm runner          [Running - 5m elapsed] │
│ ✅ ESLint CI                  [Passed]               │
│ ✅ PR Checks                  [Passed]               │
└──────────────────────────────────────────────────────┘

Local verification: ✅ Passed (ran in parallel)

Refreshing in 30 seconds... (Ctrl+C to stop)
```

### Polling Logic

```bash
while true; do
  # Get current check status
  STATUS=$(gh pr checks $PR_NUMBER --json name,state,conclusion \
    --jq '.[] | select(.name == "Bazel build and test")')

  CONCLUSION=$(echo "$STATUS" | jq -r '.conclusion')
  STATE=$(echo "$STATUS" | jq -r '.state')

  if [ "$STATE" = "completed" ]; then
    if [ "$CONCLUSION" = "success" ]; then
      echo "✅ CI passed!"
      break
    else
      echo "🔴 CI failed again. Analyzing new failure..."
      # Loop back to Phase 1
    fi
  fi

  sleep 30
done
```

### Iteration on New Failures

When CI fails again after a fix attempt:

```
### 🔄 New CI Failure (Iteration 2)

Previous fix (abc123f) resolved the import issue, but exposed a new failure:

**New Failure**: `//go/core/query:query_test`
**Error**: TestQueryHandler_Pagination: index out of range

This is a cascading issue - the import fix exposed a latent bug.

**Analyzing**...
```

---

## Phase 5: Success or Escalation

### On Success

```
### ✅ CI Green!

**PR**: #12345 - "Add query pagination"
**Fixes applied**:
1. `abc123f` - Added missing import
2. `def456g` - Fixed pagination index bug

**Total time**: 12 minutes (2 iterations)

**Summary**:
| Issue | Fix | Verification |
|-------|-----|--------------|
| Missing import | Added `query` package | Build passed |
| Index OOB | Bounds check in loop | Test passed |

Ready for review! 🎉
```

### On Unfixable Issue

When the issue requires human judgment or is beyond automation:

```
### ❌ Cannot Auto-Fix

**Issue**: Test failure in `TestQueryHandler_Auth`
**Error**: Expected 403, got 401

**Analysis**:
This appears to be a behavioral change, not a bug. The test expects the OLD behavior
(return 403 for unauthorized), but the code now returns 401.

**Root cause options**:
1. **Intentional change** - Update the test to expect 401
2. **Regression** - Revert the auth change (commit xyz789)
3. **Spec ambiguity** - Both codes are valid per HTTP spec

**Recommendation**: 🎯 Option 1 (likely intentional)

The commit message for xyz789 says "align auth responses with OAuth2 spec" which
suggests 401 is the intended new behavior.

**To apply option 1**:
```bash
# I've prepared the fix but need your confirmation:
sed -i 's/403/401/' go/core/query/handler_test.go
```

Proceed with option 1? (yes/no/discuss)
```

### Hard Failures

For truly unfixable issues:

```
### 🛑 Manual Intervention Required

**Issue**: Merge conflict in generated protobuf files
**Why automation fails**: Protobuf regeneration requires running `bazel run //:gazelle_proto`
which I cannot execute (no bazel in this context).

**Manual steps**:
1. Run: `bazel run //:gazelle_proto`
2. Resolve any remaining conflicts in generated files
3. Commit and push

**Alternative**: Run `/pr fix` again after executing step 1 locally.

---

Or, if you want me to add these steps to your worktree for later:
```bash
echo "TODO: bazel run //:gazelle_proto" >> .ci_fix_notes.md
```
```

---

## Interactive vs Non-Interactive Mode

### Non-Interactive (Default for Simple Fixes)

For high-confidence fixes, proceed without asking:

- ✅ Import fixes
- ✅ Lint/formatting auto-fixes
- ✅ Obvious typos in error messages
- ✅ Missing BUILD.bazel deps
- ✅ Retrying flaky CI

### Interactive (Always Ask)

For changes that affect behavior:

- ❓ Test expectation changes
- ❓ Skipping/disabling tests
- ❓ Code logic changes (not just imports)
- ❓ Merge conflict resolution
- ❓ Any change where intent is ambiguous

### Confidence Scoring

```
**Fix Confidence**: 9/10 - High

Reasoning:
- Error message is unambiguous
- Fix is mechanical (add import)
- Similar fixes succeeded 100% historically
- No behavioral change

Proceeding automatically...
```

```
**Fix Confidence**: 4/10 - Low

Reasoning:
- Test failure could be regression OR outdated expectation
- Multiple valid interpretations
- Requires understanding of business logic

Pausing for confirmation...
```

---

## Special Handlers

### `/pr fix --watch`

Monitor mode: fix current issues, then watch for new failures.

```
### 👀 Watch Mode Active

Monitoring PR #12345 for CI failures.
Will auto-fix when possible, alert when not.

Current status: ✅ All checks passing

[Watching... Press Ctrl+C to stop]
```

### Handling Multiple Failures

When CI has multiple distinct failures:

```
### 🔴 Multiple CI Failures Detected (3)

| # | Type | Target | Severity |
|---|------|--------|----------|
| 1 | Build | //go/core:core | 🔴 Blocking |
| 2 | Test | //python/agent:agent_test | 🟡 After build |
| 3 | Lint | ESLint | 🟢 Independent |

**Strategy**: Fix in dependency order (build → test → lint)

Starting with failure #1...
```

### Test Missing Detection

When PR adds code without tests:

```
### ⚠️ PR Check: test_coverage

New code added without corresponding tests:
- `go/core/query/pagination.go` (new file, 0% coverage)

**Options**:
1. **Generate test skeleton** - Create `pagination_test.go` with TODOs
2. **Add skip annotation** - With comment explaining why (e.g., "tested via integration")
3. **Full test generation** - I'll write real tests for the new functions

Which approach? (1/2/3)

💡 Tip: If this is WIP/flag-gated, option 2 with "[NI] flag-gated, will add tests before unflagging" is fine.
```

---

## Error Messages and UX

### Progress Indicators

```
⏳ Fetching CI logs...
📊 Analyzing failure patterns...
🔧 Applying fix...
🧪 Running local verification...
📤 Pushing changes...
👀 Monitoring CI...
```

### Clear Error Attribution

```
🔴 **Build Error**
   File: go/core/query/handler.go:47:12
   Error: undefined: QueryResult

   ┌─ go/core/query/handler.go ─────────────────────────────
   │ 45 │ func (h *Handler) Process(ctx context.Context) {
   │ 46 │     result := h.query(ctx)
   │ 47 │     return QueryResult{Data: result}  // ← ERROR HERE
   │    │            ^^^^^^^^^^^
   │ 48 │ }
   └────────────────────────────────────────────────────────
```

### Actionable Recommendations

Always end with a clear next step:

```
**Next Steps**:
1. [Recommended] Run `/pr fix` again after the fix
2. [Alternative] Manually verify with: `bazel test //go/core/query:query_test`
3. [If stuck] Share this output in #eng-ci for help
```

---

## Guidelines

- **Automate aggressively** for mechanical fixes (imports, deps, formatting)
- **Pause for judgment** on behavioral changes
- **Push early** to parallelize CI with local testing
- **Show your work** - explain what you're fixing and why
- **Iterate gracefully** - new failures after a fix are normal, handle them
- **Fail clearly** - when stuck, provide actionable manual steps
- **Be honest about confidence** - don't pretend certainty you don't have
