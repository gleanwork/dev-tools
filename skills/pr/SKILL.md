---
name: pr
description: >
  Manage safe pull-request work from explicit lifecycle commands. `fix all` continuously repairs the author's open PRs that are ready for review as a non-blocking pipeline: fix, push, reply to the addressed comments at once, move to the next PR, and read CI on the next scan; explicitly say `fix all drafts` or `PR fix drafts` to include drafts. For the exact bare command `pr`, immediately show only the four-option lifecycle menu: Help; Start or continue work; List my PRs and worktrees; Cancel. Never substitute a generic PR create/review/update chooser. Use when the user asks to run `pr`, start, new, focus, raise, park, fix, fix all, fix drafts, list, or get help with PR work.
disable-model-invocation: false
---

# Bare `pr` invocation contract

This rule has priority over every other PR instruction in this skill:

- When the user message is exactly `pr`, immediately call the host's interactive question tool (for example `ask_clarifying_question`; use the host's equivalent when it is named differently).
- Use exactly this question: `What would you like to do with the PR workflow?`
- Offer exactly these four options: **Help**; **Start or continue work**; **List my PRs and worktrees**; **Cancel**.
- Do not inspect Git, the branch, worktrees, PRs, or provider state before showing this menu.
- Do not show or invent a generic menu such as “Create a new PR from the current branch,” “Review an existing PR,” “Update an existing PR,” or “Show the current branch/status.”
- Do not replace this menu with a free-form clarification, a create/review/update chooser, or an automatic `help pr` response.
- If the user chooses **Help**, render the `help pr` screen below, including its final **Example flow** section. If the user chooses **Start or continue work** or **List my PRs and worktrees**, continue with that explicit selection. **Cancel** performs no action.

# PR lifecycle

Use this skill for the explicit command format:

```text
start pr REQUEST
focus pr
raise pr
park pr
fix pr
fix all
fix all drafts
ls pr
```

## Goals

- Work on many changes in parallel.
- Treat the primary checkout and managed worktrees as equivalent checkouts for a change.
- Prefer the primary checkout when it can be used safely; use a managed worktree when the user chooses it or the primary checkout cannot be freed.
- For a feature branch displaced from primary by `start pr` or `focus pr`, calculate every viable disposition before ordering the choices: keep the branch ref without a checkout, or preserve it in a managed worktree. Never move it automatically merely because primary must be freed.
- For an open/draft PR, prefer a managed worktree and then a branch ref only when both are viable; for a confirmed merged or closed PR, prefer the branch ref only. For unraised or unknown state, expose every viable disposition and state the preference without hiding an alternative.
- Make `focus pr` a simple move of the feature branch into the primary checkout through the same inspection and preservation question used by `start pr`.
- Make `park pr` the explicit reverse move: take a feature branch out of primary and place it in a managed worktree without changing its PR or commits. That worktree is a branch-scoped sparse worktree: it materializes only the files the branch changes relative to its base, plus the minimum support files needed to commit, push, and run hooks. A PR is not required for scoping; the branch diff is.
- Make `raise pr` publish-only: commit, push, and create or update the PR without moving the branch or opening a location dialog. Raising never relocates the branch, because the user may keep testing it in primary; `park pr` is the explicit handoff to a branch-scoped sparse worktree.
- Let `fix pr` and `fix all` work in the PR branch's existing checkout, including primary. When a PR branch has no local checkout, create a branch-scoped sparse worktree for it instead of a full checkout; never check the branch out in two places.
- Keep every managed worktree small. A new managed worktree starts as a **seed sparse checkout** (root files plus the repository's support directories) and grows only when work needs more of the tree. Never create a full checkout by default; on a large repository that does not scale.
- Make `ls pr` a read-only inventory command for branches, PRs, checkouts, and worktree locations; `list pr` and `pr ls` are aliases.
- Make `clean pr` the explicit reclaim step: remove checkouts whose work is finished, keep every branch, and never touch dirty or unpushed work; `pr clean` is an alias.
- Let `fix pr` inspect mergeability, review comments, and CI/checks on every run. Capture CI state and failure details for the current head before any rebase; rebase only after a provider-reported conflict and onto the PR's exact base branch (which may be another PR's head branch in a stack). The one exception is the `fix all` stack trickle-down, which rebases a child onto its parent's freshly fixed head under a single stack-level approval. Then refresh comments and checks on the updated head before fixing actionable issues. Recognized bot comments and clearly trivial human comments may be fixed automatically; non-trivial human requests require batched approval. Reply to each addressed comment immediately after the push that fixes it, with the commit link; never merge. For GitHub REST, use `mergeable: false` with `mergeable_state: dirty` as the conflict signal.
- Let `fix all` discover and continuously repair only author-owned open PRs that are ready for review. Drafts are out of scope unless the user explicitly says `fix all drafts`, `fix drafts`, or `PR fix drafts`; that opt-in includes both review-ready PRs and drafts. Run it as a pipeline: fix, push, and reply for one PR, then move to the next without waiting for its CI; read results on the next scan. Park PRs that wait on a reviewer or on CI infrastructure instead of polling them. Prepare independent PRs in parallel through non-interactive sub-agents when the host offers them. Process stacked PRs root-first: fix the PR closest to the default branch, then rebase each descendant onto the parent's pushed head with `git rebase --onto` before fixing it, so a parent's fixes trickle down once instead of being re-fixed in every child. Keep looping until the user stops the run, respecting approval gates. For a confirmed rate limit, wait and retry the exact provider operation instead of abandoning the run.
- Continue an existing unmerged PR in its existing branch and checkout instead of creating a duplicate branch.
- Preserve dirty work. Never guess which change owns a dirty path.

Do not solve the startup race where two `start pr` requests see the primary checkout as available at the same time. Treat that as a later improvement.

### Terminology

