#!/usr/bin/env node
// Conformance checks for the repository's generalized pr skill.
// The checks enforce behavior and dialog structure, not host-specific implementation details or old Gate N/Gate T vocabulary.

import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const skillPath = resolve(process.argv[2] ?? join(here, '..', 'SKILL.md'))
const skillDir = dirname(skillPath)
const text = readFileSync(skillPath, 'utf8')
const lines = text.split('\n')
const results = []

function check(id, description, predicate) {
  let ok = false
  let detail = ''
  try {
    const value = predicate()
    ok = value === true || value === undefined
    if (!ok) detail = String(value)
  } catch (error) {
    detail = error instanceof Error ? error.message : String(error)
  }
  results.push({ description, detail, id, ok })
}

const headings = []
let inFence = false
for (const [line, value] of lines.entries()) {
  if (/^\s*```/.test(value)) inFence = !inFence
  if (inFence) continue
  const match = /^(#{1,6})\s+(.*\S)\s*$/.exec(value)
  if (match) headings.push({ depth: match[1].length, line, title: match[2] })
}

function section(title) {
  const index = headings.findIndex((heading) => heading.title === title)
  if (index < 0) return null
  const heading = headings[index]
  const next = headings.slice(index + 1).find((candidate) => candidate.depth <= heading.depth)
  return lines.slice(heading.line + 1, next ? next.line : lines.length).join('\n')
}

function tableRows(body) {
  if (!body) return []
  return body
    .split('\n')
    .filter((line) => line.trim().startsWith('|'))
    .map((line) =>
      line
        .trim()
        .replace(/^\|/, '')
        .replace(/\|$/, '')
        .split('|')
        .map((cell) => cell.trim()),
    )
    .filter((cells) => !cells.every((cell) => /^:?-{2,}:?$/.test(cell)))
    .slice(1)
}

function choiceText(row) {
  return row[row.length - 1] ?? ''
}

function choices(row) {
  return choiceText(row)
    .split('·')
    .map((choice) => choice.trim())
    .filter(Boolean)
}

function actionable(row) {
  return !/^stop\b/i.test(choiceText(row)) && !/^\*\*Cancel/i.test(choiceText(row))
}

function oneCancel(row) {
  return (choiceText(row).match(/\bCancel\b/g) ?? []).length === 1
}

function githubSlug(title) {
  return title
    .toLowerCase()
    .replace(/`/g, '')
    .replace(/[^a-z0-9 -]/g, '')
    .trim()
    .replace(/ /g, '-')
}

const question = section('The one decision question')
const existingPr = section('Existing PR continuation')
const newFlow = section('Starting a new branch with `start pr` (`new pr` alias)')
const focusFlow = section('`focus pr`')
const focusDetails = section('Focusing an existing branch with `focus pr`')
const newCommand = section('`start pr REQUEST` (`new pr` alias)')
const focusCommand = section('`focus pr`')
const help = section('Help response')
const cleanFlow = section('`clean pr`') ?? ''
const nRules = newFlow ?? ''
const tRules = focusDetails ?? ''
const rRules = section('`raise pr`') ?? ''

