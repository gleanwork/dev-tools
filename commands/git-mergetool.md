# Git MergeTool Command

This file contains a workflow for intelligently resolving merge conflicts by analyzing file history from both branches.

---

## /git mergetool

**Intelligently resolve merge conflicts by analyzing file history from both branches**

Use this command during an active merge/rebase when conflicts exist. It analyzes how each branch evolved the file and determines the architecturally correct merged state.

**Usage:**

```
/git mergetool
```

**When to use**: During an active merge/rebase when conflicts exist

**Workflow**: This is an INTERACTIVE command that ALWAYS pauses for your review before applying any changes

1. You run `git merge <branch>` and get conflicts
2. You run `/git mergetool`
3. It analyzes all conflicts and proposes resolutions (automatic analysis phase)
4. It shows you EVERYTHING before writing anything (review phase - YOU MUST APPROVE)
5. Only after your explicit approval does it write files and stage them
6. You can then review with `git diff --cached` and commit when ready

**Guaranteed Review**: You will ALWAYS see proposed resolutions before they're applied. Nothing is written to disk until you explicitly approve.

---

## Step 1: Detect merge state and find conflicts

- Check if merge/rebase is in progress: `test -f .git/MERGE_HEAD || test -d .git/rebase-merge || test -d .git/rebase-apply`
- If no merge/rebase/cherry-pick in progress, inform user and exit
- Find all conflicted files: `git status --porcelain | awk '/^(UU|AA|AU|UA|DU|UD) /{print $2}'`
- Also check for conflict markers in working tree: `git diff --check` to catch any missed conflicts
- If no conflicts, inform user and exit
- **Filter out files that shouldn't be auto-resolved**:
  - Skip binary files: `git diff --numstat | awk '$3 == "-" || $4 == "-"'` (check if file is binary)
  - Skip very large files (>1MB): Warn user, may need manual resolution
  - Skip generated files (e.g., `*.min.js`, `package-lock.json`, `yarn.lock`, `go.sum`): Warn and ask
  - Skip submodule conflicts: Handle separately with `git submodule` commands

---

## Step 2: For each conflicted file, analyze history from both sides

- **Handle different merge states**:
  - **For merge**: `merge_base=$(git merge-base HEAD MERGE_HEAD 2>/dev/null)`, `ours=HEAD`, `theirs=MERGE_HEAD`
    - If merge-base fails (unrelated histories), warn user and skip intelligent resolution
  - **For rebase**: `onto=$(cat .git/rebase-merge/onto 2>/dev/null)`, `orig_head=$(cat .git/rebase-merge/orig-head 2>/dev/null)`, `merge_base=$(git merge-base "$onto" "$orig_head" 2>/dev/null)`, `ours="$onto"`, `theirs="$orig_head"`
  - **For cherry-pick**: Similar to rebase, check `.git/CHERRY_PICK_HEAD`
  - **For stash conflicts**: Use `git stash show -p` and compare with current HEAD
- **Check if file exists in all three stages**:
  - Base: `git cat-file -e :1:"$file" 2>/dev/null` (may not exist if file is new)
  - Ours: `git cat-file -e :2:"$file" 2>/dev/null` (may not exist if deleted on our side)
  - Theirs: `git cat-file -e :3:"$file" 2>/dev/null` (may not exist if deleted on their side)
  - Handle cases where file doesn't exist in base (new file conflict) or was deleted
- **Get commit history for each side** (only if file exists in that branch):
  - Ours side: `git log --reverse --format="%H %s" "$merge_base".."$ours" -- "$file" 2>/dev/null || echo ""`
  - Theirs side: `git log --reverse --format="%H %s" "$merge_base".."$theirs" -- "$file" 2>/dev/null || echo ""`
  - If no commits found, file may be new or unchanged on that side
- **Get detailed changes for each side**:
  - Ours: `git log --reverse -p -b "$merge_base".."$ours" -- "$file" 2>/dev/null || git diff "$merge_base" "$ours" -- "$file" 2>/dev/null || echo ""`
  - Theirs: `git log --reverse -p -b "$merge_base".."$theirs" -- "$file" 2>/dev/null || git diff "$merge_base" "$theirs" -- "$file" 2>/dev/null || echo ""`
