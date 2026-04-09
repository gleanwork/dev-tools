#!/bin/bash
#
# Creates or updates a draft PR from the current branch.
#
# Usage: make-pr.sh <title>
#   Creates a draft PR with the given title
#   Updates title if PR already exists
#
# Examples:
#   make-pr.sh "[search] Add conversation loader"
#   make-pr.sh "Fix ranking bug"
#

set -e

title="$*"

# Validate input
if [[ -z "$title" ]]; then
    echo "Usage: $(basename "$0") <title>" >&2
    echo "  Creates/updates draft PR from current branch" >&2
    echo "  Example: $(basename "$0") [search] Add conversation loader" >&2
    exit 1
fi

# Get current branch
branch=$(git branch --show-current)
if [[ -z "$branch" ]]; then
    echo "❌ Not on a branch" >&2
    exit 1
fi

# Don't create PRs from protected branches
if [[ "$branch" == "master" || "$branch" == "main" ]]; then
    echo "❌ Don't create PRs from '$branch'" >&2
    exit 1
fi

# Find PR template
template=""
template_paths=(".github/pull_request_template.md" "../x/.github/pull_request_template.md")
for path in "${template_paths[@]}"; do
    if [[ -f "$path" ]]; then
        template="$path"
        break
    fi
done

# Warn about uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "⚠️  You have uncommitted changes. Commit first?" >&2
    read -r -p "   Continue anyway? [y/N] " response
    [[ "$response" != "y" && "$response" != "Y" ]] && exit 1
fi

# Push branch to origin
if ! git rev-parse --verify "origin/$branch" &>/dev/null; then
    echo "⏳ Pushing branch to origin..."
    if ! git push -u origin "$branch"; then
        echo "❌ Failed to push branch" >&2
        exit 1
    fi
else
    echo "⏳ Pushing latest commits..."
    git push || true
fi

# Check if PR already exists
if gh pr view &>/dev/null; then
    echo "📝 PR exists, updating title..."
    if gh pr edit --title "$title"; then
        echo ""
        echo "✅ PR updated!"
        gh pr view --web 2>/dev/null || gh pr view
    else
        echo "❌ Failed to update PR" >&2
        exit 1
    fi
else
    # Create new draft PR
    if [[ -z "$template" ]]; then
        echo "❌ PR template not found. Tried:" >&2
        printf "   %s\n" "${template_paths[@]}" >&2
        exit 1
    fi

    body_file="/tmp/pr_body_$$.txt"
    # Auto-check the flag-gated checkbox
    sed 's/- \[ \] Flag-gated development/- [x] Flag-gated development/' "$template" > "$body_file"

    echo "📝 Using template: $template"
    echo "🚀 Creating draft PR..."
    if gh pr create --draft --title "$title" --body-file "$body_file"; then
        rm -f "$body_file"
        echo ""
        echo "✅ Draft PR created!"
    else
        echo "❌ Failed to create PR" >&2
        rm -f "$body_file"
        exit 1
    fi
fi

echo ""
echo "   Edit body:      gh pr edit --body 'your description here'"
echo "   Add reviewers:  gh pr edit --add-reviewer user1,user2"
echo "   Mark ready:     gh pr ready"

# Output LLM-friendly instructions for Cursor/Claude to generate PR description
# Always output - harmless for humans, actionable for LLMs
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🤖 ACTION REQUIRED: Fill in PR description"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "TEMPLATE: .github/pull_request_template.md"
echo "INSTRUCTIONS: .codeagent/commands/git.md (section: /git make PR)"
echo ""
echo "Steps:"
echo "1. Read .github/pull_request_template.md - this is the EXACT structure to preserve"
echo "2. Read .codeagent/commands/git.md section '/git make PR' for field instructions"
echo "3. Analyze: git diff origin/master...HEAD"
echo "4. Fill ONLY: Description, Context, Test plan, check appropriate boxes"
echo "5. Write to /tmp/${branch//\//_}_pr_body.md"
echo "6. Run: gh pr edit --body-file /tmp/${branch//\//_}_pr_body.md"
echo ""
echo "⚠️  CRITICAL: Keep ALL markdown structure, checkboxes, sections, and comments intact."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