// Overall shape and plain language.
check('S1', 'valid pr frontmatter', () => /^---\nname:\s*pr\b[\s\S]*?\n---/.test(text) || 'missing frontmatter')
check('S2', 'plain-language decision sections exist', () => {
  const required = [
    'The one decision question',
    'Existing PR continuation',
    'Starting a new branch with `start pr` (`new pr` alias)',
    'Focusing an existing branch with `focus pr`',
    '`start pr REQUEST` (`new pr` alias)',
    '`focus pr`',
    '`park pr`',
    '`ls pr`',
    '`clean pr`',
  ]
  const missing = required.filter((title) => section(title) === null)
  return missing.length === 0 || `missing: ${missing.join(', ')}`
})
check('P1', 'existing unmerged PRs are continued before new-branch flow', () => {
  const required = [
    /current chat\/session context/i,
    /not merged.*reuse its exact branch/i,
    /do not derive a new branch name.*create a new branch/i,
    /fix the existing branch there with `git -C <path>`/i,
    /no other checkout owner/i,
    /provider reports.*merged.*ordinary new-branch flow/i,
    /chat context.*provider.*disagree.*stop/i,
  ]
  const missing = required.filter((pattern) => !pattern.test(existingPr ?? ''))
  return missing.length === 0 || `missing rules: ${missing.map(String).join(', ')}`
})
check(
  'P2',
  'new-branch destination question is gated by existing-PR preflight',
  () =>
    (/First, perform \[Existing PR continuation\]/i.test(text) && /no matching unmerged PR exists/i.test(text)) ||
    'missing existing-PR gate',
)
check('S3', 'the old Gate N/Gate T labels are gone', () => !/\bGate\s+[NT]\b/i.test(text) || 'old Gate label remains')
check('S4', 'internal anchors resolve', () => {
  const anchors = new Set(headings.map((heading) => githubSlug(heading.title)))
  const missing = [...text.matchAll(/\]\(#([a-z0-9-]+)\)/g)]
    .map((match) => match[1])
    .filter((anchor) => !anchors.has(anchor))
  return missing.length === 0 || `dangling anchors: ${[...new Set(missing)].join(', ')}`
})
check(
  'S5',
  'provider behavior is adapter-based',
  () =>
    (/Provider adapter/i.test(text) &&
      /lifecycle and safety rules are provider-neutral/i.test(text) &&
      /For GitHub/i.test(text) &&
      /For another provider/i.test(text) &&
      /do not run GitHub-specific commands/i.test(text)) ||
    'missing provider adapter rule',
)

// The one question and its three opening facts.
check(
  'Q1',
  'one question uses ask_clarifying_question',
  () => /exactly one question with `ask_clarifying_question`/i.test(question ?? '') || 'missing tool/one-question rule',
)
check(
  'Q2',
  'nothing mutates before the answer',
  () =>
    (/Do not mutate anything before the answer|Before the answer, do nothing/i.test(question ?? '') &&
      /no branch, no worktree, no commit, no stash/i.test(question ?? '')) ||
    'missing pre-answer safety rule',
)
check(
  'Q3',
  'the question explains the goal and source',
  () =>
    (/Explain the goal and the source code/i.test(question ?? '') && /The goal is to copy/i.test(question ?? '')) ||
    'missing request-purpose fact',
)
check(
  'Q4',
  'the question identifies the branch',
  () =>
    (/Explain the branch action/i.test(question ?? '') &&
      /We will create/i.test(question ?? '') &&
      /freshly fetched origin/i.test(question ?? '')) ||
    'missing branch fact',
)
check(
  'Q5',
  'the question identifies source and home',
  () =>
    (/Explain the relevant checkout state/i.test(question ?? '') &&
      /ask where the branch should live/i.test(question ?? '') &&
      /primary checkout or a managed worktree/i.test(question ?? '') &&
      /preservation/i.test(question ?? '')) ||
    'missing source/home facts',
)
check(
  'Q6',
  'the question uses conversational paragraphs with an optional fourth',
  () =>
    (/one idea per short paragraph/i.test(question ?? '') &&
      /Usually three paragraphs are enough/i.test(question ?? '') &&
      /Use a fourth short paragraph/i.test(question ?? '')) ||
    'missing flexible paragraph structure',
)
check(
  'Q7',
  'options carry consequences and exactly one Cancel',
  () =>
    (/Put the choices only in the tool call's `options` array/i.test(question ?? '') &&
      /Each option is one selectable button and includes its own short consequence/i.test(question ?? '') &&
      /exactly one \*\*Cancel\*\* option/i.test(question ?? '')) ||
    'missing options/Cancel rule',
)
check(
  'Q8',
  'classification is not a second confirmation',
  () =>
    (/Classification of dirty paths is part of (this question's facts|these three paragraphs|the explanatory paragraphs)/i.test(
      question ?? '',
    ) &&
      /Do not ask a second confirmation/i.test(question ?? '')) ||
    'missing classification separation',
)
check(
  'Q9',
  'source and destination are separate',
  () => /source.*not.*destination|source checkout.*destination/i.test(text) || 'missing source/destination separation',
)
check(
  'Q10',
  'dialog does not list every implementation file',
  () =>
    (/Do not list every implementation path/i.test(question ?? '') &&
      /roughly three displayed lines/i.test(question ?? '')) ||
    'missing compact-dialog limit',
)
check(
  'Q11',
  'choices are not duplicated in the question text',
  () =>
    (/Do not repeat them in the `question` text/i.test(question ?? '') &&
      /do not write “Choose one” followed by a list/i.test(question ?? '') &&
      /do not write a prose lead-in before the tool call/i.test(question ?? '')) ||
    'missing tool-call separation',
)

// New-branch rules. These checks deliberately inspect prose, not a decision table.
check('N1', 'new-branch rules cover clean, dirty, transfer-only, and ambiguous states', () => {
  const required = [
    /primary is clean and on the base branch/i,
    /primary is clean but has another feature branch/i,
    /primary is dirty and every dirty path/i,
    /primary is dirty with unrelated paths/i,
    /primary is on the base branch.*copies implementation from a named source checkout/is,
    /ownership.*ambiguous/i,
  ]
  const missing = required.filter((pattern) => !pattern.test(nRules))
  return missing.length === 0 || `missing rules: ${missing.map(String).join(', ')}`
})
check(
  'N2',
  'ordinary new-branch rules offer both homes and Cancel',
  () => /Use primary.*Use a managed worktree.*Cancel/i.test(nRules) || 'missing primary/managed/Cancel choices',
)
check(
  'N3',
  'clean feature branch handling calculates parking or branch-ref-only disposition',
  () =>
    (/another feature branch.*Calculate the displaced branch's viable dispositions/i.test(nRules) &&
      /park it in a managed worktree.*keep its branch ref only/i.test(nRules)) ||
    'missing clean-branch disposition rule',
)
check(
  'N4',
  'dirty request-owned paths remain eligible for primary',
  () =>
    (/every dirty path belongs to this request.*offer the same two homes/i.test(nRules) &&
      /Do not remove primary just because it is dirty/i.test(nRules)) ||
    'missing dirty-primary rule',
)
check(
  'N5',
  'unrelated work exposes viable stash and commit preservation methods',
  () =>
    (/calculate viable stash and commit preservation methods first/i.test(nRules) &&
      /on (?:its|their|the) current feature branch/i.test(nRules) &&
      /every viable combination/i.test(nRules)) ||
    'missing unrelated preservation choices',
)
check(
  'N6',
  'ambiguous new-branch ownership stops without mutation',
  () =>
    (/ownership.*ambiguous.*offer only \*\*Cancel/i.test(nRules) &&
      /Do not create a branch, worktree, commit, stash, or transfer files/i.test(nRules)) ||
    'missing ambiguous stop rule',
)
check('N7', 'transfer-only case has exactly the required three choices', () => {
  const start = nRules.indexOf('If primary is on the base branch and the request only copies')
  const end = nRules.indexOf('If ownership of any dirty path is ambiguous')
  const block = start >= 0 && end > start ? nRules.slice(start, end) : ''
  if (!block) return 'missing transfer-only rule'
  if (!/offer exactly three short choices/i.test(block)) return 'not explicitly three choices'
  if (!/Use primary.*stash the unrelated change.*copy only the identified implementation files/i.test(block))
    return 'missing stash/use-primary transfer choice'
  if (!/Use a managed worktree.*leave primary untouched.*copy only the identified implementation files/i.test(block))
    return 'missing managed transfer choice'
  if (!/\*\*Cancel — no changes\*\*/i.test(block)) return 'missing transfer Cancel'
  return true
})
check(
  'N8',
  'new destination remains user-selected and immutable',
  () =>
    (/must choose where the new branch will live/i.test(nRules) &&
      /chosen home(?: and displaced-branch disposition)? (?:is|are) fixed after the answer/i.test(text)) ||
    'missing destination immutability',
)
check(
  'N9',
  'managed new-branch homes reuse safe detached worktrees first',
  () =>
    (/created or reused with `git worktree`/i.test(nRules) &&
      /prefer a reusable candidate/i.test(nRules) &&
      /clean including untracked files/i.test(nRules) &&
      /create a new managed worktree only when no safe candidate exists/i.test(nRules) &&
      /git worktree add --detach --no-checkout "\$WORKTREE_PATH" "\$BASE_SHA"/.test(text) &&
      /git -C "\$WORKTREE_PATH" switch --create "\$BRANCH_NAME" "\$BASE_SHA"/.test(text)) ||
    'missing managed-worktree reuse-before-create rule',
)
check(
  'N10',
  'new branches use author initials',
  () =>
    (/AUTHOR_INITIALS/i.test(text) &&
      /Ada Lovelace.*al/i.test(text) &&
      /BRANCH_NAME="\$\{AUTHOR_INITIALS\}\/\$\{BRANCH_STEM\}"/i.test(text) &&
      /Every newly created branch must use this author-initials prefix/i.test(text)) ||
    'missing author-initial branch prefix rule',
)
check(
  'N11',
  'displaced PR states expose preference without automatic parking',
  () =>
    (/For an open\/draft PR, offer managed worktree first and branch-ref-only second/i.test(text) &&
      /For a confirmed merged or closed-unmerged PR, leave the branch ref intact.*without creating a worktree/i.test(
        text,
      ) &&
      /Never auto-park an open, unknown, closed, or merged branch/i.test(text) &&
      /explicit `park pr` request overrides/i.test(text)) ||
    'missing displaced-branch disposition rules',
)
check(
  'N19',
  'a new worktree is dependency-linked at creation, install deferred',
  () =>
    (/A new worktree is linked to primary's dependencies at creation, not left bare/i.test(text) &&
      /Immediately after creating a managed worktree, link its dependency root to primary/i.test(text) &&
      /Never eagerly run a full dependency install at creation/i.test(text) &&
      /let the hook-failure bootstrap install on first need/i.test(text)) ||
    'missing creation-time dependency-link rules',
)
check(
  'N18',
  'waiting for checks is bounded and never waits on human approval',
  () =>
    (/Waiting is bounded work with a deadline, not an open loop/i.test(text) &&
      /The only thing left is a human action/i.test(text) &&
      /Approval, a requested review, a merge queue entry, or any other person-gated state is not a check/i.test(text) &&
      /Nothing is progressing/i.test(text) &&
      /must finish well inside the host's command timeout/i.test(text) &&
      /never combine a long sleep with a paginated request in one call/i.test(text)) ||
    'missing bounded check-waiting rules',
)
check(
  'N17',
  'an explicit command outranks continuation, and continuation needs coverage',
  () =>
    (/An explicit command outranks every inference/i.test(text) &&
      /Never demote it to wording, a label, a topic hint, or a statement of intent/i.test(text) &&
      /Continuation requires an affirmative coverage test/i.test(text) &&
      /If the request is a different change, it is a new change/i.test(text) &&
      /If the user typed `new pr` or `start pr`, never auto-continue/i.test(text) &&
      /Never resolve uncertainty by continuing/i.test(text)) ||
    'missing explicit-command precedence and continuation coverage rules',
)
check(
  'N16',
  'ignored build output is left alone, not enumerated or surfaced',
  () =>
    (/Ignored paths are not work/i.test(text) &&
      /Do not enumerate or count them/i.test(text) &&
      /Never put them in a confirmation question/i.test(text) &&
      /only remaining entries are ignored build or dependency output is clean/i.test(text) &&
      /Mention them only when the confirmed action can delete or move them/i.test(text)) ||
    'missing ignored-path handling rules',
)
check(
  'N15',
  'a missing dependency tree is provisioned, not reported as a blocker',
  () =>
    (/Provisioning a checkout's dependency root is setup, not a source edit/i.test(text) &&
      /does not forbid installing or linking the tree itself/i.test(text) &&
      /Never create, edit, or patch individual files inside a dependency tree/i.test(text) &&
      /is the expected first attempt for a missing hook or test binary/i.test(text) &&
      /until both provisioning paths have been attempted/i.test(text)) ||
    'missing dependency-bootstrap permission rules',
)
check(
  'N14',
  'GitHub provider operations are REST-first and dual failures are loud',
  () =>
    (/A failed provider lookup is never evidence that something does not exist/i.test(text) &&
      /command must expose that failure rather than silently continuing/i.test(text) &&
      /GitHub uses REST as the required path/i.test(text) &&
      /Do not use `gh pr` or GraphQL as a prerequisite/i.test(text) &&
      /pulls\?head=<owner>:<branch>&state=all&per_page=100/i.test(text) &&
      /Optional fallback — GraphQL only after REST failure/i.test(text) &&
      /PROVIDER_OPERATION_FAILED/i.test(text) &&
      /stop the provider-dependent command/i.test(text) &&
      /Capture each command's exit status and stderr/i.test(text) &&
      /never use `\|\| true`/i.test(text)) ||
    'missing REST-first provider transport and loud dual-failure rules',
)
check(
  'N24',
  'GitHub REST covers all required PR reads and writes',
  () =>
    (/.+commits\/<sha>\/check-runs\?per_page=100/i.test(text) &&
      /commits\/<sha>\/status/i.test(text) &&
      /pulls\/<number>\/reviews\?per_page=100/i.test(text) &&
      /pulls\/<number>\/comments\?per_page=100/i.test(text) &&
      /issues\/<number>\/comments\?per_page=100/i.test(text) &&
      /Create with `POST \/repos\/<owner>\/<repo>\/pulls`/i.test(text) &&
      /update with `PATCH \/repos\/<owner>\/<repo>\/pulls\/<number>`/i.test(text) &&
      /POST \/repos\/<owner>\/<repo>\/pulls\/<number>\/comments\/<comment_id>\/replies/i.test(text) &&
      /POST \/repos\/<owner>\/<repo>\/issues\/<number>\/comments/i.test(text)) ||
    'missing REST check, review, comment, or write endpoints',
)
check(
  'N24b',
  'fix pr treats PR-level comments and review bodies as first-class actionable items',
  () => {
    const sources = section('Three comment sources, one inventory')
    if (!sources) return 'missing "Three comment sources, one inventory" section'
    return (
      (/Inline review comments/i.test(sources) &&
        /PR-level comments/i.test(sources) &&
        /issues\/<number>\/comments/.test(sources) &&
        /Review bodies/i.test(sources) &&
        /pulls\/<number>\/reviews/.test(sources) &&
        /No source is second-class/i.test(sources) &&
        /lack of a file and line is not a reason to skip it/i.test(sources) &&
        /inline N · PR-level N · reviews N/.test(sources) &&
        /Reply in kind/i.test(sources) &&
        /kind: inline \| issue \| review/.test(sources) &&
        /Phase 2[^\n]*inline threads, PR-level \(issue\) comments, and review bodies/i.test(text) &&
        /open automatic review item from any of the three comment sources/i.test(text)) ||
      'PR-level comments or review bodies are not required in the inventory, Phase 2, or the fix all actionable bucket'
    )
  },
)
check(
  'N25',
  'REST mergeability semantics do not require GraphQL enum values',
  () =>
    (/resolved (?:pair )?`mergeable: false`/i.test(text) &&
      /`mergeable_state: dirty`/i.test(text) &&
      /`mergeable: null`/i.test(text) &&
      /`CONFLICTING` is a GraphQL enum/i.test(text) &&
      /not the REST contract/i.test(text)) ||
    'missing REST mergeability semantics',
)
check(
  'N20',
  'disposition viability is separate from preference',
  () =>
    (/Calculate viability before preference/i.test(question ?? '') &&
      /Branch ref only.*zero owning worktrees/i.test(question ?? '') &&
      /Managed worktree.*safe reusable managed worktree/i.test(question ?? '') &&
      /These are preferences, not safety gates/i.test(question ?? '') &&
      /include both in the one question/i.test(question ?? '')) ||
    'missing viability/preference separation',
)
check(
  'N21',
  'detached and closed-PR worktrees are reusable candidates',
  () =>
    (/Detached worktrees and clean checkouts left after closed or merged PRs are valid reusable candidates/i.test(
      text,
    ) &&
      /prior branch or PR state does not disqualify them/i.test(text)) ||
    'missing reusable-worktree rule',
)
check(
  'N12',
  'displaced PR state is checked before one question',
  () =>
    (/raised/i.test(text) &&
      /closed/i.test(text) &&
      /unraised/i.test(text) &&
      /unknown/i.test(text) &&
      /one bounded provider lookup before the question/i.test(text) &&
      /raise-first.*preserve-for-later/i.test(text) &&
      /ask a generic second question after preservation/i.test(text)) ||
    'missing displaced-PR preflight and compact dialogue rule',
)
check(
  'N13',
  'merged managed worktrees are deleted',
  () =>
    (/After the provider verifies that a PR is merged, remove its clean managed worktree/i.test(text) &&
      /Never delete primary/i.test(text)) ||
    'missing post-merge managed-worktree deletion rule',
)
check(
  'R1',
  'raise publishes without moving the branch',
  () =>
    (/publish-only PR handoff/i.test(rRules) &&
      /read the applicable repository instructions/i.test(rRules) &&
      /code-generation instructions/i.test(rRules) &&
      /Review the complete diff against the loaded instructions/i.test(rRules) &&
      /final self-review/i.test(rRules) &&
      /never changes the branch location/i.test(rRules) &&
      /never opens a post-raise location dialog/i.test(rRules) &&
      /(?:run|use) `park pr` explicitly/i.test(rRules)) ||
    'missing raise style-review or publish-only semantics',
)
check(
  'R2',
  'park moves primary work explicitly and safely',
  () =>
    (/explicit move out of primary/i.test(text) &&
      /destination is always a managed worktree/i.test(text) &&
      /reuse a present, detached, clean, available managed worktree/i.test(text) &&
      /If primary contains ambiguous work, stop/i.test(text)) ||
    'missing park semantics',
)
check(
  'R3',
  'ls pr is a fast local triage view',
  () =>
    (/`ls pr` is a fast, read-only local workspace triage view/i.test(text) &&
      /`pr ls` and `list pr` are aliases/i.test(text) &&
      /one bounded REST search request/i.test(text) &&
      /gh api user --jq .login/i.test(text) &&
      /author:LOGIN/i.test(text) &&
      /never use the literal `author:me` inside `gh pr list --search`/i.test(text) &&
      /never convert a provider failure into “no PRs/i.test(text) &&
      /OPEN PRs.*ready for review/i.test(text) &&
      /DRAFT PRs/i.test(text) &&
      /Raise candidates/i.test(text) &&
      /Pending changes/i.test(text) &&
      /Committed plus pending/i.test(text) &&
      /Cleanup candidates/i.test(text) &&
      /Detached or damaged/i.test(text) &&
      /at most ten attention rows/i.test(text)) ||
    'missing fast local triage semantics',
)
check(
  'R6',
  'ls pr has an explicit grouped full-inventory mode',
  () =>
    (/Explicit full-inventory mode/i.test(text) &&
      /final list.*full inventory.*complete PRLS.*all categories/i.test(text) &&
      /snapshot line with counts/i.test(text) &&
      /Clean, but stale against/i.test(text) &&
      /Pending edits.*review before raising/i.test(text) &&
      /Preserve — do not delete/i.test(text) &&
      /Other local refs/i.test(text) &&
      /group long PR lists/i.test(text) &&
      /remains read-only in full-inventory mode/i.test(text) &&
      /Phase 1.*conflict-only rebase/i.test(text) &&
      /only when (the )?provider reports a conflict/i.test(text) &&
      /mergeable: false/i.test(text) &&
      /CONFLICTING.*optional GraphQL enum/i.test(text) &&
      /Phase 2.*address review comments/i.test(text) &&
      /Phase 3.*fix CI failures/i.test(text) &&
      /replies go out right after the push/i.test(text) &&
      /commit.*push.*reply results/i.test(text)) ||
    'missing grouped exhaustive inventory or fix-comment semantics',
)
check(
  'R4',
  'legacy slash and test command vocabulary is absent',
  () => !/\/pr\s+(new|test|raise|ship|help)\b|`test`\s+is a reserved/i.test(text) || 'legacy command syntax remains',
)
check(
  'R5',
  'bare pr opens the stable confirmation menu',
  () =>
    (text.includes('# Bare `pr` invocation contract') &&
      text.includes('When the user message is exactly `pr`') &&
      text.includes('What would you like to do with the PR workflow?') &&
      text.includes(
        'Offer exactly these four options: **Help**; **Start or continue work**; **List my PRs and worktrees**; **Cancel**',
      ) &&
      text.includes('ask_clarifying_question') &&
      text.includes('Do not show or invent a generic menu') &&
      text.includes('A bare `pr` always opens the compact, read-only action menu')) ||
    'missing stable bare-pr confirmation menu',
)

// Existing-branch testing rules.
check('T1', 'focus rules cover all required checkout states', () => {
  const required = [
    /primary and the feature branch's source checkout, if any, are clean/i,
    /primary has another feature branch/i,
    /primary has unrelated dirt/i,
    /feature checkout has feature-owned work/i,
    /both primary and the feature checkout are dirty/i,
    /ownership is ambiguous/i,
  ]
  const missing = required.filter((pattern) => !pattern.test(tRules))
  return missing.length === 0 || `missing rules: ${missing.map(String).join(', ')}`
})
check(
  'T2',
  'focus destination is always primary',
  () =>
    (/always moves the selected existing feature branch into the primary checkout/i.test(tRules) &&
      /destination is always primary/i.test(tRules)) ||
    'test destination is not fixed to primary',
)
check(
  'T3',
  'focus offers no second-home option',
  () =>
    (/Never offer.*create a managed worktree.*keep it in the managed worktree/i.test(tRules) &&
      /there is no worktree choice/i.test(tRules)) ||
    'worktree option not excluded',
)
check(
  'T4',
  'focus explains branch edits and repository-wide stash behavior',
  () =>
    (/Uncommitted edits do not travel with a branch/i.test(tRules) && /stash is repository-wide/i.test(tRules)) ||
    'missing edit/stash behavior',
)
check(
  'T5',
  'focus combined dirty state preserves both groups and exposes dispositions',
  () =>
    (/both primary and the feature checkout are dirty/i.test(tRules) &&
      /preserve the two groups separately/i.test(tRules) &&
      /primary-work stash or commit/i.test(tRules) &&
      /every viable displaced-branch disposition/i.test(tRules)) ||
    'missing combined preservation or disposition rules',
)
check(
  'T6',
  'focus feature-owned dirty state offers commit or stash',
  () =>
    (/feature checkout has feature-owned work.*primary is clean/i.test(tRules) &&
      /committing that feature work/i.test(tRules) &&
      /stashing it and reapplying/i.test(tRules)) ||
    'missing feature preservation choices',
)
check(
  'T7',
  'test Cancel leaves both checkouts unchanged',
  () =>
    /Cancel always leaves both checkouts, branches, and dirty files exactly as they are/i.test(text) ||
    'missing Cancel semantics',
)

// Restored lifecycle nuances.
const requiredPhrases = [
  ['O1', 'git ls-remote --symref origin HEAD'],
  ['O2', 'git remote set-head origin --auto'],
  ['O3', 'BASE_SHA = git rev-parse REMOTE/BASE_BRANCH'],
  ['O4', 'Do not assume `main` or `master`'],
  ['O5', 'git check-ref-format --branch'],
  ['O6', 'git worktree list --porcelain'],
  ['O7', 'git worktree add --detach --no-checkout'],
  ['O8', 'git sparse-checkout set --cone'],
  ['O9', 'git sparse-checkout add'],
  ['O10', 'git worktree remove'],
  ['O11', 'git switch --detach HEAD'],
  ['O12', 'git worktree prune'],
  ['O13', 'git push --force-with-lease'],
  ['O14', 'explicit merge'],
  ['O15', 'Do not use `git stash pop`'],
  ['O16', 'A stacked branch is allowed only when the user explicitly asks'],
]
for (const [id, phrase] of requiredPhrases) {
  check(id, `lifecycle nuance: ${phrase}`, () => text.includes(phrase) || `missing: ${phrase}`)
}
check(
  'O17',
  'help describes the full lifecycle',
  () =>
    (/one continuous change lifecycle/i.test(help ?? '') &&
      /\*\*Commands:\*\*.*new pr.*focus pr.*raise pr.*park pr.*fix pr.*ls pr.*help pr/i.test(help ?? '') &&
      /start pr.*canonical spelling/i.test(help ?? '') &&
      /new pr.*compatibility alias/i.test(help ?? '')) ||
    'missing lifecycle help',
)
check(
  'O18',
  'help covers the SVG state model',
  () =>
    (/solid diamonds for decision points/i.test(help ?? '') &&
      /boxes for branch checkouts/i.test(help ?? '') &&
      /explicit merge.*terminal step/i.test(help ?? '')) ||
    'missing SVG state details',
)
check(
  'O19',
  'Chrome-rendered PNG is displayed and SVG remains the source',
  () =>
    (existsSync(join(skillDir, 'pr-lifecycle.svg')) &&
      existsSync(join(skillDir, 'pr-lifecycle.png')) &&
      /personal local skill/i.test(text) &&
      /~\/\.agents\/skills\/pr\/pr-lifecycle\.png/i.test(text) &&
      /~\/\.glean\/agent\/skills\/pr\/pr-lifecycle\.png/i.test(text) &&
      /~\/\.claude\/skills\/pr\/pr-lifecycle\.png/i.test(text) &&
      /absolute file URI/i.test(text) &&
      /emit.*immediately/i.test(text) &&
      /source of truth is \[pr-lifecycle\.svg\]/.test(text) &&
      /rendered with Chrome/i.test(text)) ||
    'missing generalized PNG/SVG asset instruction',
)
check(
  'O20',
  'help documents location transitions and read-only listing',
  () =>
    (/`focus pr`.*primary/i.test(text) &&
      /`park pr`.*managed worktree/i.test(text) &&
      /`raise pr`.*without changing its checkout/i.test(text) &&
      /`fix pr`.*mergeability/i.test(text) &&
      /fix actionable issues/i.test(text) &&
      /`ls pr`.*Read-only/i.test(text)) ||
    'missing command transition guidance',
)
check('O21', 'SVG matches the concise lifecycle vocabulary and layout', () => {
  const diagram = readFileSync(join(skillDir, 'pr-lifecycle.svg'), 'utf8')
  return (
    (!diagram.includes('stroke-dasharray') &&
      diagram.includes('id="ah-park"') &&
      diagram.includes('id="ah-fix"') &&
      diagram.includes('start pr') &&
      diagram.includes('fix pr') &&
      diagram.includes('start or continue PR') &&
      diagram.includes('Primary checkout</text>') &&
      diagram.includes('clean?</text>') &&
      !diagram.includes('confirm and focus') &&
      !diagram.includes('explicit · human') &&
      /font-size="12" fill="#17181c" font-weight="400" text-anchor="middle">clean/.test(diagram) &&
      /font-size="12" fill="#17181c" font-weight="400" text-anchor="middle">dirty/.test(diagram) &&
      /font-size="12" fill="#17181c" font-weight="400" text-anchor="middle">commit or stash/.test(diagram) &&
      /font-size="12" fill="#17181c" font-weight="400" text-anchor="middle">or build in a worktree/.test(diagram) &&
      /font-size="12" fill="#17181c" font-weight="400" text-anchor="middle">merge/.test(diagram) &&
      /<rect x="565\.0" y="24\.0"/.test(diagram) &&
      /<rect x="620\.7" y="388\.0"/.test(diagram) &&
      /<rect x="862\.0" y="640\.0"/.test(diagram) &&
      /<rect x="40" y="180"/.test(diagram) &&
      /<rect x="610" y="620"/.test(diagram) &&
      diagram.includes('M550,500 C580,530 590,590 610,665') &&
      diagram.includes('M965,540 L965,665 L860,665') &&
      diagram.includes('M300,448 C230,430 230,510 300,492') &&
      diagram.includes('M860,448 C790,430 790,510 860,492') &&
      !diagram.includes('PR location unchanged') &&
      /<rect x="160\.0" y="455\.0"/.test(diagram) &&
      /<rect x="720\.0" y="455\.0"/.test(diagram) &&
      (diagram.match(/marker-end="url\(#ah-merge\)"/g) ?? []).length === 2 &&
      (diagram.match(/marker-end="url\(#ah-raise\)"/g) ?? []).length === 2) ||
    'SVG layout or vocabulary drifted'
  )
})
check(
  'O22',
  'raise bootstraps matching managed-worktree dependencies without bypassing hooks',
  () =>
    (/managed checkout lacks its dependency tree/i.test(text) &&
      /create an absolute symlink/i.test(text) &&
      /manifest and lockfile inputs match/i.test(text) &&
      /Do not replace a non-empty directory/i.test(text) &&
      /never use `--no-verify`/i.test(text) &&
      /Retry the exact failed hook or validation once/i.test(text)) ||
    'missing safe dependency bootstrap rule',
)
check('E1', 'help ends with a short, plain-English example flow', () => {
  const exampleIndex = text.indexOf('### Example flow')
  const providerIndex = text.indexOf('## Provider adapter')
  const example = exampleIndex >= 0 && providerIndex > exampleIndex ? text.slice(exampleIndex, providerIndex) : ''
  return (
    (exampleIndex > text.indexOf('PR workflow') &&
      exampleIndex < providerIndex &&
      example.includes('new pr') &&
      example.includes('Slack discussion') &&
      example.includes('focus pr') &&
      example.includes('park pr') &&
      example.includes('raise pr') &&
      example.includes('fix pr') &&
      example.includes('fix all') &&
      example.includes('never merges') &&
      !example.includes('**Implication:**')) ||
    'missing short plain-English example flow'
  )
})

// Plain prose is intentional: the skill must be readable while the validator checks each required case.
check(
  'X1',
  'new and focus instructions are not decision tables',
  () =>
    !/\| Primary checkout state \||\| Observed state \|/i.test(`${newFlow}\n${focusDetails}`) ||
    'old dense table remains',
)
check(
  'X2',
  'the generic two-button failure is explicitly forbidden',
  () =>
    /Offering only \*\*Create branch and transfer code\*\* \/ \*\*Cancel\*\*/i.test(text) ||
    'missing regression warning',
)

check(
  'C1',
  'clean pr gates removal on clean and fully pushed work',
  () =>
    (/git status --porcelain/i.test(cleanFlow) &&
      /git log --oneline --not --remotes/i.test(cleanFlow) &&
      /never removed automatically/i.test(cleanFlow) &&
      /never widen the gate/i.test(cleanFlow)) ||
    'missing reclaim gate',
)
check(
  'C2',
  'clean pr preserves branches and uses the host removal operation',
  () =>
    (/removes checkouts, never branches/i.test(cleanFlow) &&
      /git worktree remove/.test(cleanFlow) &&
      /Never use `rm -rf`/i.test(cleanFlow) &&
      /Never delete a local branch, a remote branch, a stash, or a reflog entry/i.test(cleanFlow) &&
      /exactly one \*\*Cancel\*\*/i.test(cleanFlow)) ||
    'missing branch-preservation or removal-operation rules',
)
check('C3', 'clean pr classifies merged, closed, open, detached, and unknown states', () => {
  const required = [/PR merged/i, /closed without merging/i, /open or draft/i, /detached/i, /unknown/i]
  const missing = required.filter((pattern) => !pattern.test(cleanFlow))
  return missing.length === 0 || `missing states: ${missing.map(String).join(', ')}`
})
check(
  'C4',
  'clean pr is a reserved command surfaced in help',
  () =>
    (/`clean` followed by `pr`|`ls`, and `clean` followed by `pr`/i.test(text) &&
      /`pr clean` is an alias/i.test(text) &&
      /`clean pr` · `help pr`/.test(text) &&
      /`clean pr` — reclaim disk/i.test(text)) ||
    'clean pr missing from command grammar or help',
)
check('C5', 'SVG shows the clean step without disturbing the merge terminal', () => {
  const diagram = readFileSync(join(skillDir, 'pr-lifecycle.svg'), 'utf8')
  return (
    (diagram.includes('id="ah-clean"') &&
      diagram.includes('>clean pr</text>') &&
      /<rect x="180" y="652"/.test(diagram) &&
      diagram.includes('M610,688 L436,688') &&
      (diagram.match(/marker-end="url\(#ah-clean\)"/g) ?? []).length === 1) ||
    'SVG clean step missing or merge terminal changed'
  )
})

// Stacked fix all: root-first, trickle-down rebase with --onto, one approval per stack.
check(
  'K1',
  'fix all processes stacks root-first, never deepest-child-first',
  () =>
    (/Fix the \*\*root first\*\*/i.test(text) &&
      /then each child downward/i.test(text) &&
      !/deepest child first/i.test(text) &&
      !/deepest-first/i.test(text) &&
      !/process its child PRs first/i.test(text)) ||
    'stack order must be root-first everywhere',
)
check(
  'K2',
  'children are rebased onto the fixed parent with rebase --onto before their own fix',
  () => {
    const body = section('Stack trickle-down')
    return (
      (body !== null &&
        /git -C "\$C_PATH" rebase --onto "\$NEW_PARENT_HEAD" "\$OLD_PARENT_HEAD" "\$C_BRANCH"/.test(body) &&
        /Never run a plain `git rebase P` here/i.test(body) &&
        /Only now run `C`'s `fix pr` provider sweep/i.test(body) &&
        /run \[Stack trickle-down\]\(#stack-trickle-down\) \*\*before\*\* its provider sweep/i.test(text) &&
        /never diagnose or fix in a child a failure its parent has already fixed/i.test(text)) ||
      'missing trickle-down rebase rules'
    )
  },
)
check(
  'K3',
  'trickle-down asks once per stack and is the only non-conflict rebase',
  () => {
    const body = section('Stack trickle-down') ?? ''
    return (
      (/Ask once per stack/i.test(body) &&
        /\*\*Yes, for this whole stack\*\*/.test(body) &&
        /TRICKLE_DOWN = declined/.test(body) &&
        /do not ask again per child/i.test(text) &&
        /trickle-down is a stack-run behaviour/i.test(body)) ||
      'missing stack-level approval rules'
    )
  },
)
// fix all output, speed, and replies: plain-English status board, non-blocking pipeline, reply right after push.
check('P1', 'fix pr and fix all report with a plain-English status board, not stage cards', () => {
  const body = section('Status board') ?? ''
  return (
    (/Since last board:/.test(body) &&
      /\*\*PUSHED <sha>, CI running\*\*/.test(body) &&
      /\*\*WAITING ON YOU\*\*/.test(body) &&
      /\*\*CI INFRASTRUCTURE, rerun requested <time>\*\*/.test(body) &&
      /\*\*BLOCKED \u2014 <reason>\*\*/.test(body) &&
      /Never print the same board twice/i.test(body) &&
      /Never print a board, a row, or any line for a CI poll/i.test(body) &&
      /No stage checklists, no symbol-only rows/i.test(body) &&
      /print one \*\*action line\*\*/i.test(body) &&
      !/### Progress card/.test(text) &&
      !/\*\*Stuck on:\*\*/.test(text) &&
      !/Stage \d\/6/.test(text)) ||
    'missing status-board rules or old progress-card vocabulary remains'
  )
})
check('P2', 'replies are posted right after the push, with no separate gate', () => {
  const body = section('Reply right after the push') ?? ''
  return (
    (/never hold replies until CI finishes/i.test(body) &&
      /never ask a separate question about posting them/i.test(body) &&
      /approval covers posting it/i.test(body) &&
      /commit link/i.test(body) &&
      /Never post a generic "fixed" without evidence/i.test(body) &&
      !/Reply-posting gate/i.test(text) &&
      !/offers? to post prepared replies/i.test(text) &&
      !/Post replies now, then wait for CI/.test(text)) ||
    'missing reply-after-push rules or the old reply gate remains'
  )
})
check('P3', 'fix all is a non-blocking pipeline that never waits on one PR', () => {
  const body = section('Continuous `fix all`') ?? ''
  return (
    (/pipeline, not a babysitter/i.test(body) &&
      /Work each actionable PR to the push, then move on/i.test(body) &&
      /Do not poll its checks/i.test(body) &&
      /Only the actionable bucket consumes work/i.test(body) &&
      /Ask once per pass, not once per PR/i.test(body) &&
      /Environment blockers are reported once/i.test(body) &&
      /In `fix all` this section applies only to reading results/i.test(text) &&
      !/Fix exactly one PR at a time/i.test(text) &&
      !/serial babysitting/i.test(text) &&
      !/Do not run fixes or check polls concurrently/i.test(text) &&
      !/processes one PR at a time/i.test(text)) ||
    'missing non-blocking pipeline rules or old serial-wait vocabulary remains'
  )
})
check('P4', 'independent PRs may be prepared by non-interactive sub-agents; primary stays with the main run', () => {
  const body = section('Continuous `fix all`') ?? ''
  return (
    (/Prepare independent PRs in parallel/i.test(body) &&
      /up to three at a time/i.test(body) &&
      /must never ask the user anything/i.test(body) &&
      /never rebase or force-push/i.test(body) &&
      /A PR whose checkout is primary is worked only by the main run/i.test(body) &&
      /Sub-agent output is never shown directly/i.test(body) &&
      /Without such a tool, work serially/i.test(body)) ||
    'missing sub-agent parallelism rules'
  )
})
check('P5', 'CI infrastructure failures get one rerun and are parked, not polled', () => {
  const body = section('Waiting for checks') ?? ''
  return (
    (/CI infrastructure failures are not code failures/i.test(body) &&
      /actions\/runs\/<run_id>\/rerun-failed-jobs/.test(body) &&
      /If the rerun fails the same way/i.test(body) &&
      /Never sit polling an infrastructure rerun/i.test(body)) ||
    'missing infrastructure-failure rerun rules'
  )
})
check(
  'K4',
  'review approval is a dialog with options, not a typed exact phrase',
  () => {
    const body = section('Review-feedback approval gate') ?? ''
    return (
      (/Approve the N review changes above\?/.test(body) &&
        /\*\*Approve all\*\*/.test(body) &&
        /\*\*Defer all for now\*\*/.test(body) &&
        /never require an exact phrase/i.test(body) &&
        !/That sounds good\. Go ahead\./.test(text)) ||
      'approval gate must use host options and no exact phrase'
    )
  },
)

// Sparse managed worktrees: small by default, scoped by the branch diff, grown on demand.
const sparseFlow = section('Sparse managed worktrees') ?? ''
const scopedFlow = section('Branch-scoped sparse worktrees') ?? ''
check(
  'W1',
  'managed worktrees are sparse by default with seed and branch-scoped shapes',
  () =>
    (/Every managed worktree is sparse/i.test(text) &&
      /\*\*Seed\*\*/.test(sparseFlow) &&
      /\*\*Branch-scoped\*\*/.test(sparseFlow) &&
      /SPARSE_PATHS = SUPPORT_PATHS/.test(sparseFlow) &&
      /Never create a full checkout by default/i.test(text)) ||
    'missing sparse-by-default shapes',
)
check(
  'W2',
  'a managed start applies the seed shape before the first checkout',
  () =>
    (/apply the \*\*seed\*\* sparse shape/i.test(newCommand ?? '') &&
      /before the first checkout so the full tree is never materialized/i.test(newCommand ?? '')) ||
    'managed start does not seed-sparse the worktree',
)
check(
  'W3',
  'branch scope comes from the local merge-base diff and never requires a PR',
  () =>
    (/a PR is never required to build it/i.test(scopedFlow) &&
      /git merge-base/.test(scopedFlow) &&
      /git diff --name-only --no-renames -z/.test(scopedFlow) &&
      /never as the only source/i.test(scopedFlow) &&
      /Never guess paths/i.test(scopedFlow) &&
      !/Do not use `tools\/dev\/sparse-branch\.sh --min`/i.test(text)) ||
    'branch scope is not diff-derived or still forbids the repo helper',
)
check(
  'W4',
  'park and fix scope every existing branch regardless of PR state',
  () =>
    (/This applies whether or not the branch has a PR/i.test(text) &&
      /This does not depend on PR state/i.test(text) &&
      !/Skip this for an unraised, merged, closed, or unknown-state branch/i.test(text) &&
      !/Keep a full checkout when the branch is unraised/i.test(text)) ||
    'park/fix still fall back to full checkouts for unraised branches',
)
check(
  'W5',
  'sparse worktrees grow on demand and stay backward compatible',
  () =>
    (/Expand on need, not in advance/i.test(text) &&
      /Before editing a path outside `SPARSE_PATHS`, run `git sparse-checkout add/i.test(text) &&
      /\*\*Backward compatibility\.\*\*/.test(text) &&
      /An existing full managed worktree stays valid/i.test(text) &&
      /revived by `fix pr` or `park pr` into a branch-scoped sparse worktree at that moment, never earlier/i.test(text)) ||
    'missing grow-on-demand or backward-compatibility rules',
)
check(
  'W6',
  'support paths are named once and kept in sync with the repo helper',
  () =>
    (/\*\*`SUPPORT_PATHS`\*\*/.test(text) &&
      /`\.codeagent\/`, `\.github\/`, `tools\/dev\/`, and `tools\/onboarding\/`/.test(text) &&
      /keep the two in sync when either changes/i.test(text)) ||
    'missing SUPPORT_PATHS definition',
)

// Plain-language question rules.
const plainRules = section('Plain-language rules for the question') ?? ''
check(
  'L1',
  'the decision question has plain-language rules',
  () =>
    (/\*\*Lead with the decision\.\*\*/.test(plainRules) &&
      /\*\*Translate the vocabulary on first use\.\*\*/.test(plainRules) &&
      /the main checkout \(where your dev server runs\)/i.test(plainRules) &&
      /a separate small checkout directory next to it/i.test(plainRules) &&
      /keep the branch saved, with no directory checked out/i.test(plainRules) &&
      /\*\*No long identifiers\.\*\*/.test(plainRules) &&
      /seven characters or not at all/i.test(plainRules) &&
      /\*\*Two sentences per paragraph, at most\.\*\*/.test(plainRules) &&
      /\*\*Options read like outcomes\.\*\*/.test(plainRules) &&
      /\*\*Counts, not inventories\.\*\*/.test(plainRules) &&
      /\*\*PR state in plain words\.\*\*/.test(plainRules)) ||
    'missing plain-language rules',
)
check(
  'L2',
  'the plain-language rules ban internal jargon in the question',
  () =>
    (/Never use these words in the question/i.test(plainRules) &&
      /`disposition`/.test(plainRules) &&
      /`detach`/.test(plainRules) &&
      /`materialize`/.test(plainRules) &&
      /`sparse`/.test(plainRules) &&
      /Never show `BASE_SHA`, `SOURCE_PATH`, `DESTINATION`, `PRIMARY_PATH`/.test(plainRules)) ||
    'missing jargon ban',
)
check(
  'L3',
  'a worked example question is provided and keeps options out of the text',
  () =>
    (/A good `start pr` question reads like this/i.test(plainRules) &&
      /> Where should the new branch for the calendar export live\?/.test(plainRules) &&
      /The options above are shown only in the tool call's `options` array/i.test(plainRules)) ||
    'missing worked example',
)

const failures = results.filter((result) => !result.ok)
for (const result of results) {
  console.log(
    `${result.ok ? 'ok  ' : 'FAIL'} ${result.id.padEnd(4)} ${result.description}${result.ok ? '' : `  <-- ${result.detail}`}`,
  )
}
console.log(`\n${results.length - failures.length}/${results.length} checks passed for ${skillPath}`)
if (failures.length) {
  console.log(`violations: ${failures.map((failure) => failure.id).join(', ')}`)
  process.exit(1)
}
