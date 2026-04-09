# /pr comments [pr_number]

Address PR comments interactively, **strictly one at a time with explicit approval for each**.

## Usage

- `/pr comments` - resolve comments on current branch's PR
- `/pr comments 12345` - resolve comments on specific PR
- Works in worktrees if user previously said "cd worktree"

---

## Process

Read the PR with gh cli. Address all unaddressed comments in this development branch.

### Fetch comments

**⚠️ CRITICAL: Use `--paginate` to fetch ALL comments.** GitHub API returns max 100 items per page. PRs with many comments require pagination to get the complete list. Without `--paginate`, you will miss comments beyond the first page.

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
PR_NUMBER=$(gh pr view --json number -q .number)

# file-level comments with thread context - MUST paginate to get all
gh api --paginate repos/$REPO/pulls/$PR_NUMBER/comments --jq '.[] | {id: .id, path: .path, body: .body, line: .line, user: .user.login, in_reply_to_id: .in_reply_to_id}'

# PR-level review comments - MUST paginate to get all
gh api --paginate repos/$REPO/pulls/$PR_NUMBER/reviews --jq '.[] | select(.body != "") | {id: .id, body: .body, user: .user.login, state: .state}'

# Verify you got everything - compare counts
COMMENT_COUNT=$(gh api --paginate repos/$REPO/pulls/$PR_NUMBER/comments --jq 'length' | paste -sd+ | bc)
echo "Total file-level comments fetched: $COMMENT_COUNT"
```

**Never assume you have all comments without using `--paginate`.** A PR may have 100+ review comments across many files.

### Filter to unaddressed only

- skip comments where we already replied in that thread
- skip approvals, non-actionable feedback

### Walk through each comment

**⚠️ CRITICAL: Require explicit confirmation for EVERY comment.** A "yes" applies ONLY to the current comment being discussed. Never interpret "yes" as approval for multiple comments. Never batch approvals. Never proceed to the next comment without stopping and waiting for explicit user input.

For each nontrivial comment/resolution:

1. **Show the comment** - text, file, line, author, code context
2. **Explain the proposed resolution** - what reviewer wants, how we'll fix it
3. **State the reply** that will be added (default: "done")
4. **Get user approval** - STOP and wait for one of:
   - `yes` / `y` - approve this fix and reply, then proceed to next comment
   - `do` - make the fix now, but WAIT before posting reply (user reviews the change first)
   - `skip` - skip this comment entirely
   - `<custom reply>` - use this text instead of the default reply
   - `no` / `n` - do not proceed, discuss alternatives
5. **Make the fix** - apply the code change
6. **Reverify** - confirm it perfectly addresses the comment
7. **If user chose `do`**: Show the completed fix and STOP again to confirm posting the reply
8. **Add the reply** - only after fix is verified AND user confirms
9. **STOP and wait for input before proceeding to next comment**

**The `do` option**: Useful when user wants to inspect the code change before the reply is posted. Flow:
- User says `do` → agent makes fix → agent shows result → agent asks "Post reply?" → user confirms → reply posted

```bash
gh api repos/$REPO/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies -X POST -f body="done"
```

### Reply style

All lowercase, brief. No explanation needed if done as requested.

- `done` - fix applied as requested (most common)
- `done - <short note>` - with minor clarification
- `good call, removed` - agreed and removed
- `fixed` - addressed the issue

**Never** reply to threads we already replied to.
**Never** add PR-level comments for file-level issues.

### Commits

Batch related fixes, message format: `address pr feedback: <summary>`

---

## Branch/Worktree Handling

Before making any fixes, ensure you're in the correct context:

### Step 1: Check for review worktree

```bash
# Look for a worktree on the PR's branch
PR_BRANCH=$(gh pr view $PR_NUMBER --json headRefName -q .headRefName)
git worktree list | grep -E "$PR_BRANCH|review"
```

If a matching worktree exists, **cd there first** before making any changes.

### Step 2: If no worktree exists

Check if current branch matches the PR branch:

```bash
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "$PR_BRANCH" ]; then
  echo "Current branch: $CURRENT_BRANCH"
  echo "PR branch: $PR_BRANCH"
  # GET USER APPROVAL before switching
fi
```

**If branches differ, get explicit user approval before switching.** Never silently switch branches or make fixes in an unrelated branch.

### Step 3: Apply fixes in correct context

Once in the correct worktree/branch:

1. Apply the comments flow above
2. All git operations happen in that context