- **primary checkout** means the first checkout listed by `git worktree list --porcelain`; it is the repository's default working directory. Refer to its absolute path as `PRIMARY_PATH`.
- **default base** means the repository's advertised default branch, resolved from the remote rather than assumed. `BASE_BRANCH` is its name and `BASE_SHA` is the exact commit recorded after the required fetch. **PR base** means the base branch declared by the provider for a specific PR. For stacked PR fixes, use the exact `PR_BASE_BRANCH` and freshly fetched `PR_BASE_SHA`; this may be another open PR's head branch, not the repository default.
- A **managed worktree** is a plain Git linked worktree that this skill creates, inspects, and removes with `git worktree` commands. It does not depend on any host worktree service, slash command, UI, registry, or model tool. Its path is derived, never chosen by the user: see [Worktree paths](#worktree-paths). Every managed worktree is sparse: a **seed** shape for a new branch, or a **branch-scoped** shape for an existing branch. When parking an existing branch, reuse a suitable clean detached managed worktree if one is available; otherwise create a new one with `git worktree add`. Check out an existing branch only after `git worktree list --porcelain` shows it has no other checkout owner.
- A **seed sparse worktree** is a managed worktree for a branch that has no changes yet. Its checked-out file set is the cone root (root-level files) plus `SUPPORT_PATHS`. It grows with `git sparse-checkout add` as the work touches more of the tree. See [Sparse managed worktrees](#sparse-managed-worktrees).
- A **branch-scoped sparse worktree** is a managed worktree for an existing branch whose checked-out file set is deliberately small: the paths the branch changes relative to its base (merge-base diff) plus `SUPPORT_PATHS`. It does not require a PR. It shares the repository's object store and full history; only the working directory is reduced. See [branch-scoped sparse worktrees](#branch-scoped-sparse-worktrees).
- **`SUPPORT_PATHS`** are the directories that hooks, formatters, and the toolchain bootstrap read on every commit, independent of what the change touches. For this repository they are `.codeagent/`, `.github/`, `tools/dev/`, and `tools/onboarding/` (`mise.toml` runs `tools/dev/resolve-venv.sh` and `tools/onboarding/mise-check-install.sh`). `tools/dev/sparse-branch.sh --min` applies the same set; keep the two in sync when either changes.
- **`SOURCE_PATH`** is a checkout that contains material to copy from. It is never a destination.
- **`DESTINATION`** is exactly one of `primary` (at `PRIMARY_PATH`) or `secondary` (a managed worktree). It is chosen by the user, not inferred.
- The primary checkout is **free** when it is clean. A clean primary checkout on another feature branch is usable after that branch receives the user's selected disposition—managed worktree or branch-ref-only. A dirty primary checkout is usable after its dirty paths are classified and preserved.

### Worktree paths

Derive every managed worktree path from the primary checkout. Never ask the user to name one and never accept a hand-chosen path.

- `WORKTREE_PARENT` is the parent directory of `PRIMARY_PATH`, so worktrees sit beside the primary checkout.
- `SLUG` is the branch name with a leading `<owner>/` segment removed and every remaining `/` replaced by `-`; for example `jd/search-direct` becomes `search-direct`. If that path already exists and is not the target, append `-2`, `-3`, and so on.
- `WORKTREE_PATH = WORKTREE_PARENT/SLUG`. Report this absolute path after creation.
- `git worktree list --porcelain` is the only source of truth for checkout ownership. Run commands against a worktree with `git -C "$WORKTREE_PATH" …` or absolute paths; there is no separate activation step.

### No host worktree tooling

Do not use host-provided worktree features (for example a `/worktrees` command, a Worktrees UI, `worktree_*` model tools, or tool discovery) for any worktree operation. Use `git worktree add`, `git worktree list --porcelain`, `git worktree remove` (never `--force`), and `git worktree prune` directly. If a host-tracked worktree record exists for a path, ignore it; Git owns the checkout.

## Core model

A change is a feature branch plus its current checkout, if it has one. The branch and files are the same whether the checkout is primary or managed; only the location changes. A branch ref without a checkout is a valid deliberate disposition after its work is preserved.

Maintain these invariants:

- A local feature branch is checked out in at most one worktree; a deliberately branch-ref-only change has zero owning worktrees.
- Create, inspect, and remove managed worktrees with plain `git worktree` commands at the derived path in [Worktree paths](#worktree-paths). Do not ask the user to name a path. Do not use any host worktree UI, slash command, or tool.
- When the change lives in a managed worktree, route reads, edits, searches, and shell commands to that path (`git -C`, absolute paths).
- `raise pr` never changes checkout location. When the user explicitly runs `park pr` from primary, restore primary to `base` only after preservation and branch ownership are verified. When the feature is already managed, do not modify primary.
- A normal new branch starts at `BASE_SHA`. A newly created stacked branch requires an explicit request naming its parent. When fixing an existing stacked PR, use that PR's provider-declared base branch; in `fix all`, fix its parents first and rebase it onto their new heads before fixing it.

When the current target or branch ownership is unclear, run `git worktree list --porcelain` and use it as the only source of truth. If a branch appears in two checkouts or a listed path is missing, stop rather than guessing ownership.

## Non-negotiable invariants

- **Never guess change ownership.** If a dirty checkout contains work from more than one change, classify it with the user before committing, stashing, branching, or moving anything.
- **Never create a new branch from the current branch by accident.** A normal `start pr` branch must start at the exact freshly fetched `BASE_SHA`.
- **Preserve every path.** Staged, unstaged, untracked, ignored, and partially staged work must be inventoried and preserved. Ignored build and dependency output is preserved by leaving it alone: see [Ignored paths are not work](#ignored-paths-are-not-work).
- **Never choose the destination on the user's behalf.** See [The one decision question](#the-one-decision-question). A dirty primary checkout is not a reason to choose a managed worktree.
- **Verify, do not infer.** After every branch/worktree mutation, re-read Git and host state and prove branch ownership, base provenance, and path preservation.
- **Never reclaim unrecoverable work.** A checkout may be removed only when it is clean and every commit it holds already exists on a remote. See [`clean pr`](#clean-pr).
- **Stop safely.** If work cannot be split without risk, change nothing and ask the user to resolve the ambiguity.

## Ignored paths are not work

Ignored build output, dependency trees, and caches are not part of any change and are never endangered by this workflow. Switching branches, detaching `HEAD`, creating a managed worktree, or checking a branch out in another checkout leaves them exactly where they are; they belong to the checkout, not to the branch.

- **Do not enumerate or count them.** Never run a recursive ignored listing such as `git status --ignored` or `git clean -ndx` across a populated checkout: it walks every file in dependency and cache trees, costs far more than it returns, and answers no question the workflow asks. Classify with `git status --porcelain`. The one exception is proving that a **candidate empty** managed worktree is unused, where the listing is cheap and the emptiness is the point.
- **A checkout whose only remaining entries are ignored build or dependency output is clean.** Say "clean", not "clean except for N ignored artifacts".
- **Never put them in a confirmation question**, and never quote a count of them. Raising a five- or six-figure file count invents a risk that does not exist and buries the decision the user must actually make.
- **Mention them only when the confirmed action can delete or move them**, such as `git clean`, removing a worktree, or a destination that copies the working tree. Then name the specific paths and their consequence, still without a recursive count.
- **A new worktree is linked to primary's dependencies at creation, not left bare.** Immediately after creating a managed worktree, run the cheap symlink from the dependency bootstrap in [`raise pr`](#raise-pr) step 5 so hooks and tests work on the first commit. The hook-failure path in that step is the fallback for anything the creation-time link did not cover.

## Help and command selection

An explicit command outranks every inference. When a message uses a reserved command form, that command runs. Never demote it to wording, a label, a topic hint, or a statement of intent, and never replace it with a different behavior because the request beside it looks like ordinary implementation work. A request for local code changes next to `new pr` is the normal shape of `new pr`; it is never evidence that the user meant something else. Only a bare `pr` opens the menu.

Normalize the command before inspecting repository state or performing any Git/worktree action:

- `help pr` displays the help below and stops. It performs no Git, worktree, PR, or automation side effects.
- `start pr REQUEST` requires an implementation request and continues a matching unmerged PR or starts a feature branch when no such PR exists. `new pr REQUEST` is the same command. Both always reach the destination question in [Starting a new branch with `start pr`](#starting-a-new-branch-with-start-pr-new-pr-alias) unless the session's own PR covers this request under [Existing PR continuation](#existing-pr-continuation).
- `focus pr` moves the selected feature branch into the primary checkout when possible. It does not commit or push.
- `raise pr` commits, pushes, and creates or updates the PR. It leaves the branch exactly where it is and never opens a post-raise location dialog.
- `park pr` moves the selected feature branch out of primary into a managed worktree. For a branch with an open/draft PR, the destination is a branch-scoped sparse worktree. It does not commit, push, or alter the PR.
- `fix pr` always captures mergeability, review comments (inline, PR-level, and review bodies), and CI/check status before mutation. It records CI failures for the current head before any rebase, rebases only on a provider-reported conflict onto the exact freshly fetched PR base, then refreshes comments and checks for the updated head. It classifies every review item, automatically handles recognized bots and trivial human comments, and batches non-trivial human changes and draft replies for approval. It validates and pushes verified fixes, replies to each addressed comment immediately after the push, and never merges. It works in the branch's existing checkout, including primary; if the PR branch has no local checkout, it creates a branch-scoped sparse worktree. `pr fix` is an alias.
- `fix all` continuously discovers and repairs author-owned open PRs that are ready for review; it skips drafts. It is a pipeline: for each PR with work it fixes, pushes, and replies to the addressed comments at once, then moves to the next PR without waiting for CI; results are read on the next scan. Stacked PRs go root-first, each child rebased onto its parent's pushed head (`git rebase --onto`) before its own fix. Independent PRs may be prepared in parallel by non-interactive sub-agents. Both `fix pr` and `fix all` report with the linked [Status board](#status-board): one row per PR with a plain-English status, what was done, and what happens next. `fix all drafts` (also `fix drafts` or `PR fix drafts`) opts in to drafts and includes both drafts and review-ready PRs.
- `ls pr` performs the fast local workspace scan described below. `list pr` and `pr ls` are aliases. It does not enumerate remote, merged, or closed PR history unless explicitly requested.
- `clean pr` reclaims checkouts whose work is finished. `pr clean` is an alias. It removes checkouts only, never branches, and always asks once before deleting anything.
- A bare `pr` always opens the compact, read-only action menu and does not inspect repository state. Use exactly this question: `What would you like to do with the PR workflow?` Its only options are **Help**; **Start or continue work**; **List my PRs and worktrees**; and **Cancel**. Ask it through the host's interactive question tool (for example `ask_clarifying_question`). Do not infer `help pr`, choose a target, or add `focus pr`, `raise pr`, `park pr`, or `fix pr` to this menu. Those commands require explicit input or a verified target.

Treat `help`, `start`, `new`, `focus`, `raise`, `park`, `fix`, `fix all`, `fix all drafts`, `list`, `ls`, and `clean` followed by `pr` as reserved command forms. `fix all` and `fix all drafts` are also reserved standalone commands and must not be treated as `fix pr` with a literal target named `all`. `fix all` means all author-owned open PRs ready for review; drafts are excluded. `fix all drafts` means all author-owned open PRs, including drafts. Also recognize `fix drafts`, `fix all and drafts`, and `PR fix drafts` as the draft-inclusive form. `start pr` may have a request; `new pr` is an equal alias for it and never a weaker or deprecated form; `focus pr`, `raise pr`, `park pr`, `fix pr`, `ls pr`, and `clean pr` may accept only a clearly identified branch, PR, or supported option. `list pr` and `pr ls` are aliases, and `pr clean` is an alias for `clean pr`. Unexpected arguments must be explained and stopped without side effects.

### Help response

For `help pr`, present one continuous change lifecycle in a welcoming, concise way. Explain that `/pr` handles worktree housekeeping, always offers the relevant choices before moving anything, and keeps the primary checkout available for a long-running dev server when that is useful. Then show the lifecycle text and diagram, followed by the short example flow as the final section.

PR workflow

What is `/pr`?

`/pr` automates the worktree housekeeping around a change so you can focus on the work. Give it a change request, or paste the Slack discussion and say `new pr`; it checks the current work and offers choices before it moves or preserves anything.

**Commands:** `new pr` (`start pr`) · `focus pr` · `raise pr` · `park pr` · `fix pr` · `fix all` · `fix all drafts` (`PR fix drafts`) · `ls pr` · `clean pr` · `help pr`

**One change. One feature branch. One working checkout at a time.**

`new pr REQUEST` — start or continue a change. It can keep the change in primary, leave a displaced branch as a branch ref only, park it in a managed worktree when viable, or create a managed worktree for the new change so you can work in parallel. A new managed worktree is tiny: root files plus the hook/toolchain essentials, growing only as the work touches more of the tree. If primary is dirty, it offers safe ways to preserve those changes first. (`start pr` is the canonical spelling; `new pr` is its compatibility alias.)

`focus pr` — bring the feature into primary.

`park pr` — move it out of primary into a small branch-scoped sparse worktree (only the files the branch changes, plus hook/commit essentials) and free primary. Works with or without a PR. Use it when you are done testing in primary.

`raise pr` — run the required checks, commit confirmed paths, push, and create or update the PR without changing its checkout.

`fix pr` — capture mergeability, review comments, and CI status for the current head before mutation. Record CI failures before a possible rebase; rebase only for a reported conflict onto the PR's exact base; then refresh comments and checks for the new head, fix actionable issues, validate, push, reply to the addressed comments right away, and wait for a conclusive post-push check result. It works wherever the branch already is, including primary. If the PR branch has no local checkout, it creates a small branch-scoped sparse worktree for it. It never merges.

`fix all` — continuously repair every author-owned open PR that is ready for review. Drafts are skipped. It never waits on one PR: fix, push, reply, move on, and read CI on the next scan. Anything waiting on a reviewer or on CI infrastructure is parked, not polled. Within stacks, fix the root first, then rebase each child onto its parent's pushed head before fixing it, so a fix made once in a parent is never re-made in its children. Independent PRs can be prepared in parallel. After each pass, rescan for new PRs, review feedback, and changed checks. Keep running until the user stops it; wait and retry confirmed rate limits, never busy-poll providers or bypass approval gates.

`fix all drafts` — the same continuous workflow, but include draft PRs as well as review-ready PRs. You can also say `fix drafts` or `PR fix drafts`.

`ls pr` — show open/draft PRs and local work needing attention. Read-only. (`list pr` and `pr ls` are aliases.)

`clean pr` — reclaim disk from checkouts whose PR is merged or closed. It removes checkouts, never branches, and never anything dirty or unpushed. It shows exactly what it would delete and the space saved, then asks once. (`pr clean` is an alias.)

Nothing moves, gets preserved, committed, pushed, or merged without the workflow's explicit choice. Primary can stay ready for `pnpm run dev` or `pnpm start`; managed worktrees are sparse and small, and they share heavy dependencies with primary when their inputs match.

A simple way to choose: if you test the change with a long-running local process in primary (a dev server, an Electron app), start in primary. If you can deploy or test the change from anywhere (backend, mobile), start in a managed worktree and leave primary alone.

On hosts that resolve relative links against the active project checkout rather than the skill directory (Glean Tau is one), resolve the installed skill asset to an absolute file URI before responding. For a personal local skill, use `~/.agents/skills/pr/pr-lifecycle.png`; for a Glean-installed skill, use `~/.glean/agent/skills/pr/pr-lifecycle.png`; for Claude Code, use `~/.claude/skills/pr/pr-lifecycle.png`. Emit the resolved URI immediately after the concise response, for example `![PR lifecycle](file:///Users/<user>/.agents/skills/pr/pr-lifecycle.png)`. Display the Chrome-rendered PNG; do not substitute a relative path on those hosts. On other hosts, use `![PR lifecycle](pr-lifecycle.png)` when skill-local asset links are supported; otherwise omit the image and provide the text workflow. The source of truth is [pr-lifecycle.svg](pr-lifecycle.svg). The diagram uses solid diamonds for decision points and boxes for branch checkouts; explicit merge is the terminal step. The PNG was rendered with Chrome and uses a white outer background. Do not regenerate it with ImageMagick or substitute another visual. If an asset is referenced but unavailable, report the missing asset.

### Example flow

1. `new pr "Add calendar export"` — or paste the Slack discussion and say `new pr`. The skill checks existing work and offers primary or a managed worktree for the new change, plus every viable disposition for a displaced branch; it does not move anything without your choice.
2. Code and test where the change lives. Use `focus pr` to bring it into primary or `park pr` to move it back out so primary can stay ready for the dev server.
3. `raise pr` — run checks, commit confirmed paths, push, and create or update the PR. The checkout stays where it is, so you can keep testing in primary. When you are done, `park pr` moves the branch into a small branch-scoped sparse worktree and returns primary to the default branch.
4. `fix pr` — capture mergeability, review comments, and CI status for the current head before mutation. Record CI failures before a possible conflict rebase; then refresh comments and checks on the resulting head, fix actionable issues, validate, push, reply to the addressed comments right away, and wait for checks. Bot and trivial human comments are handled automatically; non-trivial human comments need approval. `fix all` applies this workflow to open PRs ready for review without waiting on any one of them: fix, push, reply, next PR; CI is read on the next scan. Drafts are skipped. Say `fix all drafts` or `PR fix drafts` to include drafts. Stacks go root-first (children are rebased onto the pushed parent before their turn), and it keeps rescanning until you stop it. It never merges.
5. A person merges the PR.
6. `clean pr` — reclaim the finished checkouts. Branches stay; only the checkouts go, and only when they are clean and already pushed.

## Provider adapter

The lifecycle and safety rules are provider-neutral. Resolve the pull-request provider from the repository's configured remote and use that provider's documented native integration or CLI:

- **GitHub uses REST as the required path.** Use authenticated `gh api` REST endpoints for PR discovery and state, mergeability, checks, reviews, comments, PR creation/update, and replies. Do not use `gh pr` or GraphQL as a prerequisite for any lifecycle command. REST success is sufficient; a GraphQL quota or outage must never block a successful REST operation.
- **Optional GraphQL fallback is secondary only.** If a required REST operation fails and an equivalent tested GraphQL operation exists, attempt GraphQL as a fallback. Never try GraphQL first, never replace a successful REST result with GraphQL, and never invent an ad-hoc query to avoid reporting an error. Preserve both error causes.
- For GitHub REST mergeability, treat the resolved pair `mergeable: false` and `mergeable_state: dirty` as a provider-reported conflict. If the fields disagree or `mergeable_state` is missing, treat the result as inconclusive and do not rebase. Treat `mergeable: null`, missing, `unknown`, `behind`, `blocked`, or any unavailable result as inconclusive, not as a conflict. `CONFLICTING` is a GraphQL enum and is not the REST contract.
- For another provider, use its equivalent bounded author-filtered PR listing, mergeability result, review-thread API, and PR create/update operation; do not run GitHub-specific commands against it.
- If REST fails and the optional GraphQL fallback also fails, the provider-dependent command must fail loudly with `PROVIDER_OPERATION_FAILED`, naming the operation and both causes. A mutating command must stop before mutation when the result is required. A command that has already pushed a branch must report the push separately and fail the provider phase; it must not claim that a PR was created or updated. A read-only inventory may show its local portion only after emitting `PROVIDER_OPERATION_FAILED`, marking provider data unavailable, and naming the error; it must return an incomplete/error outcome and never report “no PR.”

## Shared repository setup

For any command that needs repository state:

1. Confirm the current directory is inside a Git worktree. Resolve the repository root with `git rev-parse --show-toplevel` and canonicalize it.
2. Run `git worktree list --porcelain`. Identify the primary checkout as the first `worktree` entry and record `PRIMARY_PATH`. Never remove or replace it.
3. When the change may live in a managed worktree, locate it in `git worktree list --porcelain` and confirm the branch has exactly one owning path. Treat any remembered path as possibly stale until re-verified.
4. Confirm the intended remote exists. Prefer the repository's configured default remote; ask when multiple remotes are equally plausible.
5. For `start pr` and `raise pr`, refresh the advertised default base immediately before creation or handoff. For `fix pr`, capture CI/check state and failure details for the current PR head before any possible rebase, then check mergeability. Only on a provider-reported conflict, fetch the exact provider-declared PR base branch. For a stacked PR this is its parent PR's head branch, not the repository default. For GitHub REST, require `mergeable: false` together with `mergeable_state: dirty`; do not use the GraphQL-only `CONFLICTING` enum as a REST requirement.

```bash
git fetch origin --prune
git ls-remote --symref origin HEAD
```

Parse the advertised `ref: refs/heads/<branch> HEAD` line and set `BASE_BRANCH` to that branch and `BASE_REF` to its `origin/<branch>` ref. Do not assume `main` or `master`. If `HEAD` is not advertised, fall back to repository configuration, or to a single unambiguous candidate among `origin/main` and `origin/master`; stop if both or neither exist. Never choose one merely by preference order. Refresh `origin/HEAD` with `git remote set-head origin --auto` when it is missing or stale. 6. Record `BASE_SHA = git rev-parse REMOTE/BASE_BRANCH` after the fetch and immediately before branch creation. Verify `BASE_SHA` resolves locally. Do not use the current branch, its `HEAD`, or a stale local base as the implicit source. 7. When the primary checkout must be restored to the base branch, use the matching local `BASE_BRANCH`; if it does not exist, create a local tracking branch from `BASE_REF`. Stop if switching the primary checkout would overwrite work or the base branch is already owned unexpectedly.

Do not pull, rebase outside `fix pr`, reset, clean, or silently overwrite existing work. Never use a blind force-push; a rewritten published branch may be updated only with an explicit confirmation and `git push --force-with-lease`.

## The one decision question

Before any branch, worktree, commit, stash, activation, or file transfer, ask exactly one question through the host's confirmation mechanism. This means exactly one question with `ask_clarifying_question` or the host's equivalent interactive question tool. This is the only confirmation for `start pr` or `focus pr`.

The question must be understandable without knowing this skill, by someone who has never heard of a worktree. Explain the situation conversationally, with one idea per short paragraph:

1. Explain the goal and the source code, in one sentence. For example: `The goal is to copy the search follow-up changes you already made in <source>; that directory stays as it is.`
2. Explain the branch action, in one sentence. For `start pr`, say: `We will create a new branch, <new-branch>, from the freshly fetched origin/<base> (commit <short-sha>).` For `focus pr`, name the existing branch and say that it will be moved, not recreated.
3. Explain the relevant checkout state: where primary is, which branch it has, what dirty or unrelated work is present, and what must be preserved. Before asking, check the displaced branch's PR state and summarize it briefly as **raised** (open/draft PR), **closed**, **unraised**, or **unknown**. Keep this separate from the goal and branch explanation when that makes it easier to read.
4. Ask the user for the one decision that remains. For `start pr`, ask where the branch should live: for example, `Should this branch live in the primary checkout or a managed worktree?` For `focus pr`, explain that the destination is already primary and ask only how to preserve work in the way. If the displaced branch is unraised and the chosen destination would displace it, fold a single **raise it first** versus **preserve it for later** choice into these options; do not make the user discover its PR state or ask a generic second question after preservation.

Usually three paragraphs are enough: combine the checkout facts and the final question when they remain clear. Use a fourth short paragraph when separating the facts from the question makes the choice easier to understand. Do not force unrelated facts into one paragraph, and do not mechanically repeat the examples above. The user must be able to tell whether they are choosing a destination for `start pr` or a preservation action for `focus pr`.

### Plain-language rules for the question

The question is dense by nature. These rules keep it readable for non-engineers without removing information:

- **Lead with the decision.** The first sentence says what is being decided, for example `Where should the new branch live?` The facts that justify the choice come after it.
- **Translate the vocabulary on first use.** Say `the main checkout (where your dev server runs)` for the primary checkout; `a separate small checkout directory next to it` for a managed worktree; `keep the branch saved, with no directory checked out` for branch-ref-only; `uncommitted edits` for dirty work; `the shared starting point` for the base. After the first use, the short term alone is fine. Never use these words in the question: `disposition`, `detach`, `materialize`, `viable`, `sparse`, `ref`, `checkout owner`.
- **No long identifiers.** Show commit SHAs as seven characters or not at all. Never show `BASE_SHA`, `SOURCE_PATH`, `DESTINATION`, `PRIMARY_PATH`, or any other internal label. Show a path only when the user needs it to decide; otherwise name the directory by its role.
- **Two sentences per paragraph, at most.** If a paragraph needs a third sentence, split it or cut a fact that does not affect the decision.
- **Options read like outcomes.** Start each option with a verb, keep it under about twelve words, and state what the user ends up with, not the mechanism: `Use the main checkout; stash the 3 unrelated edits first`, not `Primary with stash preservation of unrelated paths`.
- **Counts, not inventories.** Say `3 edited files in the reporting UI`, never a path list.
- **PR state in plain words.** `already has an open PR`, `no PR yet`, `its PR was merged`, or `I could not check its PR state` — never `raised/unraised/unknown` as bare labels.

A good `start pr` question reads like this:

> Where should the new branch for the calendar export live?
>
> I will create `jd/calendar-export` from the latest `origin/master` (commit `3f2a9c1`). It starts clean; nothing from your current work is carried over.
>
> The main checkout (where your dev server runs) is on `jd/search-direct`, which already has an open PR, and has 3 uncommitted edits in the reporting UI. Whatever you choose, those edits and that branch are kept.

> Options: `Use the main checkout; park search-direct in a small side directory` · `Use the main checkout; keep search-direct saved with no directory` · `Use a separate small directory; leave the main checkout as it is` · `Cancel; change nothing`

The options above are shown only in the tool call's `options` array, never in the question text.

Put the choices only in the tool call's `options` array. Do not repeat them in the `question` text, do not write “Choose one” followed by a list, and do not write a prose lead-in before the tool call. Each option is one selectable button and includes its own short consequence. Include exactly one **Cancel** option, meaning that nothing changes.

Do not ask a second confirmation. Before the answer, do nothing: no branch, no worktree, no commit, no stash, no activation, and no file transfer. Classification of dirty paths is part of the explanatory paragraphs; it is not a separate confirmation.

Keep each paragraph short enough to fit in roughly three displayed lines. Do not list every implementation path in the question. Give the count and a short category summary; inspect and preserve the exact paths internally. Use actual paths and branch names. Internal labels such as `SOURCE_PATH`, `DESTINATION`, and `BASE_SHA` may be used in implementation notes, but never replace the plain-English facts shown to the user.

A bare **Proceed / Cancel** pair is invalid. Do not offer two choices that mean the same thing. The chosen home and displaced-branch disposition are fixed after the answer; if either cannot be honored, stop without mutation and require a new question before choosing an alternative.

Use one bounded provider lookup before the question to determine whether a displaced branch is raised, merged, closed, unraised, or unknown, following [Provider lookups and quota](#provider-lookups-and-quota). If it is unraised, make raise-first versus preserve-for-later part of the same question. If it is merged or closed, do not auto-park it. If it is unknown, preserve conservatively. After a confirmed commit or stash, refresh status and PR association but do not repeat the whole dialogue unless the state changed or remains unknown.

Calculate viability before preference. Preservation and displaced-branch disposition are separate dimensions:

- A stash is viable when all affected paths are classified, the stash can include the required untracked paths, and the resulting record can be verified. A commit is viable when ownership is confirmed and a normal hook-checked commit can safely remain on that branch. If either method is viable, keep it as a selectable option; prefer stash when both are viable, but never hide commit.
- **Branch ref only** is viable when the displaced branch can be detached or switched away after its work is preserved, leaving the branch name and commits intact with zero owning worktrees. This remains viable for an open/draft PR and is the default disposition for confirmed merged or closed PRs during automatic displacement.
- **Managed worktree** is viable when a safe reusable managed worktree exists or `git worktree add` can create one at the derived path. For an open/draft PR, prefer this before branch-ref-only because follow-up work may need a ready checkout; for unraised work, prefer branch-ref-only; for unknown PR state, prefer the managed worktree as conservative preservation. These are preferences, not safety gates.
- If both dispositions are viable, include both in the one question. If dirty paths require preservation, include every viable preservation method with each materially different disposition rather than collapsing the choices into one preferred route. If no safe combination is viable, offer only Cancel and explain why.

### Existing PR continuation

Before treating an implementation request as a new branch request, inspect the current chat/session context for the repository, feature branch, and pull request that this work already created or raised. The chat context is a strong identity clue for **where** work has been happening; it is not evidence that a new request belongs to that work. Verify it against the provider and Git before changing anything.

Continuation requires an affirmative coverage test. The session's PR covers the new request only when the request is the same change: it touches the same feature area or files, or it plainly refers back to that work, for example a follow-up, a correction, review feedback, or a revert of it. A chat being homed on a branch is location, not coverage.

- **If the request is a different change, it is a new change.** Use the ordinary new-branch flow even when the session has an unmerged PR, and never add unrelated work to a raised branch. Continuing would mix two changes into one PR, which no later step can cleanly undo.
- **If the user typed `new pr` or `start pr`, never auto-continue.** The explicit command means a new change unless the request itself refers back to the session's work. When an unmerged session PR exists and coverage is anything short of obvious, ask exactly one question offering a new branch in the primary checkout, a new branch in a managed worktree, and continuing PR `#<number>` on its existing branch. Name the PR and its branch in the question so the user can see what would be continued.
- **If coverage is uncertain and no command was given, ask.** Never resolve uncertainty by continuing; silent continuation is the failure this rule exists to prevent.
- **Classify existing dirty work first.** When the working tree already holds changes, apply [Late-start recovery](#late-start-recovery-changes-made-before-the-pr-workflow-was-invoked) before any branch decision, so pre-existing edits are never absorbed into a continuation commit.

When the coverage test passes and continuation is correct:

- If the identified PR exists and is **not merged**, reuse its exact branch. Do not derive a new branch name, create a new branch, or copy the work onto a sibling branch. A still-open PR is the normal continuation case for the same change. If the PR is closed but unmerged, report that state and stop before pushing or reopening it unless the user explicitly authorizes that follow-up.
- Find the branch's one owning checkout with `git worktree list --porcelain`. Never create a duplicate branch. If it is already in a managed worktree, fix the existing branch there with `git -C <path>`. If it is in primary, continue there. If it is parked in a detached managed worktree, run `git -C <path> switch` only after Git confirms the branch has no other checkout owner.
- If the user explicitly needs the existing branch moved into primary, use the `focus pr` preservation question and rules. The destination is the existing branch, not a newly selected home; preserve any primary work before moving it.
- If the provider reports that the identified PR is **merged**, only then proceed with the ordinary new-branch flow from a freshly fetched `BASE_SHA`. If no matching PR exists in the chat context or provider, use the ordinary new-branch flow.
- If chat context, provider state, branch name, or repository identity disagree, stop and report the mismatch. Never resolve the ambiguity by creating a new branch.

### Starting a new branch with `start pr` (`new pr` alias)

Use the new-branch question only after [Existing PR continuation](#existing-pr-continuation) confirms that no matching unmerged PR exists. The user must choose where the new branch will live; do not infer that choice from the source checkout, tool availability, or a dirty primary checkout.

There are two possible homes:

- **Primary checkout:** `PRIMARY_PATH`. It may be used after unrelated work is safely committed or stashed, and after another clean feature branch is parked if needed.
- **Managed worktree:** a plain Git linked worktree created or reused with `git worktree` at the derived path in [Worktree paths](#worktree-paths). The user does not choose its filesystem path. Before creating one, inspect `git worktree list --porcelain` and prefer a reusable candidate that is present, non-primary, detached, clean including untracked files, and not in use by another operation. Detached worktrees and clean checkouts left after closed or merged PRs are valid reusable candidates; their prior branch or PR state does not disqualify them. Re-verify the candidate immediately before use; create a new managed worktree only when no safe candidate exists.

If the request names an existing checkout because it contains code to reuse, that checkout is the **source**. It is not automatically the home for the new branch. Keep those two paths separate in the question and in the execution.

Use these simple rules to build the one question. Every option must be a separate selectable answer and must briefly say what it preserves or changes.

- If primary is clean and on the base branch, offer: **Use primary — create the new branch there**, **Use a managed worktree — leave primary untouched**, and **Cancel — change nothing**.
- If primary is clean but has another feature branch checked out, state whether that branch is raised, merged, closed, unraised, or unknown. Report an unavailable lookup as **PR state unknown**, never as unraised. Calculate the displaced branch's viable dispositions: for open/draft, offer **park it in a managed worktree** first and **keep its branch ref only** second when both are viable; for confirmed merged or closed, offer **keep its branch ref only** and do not create a worktree; for unraised, prefer branch-ref-only but show a viable managed worktree; for unknown, prefer a managed worktree but show branch-ref-only. If it is unraised, include raising it first or preserving it for later within the same choice.
- If primary is dirty and every dirty path belongs to this request, offer the same two homes, preserving and transferring only the request-owned paths as required. Do not remove primary just because it is dirty.
- If primary is dirty with unrelated paths and its current branch is a feature branch, calculate viable stash and commit preservation methods first. If committing is viable, commit the unrelated paths on their current feature branch. For each viable method, show the applicable displaced-branch disposition: open/draft or unknown may be **parked in a managed worktree** or **kept as a branch ref only**; confirmed merged or closed is **kept as a branch ref only**. Prefer stash over commit and managed worktree over branch-ref-only for an open/draft or unknown branch, but show every viable combination and Cancel.
- If primary is on the base branch and the request only copies implementation from a named source checkout while primary has unrelated dirt, offer exactly three short choices: **Use primary — stash the unrelated change, then copy only the identified implementation files**; **Use a managed worktree — leave primary untouched, then copy only the identified implementation files**; **Cancel — no changes**. Do not replace them with **Create branch and transfer code** / **Cancel**. Do not offer to commit work directly on the base branch.
- If ownership of any dirty path is ambiguous, offer only **Cancel — change nothing; classify the paths first**. Do not create a branch, worktree, commit, stash, or transfer files.

Do not use a source checkout as the destination unless the user explicitly chooses the managed-worktree home and `git worktree add` creates that destination at the derived path. A source path tells you where to copy from; it does not decide where the branch lives.

### Focusing an existing branch with `focus pr`

`focus pr` always moves the selected existing feature branch into the primary checkout. It does not create a branch and it does not choose a second home.

Never offer **create a managed worktree** or **keep it in the managed worktree** as a destination for the selected feature branch. **Cancel** is the only way to leave that branch where it is. A focus question may offer a managed-worktree disposition only for a different branch being displaced from primary. Never activate, create, or redirect to another checkout to satisfy the selected branch's `focus pr` destination.

Uncommitted edits do not travel with a branch. When the branch moves, edits left in its old checkout stay there. A stash is repository-wide, so a stash made in the feature checkout can be reapplied in primary after the move; plain uncommitted edits cannot follow by themselves. Explain this in the selected option's consequence.

Use these rules to build the one question. The destination is always primary; there is no worktree choice.

- If primary and the feature branch's source checkout, if any, are clean, offer: **Move the existing branch into primary** and **Cancel — leave the branch where it is**. A branch-ref-only feature has no source checkout to preserve and can be checked out directly in primary.
- If primary has another feature branch checked out, state whether that branch is raised, merged, closed, unraised, or unknown. Calculate its viable disposition instead of assuming parking: an open/draft or unknown branch may be **moved to a managed worktree** or **left as a branch ref only**, with managed worktree preferred; an unraised branch may use either with branch-ref-only preferred; a confirmed merged or closed branch is **left as a branch ref only**. The selected feature branch still moves into primary. If the displaced branch is unraised, include raise-first versus preserve-for-later in the same preservation choice, plus **Cancel — leave both branches where they are**.
- If primary has unrelated dirt and the feature checkout is clean, offer every viable primary preservation method—prefer stashing, then committing on its current feature branch—and combine it with each viable disposition of the displaced primary branch. Also offer **Cancel — preserve both checkouts exactly as they are**.
- If the feature checkout has feature-owned work and primary is clean, offer committing that feature work or stashing it and reapplying it in primary after the move. Also offer **Cancel — leave the branch and edits where they are**.
- If both primary and the feature checkout are dirty, preserve the two groups separately. Offer every viable combination of feature-work commit or stash and primary-work stash or commit, together with every viable displaced-branch disposition; prefer stash and managed worktree where applicable without hiding alternatives. Also offer **Cancel — change nothing**.
- If ownership is ambiguous in either checkout, offer only **Cancel — change nothing; classify the paths first**.

Cancel always leaves both checkouts, branches, and dirty files exactly as they are. Never commit unrelated work directly onto the base branch. If the feature is already in primary, show one confirmation that testing will proceed there and make no checkout change.

### Forbidden shortcuts

- Choosing a managed worktree just because primary is dirty.
- Treating the source checkout as the new branch's home without an explicit choice.
- Creating a new branch when the current chat already identifies an unmerged PR for the requested work.
- Offering only **Create branch and transfer code** / **Cancel**.
- Silently reusing an existing checkout instead of showing the primary choice. Reuse of a managed worktree is an internal implementation detail after the user selects the managed-worktree home; report the actual reused path afterward.
- Creating a new managed worktree before checking for a safe reusable detached one.
- Running `git worktree add` to a hand-chosen path instead of the derived path.
- Describing a reused worktree as a fresh branch location.
- Offering a second-home or keep-worktree choice during `focus pr`.
- Listing choices without saying what each one does.
- Running two questions, or no question, for one request.

## `start pr REQUEST` (`new pr` alias)

**First, perform [Existing PR continuation](#existing-pr-continuation).** Do not derive a branch stem or show a new-branch destination question until the chat/session context and provider state establish that no matching unmerged PR exists. A request to fix or extend work does not by itself authorize a sibling branch.

For a genuinely new branch, first resolve `AUTHOR_INITIALS` from the authenticated author's display name or configured `git user.name`, using the lowercase initials of the first and last name (`Ada Lovelace` → `al`). If the identity is unavailable or ambiguous, ask the user for the prefix; do not guess. Derive a two- or three-word lowercase kebab-case `BRANCH_STEM` from the request and set `BRANCH_NAME="${AUTHOR_INITIALS}/${BRANCH_STEM}"`. Every newly created branch must use this author-initials prefix; do not apply the old prefix-frequency heuristic. Inspect local `refs/heads/` names, not remote-tracking branches. Validate the complete `BRANCH_NAME` with `git check-ref-format --branch` and reject local or remote names that already exist.

1. Run the shared repository setup and record `BASE_BRANCH`, `BASE_SHA`, `PRIMARY_PATH`, and the remote used. Do this before selecting a destination or creating the branch.
2. Inspect the primary checkout's current branch and status before asking anything. Summarize staged, unstaged, and untracked paths; ignored output is not summarized. Clean status does not skip the confirmation.
3. If the primary checkout is dirty, run [Late-start recovery](#late-start-recovery-changes-made-before-the-pr-workflow-was-invoked) and classify every path before proposing a destination.
4. Ask the one `start pr` decision question using the three short paragraphs above and the matching prose rule. Wait for the answer.
5. Perform the preservation action the user chose:
   - **Commit the existing work** — use a concise descriptive subject derived from the branch and affected paths, such as `reporting: update search agent and design docs`; avoid process labels such as save or WIP. This authorizes staging those paths and a normal hook-checked commit without a second confirmation. The commit stays on the existing branch and is not inherited by the new branch.
   - **Stash the existing work** — include untracked files, omit ignored files unless requested, and use a clear message containing the branch stem. Keep the stash until the destination and source are both verified.
     Committed or stashed work is not included in the new feature branch. Re-run `git status` afterward and continue only when the chosen source is safe. Never use `--no-verify`.
6. If the primary checkout holds another clean feature branch and `primary` was chosen, inspect its associated PR state before displacing it and apply the disposition the user selected. Use [Parking a checked-out branch](#parking-a-checked-out-branch) only when managed-worktree disposition was selected. For branch-ref-only disposition, preserve the branch, detach or switch primary as needed, and create no worktree. Never auto-park an open, unknown, closed, or merged branch merely because primary is changing. An explicit `park pr` request always parks the selected branch, including a merged or closed PR, then restore primary to `BASE_BRANCH`.
7. Create the branch in the confirmed destination only:

   For a primary start, from `PRIMARY_PATH`:

```bash
git switch --create "$BRANCH_NAME" "$BASE_SHA"
```

For a managed start, inspect `git worktree list --porcelain` first. Reuse a clean detached worktree if one qualifies; otherwise run `git worktree add --detach --no-checkout "$WORKTREE_PATH" "$BASE_SHA"` at the derived path, never a user-named path, then apply the **seed** sparse shape per [Sparse managed worktrees](#sparse-managed-worktrees) before the first checkout so the full tree is never materialized. A reused detached worktree is reset to the seed shape with `git sparse-checkout set --cone <SUPPORT_PATHS>` only after it is verified clean. Then create the branch with `git -C "$WORKTREE_PATH" switch --create "$BRANCH_NAME" "$BASE_SHA"`. Verify ownership afterward with `git worktree list --porcelain`.

8. Transfer only the confirmed paths. When `SOURCE_PATH` is set, copy exactly those paths from it and change nothing inside `SOURCE_PATH`. Do not transfer unrelated or unclassified paths.
9. Verify before implementation changes: `git rev-parse "$BRANCH_NAME"` equals `BASE_SHA`, the branch has exactly one owning checkout, that checkout's path matches the confirmed destination, and every unrelated path is still preserved. Re-verify the actual checkout path after every branch/worktree operation.
10. Do not commit or push implementation changes automatically. Inspect the request's source and tests, implement it, and run focused validation.

Report the branch, the destination kind and its absolute path, `BASE_BRANCH@BASE_SHA`, any preservation record and where it remains, the `SOURCE_PATH` used, and the validation status.

### Provider lookups and quota

A failed provider lookup is never evidence that something does not exist. Absence of a PR may only be reported when a lookup actually succeeded and returned no PR. A lookup that is rate-limited, unauthorized, timed out, malformed, or errored yields **unknown**, and the command must expose that failure rather than silently continuing as if the PR were absent.

For GitHub, REST is the authoritative and required transport for every provider operation. Use `gh api` with bounded pagination and validate the response before using it:

1. **Identity and branch association — REST.** Use `gh api user --jq .login` and `gh api "repos/<owner>/<repo>/pulls?head=<owner>:<branch>&state=all&per_page=100" --jq '.[]|{number,state,draft,merged_at,url,head_sha:.head.sha,base_ref:.base.ref,base_sha:.base.sha}'`. A successful empty array means no PR; an error means unknown. Treat non-null `merged_at` as merged, `state: "closed"` with null `merged_at` as closed-unmerged, and `state: "open"` as open or draft according to `draft`.
2. **One PR’s state and mergeability — REST.** Use `gh api "repos/<owner>/<repo>/pulls/<number>"` and read `mergeable`, `mergeable_state`, `head.sha`, `base.sha`, `draft`, and `state`. GitHub may return `mergeable: null` while computing; poll with a bounded deadline when this fact is required. The resolved pair `mergeable: false` and `mergeable_state: dirty` is the REST conflict result. If the fields disagree or `mergeable_state` is missing, report the result as inconclusive and do not rebase. Do not treat `null`, `unknown`, `behind`, `blocked`, or a failing check as a merge conflict.
3. **Checks — REST.** Use both `gh api "repos/<owner>/<repo>/commits/<sha>/check-runs?per_page=100"` and `gh api "repos/<owner>/<repo>/commits/<sha>/status"`. Combine check runs and commit statuses by context, record each state, and classify the snapshot as terminal green, terminal failure, or inconclusive. No runs, missing permissions, a rate limit, or a malformed response is inconclusive or a provider failure; it is never green.
4. **Reviews and comments — REST.** Use all three of `gh api "repos/<owner>/<repo>/pulls/<number>/reviews?per_page=100"`, `gh api "repos/<owner>/<repo>/pulls/<number>/comments?per_page=100"`, and `gh api "repos/<owner>/<repo>/issues/<number>/comments?per_page=100"` on every sweep; the second is inline-only, and the third holds the PR-level conversation ([Three comment sources, one inventory](#three-comment-sources-one-inventory)). REST review comments do not expose every GraphQL thread-resolution field, so inspect all returned comments, use `in_reply_to_id` and comment chronology, and mark resolution as unknown when REST cannot prove it. Classify every actionable item by author and ambiguity: recognized bot findings and clearly mechanical human requests may be automatic; non-trivial human requests require the batched approval gate in [`fix pr`](#fix-pr). Never silently skip a comment because GraphQL is unavailable.
5. **PR writes and replies — REST.** Create with `POST /repos/<owner>/<repo>/pulls`, update with `PATCH /repos/<owner>/<repo>/pulls/<number>`, reply to a review comment with `POST /repos/<owner>/<repo>/pulls/<number>/comments/<comment_id>/replies` (the PR number is required; the shorter `pulls/comments/<id>/replies` form returns 404), and post an issue-level reply with `POST /repos/<owner>/<repo>/issues/<number>/comments`. Validate each response and report its URL or number.
6. **Batch inventory — REST.** Use bounded, author-filtered REST listing and paginate deliberately. Do not replace it with an unbounded search or a GraphQL query that hides pagination or author filtering.
7. **Optional fallback — GraphQL only after REST failure.** GraphQL may be attempted only for the same operation when a tested equivalent exists. A GraphQL quota, authorization, timeout, or schema error must not affect a successful REST result. If REST fails and no tested GraphQL equivalent exists, record GraphQL as `unavailable — no tested fallback` rather than inventing a query. If REST and the fallback both fail, emit `PROVIDER_OPERATION_FAILED: <operation>; REST: <cause>; GraphQL: <cause>` and stop the provider-dependent command. Capture each command's exit status and stderr; never use `|| true`, discard errors, or treat empty output as success. Do not convert the failure to “unknown” without the loud error.
8. **Never poll a provider in a tight loop.** Reuse an already-fetched snapshot within a phase, and when waiting on checks, wait between bounded polls rather than re-querying continuously.

### Rate-limit recovery

For active `fix pr` and `fix all` runs, a confirmed GitHub API rate limit is a retryable wait, not a terminal provider failure.

1. Treat only HTTP 429 or HTTP 403 whose response explicitly identifies a primary/secondary rate limit as rate-limited. Use response text or headers such as `X-RateLimit-Remaining: 0` and `Retry-After` to distinguish it from permission or authorization errors. Do not retry a generic 401/403, malformed response, or unrelated provider error as a rate limit.
2. Preserve the exact failed operation, endpoint and parameters, page/cursor, PR number, pinned head SHA, response, and any `Retry-After` or `X-RateLimit-Reset`. Keep the provider sweep incomplete. Do not treat partial or empty data as complete/green, and do not rebase, edit, create a deferred sparse worktree, commit, push, or reply using an incomplete snapshot.
3. Honor `Retry-After` and `X-RateLimit-Reset`; never retry early. If neither gives a retry time, wait 60 seconds, then retry the exact failed operation. If the allowed retry time is farther away, wait in chunks of at most 60 seconds but do not call GitHub before that time. If the retry is still rate-limited, record the new wait information and repeat. Do not issue unrelated provider calls during the cooldown.
4. Do not invent a GraphQL query or switch transports just to evade a rate limit. Use a GraphQL fallback only when the existing tested-fallback rule above permits that exact operation.
5. While a `fix pr` or `fix all` invocation remains active, keep waiting and retrying with no fixed attempt count until the operation succeeds or the user stops the run. In `fix all`, preserve the ordered queue and resume the same incomplete operation; do not abandon the run or restart its inventory because of a rate limit. If the host ends the run, report `RATE_LIMIT_WAITING`, the operation, PR/head, next allowed retry time, and exact resume point.

For a required mutating operation, an unresolved non-rate-limit provider failure is a hard stop before mutation. A confirmed rate limit in an active fix command follows [Rate-limit recovery](#rate-limit-recovery); keep required reads incomplete until retry succeeds. For `raise pr`, a push may already be irreversible; report `PUSH_SUCCEEDED` separately, then fail loudly because PR creation/update was not verified. For read-only `ls pr`, show local results only after emitting `PROVIDER_OPERATION_FAILED` with the exact operation error; never claim that no PR exists. Report provider reset times when supplied.

### Parking a checked-out branch

When a branch currently checked out in the primary checkout must be displaced by `start pr` or `focus pr`, first inspect its associated PR state, following [Provider lookups and quota](#provider-lookups-and-quota). This section describes the managed-worktree execution only after that disposition was selected; automatic displacement must not silently choose it. For an open/draft PR, offer managed worktree first and branch-ref-only second when both are viable. For an unraised PR, offer branch-ref-only first and managed worktree second; for unknown state, offer managed worktree first and branch-ref-only second. For a confirmed merged or closed-unmerged PR, leave the branch ref intact and detach or switch primary after preservation without creating a worktree. An explicit `park pr` request overrides these automatic-displacement preferences and must create/reuse a managed worktree for the selected branch. Preserve the branch and its selected current checkout disposition without racing Git's worktree ownership checks:

1. Reuse a suitable clean detached managed worktree if one is available; otherwise create one with `git worktree add --detach "$WORKTREE_PATH" "$(git rev-parse "$EXISTING_BRANCH")"` at the derived path. Do not create a new branch.
2. In the primary checkout, run `git switch --detach HEAD` only after the user's chosen preservation action and explicit decision. This frees `EXISTING_BRANCH` without changing its commit.
3. Run `git -C "$WORKTREE_PATH" switch "$EXISTING_BRANCH"` only after `git worktree list --porcelain` shows the branch has no other checkout owner.
4. Verify with `git worktree list --porcelain` that the managed worktree owns `EXISTING_BRANCH` and primary is detached or on `BASE_BRANCH`.
5. Reduce the new checkout to its branch-scoped sparse path set per [branch-scoped sparse worktrees](#branch-scoped-sparse-worktrees). This applies whether or not the branch has a PR; the scope comes from the branch's merge-base diff against its base.

### Sparse managed worktrees

Every managed worktree is an ordinary Git linked worktree whose working directory is reduced with cone-mode sparse-checkout. It is not a clone and does not copy history; the object store and full history are shared. There are two shapes, and both grow on demand:

- **Seed** — for a branch with no changes yet (`start pr` into a managed worktree). `SPARSE_PATHS = SUPPORT_PATHS`. Cone mode always includes root-level files, so manifests, lockfiles, hook configs, and `AGENTS.md` are present. Create the worktree with `--no-checkout`, apply the seed paths, then check out, so the full tree is never materialized.
- **Branch-scoped** — for an existing branch (`park pr`, and `fix pr`/`fix all` when the branch has no local checkout). `SPARSE_PATHS` = directories of the branch's changed paths plus `SUPPORT_PATHS`. See the next section.

The same algorithm is implemented for human use in `tools/dev/sparse-branch.sh --min`; this skill performs the equivalent Git commands directly so it never depends on a repository-specific helper. Running that script is permitted when the user asks for it.

### Branch-scoped sparse worktrees

A branch-scoped sparse worktree is the default checkout shape for any existing feature branch that lives outside primary, raised or not. Its scope is the branch's diff against its base, computed locally; a PR is never required to build it.

**Build `SPARSE_PATHS`:**

1. Resolve `SCOPE_BASE`: the PR's provider-declared base branch when a PR exists (`PR_BASE_BRANCH`), otherwise the default base (`BASE_BRANCH`). Fetch it, then run `git diff --name-only --no-renames -z "$(git merge-base "origin/$SCOPE_BASE" "$BRANCH_NAME")" "$BRANCH_NAME"`. The merge-base diff naturally includes changes inherited from parent branches in a stack; that superset is acceptable. When a PR exists, the provider file list (`gh api "repos/<owner>/<repo>/pulls/<number>/files?per_page=100"`, paginated) may be used as a cross-check but never as the only source. If the diff cannot be computed, record `SPARSE_PATHS = unknown`, create a seed sparse worktree instead, grow it on need, and report why. Never guess paths.
2. Use cone mode. Add the narrowest directory that contains each changed path; for a deleted or renamed-away file, add its former parent directory so the deletion is visible in the tree. Collapse a directory whose parent is already selected.
3. Add `SUPPORT_PATHS`. Do not add dependency trees; they are ignored paths and are linked, not checked out.
4. Record `SPARSE_PATHS` with `SCOPE_BASE` and the branch head SHA it was derived from, in `<git-dir>/info/branch-sparse-checkout`. If the branch head moves before the paths are applied, recompute; never apply a stale set.

**Create it:**

1. Create or reuse a managed worktree with `git worktree add --detach --no-checkout "$WORKTREE_PATH" <branch head sha>` at the derived path. Never create a duplicate branch: if the local branch is missing, fetch the branch and create a local tracking branch only after confirming it is not checked out elsewhere; if a PR head lives in a fork, stop and report rather than inventing a remote.
2. Apply sparse-checkout inside that worktree only. Sparse patterns must be worktree-local: verify `extensions.worktreeConfig` is enabled, or enable it with Git's documented `git sparse-checkout` initialization in that worktree, and confirm that primary's `core.sparseCheckout` setting and sparse-checkout file are unchanged afterward. If isolation cannot be verified, do not apply patterns; stop and report rather than materializing a full checkout silently. Then run `git sparse-checkout set --cone <SPARSE_PATHS dirs>` and `git -C "$WORKTREE_PATH" switch "$BRANCH_NAME"`.
3. Verify before use: the branch has exactly one owning worktree in `git worktree list --porcelain`; `git sparse-checkout list` matches `SPARSE_PATHS`; every changed path exists in the working directory, or its parent for a deletion; `git status --porcelain` is clean; and primary is unchanged.
4. Front-load the guarded dependency symlink from [`raise pr`](#raise-pr) step 5 exactly as for any new managed worktree.

**Working inside any sparse managed worktree (seed or branch-scoped):**

- Code that is not materialized is still in the object store. Search or read it with `git grep PATTERN HEAD -- <path>` or `git show HEAD:<path>` rather than concluding it does not exist. Filesystem-wide searches return partial results; say so when a diagnosis depends on them.
- Before editing a path outside `SPARSE_PATHS`, run `git sparse-checkout add <dir>` in that worktree and record the addition. Never commit a path that was not materialized and reviewed.
- Expand on need, not in advance. If a hook, generator, focused test, or fix needs more of the tree, add the narrowest directories and retry. If the needed set grows to most of the repository, run `git sparse-checkout disable` in that worktree to make it a full checkout and report the change.
- Never claim validation passed when its inputs were not materialized. If a required test cannot run in the sparse set and expanding it is impractical, report that limitation; do not mark the PR green.
- `focus pr` moves the branch back to primary, which is a full checkout, so the sparse state never follows the branch. `clean pr` removes a merged PR's sparse worktree like any other managed worktree.
- **Backward compatibility.** An existing full managed worktree stays valid; do not re-shape it unless the user asks. A branch that has only a branch ref (for example, one displaced from primary by a later `start pr`) is revived by `fix pr` or `park pr` into a branch-scoped sparse worktree at that moment, never earlier.

## Late-start recovery: changes made before the PR workflow was invoked

Apply this whenever an implementation request arrives after files were already changed, whether or not the user remembers making them:

1. **Freeze the workspace.** Do not edit more files, switch branches, create a branch, commit, stash, or create a worktree until the current state is recorded.
2. **Inventory the complete state.** Record the current branch and `HEAD`, worktree ownership, staged paths, unstaged paths, untracked paths, affected ignored paths, and any existing stash or patch record.
3. **Partition ownership.** Show a concise path-level summary and classify each path or coherent patch as `existing branch`, `new request`, or `ambiguous`. Preserve partial staging boundaries; do not collapse unrelated changes into one group.
4. **Choose one safe outcome:**
   - **Existing branch work:** preserve or commit only those paths on the existing branch. They must not be inherited by the new branch.
   - **New request work:** preserve them, record a fresh `BASE_SHA`, create the new branch there, then apply only those paths.
   - **Mixed work:** preserve each group separately, park the old branch if necessary, create the new branch from `BASE_SHA`, and transfer only the new-request group.
   - **Ambiguous or unsafe split:** change nothing and ask for a narrower classification.
5. **Use reversible preservation.** Prefer a named, verifiable stash or patch plus an explicit list of untracked files. Do not use `git stash pop` or delete a preservation record until the destination diff and source status are verified.
6. **Verify the result.** Re-check branch ancestry, `NEW_BRANCH == BASE_SHA` before new commits, worktree ownership, source and destination status, and every path's disposition. Report any path that was not transferred.

Never use `git switch -c`, `git checkout -b`, or a native branch-creation operation from the current feature branch as a shortcut during late-start recovery. A stacked branch is allowed only when the user explicitly asks for it, names the parent branch, and confirms that inheritance is intended.

## `focus pr`

`focus pr` is the explicit move into primary. It does not imply that the host runs tests automatically.

1. Identify the selected feature branch from an explicit PR or branch, the current working directory's worktree, the primary checkout, or a local branch-ref-only inventory. If it is ambiguous, show the available local feature branches and ask the user to choose; do not guess.
2. If the feature branch is already in primary, inspect its status and show exactly one confirmation that no transfer is needed; leave the checkout unchanged after confirmation.
3. If it is in a managed worktree, inspect both checkouts before asking anything. Record branches and staged, unstaged, untracked, ignored, and partially staged paths. Run commands against the worktree that owns `BRANCH_NAME` with `git -C <path>`. If the branch is branch-ref-only, record that it has no source checkout and inspect primary without inventing one.
4. Ask exactly one `focus pr` question. The destination is always primary. Never offer another destination or a keep-managed-worktree choice.
5. Preserve classified work with the selected commit, selective stash/patch, or cancel outcome. If either checkout has ambiguous ownership, offer only cancellation and change nothing.
6. Before moving the selected branch, inspect the displaced branch's associated PR state and apply the disposition the user selected. Use [Parking a checked-out branch](#parking-a-checked-out-branch) only when managed-worktree disposition was selected. For branch-ref-only disposition, preserve the displaced branch, detach or switch primary as needed, and create no worktree. Never auto-park an open, unknown, closed, or merged branch merely because the selected branch is moving in. An explicit `park pr` request always parks the selected branch, including a merged or closed PR. Preserve primary work separately; never commit unrelated work onto the base branch.
7. If `BRANCH_NAME` owns a managed worktree, run `git -C <path> switch --detach HEAD` there first, then switch primary to the existing branch only after `git worktree list --porcelain` confirms ownership is free. If it is branch-ref-only, skip the detach and switch primary directly after the selected preservation actions. Verify that the selected branch has exactly one owner in primary and the displaced branch has the selected zero-or-one-owner disposition.

Uncommitted edits do not travel with a branch. A repository-wide stash made during the confirmed operation must be reapplied only where the question says it will go; never blindly pop it. `focus pr` does not commit implementation changes, push, create a PR, or automatically move the branch back.

## `park pr`

`park pr` is the explicit move out of primary. It moves the selected feature branch into a managed worktree and frees primary; it does not commit, push, or alter the PR.

1. Identify the selected branch from the current working directory's checkout, the primary checkout, or an explicitly named PR/branch. Use `ls pr` when the target is ambiguous; never guess.
2. If the branch is already in a managed worktree, report its exact location and make no changes.
3. If the branch is in primary, inspect primary completely before asking anything. Inventory staged, unstaged, untracked, ignored, and partially staged paths and classify ownership.
4. Ask exactly one `park pr` question before any mutation. The destination is always a managed worktree, so choices cover only preservation of confirmed primary work or cancellation. Do not offer another destination.
5. Reuse a present, detached, clean, available managed worktree before creating one. Re-verify it immediately before use. Never use a source checkout or hand-named path as the destination.
6. Preserve confirmed primary work, detach or restore primary to the recorded base branch without changing the feature commit, check out the existing feature branch in the managed worktree, and verify exactly one owner.
7. Reduce the managed worktree to its `SPARSE_PATHS` per [branch-scoped sparse worktrees](#branch-scoped-sparse-worktrees). This does not depend on PR state: an unraised branch is scoped by its diff against the default base, and a raised branch by its diff against the PR base. Sparse reduction is part of the parking action already confirmed; do not ask a second question for it.

If primary contains ambiguous work, stop with cancellation. If no safe managed destination exists, create one with `git worktree add` at the derived path only after the preservation decision. Report the worktree path, whether it is sparse and its `SPARSE_PATHS`, primary's final branch/status, and the unchanged feature commit.

## `ls pr`

`ls pr` is a fast, read-only local workspace triage view. `pr ls` and `list pr` are aliases.

Default behavior is local-first and bounded:

1. Inspect the current repository's primary checkout and `git worktree list --porcelain`. Run independent local status checks in parallel when possible. Do not enumerate remote branches, merged or closed PR history, every local branch, or ignored files unless they affect a specific cleanup decision.
2. For GitHub repositories, identify the authenticated GitHub login first, using the low-cost REST identity endpoint (`gh api user --jq .login`), then make one bounded REST search request for the current repository, using an explicit login in the server-side query: `repo:OWNER/REPO is:pr is:open author:LOGIN`. For another provider, use its equivalent bounded author-filtered query and do not invoke GitHub-specific commands. Draft PRs are open PRs and must be split into the draft section locally. Prefer `gh api --method GET search/issues -f q=... -f per_page=100` or `gh search prs --author=@me`; never use the literal `author:me` inside `gh pr list --search`, which can return an empty result. Never fetch all PRs and filter them afterward. If the provider cannot enforce the author filter, omit provider PR rows and report that limitation; never show another contributor's PR. Correlate a PR number, title, draft state, branch, and checkout only for the filtered results. If the provider is slow, unavailable, or rate-limited, finish the local view and mark PR association unknown with the error; never convert a provider failure into “no PRs.”
3. Render these nonempty sections in this order: **OPEN PRs — ready for review**, **DRAFT PRs**, **LOCAL WORK NOT IN A PR**, then **Summary**. For every open or draft PR, render one compact row in this order: **linked `#number — title/what it does` · branch · worktree · status**. Link the PR number/title to its full provider URL; if the URL is unavailable, say `PR link unavailable` rather than emitting an unlinked PR row. Use the provider title first; when it is only a branch-like label or too vague, use a one-line PR body summary or latest commit subject from the same bounded result. If no meaningful description is available, say `purpose unknown` rather than inventing one. “Ready for review” means open and not draft; it does not claim that checks pass.
4. Under **LOCAL WORK NOT IN A PR**, use these categories: **Raise candidates** for clean branches with commits ahead of base; **Pending changes** for uncommitted files; **Committed plus pending** for branches with both commits and uncommitted files; **Cleanup candidates** for clean worktrees with no unique commits to preserve; and **Detached or damaged** for detached, dirty, missing, stale, orphaned, duplicate-owner, or provider/Git-mismatched worktrees. For each row show the branch, checkout, clean/dirty state, pending-file count, commit delta when relevant, and a safe next action. When a short description is useful, read only the latest local commit subject in parallel; do not search remotely or invent a description.
5. Keep the output to the primary row, compact linked open/draft rows, at most ten attention rows, and summary counts. Hide clean parked worktrees and inactive branches behind counts. Use dot-separated metadata rather than labels such as `Branch:` or `Worktree:`. Status must include clean/dirty and pending-file count when available; use `no local checkout` when no checkout is found.
6. Do not activate, switch, create, park, focus, commit, stash, push, delete, or update anything. If the repository cannot be resolved, report the limitation instead of guessing. A broader provider or historical search requires an explicit separate request.

### Explicit full-inventory mode

When the user asks for a **final list**, **full inventory**, **complete PRLS**, **all categories**, or equivalent exhaustive output, switch from the bounded scan to a detailed, read-only inventory. This mode may be slower and may enumerate provider and local history, but it must remain safe and must never mutate anything.

1. State a snapshot line with counts for open PRs, drafts, relevant closed PRs, potential PR candidates, pending worktrees, cleanup candidates, and worktrees to preserve. Do not claim completeness if a provider, remote, or local source could not be enumerated.
2. Enumerate the requested repository's open and draft PRs, correlating each branch with its title, URL, checkout, and clean/dirty state. Group long PR lists under short topic headings inferred from titles or branch names; use **Other** when no reliable grouping exists. Do not invent project categories.
3. Include relevant closed PRs only when their branch or checkout still exists locally, or when they explain a local cleanup/candidate decision. Mark them as closed and explain why they are or are not an unraised candidate.
4. Inventory local work not associated with an open/draft PR under separate headings: **Clean, but stale against `BASE_REF`**, **Pending edits — review before raising**, **Committed plus pending**, and **Potential PR candidates**. Show unique commit counts, behind counts when the base can be measured, pending-file counts, latest local subject, and a safe next action.
5. Inventory **Cleanup candidates** separately, including clean worktrees with no unique commits, merged-PR leftovers, missing/orphaned worktrees, and detached worktrees duplicating an active PR. Never call a worktree safe to delete when it is dirty, unreferenced, ambiguous, or still needed for recovery.
6. Inventory **Preserve — do not delete** items separately. Include detached or orphaned commits, dirty worktrees, untracked paths, partial staging, and any work whose ownership is uncertain. List an ignored path only when it holds irreplaceable local state, never for dependency trees, build output, or caches. Explain the preservation reason and latest known work.
7. End with **Other local refs**, including counts for unchecked-out branches, unique commits, deleted remote tracking, backup prefixes, and any other relevant ref class. Hide no category merely because it is empty; show zero counts in the snapshot when useful.
8. Keep each row concise and group long sections into sub-bullets. Use full PR URLs and file links when they make the inventory actionable. Distinguish observed facts from unknown or unverified associations.

`ls pr` remains read-only in full-inventory mode. The mode changes reporting breadth only; it never authorizes cleanup or other Git/provider mutations.

## `raise pr`

`raise pr` is the publish-only PR handoff. It commits confirmed implementation paths, pushes the branch, and creates or updates the PR. It never changes the branch location and never opens a post-raise location dialog.

1. Identify the feature branch and its checkout. Stop if it is the base branch. If the feature is in a managed worktree, run every command against that exact path (`git -C`) before reading or changing files.
2. Before staging or committing, read the applicable repository instructions: `AGENTS.md`, contributor/style guides, code-generation instructions, formatter/linter configuration, and relevant package or directory guidance. For generated code, identify the source-of-truth and required generator; never review or publish generated output in isolation.
3. Inspect status and classify every changed path. If any path is unrelated or ambiguous, stop; do not stage the whole worktree. Review the complete diff against the loaded instructions, correct confirmed style or code-generation violations within owned paths, and stop if a required change has ambiguous ownership.
4. Run the relevant formatter, linter, typecheck, generator validation, and focused tests. Perform a final self-review of the resulting diff for instruction/style compliance before creating the commit. Then run [`references/pre-raise-review.md`](references/pre-raise-review.md) on the full diff and include its eleven verdict lines in the step 10 report; carry `open` items into the PR's known limitations. Do not raise while known violations or unreviewed generated changes remain.
5. If a required hook or validation tool fails only because a managed checkout lacks its dependency tree (for example, a missing `node_modules/<package>/bin/<tool>`), provision that checkout's own dependencies. This also runs proactively right after a worktree is created, per [Non-negotiable invariants](#non-negotiable-invariants), where only the cheap symlink is front-loaded and a full install is deferred to first need. Provisioning a checkout's dependency root is setup, not a source edit: a repository rule that forbids creating or editing files inside an ignored directory such as `node_modules/` forbids authoring content in it, and does not forbid installing or linking the tree itself. Never create, edit, or patch individual files inside a dependency tree.
   - Preserve normal hook enforcement; never use `--no-verify`.
   - Prefer a host-provided managed-checkout setup or dependency-provisioning capability when one exists, because it reproduces the project's expected layout.
   - Otherwise identify the dependency root from the failure and the corresponding root in `PRIMARY_PATH`. If the worktree's dependency root is absent, the primary dependency root exists, the project manifest and lockfile inputs match between the two checkouts, and the target path is ignored or otherwise untracked, create an absolute symlink from the managed dependency root to the primary dependency root. This is the cheapest fix and is the expected first attempt for a missing hook or test binary. Do not replace a non-empty directory, a tracked path, or a dependency tree whose inputs differ.
   - A failure may name a nested root, such as a workspace package's own `node_modules`. Link the exact root the failure names, then re-run and link the next named root if another one is missing.
   - Verify the symlink resolves to the intended primary path and that the exact missing executable is now present. If the roots or inputs do not match, install dependencies in the managed checkout with the repository's package manager instead.
   - A borrowed tree in a workspace or monorepo may resolve workspace packages back to `PRIMARY_PATH`. If validation must compile the managed checkout's own workspace sources, or a failure shows imports resolving into the other checkout, install in the managed checkout instead of borrowing.
   - Retry the exact failed hook or validation once after this bootstrap. Report the dependency reuse or installation and its verification; a hook failure remains a blocker if the retry fails. Do not stop and report a missing dependency tree as a blocker until both provisioning paths have been attempted.
6. Stage only confirmed implementation paths and create one normal hook-checked commit. Never use `--no-verify`.
7. Push the feature branch to the intended remote with upstream tracking.
8. Use the provider adapter to create or update the PR with the change, validation status, and known limitations. For GitHub, use the REST create/update endpoints in [Provider lookups and quota](#provider-lookups-and-quota); do not invoke `gh pr create` or `gh pr edit` as a hidden GraphQL dependency. If the provider operation fails, follow the loud dual-transport failure rule and report the pushed branch separately without claiming a PR was created or updated.
9. Leave the branch in exactly the checkout where `raise pr` found it. Do not activate, create, detach, switch, park, or clear a worktree as an implicit consequence of raising.
10. Report the branch, PR URL when available, validation status, instruction/style review performed, current checkout, `BASE_BRANCH@BASE_SHA`, and primary status. Mention once that `park pr` moves the branch into a branch-scoped sparse worktree and frees primary when the user is done testing there; do not ask.

If the PR is raised from primary, primary remains on the feature branch so the user can keep testing it there. If it is raised from a managed worktree, primary remains untouched. `fix pr` operates in the branch's owning checkout, including primary; use `park pr` explicitly when the branch-scoped sparse worktree location is wanted.

## `fix pr`

`fix pr` gets an existing PR merge-ready. It never merges. Before changing the branch or its files, it captures the CI/check snapshot and failure details for the current head, the complete review/comment inventory, and the provider's mergeability result. It rebases only when the provider reports a conflict (or, inside `fix all`, when [Stack trickle-down](#stack-trickle-down) applies), and only onto the exact branch named by the PR's declared base, freshly fetched from that base repository. For a non-stacked PR this is usually the advertised default branch; for a stacked PR it is the parent PR's head branch. For GitHub REST, the resolved pair `mergeable: false` and `mergeable_state: dirty` is the conflict result; `CONFLICTING` is only the optional GraphQL enum and is never required. After a conflict rebase, it refreshes comments and checks for the new head, then addresses review feedback and actionable CI failures. It pushes verified fixes, replies to each addressed comment immediately after that push, and, as a single command, waits for the provider's post-push checks to reach a conclusive green state before it can finish; inside `fix all` that wait is replaced by the next scan. Running, pending, unknown, unavailable, or rate-limited checks are inconclusive—not green. Any review fix, conflict resolution, merge update, or later push can invalidate an earlier green result, so the final check wait is always the last workflow phase.

### Three comment sources, one inventory

A PR's feedback lives in three places, and a run that reads only one of them has not read the PR. Every `fix pr` and `fix all` sweep must fetch, list, and classify all three, with the same rules, before any review-driven change:

1. **Inline review comments** — `pulls/<number>/comments`: threads anchored to a file and line.
2. **PR-level comments** — `issues/<number>/comments`: the conversation tab. Reviewers and bots (summaries, "please also…", "can you split this", a failing-check explanation) post here with no file or line.
3. **Review bodies** — `pulls/<number>/reviews`: the text a reviewer writes when submitting a review, which is not in either list above. An empty `APPROVED` or `COMMENTED` review carries no request; a non-empty body is a comment like any other.

Rules:

- **Count, then classify.** The inventory records a count per source — `inline N · PR-level N · reviews N` — and a per-source count of zero is a result to print, never an omission. If a source could not be read, the sweep is incomplete; say so and stop before mutation, as for any other provider failure.
- **No source is second-class.** A PR-level comment or review body is classified exactly as an inline comment is: automatic, approval required, or deferred. Its lack of a file and line is not a reason to skip it, defer it, or treat it as context. If it asks for a change anywhere in the PR, it is actionable.
- **PR-level "open" test.** With no thread structure, a PR-level comment or review body is open when the author has not posted a PR-level comment or review after it. A later inline reply does not close a PR-level request.
- **Reply in kind.** An inline comment gets a threaded reply; a PR-level comment or review body gets one issue comment that quotes or names what was addressed (see [Reply right after the push](#reply-right-after-the-push)).
- **Board it.** When the run addresses or defers items, the action line and status row say the source when it is not inline, for example `replied to 2 inline + 1 PR-level`.
- `tools/sweep.py` implements this inventory for `fix all`: every open item from all three sources is listed in `open_bot` / `open_human` tagged with `kind: inline | issue | review`. Do not use a sweep or an ad-hoc query that lists only `pulls/<number>/comments`.

### Review-feedback approval gate

`fix pr` must inspect and classify every actionable review comment — inline, PR-level, and review body — before making review-driven changes. The command itself authorizes these automatic items:

- **Automatic:** recognized bot findings with a deterministic fix, and human comments that are clearly trivial and mechanical, such as an obvious typo, formatting correction, or narrow naming change with no behavior or design choice.
- **Approval required:** any human request with ambiguity, a behavior/API/design trade-off, broad scope, security or data implications, or a non-obvious test or architecture change. If classification is uncertain, require approval.
- **Deferred:** already addressed, duplicate, non-actionable, or unresolved-thread items whose state cannot be proved. Do not change or reply to these items.

For every approval-required item, prepare one numbered entry containing all of the following before mutation:

1. **Comment:** the author, location, and the complete comment or a faithful excerpt.
2. **Proposed change:** the files and concrete implementation or test change to make.
3. **Draft reply:** the exact reply to post after the change, with placeholders only for the final commit, PR link, and verified validation evidence.

Before drafting the proposed change, map the comment to its item in [`references/pre-raise-review.md`](references/pre-raise-review.md) and check the rest of the diff for the same pattern; the proposed change covers the sibling cases, not only the line the comment is on.

Collect every approval-required item first and show them as one batch. Repeat the three fields for item 1, item 2, item 3, and so on; never ask one question per comment. Then ask through the host's interactive question tool (for example `ask_clarifying_question`), not by requesting a typed phrase: `Approve the N review changes above?` with the options **Approve all**, **Approve some — I'll say which**, and **Defer all for now**. Stop and wait for the answer before changing code, committing, pushing, or replying for those items. **Approve all** approves every numbered item; after **Approve some**, operate only on the items the user names and leave the others deferred; **Defer all** makes no review-driven change and records every item as deferred. Any free-text answer that clearly approves (for example "go ahead", "yes", "do it") counts as **Approve all**; never require an exact phrase. Automatic items may proceed without this gate, but the classification must be complete before review mutations begin.

### Status board

`fix pr` and `fix all` report with a **status board**: a numbered list where every row is one PR, one plain-English status, what was done, and what happens next. A reader who has never seen this skill must be able to tell, from one row, whether the PR moved and whether anything is expected of them. No stage checklists, no symbol-only rows, no cards for polls.

```text
**fix all · pass 2 · 14:07** — 6 ready PRs: 2 pushed (CI running), 1 waiting on you, 1 CI infrastructure, 2 nothing to do · 3 drafts skipped
Since last board: pushed #1234 (a1b2c3d) and replied to 3 comments · rebased #1240 onto it · asked you about 2 review changes on #1198

1. [#1234 — Short title](https://github.com/OWNER/REPO/pull/1234) — **PUSHED a1b2c3d, CI running** · fixed 1 failing test and 3 bot comments; replied to 3 · next: read CI on the next scan
2. [#1240 — Child of 1234](https://github.com/OWNER/REPO/pull/1240) — **WORKING** · rebased onto #1234; moving 2 inline imports · next: push and reply
3. [#1198 — Other fix](https://github.com/OWNER/REPO/pull/1198) — **WAITING ON YOU** · 2 review changes need approval (question above)
4. [#1203 — Twilio default](https://github.com/OWNER/REPO/pull/1203) — **CI INFRASTRUCTURE, rerun requested 14:02** · compat harness got a 404 on test data, not this PR's code · next: read the rerun on the next scan
5. [#1190 — Endpoint](https://github.com/OWNER/REPO/pull/1190) — **GREEN, needs reviewer** · nothing for me to do
Drafts skipped (3) — say `fix all drafts` to include them.
```

**Status words.** Use exactly these, in bold capitals, and nothing else:

- **NEXT** — queued for work; one clause saying why it needs work.
- **WORKING** — being fixed now; name the fix in progress.
- **PUSHED <sha>, CI running** — fixes are pushed and replies are posted; only CI is left. Do not poll it; read it on the next scan.
- **WAITING ON YOU** — a question is open above; say which one.
- **WAITING ON #N** — a stacked child whose parent has not been pushed yet in this pass.
- **GREEN, needs reviewer** — checks are terminal; only a person can move it. Nothing for the run to do.
- **CI INFRASTRUCTURE, rerun requested <time>** — the failure is not this PR's code (a download 404, a lost runner, a timeout, an external service); one rerun was requested.
- **BLOCKED — <reason>** — cannot proceed without the user; name the exact reason and the next action the user can take.
- **GREEN** — nothing to do.
- Drafts are one count line, not rows, unless the user opted in.

**Rules.**

- Every row is a Markdown link to the provider URL (`html_url` from REST); never a bare `#1234`. If the URL is unavailable, write `PR link unavailable (#1234)` and the cause.
- Print the board only when at least one row's status changed, and open it with a `Since last board:` line naming what changed. Never print the same board twice. Never print a board, a row, or any line for a CI poll.
- Between boards, when the run does something to a PR, print one **action line**: `#1234 → pushed a1b2c3d: config key + 2 test fixes` · `#1234 → replied to 3 comments` · `#1203 → rerun requested (compat 404)` · `#1240 → rebased onto #1234 (a1b2c3d)`. One line per action; no stage names.
- If one step runs longer than about two minutes with nothing to show (a long test, a hook install), print one line saying what is running and in which checkout.
- `fix pr` for a single PR uses one row plus action lines and finishes with one line: `**Done:** pushed a1b2c3d · replied to 3 · CI green` or `**Blocked:** <reason> → <what you can do>`.
- When the loop has nothing actionable, print `**Waiting:** nothing to do until CI or a reviewer moves · scanning every 60s` once, then stay silent until a status changes.
- Never show counts of ignored files, internal labels (`INITIAL_HEAD_SHA`, `PR_BASE_SHA`), or raw JSON.

### Reply right after the push

Replies are part of the fix, not a reward for a green run. The moment a commit that addresses a comment is pushed, post the reply for that comment; never hold replies until CI finishes, and never ask a separate question about posting them.

- **Automatic items** (recognized bot findings, trivial human comments): the `fix pr` / `fix all` command authorizes both the fix and the reply. Post the reply immediately after the push that contains the fix.
- **Approved items**: the approval batch already showed the draft reply, so approval covers posting it. Post it immediately after the push, filling in only the commit link and the validation evidence.
- **Content**: one or two sentences — the fix in plain words and the commit link (`<repo-url>/commit/<sha>`). Say what was validated locally; if local validation could not run, say so and that CI will verify. Never post a generic "fixed" without evidence.
- **Where**: a review comment gets a threaded reply through `POST /repos/<owner>/<repo>/pulls/<number>/comments/<comment_id>/replies`; an issue-level (PR-level) comment or a review body gets one issue comment through `POST /repos/<owner>/<repo>/issues/<number>/comments` naming what was addressed, quoting enough of the request that the reader knows which comment it answers. Do not reply to deferred, ambiguous, or untouched comments, and never dismiss, edit, resolve, or delete anyone else's comment.
- **Already addressed**: if the current head already contains what an open comment asks for (a stale bot finding), reply once with the commit that contains it, without pushing anything new.
- **A later push** that touches the same code needs a second reply only if the first one is now wrong.
- Append any attribution footnote the host requires for outgoing messages.

Print the PR's [Status board](#status-board) row as soon as the PR is resolved in step 1, an action line for each push, reply, rerun, or rebase, and a final `Done`/`Blocked` line.

1. Resolve the feature branch and its PR. If no PR exists, do not create one silently; explain that `raise pr` is required first unless the user explicitly authorizes fixing an unpublished branch.
2. Identify the branch's owning checkout. If it is a managed worktree, work there with `git -C <path>` and leave primary untouched. If it is primary, work in primary; do not park, switch, or create a second checkout, because the user may be testing there. If the branch has no local checkout, record that a branch-scoped sparse worktree is needed, but defer creating it until the provider sweep in step 4 succeeds. That creation checks out the existing branch, creates no branch, and changes nothing in primary, so the `fix pr` command authorizes it without a location question.
3. Inspect the complete status before mutation. Classify staged, unstaged, untracked, ignored, and partially staged paths. If any ownership is unrelated or ambiguous, stop and preserve everything.
4. Before any branch or source-file mutation, complete a read-only provider sweep for the PR's current head and record `INITIAL_HEAD_SHA`. Always inspect all three categories on every `fix pr` run. If step 2 found no local checkout, defer its sparse worktree until all three inspections succeed:
   - **CI first:** query check runs and commit statuses for `INITIAL_HEAD_SHA`. Record terminal green, terminal failure, or inconclusive. For failures, capture the failing check names, IDs/URLs, and available summaries or diagnostics now, before a rebase can start new runs. An empty failure list, missing permissions, or `mergeStateStatus` alone is not green.
   - **Mergeability:** query the current PR object. On GitHub REST, only the resolved pair `mergeable: false` and `mergeable_state: dirty` signals a conflict. `null`, `unknown`, `behind`, `blocked`, a failing check, a mismatched pair, or a provider lookup failure is not a conflict. Use only the tested GraphQL fallback for the same fact after REST fails; if both fail, emit `PROVIDER_OPERATION_FAILED` and stop before mutation. If no conflict is reported, record `BASE_UPDATE = skipped — no provider-reported conflict`.
   - **Reviews and comments:** fetch the complete review, review-comment, and issue-comment sets — all three sources in [Three comment sources, one inventory](#three-comment-sources-one-inventory) — and print the per-source counts. Record this initial inventory as a baseline; after any rebase, refresh and classify comments against the updated PR before review-driven edits. Use `in_reply_to_id` and chronology; when REST cannot prove resolution, mark resolution unknown rather than silently skipping the item.

   Finish all three inspections before rebasing, changing files, or creating the deferred sparse worktree. If a required read is confirmed rate-limited, follow [Rate-limit recovery](#rate-limit-recovery) and resume this exact sweep. For any other required dataset that cannot be retrieved after its allowed fallback, report the exact operation and error and stop before those actions. If the sweep succeeds and step 2 found no local checkout, create the branch-scoped sparse worktree at `INITIAL_HEAD_SHA` per [branch-scoped sparse worktrees](#branch-scoped-sparse-worktrees). Do not wait for CI yet.
5. If and only if the provider reports a conflict, read the PR's current `base.ref` and base repository from the provider, then fetch and record that exact base branch immediately before rebasing. Verify that the configured remote points to the PR's base repository; if it does not, resolve the correct remote or stop rather than rebasing onto the default branch by assumption.

```bash
git fetch "$BASE_REMOTE" "refs/heads/$PR_BASE_BRANCH:refs/remotes/$BASE_REMOTE/$PR_BASE_BRANCH"
git rev-parse "refs/remotes/$BASE_REMOTE/$PR_BASE_BRANCH"
```

Record the result as `PR_BASE_SHA`; verify it resolves locally and still matches the provider's current base before rebasing. Do not assume `main` or `master`, use a stale local base, or substitute the repository default when this PR targets a stack parent. 6. Establish mutation authorization. The `fix pr` command authorizes normal local fixes for automatic review items. Do not ask a generic preflight question before review classification. When a conflict rebase would rewrite a published branch, require separate explicit approval for `git push --force-with-lease` before the rebase/push, asked through the host's confirmation mechanism with the options **Rebase and force-push with lease** and **Stop here**; this approval does not approve any review change. When no conflict is reported, do not ask for rebase or force-push authorization. In `fix all`, the one stack-level approval described under [Stack trickle-down](#stack-trickle-down) covers the trickle-down rebases of every descendant in that stack; do not ask again per child. 7. Preserve confirmed local work with a named, verifiable stash or patch when needed. Never use a full-worktree stash for mixed ownership, and never blindly pop a preservation record. 8. **Phase 1 — conflict-only rebase.** If and only if the provider reported a conflict, rebase onto the exact fetched ref and resolve only unambiguous conflicts. After each resolution, inspect staged paths and continue. If a conflict is ambiguous, stop with the rebase state and report the paths. After a successful rebase, record the new head SHA and refresh the PR, review/comment inventory, and CI/check snapshot for that head; keep the initial pre-rebase CI snapshot for diagnosis, but never treat its status as current. If the provider did not report a conflict, do not rebase; continue directly to the review-comment phase with the initial snapshot as the baseline. 9. **Phase 2 — address review comments.** Refresh and inspect every review comment and thread after the conflict phase — inline threads, PR-level (issue) comments, and review bodies — including human and recognized-bot comments; compare with the initial inventory so no item from any source is skipped. Classify each as automatic, approval required, already addressed, non-actionable, or requiring human judgment. When REST cannot prove thread resolution, classify the item as requiring human judgment rather than silently treating it as open or resolved. Complete the classification and prepare the numbered approval batch before making review-driven changes. Apply automatic items without approval. For approval-required items, show the original comment, proposed change, and draft reply for every item in one batch, then stop until the user explicitly approves. After approval, make the smallest safe fixes for all approved items and record the exact reply for each. Do not dismiss, edit, or delete review comments; stop on ambiguous requests. 10. **Phase 3 — fix CI failures.** Use the pre-rebase `INITIAL_HEAD_SHA` snapshot and failure details captured before mutation, then inspect the latest CI/check results for the current head without waiting. If a rebase started new runs, treat old failures only as diagnostic evidence; verify that each failure still applies to the rebased code or is reproduced by focused validation before changing code for it. Diagnose actionable terminal failures on the current head and make only unambiguous fixes. A running or unknown check is not a failure to fix, but it is also not evidence of success. Do not claim a check is fixed until the resulting check or required validation is verified. 11. **Phase 4 — validate, commit, push, reply.** Run every validation command from inside the PR's owning checkout (`cd` there, or `git -C`); a result produced in another checkout is not evidence for this PR. Run focused tests and required local checks for all completed phases. If a hook or a validation tool fails only because this checkout lacks its dependency tree, provision it using the dependency bootstrap in [`raise pr`](#raise-pr) step 5 before treating it as a blocker. Commit all confirmed fixes with normal hooks; never use `--no-verify`. Push normally. Immediately post the replies per [Reply right after the push](#reply-right-after-the-push). Only then, in a single `fix pr`, poll the provider under [Waiting for checks](#waiting-for-checks) until every required/in-scope check is terminal, or until that budget ends; inside `fix all`, do not poll — mark the PR **PUSHED <sha>, CI running** and move to the next PR, and let the next scan read the result. If any check fails after that push, diagnose and fix it when actionable, run the focused validation, commit, push again, reply again, and (single `fix pr`) restart the post-push wait from the new HEAD. Do not stop after a push merely because checks have started, because an earlier run was green, or because no failure is visible yet. 12. Push normally when the update is fast-forward. If the rebase rewrote a published branch, use `git push --force-with-lease` only when the confirmation explicitly authorized it, and verify the remote branch afterward. Never use an unleased force-push. If the provider reports an inconclusive state or cannot be polled, stop and report `CI_CONCLUSION = inconclusive` rather than claiming the PR is fixed. 13. Do not wait for green before replying: replies go out right after the push, as [Reply right after the push](#reply-right-after-the-push) describes, using the approved draft for non-trivial items with only the commit link and verified validation evidence added. If replying or any provider action causes a new code push or check run, return to Phase 4 and reply for anything newly addressed. 14. Report `BASE_UPDATE` (`PR_BASE_BRANCH@PR_BASE_SHA` and conflict paths when rebased, or `skipped — no provider-reported conflict`), the initial and final check snapshots, `CI_CONCLUSION` (`green` only for a terminal post-push green result, otherwise `inconclusive` or `failed`), addressed and deferred comments, CI failures and fixes, validation, commit, push, and reply results, PR URL when available, checkout location, and primary status. Explicit human merge remains the terminal lifecycle step.

### Waiting for checks

Waiting is bounded work with a deadline, not an open loop. Record a total budget before the first poll, keep roughly ten minutes as the default, and stop at whichever of these comes first:

- **Every required check is terminal.** Green gives `CI_CONCLUSION = green`. Any terminal failure ends the wait immediately: fix it or report it, but never keep polling a failed run in the hope it changes.
- **The only thing left is a human action.** Approval, a requested review, a merge queue entry, or any other person-gated state is not a check. `fix pr` never merges, so a PR whose checks are terminal is finished for this phase even when the provider still reports it as blocked. Say plainly that the remaining blocker is review, and stop.
- **Nothing is progressing.** If no check has changed state across several consecutive polls, or the provider reports no runs at all for the pushed head, stop with `CI_CONCLUSION = pending` and report what was observed. A stalled queue is not a reason to keep sleeping.
- **The budget ends.** Report the last observed snapshot and `CI_CONCLUSION = pending`. An unfinished wait is a reportable outcome, not a failure to hide by waiting longer.

Size each poll to the execution environment. A single command must finish well inside the host's command timeout, so keep a short sleep and one bounded query per call, leave clear headroom for the query, and never combine a long sleep with a paginated request in one call. Prefer a short interval repeated a few times over one long blocking wait, and avoid a provider watch mode that blocks until completion with no deadline of its own. Between polls, wait rather than re-querying continuously.

**In `fix all` this section applies only to reading results.** The loop never sleeps on one PR's checks: after a push it moves to the next PR and reads check results on the next scan ([Continuous `fix all`](#continuous-fix-all) step 7).

**CI infrastructure failures are not code failures.** A download or fetch 404, a lost or cancelled runner, a timeout, an external service error, or a failing job whose log names no file in this PR is infrastructure. Request one rerun of the failed jobs with `POST /repos/<owner>/<repo>/actions/runs/<run_id>/rerun-failed-jobs`, record the time, mark the PR **CI INFRASTRUCTURE, rerun requested**, and move on. If the rerun fails the same way, mark it **BLOCKED — CI infrastructure** with a short log excerpt and do not rerun again without new evidence. Never sit polling an infrastructure rerun.

### Continuous `fix all`

Treat `fix all`, `fix all prs`, and `fix all open prs` as the same continuous workflow. By default, its action scope is every PR authored by the authenticated user in the current repository whose provider state is open and whose draft flag is false (ready for review). Drafts are excluded unless the user explicitly requests them with `fix all drafts`; `fix drafts`, `fix all and drafts`, and `PR fix drafts` are equivalent opt-ins that include both review-ready PRs and drafts. Paginate the complete author-filtered open-PR inventory so draft status and stack relationships are known; only mutate PRs in the requested scope. Do not limit discovery to local branches or the first page. Do not infer cross-repository scope. Never merge a PR.

`fix all` is a **pipeline, not a babysitter**. Its time goes into fixing, pushing, and replying; it never sits waiting on one PR's checks, a reviewer, or CI infrastructure while another PR has work. Run it while the invocation remains active, until the user explicitly stops it, the host ends the run, or a hard global blocker prevents all further work. A blocker on one PR must not stop unrelated work. Do not silently create a separate scheduled automation. If the host cannot keep the invocation active, report that limit and the last verified state instead of claiming indefinite monitoring.

1. **Inventory and classify.** On startup and at the start of every pass, fetch the full author-owned open-PR inventory, including draft flags, then apply the requested scope: ready-for-review only by default, or ready-for-review plus drafts when the user opted in. For each in-scope candidate, refresh its state, head SHA, base ref/SHA, checks, reviews, and branch/checkout ownership. Freeze the target head SHA before making changes. Map each PR to its owning checkout: primary, a managed worktree, or none. A PR with no checkout is still a candidate; its branch-scoped sparse worktree is created when it is selected, per [branch-scoped sparse worktrees](#branch-scoped-sparse-worktrees), and never earlier. If provider data is incomplete because of a confirmed rate limit, follow [Rate-limit recovery](#rate-limit-recovery), preserve the queue, and resume the exact failed operation. For other provider failures, report the exact operation and error; do not claim the inventory is complete or mutate a PR with unknown state. Then put every in-scope PR in exactly one bucket:
   - **Actionable** — a terminal CI failure that names this PR's code, an open automatic review item from any of the three comment sources (inline, PR-level, review body), an approved review item not yet applied, a stacked child whose parent was pushed in this run, or a provider-reported conflict.
   - **Needs a decision** — approval-required review items, an ambiguous conflict, a force-push that needs consent.
   - **CI running** — a head this run pushed or reran whose checks are not terminal.
   - **CI infrastructure** — failed for reasons outside this PR's code; one rerun requested ([Waiting for checks](#waiting-for-checks)).
   - **Waiting on a person** — checks terminal; only a reviewer or a merge is left.
   - **Blocked** — a recorded blocker with no new evidence.
   - **Green** — nothing to do.

   Only the actionable bucket consumes work. Every other bucket is read, not polled, on the next scan.
2. **Build stack order.** Link a PR to its parent when its provider-declared `base.ref` matches another open PR's `head.ref` in the same repository, and verify the relationship against provider data. Build a dependency graph. Fix the **root first** — the PR whose base is the default branch — then each child downward, one PR at a time. A fix made in a parent (a CI failure, a review change) is inherited by every descendant through the trickle-down rebase below; never diagnose or fix in a child a failure its parent has already fixed. If the graph is ambiguous, cyclic, or cannot be verified, stop the affected stack and report why; continue with unrelated PRs.
3. **Order the work.** Within a stack, root first: a parent is ready to hand down as soon as its fixes are **pushed**; its CI need not be finished, and a parent waiting on a person is not a reason to leave its children stale. Never start a child before its parent's turn in this pass is finished. Across the actionable bucket, order by the cost of delay: PRs with code fixes to push first, then reruns and metadata fixes, then anything else; break ties by PR number. In the default mode, only review-ready PRs are in scope. If an in-scope child sits on a draft parent that is out of scope, still rebase the child onto that draft's current head when the draft has moved, but do not fix the draft; report that `fix all drafts` (or `PR fix drafts`) is needed to include it. When drafts were explicitly included, process them in the same root-first order. Watch-only PRs (green, waiting on a person, CI running) never enter the queue.
4. **Work each actionable PR to the push, then move on.** Run [`fix pr`](#fix-pr) for it through Phase 4 — sweep, fix, validate, commit, push, reply — and stop there. Do not poll its checks. Mark it **PUSHED <sha>, CI running** and take the next PR. Work in the PR's existing checkout, including primary; create a branch-scoped sparse worktree only when the branch has none, and never move a branch out of primary during `fix all`. For a stacked child, run [Stack trickle-down](#stack-trickle-down) **before** its provider sweep, so the CI, mergeability, and comment snapshot describe the rebased head. Rebase only onto the exact current `PR_BASE_BRANCH` and `PR_BASE_SHA`, never the repository default by assumption. A PR that turns out to be infrastructure-failed, waiting on a person, or blocked is marked and left at once; still trickle its current head down to its children.
5. **Prepare independent PRs in parallel.** When the host offers a delegation or sub-agent tool, the main run may hand independent PRs to sub-agents, up to three at a time. Independent means: not in the same stack, a different owning checkout, and no dirty state shared with another PR. A PR whose checkout is primary is worked only by the main run, one at a time, because the user may be testing there. A sub-agent receives the PR number, the owning checkout path, the pinned head, and this skill's `fix pr` rules. It may apply automatic items, validate, commit, push, reply, and request one infrastructure rerun. It must never ask the user anything, never rebase or force-push, never touch another checkout or primary, and never merge. Anything that needs a human decision comes back as a structured item — comment, proposed change, draft reply — and the main run folds it into the single batched question. Sub-agent output is never shown directly; the main run owns the [Status board](#status-board) and reports each result as one action line and one row. Without such a tool, work serially — still never waiting on CI.
6. **Ask once per pass, not once per PR.** Collect every needs-a-decision item from the pass — PR number, original comment, proposed change, draft reply — into one batch and ask one question per the [Review-feedback approval gate](#review-feedback-approval-gate) after the pass's automatic work is pushed, so the question never stalls automatic fixes. Stack trickle-down consent is asked once per stack, the first time that stack has a pushed parent. Approved items become actionable in the next pass. A pending question on one PR never blocks another PR's automatic work. Do not make approval-required changes, commit, push, or reply for them until explicitly approved.
7. **Scan again.** When the actionable bucket is empty, wait at least 60 seconds, then refresh the full inventory and stack graph. Read the heads this run pushed: terminal green → waiting on a person or green; a terminal failure that names this PR's code → actionable again; an infrastructure failure → one rerun, then CI infrastructure. Newly opened PRs, new comments, and new approvals enter the buckets. Do not re-poll or re-touch a PR whose head, base, reviews, and checks are unchanged. Use longer waits when provider reset/backoff requires them; for a confirmed rate limit, retry the exact incomplete operation under [Rate-limit recovery](#rate-limit-recovery), not just the full scan. Never busy-poll.
8. **Track each PR.** Keep a ledger with PR number, ready/draft status, stack parent/children and depth, branch, checkout, pinned head SHA, `PR_BASE_BRANCH@PR_BASE_SHA`, bucket, initial/last check state, pending fixes, approval state, validation, commit/push, replies posted, rerun time, and blocker/conclusion. Do not repeat an unchanged failed or blocked action without new provider evidence or an explicit user direction, except for the exact periodic retry required by [Rate-limit recovery](#rate-limit-recovery).
9. **Environment blockers are reported once.** If hooks or tests cannot run for a reason outside the repository — a certificate error, a missing toolchain, a dependency download the network refuses — do not retry the same failing command PR after PR. Report it once with the exact error and a concrete fix the user can apply, keep each prepared change in its checkout uncommitted, continue with provider-side work that needs no commit (infrastructure reruns, metadata fixes, replies to already-addressed comments), and list every checkout holding uncommitted prepared changes under **BLOCKED — local environment** on the next board.
10. **Report with the board.** Print the [Status board](#status-board) after the first classification and after every pass whose statuses changed, and one action line per push, reply, rerun, or rebase as it happens. Report drafts skipped by default as one count line with the `fix all drafts` opt-in. Do not call the run complete while it is still active; give a terminal summary only after the user stops it or the host ends the run: the final board plus every uncommitted change left behind.

### Stack trickle-down

In `fix all`, a parent's pushed fixes reach its children by rebasing each child onto the parent's new head. This is the only rebase that does not require a provider-reported conflict, and it exists so that one fix in a parent is never re-made in a child and never collides with it later.

1. **Ask once per stack.** Before the first trickle-down rebase of a stack, ask through the host's confirmation mechanism: `Stack <root PR> → … → <leaf PR>: rebase each child onto its fixed parent and force-push with lease as parents change during this run?` Options: **Yes, for this whole stack** and **No — fix without rebasing children**. One **Yes** covers every descendant rebase in that stack for the rest of the run; a **No** leaves children on their current bases and records `TRICKLE_DOWN = declined` for that stack.
2. **Record both parent heads.** For child `C` with parent `P`: `OLD_PARENT_HEAD` is the merge base of `C` and `P` as it was before `P` was fixed (`git merge-base C P`, taken before `P` is touched, or the provider's last-known base SHA for `C`); `NEW_PARENT_HEAD` is `P`'s pushed head after its `fix pr` run; `P`'s checks need not be finished.
3. **Rebase only the child's own commits.** Fetch, then in `C`'s owning checkout:

```bash
git fetch "$REMOTE" "$P_BRANCH" "$C_BRANCH"
git -C "$C_PATH" rebase --onto "$NEW_PARENT_HEAD" "$OLD_PARENT_HEAD" "$C_BRANCH"
```

`--onto` with the old merge base replays only `C`'s own commits, so `P`'s rewritten or squashed commits are never carried twice and the child never "reverts" a parent change. Never run a plain `git rebase P` here: if `P` was squashed, amended, or force-pushed, that replays `P`'s old commits into `C` and produces exactly the conflicts this step exists to avoid.
4. **Resolve only unambiguous conflicts.** A conflict here means the child touched lines the parent's fix also changed. Resolve it only when one side is clearly stale; otherwise stop with the rebase state, report the paths, record `TRICKLE_DOWN = conflict` for `C`, defer `C` and its descendants, and continue with unrelated PRs.
5. **Push with lease, verify, then sweep.** `git push --force-with-lease` under the stack-level approval; confirm the remote head matches; record `TRICKLE_DOWN = <OLD_PARENT_HEAD>..<NEW_PARENT_HEAD>` in the ledger. Only now run `C`'s `fix pr` provider sweep, so CI and comments are read for the rebased head and an inherited failure is never diagnosed twice.
6. **Repeat down the stack.** The rebased `C` is the `P` for its own children; use `C`'s new head as their `NEW_PARENT_HEAD`. If `P` was not changed in this pass, skip the rebase and record `TRICKLE_DOWN = skipped — parent unchanged`.

Outside `fix all`, a single `fix pr` on a stacked child still rebases only on a provider-reported conflict; trickle-down is a stack-run behaviour, because only the stack run knows which parents it changed.


## `clean pr`

`clean pr` is the explicit reclaim step for checkouts whose work is finished. It removes checkouts, never branches, and never the primary checkout. `pr clean` is an alias.

Cleanup is a source-state decision, not a cache decision. Dependency trees, build output, and caches are reclaimed by the repository's own disk tooling, never here; see [Ignored paths are not work](#ignored-paths-are-not-work). Removing a checkout costs only the time to recreate it, so the entire risk is whether the work inside it still exists somewhere else.

### Reclaim gate

A checkout is **reclaimable** only when both of these local facts hold:

1. `git status --porcelain` reports nothing, including untracked files.
2. `git log --oneline --not --remotes` reports nothing, so every commit it holds already exists on some remote.

These two facts are the whole safety argument and neither needs the provider, so they still hold when the provider is rate-limited or unavailable. A checkout that fails either one is never removed automatically, whatever its PR state says: it may hold the only copy of that work. Never widen the gate because a PR looks merged.

### Classification

Resolve PR state with one bounded REST lookup per branch, following [Provider lookups and quota](#provider-lookups-and-quota). PR state decides only what is worth keeping ready; it never authorizes removing something the gate rejected. Apply the first matching rule:

| Checkout state                                              | Action                                             |
| ----------------------------------------------------------- | -------------------------------------------------- |
| primary checkout, the current working directory, or locked  | never remove                                       |
| dirty, or holding commits absent from every remote          | never remove · report under preservation           |
| PR merged                                                   | remove the checkout · keep the branch              |
| PR closed without merging                                   | remove the checkout · keep the branch              |
| PR open or draft                                            | keep · active iteration needs a ready checkout     |
| no PR, and the branch is gone from the remote               | remove the checkout · keep the branch              |
| no PR, and the branch still exists on the remote            | keep unless the user asks to include it            |
| detached, and its head is reachable from a remote ref       | remove the checkout                                |
| detached, and its head is unreachable from every remote ref | never remove · report under preservation           |
| PR state unknown                                            | keep · say the state is unknown and name the cause |

### Execution

1. Build the inventory from `git worktree list --porcelain` for the current repository. For each non-primary checkout record the branch, clean/dirty state, unpushed-commit count, PR state, and reclaimable size (`du -sh` on the worktree path, run only for checkouts that already passed the gate).
2. Ask exactly one confirmation through the host's mechanism, listing the exact checkouts, the reason each one qualifies, and the total reclaimable size with the largest first. Include exactly one **Cancel**. Never treat silence, a prior approval, or an unrelated yes as authorization.
3. Remove each confirmed checkout with `git worktree remove "$PATH"` without `--force`, then run `git worktree prune`. Git refuses to remove a dirty or locked worktree; treat that refusal as a skip, never as a reason to force. Never use `rm -rf` on a checkout.
4. If a removal fails—for example, the worktree is locked or a process holds it—report it as skipped with Git's exact message.
5. Re-verify with `git worktree list --porcelain` afterward and report what was removed, which branches were preserved, and how much space was reclaimed.

Never delete a local branch, a remote branch, a stash, or a reflog entry. The branch is the recovery handle that makes removing a checkout safe, and keeping it costs nothing. This command is the batch form of the post-merge cleanup required by [Safety boundaries](#safety-boundaries).

## Safety boundaries

- Preserve dirty work. Never use `git reset --hard`, `git clean`, a blind force-push, destructive cleanup, or an unconfirmed commit or stash to make room. `fix pr` may use only an explicitly authorized `git push --force-with-lease` after a rebase.
- Immediately after creating a managed worktree, link its dependency root to primary's under the [`raise pr`](#raise-pr) step 5 guards: create the symlink when the manifest and lockfile inputs match and the target is absent and ignored. This is a free operation that front-loads the same guarded link the hook-failure path would do later. Never eagerly run a full dependency install at creation; if a symlink is not valid, leave the tree unprovisioned and let the hook-failure bootstrap install on first need. Never link into the primary checkout or a non-empty or tracked target.
- Never remove the primary checkout. Manage secondary checkouts only with `git worktree` commands at derived paths; do not use host worktree UIs, slash commands, or tools.
- Sparse-checkout patterns belong to one managed worktree. Never change primary's sparse state, and never apply sparse patterns through a shared config or `.git/info/sparse-checkout` that other worktrees read. If worktree-local isolation cannot be verified, do not apply patterns; with `--no-checkout` nothing has been materialized yet, so stop and report instead of silently producing a full checkout.
- Do not create duplicate branches or attach one branch to multiple checkouts. Use Git to create or switch branches only after `git worktree list --porcelain` shows that no other checkout owns the branch.
- A normal new branch must be provably based on the freshly fetched `BASE_SHA`; stacked branching requires explicit opt-in.
- Do not stage, commit, stash, transfer, or delete a path whose ownership is not confirmed.
- Never silently switch between the primary checkout and a managed worktree. Report the conflict and re-confirm instead.
- Do not auto-commit implementation work during `start pr` or `focus pr`. `raise pr` and `fix pr` are the explicit exceptions.
- Do not commit, push, open or update a PR, create an automation, or send external communication outside the command whose semantics authorize it.
- Do not automatically merge a PR. After the provider verifies that a PR is merged, remove its clean managed worktree with `git worktree remove` (no `--force`) only through a confirmed `clean pr`, and verify it is gone from `git worktree list --porcelain`. Never delete primary, a dirty worktree, or an ambiguous/unowned worktree.
- Never claim an external action succeeded, or a location is fresh, without verifying it.
