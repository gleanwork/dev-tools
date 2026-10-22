#!/usr/bin/env python3
"""Read-only provider sweep for `fix all`: one JSON ledger row per open ready PR.

Usage: sweep.py OWNER/REPO LOGIN [--drafts] [--numbers N,N,...]
Prints a JSON list: number, title, draft, base, head, head_sha, mergeable,
mergeable_state, checks {state, failing:[name...], pending:[...]} , comments
{review_total, issue_total, reviews_total, open_bot, open_human}, parent.

open_bot / open_human hold every open item from ALL THREE comment sources, each
tagged with `kind`: 'inline' (pulls/N/comments review threads), 'issue'
(issues/N/comments, the PR-level conversation), or 'review' (pulls/N/reviews
bodies). PR-level comments are first-class actionable items, not a count.
Uses REST only via `gh api`.
"""
import json
import os
import subprocess
import sys


def api(path, paginate=False):
    cmd = ['gh', 'api'] + (['--paginate'] if paginate else []) + [path]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode:
        raise RuntimeError(f'{path}: {out.stderr.strip()[:300]}')
    txt = out.stdout
    if paginate:
        # gh --paginate concatenates arrays; join them.
        parts = txt.replace('][', ',')
        return json.loads(parts) if parts.strip() else []
    return json.loads(txt) if txt.strip() else None


# Review bots whose comments `fix all` may address automatically. Any login ending in
# `[bot]` is also treated as a bot. Extend with PR_SWEEP_EXTRA_BOTS="login1,login2".
BOTS = {'github-actions[bot]', 'coderabbitai[bot]', 'cursor[bot]', 'devin-ai-integration[bot]',
        'copilot-pull-request-reviewer[bot]', 'greptile-apps[bot]', 'ellipsis-dev[bot]', 'graphite-app[bot]'}
BOTS |= {b.strip() for b in os.environ.get('PR_SWEEP_EXTRA_BOTS', '').split(',') if b.strip()}


def checks(repo, sha):
    runs = api(f'repos/{repo}/commits/{sha}/check-runs?per_page=100', paginate=True)
    if isinstance(runs, dict):
        runs = runs.get('check_runs', [])
    else:
        merged = []
        for r in runs if isinstance(runs, list) else []:
            merged.extend(r.get('check_runs', []) if isinstance(r, dict) else [])
        runs = merged
    status = api(f'repos/{repo}/commits/{sha}/status')
    failing, pending, ok = [], [], []
    for r in runs:
        name = r['name']
        if r['status'] != 'completed':
            pending.append(name)
        elif r['conclusion'] in ('success', 'neutral', 'skipped'):
            ok.append(name)
        else:
            failing.append(f"{name} [{r['conclusion']}] {r.get('html_url','')}")
    for s in (status or {}).get('statuses', []):
        if s['state'] == 'pending':
            pending.append(s['context'])
        elif s['state'] != 'success':
            failing.append(f"{s['context']} [{s['state']}] {s.get('target_url','')}")
        else:
            ok.append(s['context'])
    if not runs and not (status or {}).get('statuses'):
        state = 'none'
    elif failing:
        state = 'failure'
    elif pending:
        state = 'pending'
    else:
        state = 'green'
    return {'state': state, 'failing': failing, 'pending': pending, 'ok': len(ok)}


def is_bot(login):
    return login in BOTS or login.endswith('[bot]')