- **Get the three-way merge states** (handle missing stages gracefully):
  - Base: `git show :1:"$file" 2>/dev/null || echo ""` (empty if file didn't exist in base)
  - Ours: `git show :2:"$file" 2>/dev/null || echo ""` (empty if deleted on our side)
  - Theirs: `git show :3:"$file" 2>/dev/null || echo ""` (empty if deleted on their side)
- **Check for file renames/moves**:
  - Use `git log --follow --name-status` to detect renames
  - If file was renamed on one side, check if changes can be applied to new location
- **Analyze conflict regions**:
  - Read the conflicted file and identify all conflict markers
  - Support both standard (`<<<<<<<`, `=======`, `>>>>>>>`) and zdiff3 (`|||||||`) markers
  - Detect nested or malformed conflict markers and warn user
  - For each conflict region, understand:
    - What changed from base to ours (lines, functions, blocks)
    - What changed from base to theirs (lines, functions, blocks)
    - Whether changes are independent (different regions) or overlapping (same regions)
    - The semantic intent of each change (refactor, bug fix, feature addition, etc.)
    - Detect whitespace-only conflicts (can often auto-resolve)

---

## Step 3: Intelligent resolution strategy

### CRITICAL: Analyze direction of change, not just end states

**The most important principle**: Don't just compare OURS vs THEIRS. Compare each to BASE to understand **who made the intentional change**.

For each conflict region, determine:
1. `BASE → OURS diff`: Did our branch change this code from base?
2. `BASE → THEIRS diff`: Did their branch change this code from base?

**Resolution based on direction of change**:

| BASE→OURS | BASE→THEIRS | Resolution |
|-----------|-------------|------------|
| Unchanged | Changed | **Use THEIRS** - they made an intentional change, we didn't touch it |
| Changed | Unchanged | **Use OURS** - we made an intentional change, they didn't touch it |
| Both changed to same thing | Same | Use either (identical) |
| Both changed differently | Different | True conflict - analyze intent and merge |

### REQUIRED: Show a timeline for each conflict

Before proposing any resolution, show the evolution timeline in this format:

---

**🔀 CONFLICT**: `<file>` — <brief description>

**📍 BASE had**: <what the code was before branches diverged>

**📅 TIMELINE**:
| Date | Commit | Branch | Change |
|------|--------|--------|--------|
| Jan 5 | `abc123` | 🔵 OURS | Added X |
| Jan 7 | `def456` | 🟢 THEIRS | Added Y |

**✅ RESOLUTION**: <OURS / THEIRS / MERGE BOTH>
**💡 WHY**: <one-line reason based on timeline>

---

**Example**:

---

**🔀 CONFLICT**: `constants.py:88-94` — MSG_TYPE constants

**📍 BASE had**: `MSG_TYPE_CONVERSATION_ITEM_CREATE` only

**📅 TIMELINE**:
| Date | Commit | Branch | Change |
|------|--------|--------|--------|
| Jan 5 | `abc123` | 🔵 OURS | Added `MSG_TYPE_INPUT_AUDIO_BUFFER_*` |
| Jan 7 | `def456` | 🟢 THEIRS | Added `MSG_TYPE_CONVERSATION_ITEM_CREATED/ADDED` |

**✅ RESOLUTION**: MERGE BOTH
**💡 WHY**: Independent additions — different constants, no overlap

---

**Commands to build timeline**:
- `git show :1:"$file"` for BASE
- `git log --oneline --date=short --format="%ad %h %s" $merge_base..HEAD -- "$file"`
- `git log --oneline --date=short --format="%ad %h %s" $merge_base..MERGE_HEAD -- "$file"`

**Example**: If both branches have different implementations:
- OURS: uses regex pattern matching
- THEIRS: uses isinstance() check

DON'T just pick based on "which looks better". Instead:
1. Check BASE - what was the original implementation?
2. If BASE had regex and THEIRS changed to isinstance → **use THEIRS** (intentional refactor)
3. If BASE had isinstance and OURS changed to regex → **use OURS** (intentional refactor)
4. If BASE had neither (new file on both) → look at commit history to see evolution

**For AA (both added) conflicts**: Since there's no BASE, trace the file's evolution:
- `git log --oneline --all -- "$file"` to see first appearance on each branch
- Check if one copied from the other and evolved it
- The more recent evolution is usually the intended version

---

- **API compatibility check** - Before merging code from HEAD, verify it works with master's current APIs:
  - If HEAD calls functions/methods, check if signatures match master's current definitions
  - If HEAD uses variables/constants, verify they exist in master's version of the file
  - If HEAD assigns IDs/field numbers, verify they're available in master's context
  - If APIs changed in master, update HEAD's code to use master's API (don't keep HEAD's old API calls)
- **For each conflict region, determine the architecturally correct resolution**:
  - **Independent changes** (different functions/lines): Merge both changes, but verify HEAD's code works with master's APIs
  - **Non-conflicting additions** (one side adds, other doesn't touch): Include both, but verify HEAD's additions work with master's context
  - **Same change** (identical modifications): Use either side (prefer ours if identical)
  - **Whitespace-only conflicts**: Auto-resolve by choosing the version with consistent whitespace
  - **Conflicting modifications** (both changed same area):
    - **FIRST: Check direction of change** (see above) - if only one side changed from BASE, use that side
    - If both truly changed from BASE differently:
      - Analyze commit messages to understand intent (bug fix? refactor? feature?)
      - Look for refactoring patterns (renames, restructuring, variable renames)
      - Look for bug fixes vs feature additions (bug fixes usually take precedence)
      - Check if one side's change is a subset of the other (prefer the more comprehensive)
      - Determine if changes can be combined semantically
      - Consider file type: For config files, prefer the more restrictive/secure version
    - **For `.proto` files with field number conflicts**: Preserve incoming branch field numbers (they may be deployed/referenced), renumber local additions to resolve conflicts
  - **Deletions** (AU/UA/DU/UD conflicts):
    - If one side deleted, other modified: Usually keep modification (deletion may be accidental)
    - If both deleted: Delete
    - If one deleted, other added: Usually keep addition (deletion may be refactor)
    - Check commit messages to determine if deletion was intentional
  - **New file conflicts** (AA - added on both sides):
    - Compare contents: if identical, use either
    - If different, **trace evolution** since there's no BASE. You MUST report:

**Show a chronological timeline** of all commits touching this code:

---

**🆕 AA CONFLICT**: `<file>` — both branches added this file

**📅 TIMELINE**:
| Date | Commit | Branch | Change |
|------|--------|--------|--------|
| Jan 5 | `cdf49d7` | 🔵 OURS | First version: regex pattern matching |
| Jan 8 | `8909a46` | 🟢 THEIRS | PR #195854: isinstance() approach |

**✅ RESOLUTION**: Use THEIRS
**💡 WHY**: PR #195854 was merged — team-reviewed version

---

**Commands to build timeline**:
- `git log --all --oneline --date=short --format="%ad %h %s" -- "$file" | sort`
- Cross-reference with `git branch --contains <sha>` to determine OURS/THEIRS

**⚠️ Resolution reasoning MUST be based on timeline facts**:
- ✅ "PR #195854 was merged — use the team-reviewed version"
- ✅ "THEIRS is the later intentional change"
- ✅ "Both added different things — merge both"
- ❌ "isinstance is cleaner" (subjective — timeline already justifies it)
- ❌ "regex is more explicit" (subjective)

    - Commands to investigate:
      - `git log --oneline --diff-filter=A $ours -- "$file"` - when OURS first added
      - `git log --oneline --diff-filter=A $theirs -- "$file"` - when THEIRS first added
      - `git log --oneline $ours -- "$file"` - all OURS commits touching file
      - `git log --oneline $theirs -- "$file"` - all THEIRS commits touching file
    - If one side later refactored/improved, prefer that version
- **Consider file-level operations**:
  - If file was moved/renamed on one side: Check if both sides' changes can be applied to new location
  - If file was deleted on one side: Determine if deletion was intentional or accidental
  - Handle symlinks specially (may need to resolve target conflicts)

---

## Step 4: Generate resolved content

- For each conflict region, produce the resolved code
- **Validate resolution**:
  - Check syntax validity (for code files): Use language-specific validators if available
  - Ensure no conflict markers remain in output
  - Verify resolved code preserves functionality from both sides where possible
  - Follow code patterns and style from the codebase
  - Make architectural sense (doesn't create duplicate code, maintains consistency)
  - Check for obvious errors (unclosed brackets, syntax errors, etc.)
- **Critical checks before finalizing**:
  - **For `.proto` files**:
    - **CRITICAL: Field number preservation rule**: When resolving proto field number conflicts:
      - **Preserve incoming field numbers** (from master/incoming branch): Never renumber fields that come from the incoming branch - they may already be deployed or referenced elsewhere
      - **Renumber local additions** (from HEAD/your branch): Your own additions can be renumbered to avoid conflicts
      - Example: If master adds `field_a = 367` and HEAD adds `field_b = 367`, keep master's `field_a = 367` and renumber HEAD's `field_b` to the next available number (e.g., `369`)
    - Before assigning field numbers, verify availability: `grep "= $field_number" "$file"` must be empty. Don't trust "Next ID" comments - scan actual field assignments.
  - **For Python/TypeScript files**: If resolving imports, ensure imported symbols exist in the resolved file. If a symbol exists in theirs but not ours, include it (non-conflicting addition).
  - **For JSX/TSX files**: Verify JSX structure is valid - matching opening/closing tags, no orphaned fragments or Suspense wrappers. Count opening vs closing tags to catch mismatches.
  - **For all code files**: Verify all referenced variables/functions exist in scope. If merging code that references variables, ensure those variables are defined in the resolved version.
  - **For function calls**: When merging code that calls functions, verify the call signature matches - check parameter count and order. If one side added/removed parameters, ensure the call site matches the function definition.
  - **For method calls**: When merging code that calls methods on objects, verify the method exists on that object type. If API changed (method renamed/removed), ensure call site matches current API.
- **Handle special cases**:
  - If resolution would create invalid code, warn user and mark for manual resolution
  - For very large conflicts (>100 lines), break into smaller chunks for review
  - Preserve file encoding and line endings (check `.gitattributes` if present)
- Write the resolved file content (but don't write to disk yet - keep in memory for review)

---

## Step 5: Present resolution plan

**CRITICAL: This is where you review everything before approval**

- **First, show high-level summary**:
  - Total number of conflicted files
  - Group files by confidence: High (auto-approve candidates), Medium (review needed), Low (manual review), Skipped (binary/large)
  - Quick stats: conflicts resolved, files needing attention
- **For EACH conflicted file, show comprehensive four-way comparison**:
  - **File header**: Path, conflict type (UU/AA/AU/UA/DU/UD), number of conflict regions, overall confidence
  - **Four versions side-by-side** (or sequentially if side-by-side is too wide):
    - **BASE** (common ancestor): `git show :1:"$file"` - what file looked like before branches diverged
    - **OURS** (your branch): `git show :2:"$file"` - what your branch changed it to
    - **THEIRS** (incoming branch): `git show :3:"$file"` - what incoming branch changed it to
    - **RESOLVED** (proposed): The intelligently merged version (highlighted in green/diff format)
  - **Commit history context** (helps understand WHY changes were made):
    - Our side commits: `git log --oneline "$merge_base".."$ours" -- "$file"` with commit messages
    - Their side commits: `git log --oneline "$merge_base".."$theirs" -- "$file"` with commit messages
  - **Conflict-by-conflict breakdown** (for each conflict region):
    - Location: Line numbers, function/class name if applicable
    - BASE → OURS diff: What your branch changed (with highlighting)
    - BASE → THEIRS diff: What their branch changed (with highlighting)
    - Proposed resolution: What will be in final file (with highlighting)
    - Strategy: "merge both" / "prefer ours" / "prefer theirs" / "custom"
    - Explanation: Why this resolution makes architectural sense
    - Confidence: High/Medium/Low
  - **Final diff**: Show `git diff` comparing conflicted file → resolved file (what will actually change)
- **Interactive review options**:
  - Review files one-by-one: "show me file X" or "next file"
  - For each file, you can:
    - **Approve as-is**: "approve file X" or "yes to file X"
    - **Request changes**: "use theirs for file X" or "merge differently for conflict Y in file X"
    - **Skip for manual resolution**: "skip file X" or "I'll handle file X manually"
    - **See more detail**: "show me commit messages for file X" or "show me full diff for file X"
    - **Compare versions**: "show me ours vs theirs side-by-side for file X"
  - **Batch operations**:
    - Approve all high-confidence: "approve all high confidence"
    - Approve all files: "approve all" (after reviewing)
    - Skip all low-confidence: "skip all low confidence"
- **Before applying, show final summary**:
  - List all files that WILL be modified (with your approval)
  - List all files that WILL be skipped (for manual resolution)
  - Show total changes: lines added/removed per file
  - **Final confirmation prompt**: "Apply these resolutions? (yes/no/modify)"
- **CRITICAL**: Nothing is written to disk until you explicitly approve. You can abort at any time before approval.

---

## Step 6: Apply resolutions

- Only after explicit user approval (can be per-file or all-at-once)
- **Backup conflicted files** (optional but recommended for large merges):
  - Save conflicted versions: `git show :2:"$file" > "$file.ours"` and `git show :3:"$file" > "$file.theirs"`
- Write resolved content to each approved file
- Remove conflict markers
- **Handle file deletions**: If resolution is to delete file, use `git rm "$file"`
- **Handle file additions**: If resolution is to add new file, ensure directory exists
- Stage resolved files: `git add <resolved-files>`
- **Verify staging**: Run `git status` to confirm conflicts are resolved
- Do NOT commit automatically - user may want to review or test first
- Inform user they can review with `git diff --cached` and commit when ready
- **If resolution fails**: Provide clear error messages and allow user to retry or manually resolve

---

## Key principles

- **Always interactive**: Never write to disk without explicit user approval
- **Comprehensive analysis**: Understand the full history and context of both branches
- **Architectural correctness**: Resolve conflicts in a way that makes architectural sense
- **API compatibility**: Verify merged code works with current APIs
- **Validation**: Check syntax, structure, and correctness before proposing resolutions
- **User control**: User can approve, modify, or skip any resolution
- **No automatic commits**: User reviews staged changes and commits when ready

---

## Common conflict types

### UU (Both Modified)

Both branches modified the same file. Most common conflict type. Analyze changes to determine if they can be merged or if one takes precedence.

### AA (Both Added)

Both branches added the same file. Compare contents - if identical, use either; if different, merge intelligently.

### AU (Added by Us)

We added the file, they modified it. Usually keep our addition, but verify their changes don't conflict.

### UA (Added by Them)

They added the file, we modified it. Usually keep their addition, but verify our changes don't conflict.

### DU (Deleted by Us)

We deleted the file, they modified it. Usually keep their modification (deletion may be accidental).

### UD (Deleted by Them)

They deleted the file, we modified it. Usually keep our modification (deletion may be accidental).

---

## Tips and best practices

1. **Review thoroughly**: Take time to understand the four-way comparison before approving
2. **Check commit messages**: They often explain WHY changes were made, which helps resolve conflicts
3. **Verify API compatibility**: Always check that merged code works with current APIs
4. **Test after resolution**: Even if resolution looks correct, test the merged code
5. **Use backups**: For large merges, consider backing up conflicted files before resolution
6. **Incremental approval**: Approve files one at a time if unsure, rather than approving all at once
7. **Manual resolution**: Don't hesitate to skip files for manual resolution if automatic resolution is uncertain
8. **Review staged changes**: Always review `git diff --cached` before committing