def comments(repo, n, author):
    rc = api(f'repos/{repo}/pulls/{n}/comments?per_page=100', paginate=True) or []
    ic = api(f'repos/{repo}/issues/{n}/comments?per_page=100', paginate=True) or []
    rv = api(f'repos/{repo}/pulls/{n}/reviews?per_page=100', paginate=True) or []
    open_bot, open_human = [], []

    def add(entry):
        (open_bot if is_bot(entry['user']) else open_human).append(entry)

    # 1. Inline review threads. A thread is "open" if its root has no reply from
    #    the author after the last non-author comment.
    by_id = {c['id']: c for c in rc}
    threads = {}
    for c in rc:
        root = c.get('in_reply_to_id') or c['id']
        threads.setdefault(root, []).append(c)
    for root, cs in threads.items():
        cs.sort(key=lambda c: c['created_at'])
        last = cs[-1]
        rootc = by_id.get(root, cs[0])
        if last['user']['login'] == author:
            continue
        add({'kind': 'inline', 'id': rootc['id'], 'user': rootc['user']['login'], 'path': rootc.get('path'),
             'line': rootc.get('line') or rootc.get('original_line'), 'body': rootc['body'][:400],
             'url': rootc['html_url'], 'replies': len(cs) - 1, 'created_at': rootc['created_at']})

    # 2. PR-level conversation (issue comments) and 3. review bodies. These have
    #    no thread structure, so treat one as "open" when the author has not
    #    posted any PR-level comment or review after it.
    author_pr_level_times = sorted(
        [c['created_at'] for c in ic if c['user']['login'] == author]
        + [r['submitted_at'] for r in rv if r['user']['login'] == author and r.get('submitted_at')]
    )
    last_author_reply = author_pr_level_times[-1] if author_pr_level_times else ''

    for c in ic:
        if c['user']['login'] == author or not (c.get('body') or '').strip():
            continue
        if c['created_at'] <= last_author_reply:
            continue
        add({'kind': 'issue', 'id': c['id'], 'user': c['user']['login'], 'path': None, 'line': None,
             'body': c['body'][:400], 'url': c['html_url'], 'replies': 0, 'created_at': c['created_at']})

    for r in rv:
        body = (r.get('body') or '').strip()
        if r['user']['login'] == author or not body:
            continue  # an empty APPROVED/COMMENTED review carries no request
        if (r.get('submitted_at') or '') <= last_author_reply:
            continue
        add({'kind': 'review', 'id': r['id'], 'user': r['user']['login'], 'path': None, 'line': None,
             'state': r.get('state'), 'body': body[:400], 'url': r['html_url'], 'replies': 0,
             'created_at': r.get('submitted_at')})

    return {'review_total': len(rc), 'issue_total': len(ic), 'reviews_total': len(rv),
            'open_bot': open_bot, 'open_human': open_human}


def main():
    repo, login = sys.argv[1], sys.argv[2]
    drafts = '--drafts' in sys.argv
    only = None
    if '--numbers' in sys.argv:
        only = {int(x) for x in sys.argv[sys.argv.index('--numbers') + 1].split(',')}
    prs = api(f'repos/{repo}/pulls?state=open&per_page=100', paginate=True)
    mine = [p for p in prs if p['user']['login'] == login and (drafts or not p['draft'])]
    heads = {p['head']['ref']: p['number'] for p in mine}
    rows = []
    for p in mine:
        if only and p['number'] not in only:
            continue
        full = api(f"repos/{repo}/pulls/{p['number']}")
        row = {
            'number': p['number'], 'title': p['title'], 'draft': p['draft'], 'url': p['html_url'],
            'base': p['base']['ref'], 'head': p['head']['ref'], 'head_sha': p['head']['sha'],
            'base_sha': full['base']['sha'],
            'mergeable': full.get('mergeable'), 'mergeable_state': full.get('mergeable_state'),
            'parent': heads.get(p['base']['ref']),
            'review_decision': None,
        }
        try:
            row['checks'] = checks(repo, p['head']['sha'])
        except Exception as e:  # noqa: BLE001
            row['checks'] = {'state': 'error', 'error': str(e)}
        try:
            row['comments'] = comments(repo, p['number'], login)
        except Exception as e:  # noqa: BLE001
            row['comments'] = {'error': str(e)}
        rows.append(row)
    json.dump(rows, sys.stdout, indent=1)


if __name__ == '__main__':
    main()
