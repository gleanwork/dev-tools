#!/usr/bin/env python3
"""
PR Dashboard — a local web UI for tracking your active GitHub pull requests.

Aggregates PRs from three sources into a single view:
  1. Local git worktrees (shows dirty/unpushed status)
  2. Extra branches listed in ~/.worktrees.txt
  3. Open PRs authored by you that aren't checked out locally

PRs are aggregated across several repos: the repo containing the current directory
plus any extras listed in PR_DASH_REPOS (none by default).

Polls PR metadata every 30 s and running CI every 15 s while viewed (10 min when idle).
Unchanged comments and settled CI are reused for up to 5 min; Refresh bypasses these caches.

Environment variables:
  PR_DASH_DEBUG=1          Enable verbose logging (also: WORKTREES_DEBUG)
  PR_DASH_CMD_TIMEOUT=30   Per-command timeout in seconds (also: WORKTREES_CMD_TIMEOUT)
  PR_DASH_BATCH_SIZE=15    Branches per GraphQL batch (also: WORKTREES_BATCH_SIZE)
  PR_DASH_PARALLEL=4       Parallel batch workers (also: WORKTREES_PARALLEL)
  PR_DASH_RATE_LIMIT_COOLDOWN=900
                           Seconds without GitHub calls after GitHub reports a rate
                           limit (the limits are per user, shared with every other
                           tool signed in as you).
  PR_DASH_REPOS=...        Comma-separated extra repos to include, each
                           "owner/name" or "owner/name=/path/to/checkout".
                           Unset or empty for current repo only.
  PR_DASH_BOTS=...         Comma-separated extra bot logins to hide from the
                           reviewer list (any *[bot], *-bot, *-ci login is
                           already treated as a bot).

Requires: gh (GitHub CLI), git, flask
"""

import argparse
from concurrent.futures import as_completed
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import datetime
from datetime import timedelta
from datetime import timezone
import json
import os
from pathlib import Path
import random
import re
import subprocess
import threading
import time
from urllib.parse import urlencode
from urllib.parse import urlsplit

from flask import Flask
from flask import jsonify
from flask import render_template_string
from flask import request

app = Flask(__name__)

# Cache for PR dashboard data
_cache = {
    'data': [],
    'review_requests': [],
    'last_updated': None,
    'updating': False,
    'is_stale': False,  # True if last fetch failed and we're showing cached data
}
_cache_lock = threading.Lock()

# GitHub repo info (cached)
_repo_info = {
    'owner': None,
    'name': None,
    'current_user': None,
}

# Track last API access for adaptive refresh rate (using dict to avoid global statement)
_api_state: dict[str, datetime | None] = {'last_access': None}
_api_access_lock = threading.Lock()

# GitHub quota guard. The REST (5,000/h) and GraphQL (5,000 points/h) limits are per *user*,
# shared with every other tool signed in as you (gh in other shells, the editor, Tau). When GitHub
# says we are over, every further call is a wasted process and a 403, and a REST fallback on top
# of a GraphQL limit just drains the second bucket too. So: remember the limit, make no gh calls
# until it has had time to reset, and let the refresh loop sleep through it instead of retrying
# every 15 s. GitHub's windows are an hour from the first request, so a hit near the end of a
# window clears sooner than this; the next cycle after the cooldown finds out either way.
_RATE_LIMIT_COOLDOWN_SECONDS = int(os.environ.get('PR_DASH_RATE_LIMIT_COOLDOWN', '900'))
_rate_limit_state: dict[str, datetime | None] = {'until': None}
_rate_limit_lock = threading.Lock()

# Closed PR details rarely change; updatedAt invalidates edits made after closing.
_closed_pr_cache: dict[tuple[str, str], tuple[str, dict]] = {}
_closed_pr_cache_lock = threading.Lock()

_METADATA_INTERVAL = 30
_ACTIVE_CI_INTERVAL = 15
_SETTLED_INTERVAL = 300
_CLOSED_LIST_INTERVAL = 600

# Cache raw snapshots, not parsed rows: relative times and local git state still update each cycle.
_list_cache: dict[tuple[str, ...], tuple[float, list[dict]]] = {}
# One bounded (at most 200 numbers) authoritative open-PR snapshot per configured repo.
_open_pr_numbers: dict[str, set[int]] = {}
_field_cache: dict[tuple[str, str, str], tuple[tuple[str, ...], float, dict]] = {}
_rest_cache: dict[str, tuple[dict[str, str], dict | list]] = {}
_fetch_cache_lock = threading.Lock()
_refresh_wakeup = threading.Event()


def _store_snapshot(cache: dict, key: object, value: object) -> None:
    """Bound each cache to 1024 snapshots of at most 128 KiB of encoded data each.

    Oversized snapshots are served uncached; the oldest entry is evicted on overflow.
    The caller holds the cache's lock.
    """
    if len(json.dumps(value).encode()) > 128 * 1024:
        cache.pop(key, None)
        return
    if len(cache) >= 1024 and key not in cache:
        cache.pop(next(iter(cache)))
    cache[key] = deepcopy(value)


def _is_rate_limit_error(message: str) -> bool:
    lowered = (message or '').lower()
    return 'rate limit' in lowered or 'secondary limit' in lowered or 'abuse detection' in lowered


def _note_rate_limited(message: str) -> None:
    """Start (or extend) the cooldown after GitHub reported a rate limit."""
    until = datetime.now(timezone.utc) + timedelta(seconds=_RATE_LIMIT_COOLDOWN_SECONDS)
    with _rate_limit_lock:
        current = _rate_limit_state['until']
        if current is None or until > current:
            _rate_limit_state['until'] = until
            print(f'[gh] GitHub rate limit hit; no GitHub calls until {until:%H:%M:%S} UTC ({message[:120]})')


def rate_limited_until() -> datetime | None:
    """When the cooldown ends, or None when GitHub calls are allowed."""
    with _rate_limit_lock:
        until = _rate_limit_state['until']
        if until and until <= datetime.now(timezone.utc):
            _rate_limit_state['until'] = None
            return None
        return until


def run_command(cmd: list[str], capture_output: bool = True, debug: bool = False) -> tuple[bool, str]:
    """Run a shell command and return success status and output."""
    timeout = int(os.environ.get('PR_DASH_CMD_TIMEOUT', os.environ.get('WORKTREES_CMD_TIMEOUT', '30')))
    try:
        result = subprocess.run(
            cmd,
            capture_output=capture_output,
            text=True,
            check=False,
            timeout=timeout,
        )
        output = result.stdout.strip()
        if result.returncode != 0:
            # gh treats 304 as an error. Keep included HTTP responses so the caller can
            # distinguish Not Modified from a failed fetch without retrying it.
            if not (cmd[:2] == ['gh', 'api'] and '--include' in cmd and output.startswith('HTTP/')):
                output = result.stderr.strip() or output
            if debug:
                print(f'[cmd] {" ".join(cmd[:3])}... failed: {output[:100] if output else "no output"}')
        return result.returncode == 0, output
    except subprocess.TimeoutExpired:
        if debug:
            print(f'[cmd] {" ".join(cmd[:3])}... timed out after {timeout}s')
        return False, ''
    except Exception as e:
        if debug:
            print(f'[cmd] {" ".join(cmd[:3])}... exception: {e}')
        return False, ''


def run_gh_command(cmd: list[str], max_retries: int = 3) -> tuple[bool, str]:
    """Run a GitHub CLI command with retry logic for transient failures."""
    debug = os.environ.get('PR_DASH_DEBUG', os.environ.get('WORKTREES_DEBUG', '')).lower() in ('1', 'true', 'yes')
    last_error = ''

    if rate_limited_until():
        # Every call during the cooldown would be another 403; spend nothing.
        return False, 'GitHub rate limit cooldown'

    for attempt in range(max_retries):
        success, output = run_command(cmd, debug=debug)
        not_modified = (
            cmd[:2] == ['gh', 'api']
            and '--include' in cmd
            and output.startswith('HTTP/')
            and output.splitlines()[0].split()[1:2] == ['304']
        )
        if success or not_modified:
            return True, output

        last_error = output
        if _is_rate_limit_error(last_error):
            _note_rate_limited(last_error)
            return False, last_error

        if attempt < max_retries - 1:
            # Exponential backoff with jitter: base * 2^attempt + random jitter
            base_delay = 0.5 * (2**attempt)
            jitter = random.uniform(0, 0.5)
            delay = base_delay + jitter
            if debug:
                print(f'[gh] Retry {attempt + 1}/{max_retries} after {delay:.2f}s for: {" ".join(cmd[:4])}...')
            time.sleep(delay)

    if debug:
        print(
            f'[gh] All {max_retries} attempts failed for: {" ".join(cmd[:4])}... last_error={last_error[:100] if last_error else "none"}'
        )
    return False, ''


def _parallel_workers() -> int:
    """Worker count for parallel per-PR fetches (PR_DASH_PARALLEL / WORKTREES_PARALLEL)."""
    return max(1, int(os.environ.get('PR_DASH_PARALLEL', os.environ.get('WORKTREES_PARALLEL', '4'))))


def get_repo_info() -> tuple[str, str]:
    """Get repository owner and name."""
    if _repo_info['owner'] and _repo_info['name']:
        return _repo_info['owner'], _repo_info['name']

    success, output = run_gh_command(['gh', 'repo', 'view', '--json', 'owner,name', '-q', '.owner.login + "|" + .name'])
    if success and output and '|' in output:
        owner, name = output.split('|', 1)
    else:
        success, output = run_command(['git', 'remote', 'get-url', 'origin'])
        nwo = _remote_to_nwo(output) if success else ''
        if '/' not in nwo:
            return '', ''
        owner, name = nwo.split('/', 1)

    _repo_info['owner'] = owner
    _repo_info['name'] = name
    return owner, name


# Repos aggregated in addition to the one containing the current directory.
# Override with PR_DASH_REPOS; e.g. 'myorg/other-repo,myorg/mobile=/path/to/mobile'.
_DEFAULT_EXTRA_REPOS: list[str] = []

_repos_state: dict[str, list[dict] | None] = {'repos': None}
_repos_lock = threading.Lock()


def _remote_to_nwo(url: str) -> str:
    """Reduce a git remote URL to "owner/name"."""
    url = url.strip()
    if url.endswith('.git'):
        url = url[:-4]
    parts = [p for p in url.replace(':', '/').split('/') if p]
    if len(parts) >= 2:
        return f'{parts[-2]}/{parts[-1]}'
    return ''


def _detect_local_path(nwo: str) -> str:
    """Find a local checkout of owner/name by probing common sibling locations."""
    name = nwo.split('/')[-1]
    cwd = Path.cwd()
    candidates = [cwd.parent / name, Path.home() / 'workspace' / name, Path.home() / name]
    for candidate in candidates:
        if not (candidate / '.git').exists():
            continue
        success, output = run_command(['git', '-C', str(candidate), 'remote', 'get-url', 'origin'])
        if success and output and _remote_to_nwo(output) == nwo:
            return str(candidate)
    return ''


def get_repos() -> list[dict]:
    """Repos to aggregate: the current directory's repo first, then PR_DASH_REPOS extras.

    Each entry is {'nwo', 'owner', 'name', 'path', 'primary'}. 'path' is a local
    checkout used for worktree/dirty state, and is empty when none was found.
    """
    with _repos_lock:
        cached = _repos_state['repos']
    if cached is not None:
        return cached

    repos: list[dict] = []
    seen: set[str] = set()

    owner, name = get_repo_info()
    if owner and name:
        nwo = f'{owner}/{name}'
        seen.add(nwo)
        repos.append({'nwo': nwo, 'owner': owner, 'name': name, 'path': str(Path.cwd()), 'primary': True})

    raw = os.environ.get('PR_DASH_REPOS')
    specs = raw.split(',') if raw is not None else list(_DEFAULT_EXTRA_REPOS)
    for spec in specs:
        spec_nwo, _, spec_path = spec.partition('=')
        spec_nwo = spec_nwo.strip()
        if '/' not in spec_nwo or spec_nwo in seen:
            continue
        seen.add(spec_nwo)
        extra_owner, extra_name = spec_nwo.split('/', 1)
        repos.append(
            {
                'nwo': spec_nwo,
                'owner': extra_owner,
                'name': extra_name,
                'path': spec_path.strip() or _detect_local_path(spec_nwo),
                'primary': False,
            }
        )

    if repos:
        with _repos_lock:
            _repos_state['repos'] = repos
    return repos


def make_pr_key(nwo: str, branch: str) -> str:
    """Cache/row key for a PR. Branch names collide across repos, so scope by repo."""
    return f'{nwo}#{branch}'


def get_current_user() -> str:
    """Get current GitHub username."""
    if _repo_info['current_user']:
        return _repo_info['current_user']

    success, output = run_gh_command(['gh', 'api', 'user', '--jq', '.login'])
    if success and output:
        _repo_info['current_user'] = output.strip()
        return _repo_info['current_user']
    return ''


# Cache for batch PR data (refreshed each cycle)
_pr_cache: dict[str, dict] = {}
_pr_cache_lock = threading.Lock()

# Persistent PR cache that survives fetch failures (stale data fallback)
_last_successful_pr_cache: dict[str, dict] = {}
_last_successful_pr_cache_lock = threading.Lock()

# Persistent cache for conflict states (survives UNKNOWN responses from GitHub)
_conflict_cache: dict[str, bool] = {}
_conflict_cache_lock = threading.Lock()


# statusCheckRollup and comments are expensive GraphQL sub-queries: including them
# in a `gh pr list` over many open PRs makes GitHub return HTTP 504. They're fetched
# per-PR (cheap) and merged in instead — see _fetch_pr_heavy_fields.
_PR_HEAVY_FIELDS = ['statusCheckRollup', 'comments']

_PR_LIST_FIELDS = ','.join(
    [
        'number',
        'title',
        'state',
        'isDraft',
        'url',
        'mergedAt',
        'closedAt',
        'updatedAt',
        'createdAt',
        'headRefName',
        'headRefOid',
        'reviewDecision',
        'reviews',
        'latestReviews',
        'reviewRequests',
        'statusCheckRollup',
        'comments',
        'mergeable',
    ]
)

_PR_LIST_FIELDS_LIGHT = ','.join(f for f in _PR_LIST_FIELDS.split(',') if f not in _PR_HEAVY_FIELDS)

_REVIEW_REQUEST_FIELDS = ','.join(
    [
        'number',
        'title',
        'state',
        'isDraft',
        'url',
        'updatedAt',
        'createdAt',
        'headRefName',
        'headRefOid',
        'author',
        'reviewDecision',
        'reviews',
        'latestReviews',
        'reviewRequests',
        'statusCheckRollup',
    ]
)


_REVIEW_REQUEST_FIELDS_LIGHT = ','.join(f for f in _REVIEW_REQUEST_FIELDS.split(',') if f not in _PR_HEAVY_FIELDS)


def _fetch_pr_list(cmd: list[str], max_age: float, force: bool = False) -> tuple[list[dict], bool]:
    """Reuse discovery snapshots between their polls, never caching failed responses."""
    key = tuple(cmd)
    with _fetch_cache_lock:
        cached = _list_cache.get(key)
    if cached and not force and time.monotonic() - cached[0] < max_age:
        return deepcopy(cached[1]), True
    with _fetch_cache_lock:
        _list_cache.pop(key, None)
    ok, output = run_gh_command(cmd)
    if not ok:
        return [], False
    try:
        prs = json.loads(output)
    except json.JSONDecodeError:
        return [], False
    if not isinstance(prs, list) or not all(isinstance(pr, dict) for pr in prs):
        return [], False
    with _fetch_cache_lock:
        _store_snapshot(_list_cache, key, (time.monotonic(), prs))
    return prs, True


def _fetch_pr_heavy_fields(
    nwo: str, pr_number: str, fields: list[str] | None = None, expected_head: str = ''
) -> tuple[str, dict] | None:
    """Fetch only the expensive fields whose cached snapshots need revalidation."""
    fields = _PR_HEAVY_FIELDS if fields is None else fields
    ok, detail = run_gh_command(
        ['gh', 'pr', 'view', pr_number, '--repo', nwo, '--json', ','.join(['number', 'headRefOid', *fields])]
    )
    if ok and detail:
        try:
            data = json.loads(detail)
            if isinstance(data, dict) and all(
                field in data and isinstance(data[field], (list, type(None))) for field in fields
            ):
                if expected_head and data.get('headRefOid') != expected_head:
                    return None
                return pr_number, {field: data[field] for field in fields}
        except json.JSONDecodeError:
            pass

    if rate_limited_until():
        return None
    rest_data = _fetch_rest_pr_details(nwo, pr_number, fields=','.join(fields))
    if not rest_data or (expected_head and rest_data.get('headRefOid') != expected_head):
        return None
    return pr_number, {field: rest_data[field] for field in fields}


def _enrich_open_pr(nwo: str, pr: dict, include_comments: bool = True, force: bool = False) -> dict:
    """Invalidate comments on PR activity, but poll CI independently of updatedAt."""
    full = dict(pr)
    number = str(pr['number'])
    head = str(pr.get('headRefOid') or '')
    fields = _PR_HEAVY_FIELDS if include_comments else ['statusCheckRollup']
    due: list[str] = []
    revisions: dict[str, tuple[str, ...]] = {}
    for field in fields:
        revision = (head,) if field == 'statusCheckRollup' else (head, str(pr.get('updatedAt') or ''))
        revisions[field] = revision
        with _fetch_cache_lock:
            cached = _field_cache.get((nwo, number, field))
        if cached:
            cached_revision, fetched_at, data = cached
            # Never carry CI for a previous head onto a newly pushed commit.
            if cached_revision[0] == head:
                full.update(deepcopy(data))
            rollup = data.get('statusCheckRollup')
            settled = rollup and all(
                (ctx.get('status') or '').upper() == 'COMPLETED'
                or (ctx.get('__typename') == 'StatusContext' and ctx.get('state') in ('SUCCESS', 'FAILURE', 'ERROR'))
                for ctx in rollup
                if ctx
            )
            if field == 'statusCheckRollup' and not rollup:
                # Repositories without CI should not be polled as perpetually running.
                # Allow two minutes for checks to register after recent PR activity.
                changed_at = parse_timestamp(pr.get('updatedAt'))
                settled = changed_at is None or (datetime.now(timezone.utc) - changed_at).total_seconds() >= 120
            max_age = _ACTIVE_CI_INTERVAL if field == 'statusCheckRollup' and not settled else _SETTLED_INTERVAL
            if not force and head and cached_revision == revision and time.monotonic() - fetched_at < max_age:
                continue
        due.append(field)

    if due:
        result = _fetch_pr_heavy_fields(nwo, number, due, expected_head=head)
        if result is None:
            full['_details_stale'] = True
            # A failed forced refresh must retry too, even if the old snapshot's
            # normal TTL has not expired. Keep its data, but not its freshness.
            with _fetch_cache_lock:
                for field in due:
                    key = (nwo, number, field)
                    cached = _field_cache.get(key)
                    if cached:
                        _store_snapshot(_field_cache, key, (cached[0], time.monotonic() - _SETTLED_INTERVAL, cached[2]))
        else:
            full.update(result[1])
            with _fetch_cache_lock:
                for field in due:
                    _store_snapshot(
                        _field_cache,
                        (nwo, number, field),
                        (revisions[field], time.monotonic(), {field: result[1][field]}),
                    )
    return full


def _fetch_search_pr_numbers(nwo: str, query: str, max_pages: int = 1) -> tuple[list[str], bool]:
    """Find PR numbers through GitHub's conditionally revalidated REST search API."""
    numbers: list[str] = []
    for page in range(1, max_pages + 1):
        params = urlencode(
            {'q': f'repo:{nwo} {query}', 'per_page': 100, 'page': page, 'sort': 'updated', 'order': 'desc'}
        )
        data = _fetch_rest_json(f'search/issues?{params}')
        if not isinstance(data, dict) or not isinstance(data.get('items'), list) or data.get('incomplete_results'):
            return [], False
        if not all(isinstance(item, dict) and isinstance(item.get('number'), int) for item in data['items']):
            return [], False
        page_numbers = [str(item['number']) for item in data['items']]
        numbers.extend(page_numbers)
        if len(page_numbers) < 100:
            break
    return numbers, True


def _fetch_authored_pr_numbers(nwo: str, state: str, username: str) -> tuple[list[str], bool]:
    """Find authored PR numbers with REST when the gh author filter is unavailable."""
    if not username:
        return [], False
    return _fetch_search_pr_numbers(nwo, f'is:pr is:{state} author:{username}', max_pages=2)


def _fetch_rest_page(endpoint: str) -> tuple[dict | list, dict[str, str]] | None:
    """Revalidate REST pages with ETags; authenticated 304s spend no primary quota."""
    with _fetch_cache_lock:
        cached = _rest_cache.get(endpoint)
    cmd = ['gh', 'api', endpoint, '--include']
    if cached and cached[0].get('etag'):
        cmd.extend(['--header', f'If-None-Match: {cached[0]["etag"]}'])
    ok, output = run_gh_command(cmd)
    if not ok:
        return None
    headers_text, separator, body = output.replace('\r\n', '\n').partition('\n\n')
    lines = headers_text.splitlines()
    status = lines[0].split()[1:2] if lines else []
    headers = {name.lower(): value.strip() for line in lines[1:] if ':' in line for name, value in [line.split(':', 1)]}
    if status == ['304'] and cached:
        # Retain Link as well as the body: a 304 need not repeat pagination headers.
        headers = {**cached[0], **headers}
        with _fetch_cache_lock:
            _store_snapshot(_rest_cache, endpoint, (headers, cached[1]))
        return deepcopy(cached[1]), headers
    if status != ['200'] or not separator:
        return None
    try:
        value = json.loads(body)
    except json.JSONDecodeError:
        return None
    if not isinstance(value, (dict, list)):
        return None
    with _fetch_cache_lock:
        _store_snapshot(_rest_cache, endpoint, (headers, value))
    return value, headers


def _fetch_rest_json(endpoint: str) -> dict | list | None:
    """Fetch one JSON resource through GitHub's REST API."""
    page = _fetch_rest_page(endpoint)
    return page[0] if page else None


def _fetch_rest_items(endpoint: str, jq: str = '.[]') -> list[dict] | None:
    """Revalidate each REST page; a failed page is never a successful partial list."""
    items: list[dict] = []
    for _ in range(20):
        page = _fetch_rest_page(endpoint)
        if page is None:
            return None
        value, headers = page
        values = value.get('check_runs') if isinstance(value, dict) and jq == '.check_runs[]' else value
        if not isinstance(values, list) or not all(isinstance(item, dict) for item in values):
            return None
        items.extend(values)
        next_page = re.search(r'<([^>]+)>;\s*rel="next"', headers.get('link', ''))
        if not next_page:
            return items
        url = urlsplit(next_page.group(1))
        if url.scheme != 'https' or url.netloc != 'api.github.com':
            return None
        endpoint = url.path.lstrip('/') + ('?' + url.query if url.query else '')
    return None


def _fetch_rest_pr_details(nwo: str, pr_number: str, enrich: bool = True, fields: str | None = None) -> dict | None:
    """Build the requested PR fields from REST, without unrelated enrichment calls."""
    wanted = set((fields if fields is not None else _PR_LIST_FIELDS if enrich else '').split(','))
    basic = _fetch_rest_json(f'repos/{nwo}/pulls/{pr_number}')
    if not isinstance(basic, dict):
        return None

    head = basic.get('head') or {}
    head_sha = head.get('sha', '')
    mergeable = basic.get('mergeable')
    if mergeable is True:
        mergeable = 'MERGEABLE'
    elif mergeable is False:
        mergeable = 'CONFLICTING'

    mapped_reviews = []
    comments = []
    check_runs = []
    if wanted.intersection(('reviews', 'latestReviews')):
        reviews = _fetch_rest_items(f'repos/{nwo}/pulls/{pr_number}/reviews?per_page=100')
        if reviews is None:
            return None
        mapped_reviews = [
            {
                'author': {'login': (review.get('user') or {}).get('login', '')},
                'state': review.get('state'),
                'submittedAt': review.get('submitted_at'),
                'body': review.get('body', ''),
            }
            for review in reviews
        ]

    if 'comments' in wanted:
        for endpoint in (
            f'repos/{nwo}/issues/{pr_number}/comments?per_page=100',
            f'repos/{nwo}/pulls/{pr_number}/comments?per_page=100',
        ):
            fetched_comments = _fetch_rest_items(endpoint)
            if fetched_comments is None:
                return None
            for comment in fetched_comments:
                comments.append(
                    {
                        'author': {'login': (comment.get('user') or {}).get('login', '')},
                        'createdAt': comment.get('created_at'),
                        'updatedAt': comment.get('updated_at'),
                    }
                )

    if 'statusCheckRollup' in wanted and head_sha:
        checks = _fetch_rest_items(f'repos/{nwo}/commits/{head_sha}/check-runs?per_page=100', '.check_runs[]')
        if checks is None:
            return None
        for check in checks:
            check_runs.append(
                {
                    '__typename': 'CheckRun',
                    'name': check.get('name', ''),
                    'workflowName': (check.get('app') or {}).get('name', ''),
                    'status': check.get('status'),
                    'conclusion': check.get('conclusion'),
                    'detailsUrl': check.get('html_url', ''),
                    'completedAt': check.get('completed_at'),
                    'startedAt': check.get('started_at'),
                }
            )

    requested = basic.get('requested_reviewers') or []
    review_requests = []
    for reviewer in requested:
        if reviewer.get('login'):
            review_requests.append({'login': reviewer['login']})
        elif reviewer.get('name'):
            review_requests.append({'__typename': 'Team', 'name': reviewer['name']})

    return {
        'number': basic.get('number'),
        'title': basic.get('title', ''),
        'state': basic.get('state'),
        'author': {'login': (basic.get('user') or {}).get('login', '')},
        'isDraft': basic.get('draft', False),
        'url': basic.get('html_url', ''),
        'mergedAt': basic.get('merged_at'),
        'closedAt': basic.get('closed_at'),
        'updatedAt': basic.get('updated_at'),
        'createdAt': basic.get('created_at'),
        'headRefName': head.get('ref', ''),
        'headRefOid': head_sha,
        'reviewDecision': None,
        'reviews': mapped_reviews,
        'latestReviews': [],
        'reviewRequests': review_requests,
        'statusCheckRollup': check_runs,
        'comments': comments,
        'mergeable': mergeable,
    }


def _fetch_pr_details(args: tuple[str, str, str]) -> dict | None:
    """Fetch one PR's requested fields from GraphQL, falling back to REST."""
    nwo, pr_number, fields = args
    ok, detail = run_gh_command(['gh', 'pr', 'view', pr_number, '--repo', nwo, '--json', fields])
    if ok and detail:
        try:
            return json.loads(detail)
        except json.JSONDecodeError:
            pass
    if rate_limited_until():
        # The GraphQL bucket is gone; five REST calls per PR would only take the REST one with it.
        return None
    return _fetch_rest_pr_details(nwo, pr_number, fields=fields)


def _closed_pr_details(nwo: str, pr: dict, force: bool = False) -> dict | None:
    """A closed PR's full record: the light list fields plus checks and comments.

    Reuse details while updatedAt is unchanged, unless the user forces a refresh."""
    number = str(pr.get('number'))
    updated_at = str(pr.get('updatedAt') or '')
    key = (nwo, number)
    with _closed_pr_cache_lock:
        cached = _closed_pr_cache.get(key)
    if cached and cached[0] == updated_at and not force:
        return dict(cached[1])

    heavy = _fetch_pr_heavy_fields(nwo, number)
    if not heavy:
        with _closed_pr_cache_lock:
            _closed_pr_cache.pop(key, None)
        return {**pr, '_details_stale': True}
    full = {**pr, **heavy[1]}
    with _closed_pr_cache_lock:
        _store_snapshot(_closed_pr_cache, key, (updated_at, full))
    return full


def fetch_user_prs(force: bool = False) -> tuple[dict[str, dict], bool]:
    """Fetch relevant PRs authored by the current user across all configured repos.

    Returns (key_to_pr dict, open_fetch_success bool) where the key is
    "owner/name#branch" (see make_pr_key). Success is True only when the open-PR
    fetch succeeded for every repo, so a stale repo can't silently drop rows.
    """
    repos = get_repos()
    if not repos:
        return {}, False

    all_prs: dict[str, dict] = {}
    all_success = True
    with ThreadPoolExecutor(max_workers=len(repos)) as executor:
        for prs, ok in executor.map(lambda repo: _fetch_user_prs_for_repo(repo, force=force), repos):
            all_prs.update(prs)
            all_success = all_success and ok
    return all_prs, all_success


def _fetch_user_prs_for_repo(repo: dict, force: bool = False) -> tuple[dict[str, dict], bool]:
    """Fetch the current user's PRs for a single repo.

    Includes open PRs, closed-but-unmerged PRs, and recently merged PRs (last 30 days).

    The open discovery list is authoritative. Expensive fields are revalidated only
    when due or invalidated; closed discovery is slower and supplementary.
    """
    nwo = repo['nwo']
    current_user = get_current_user()
    all_prs: dict[str, dict] = {}
    debug = os.environ.get('PR_DASH_DEBUG', os.environ.get('WORKTREES_DEBUG', '')).lower() in ('1', 'true', 'yes')

    raw_open, open_success = _fetch_pr_list(
        [
            'gh',
            'pr',
            'list',
            '--repo',
            nwo,
            '--author',
            '@me',
            '--state',
            'open',
            '--limit',
            '200',
            '--json',
            _PR_LIST_FIELDS_LIGHT,
        ],
        _METADATA_INTERVAL,
        force=force,
    )

    if not open_success:
        open_numbers, fallback_success = _fetch_authored_pr_numbers(nwo, 'open', current_user)
        if fallback_success:
            open_success = True
            with ThreadPoolExecutor(max_workers=_parallel_workers()) as executor:
                raw_open = [
                    pr
                    for pr in executor.map(
                        _fetch_pr_details,
                        [(nwo, number, _PR_LIST_FIELDS_LIGHT) for number in open_numbers],
                    )
                    if pr
                ]
            open_success = len(raw_open) == len(open_numbers)
            if debug:
                print(f'[fetch] {nwo}: REST fallback found {len(raw_open)} open PRs')
        elif debug:
            print(f'[fetch] {nwo}: open PR fetch failed, including REST fallback')

    closed_force = force
    if open_success:
        numbers = {pr['number'] for pr in raw_open if pr.get('number') is not None}
        with _fetch_cache_lock:
            previous = _open_pr_numbers.get(nwo, numbers)
            _open_pr_numbers[nwo] = numbers
        # A PR leaving the open list must appear as closed/merged immediately, not
        # disappear until the slower closed discovery poll catches up.
        closed_force = force or bool(previous - numbers)
        with ThreadPoolExecutor(max_workers=_parallel_workers()) as executor:
            for raw_pr in executor.map(
                lambda pr: _enrich_open_pr(nwo, pr, force=force),
                [pr for pr in raw_open if pr.get('headRefName') and pr.get('number') is not None],
            ):
                branch = raw_pr['headRefName']
                parsed = _parse_pr(raw_pr, current_user, repo)
                if parsed:
                    all_prs[make_pr_key(nwo, branch)] = parsed

    # Closed discovery normally runs every ten minutes, or when a PR leaves the open list.
    merged_cutoff = datetime.now(timezone.utc) - timedelta(days=30)
    raw_closed, closed_success = _fetch_pr_list(
        [
            'gh',
            'pr',
            'list',
            '--repo',
            nwo,
            '--author',
            '@me',
            '--state',
            'closed',
            '--limit',
            '200',
            '--json',
            _PR_LIST_FIELDS_LIGHT,
        ],
        _CLOSED_LIST_INTERVAL,
        force=closed_force,
    )
    relevant_closed: list[dict] = []
    if closed_success:
        try:
            for pr in raw_closed:
                if not isinstance(pr, dict) or not pr.get('headRefName') or pr.get('number') is None:
                    continue
                merged_at = pr.get('mergedAt')
                if not merged_at:
                    relevant_closed.append(pr)
                else:
                    merged_time = parse_timestamp(merged_at)
                    if merged_time and merged_time >= merged_cutoff:
                        relevant_closed.append(pr)
        except (json.JSONDecodeError, KeyError, TypeError):
            closed_success = False

    if not closed_success and not rate_limited_until():
        # GraphQL list failed for a reason other than quota: find the numbers through REST search
        # and take each PR's basic record (one REST call each, no checks or comments).
        numbers, search_success = _fetch_authored_pr_numbers(nwo, 'closed', current_user)
        if search_success:
            closed_success = True
            if debug:
                print(f'[fetch] {nwo}: using REST fallback for closed PR discovery')
            with ThreadPoolExecutor(max_workers=_parallel_workers()) as executor:
                for raw_pr in executor.map(lambda n: _fetch_rest_pr_details(nwo, n, enrich=False), numbers[:20]):
                    if not raw_pr or not raw_pr.get('headRefName'):
                        continue
                    merged_at = raw_pr.get('mergedAt')
                    if merged_at:
                        merged_time = parse_timestamp(merged_at)
                        if not merged_time or merged_time < merged_cutoff:
                            continue
                    relevant_closed.append(raw_pr)

    if closed_success:
        if debug:
            print(f'[fetch] {nwo}: found {len(relevant_closed)} closed/recently-merged PRs')

        def _closed_row(pr: dict) -> tuple[str, dict] | None:
            full = _closed_pr_details(nwo, pr, force=force)
            if not full:
                return None
            branch = full.get('headRefName', '')
            parsed = _parse_pr(full, current_user, repo) if branch else None
            return (make_pr_key(nwo, branch), parsed) if parsed else None

        with ThreadPoolExecutor(max_workers=_parallel_workers()) as executor:
            for result in executor.map(_closed_row, relevant_closed):
                if result and result[0] not in all_prs:
                    all_prs[result[0]] = result[1]
    elif debug:
        print(f'[fetch] {nwo}: closed PR fetch failed, including REST fallback')

    return all_prs, open_success


def fetch_review_requests(force: bool = False) -> tuple[list[dict], bool]:
    """Fetch PRs needing review and recently reviewed by the current user, across repos.

    Returns pending review requests (direct + team-based) and open PRs
    the user has already reviewed. Each entry is tagged with review_status
    ('pending'/'reviewed') and is_direct_request so the frontend can filter:
    active-only mode shows only pending direct requests.
    """
    current_user = get_current_user()
    repos = get_repos()
    if not repos:
        return [], False

    pending_prs: list[dict] = []
    all_success = True
    with ThreadPoolExecutor(max_workers=len(repos)) as executor:
        for prs, ok in executor.map(lambda repo: _fetch_review_requests_for_repo(repo, force=force), repos):
            pending_prs.extend(prs)
            all_success = all_success and ok

    if not all_success:
        return [], False

    pending_prs.sort(key=lambda p: p.get('updatedAt', ''), reverse=True)

    results = []
    for pr in pending_prs:
        repo = pr.get('_repo', {})
        check_runs = parse_status_check_rollup(pr.get('statusCheckRollup'))
        ci_symbol, ci_class, ci_url = get_ci_status_summary(check_runs)

        author = pr.get('author', {})
        author_login = author.get('login', '') if author else ''

        approvers = []
        all_reviewers = set()
        user_approved = False
        all_reviews = list(pr.get('reviews', []) or []) + list(pr.get('latestReviews', []) or [])
        for review in all_reviews:
            if not review:
                continue
            reviewer = review.get('author', {})
            username = reviewer.get('login', '') if reviewer else ''
            if not username or is_bot_user(username):
                continue
            if username.lower() == current_user.lower():
                if review.get('state') == 'APPROVED':
                    user_approved = True
                continue
            all_reviewers.add(username)
            if review.get('state') == 'APPROVED':
                approvers.append(username)
        approvers = list(dict.fromkeys(approvers))
        approvers_set = set(approvers)

        pending_reviewers = []
        for req in pr.get('reviewRequests', []) or []:
            if not req or req.get('__typename') == 'Team':
                continue
            username = req.get('login') or req.get('name', '')
            if not username or is_bot_user(username) or username.lower() == current_user.lower():
                continue
            pending_reviewers.append(username)
        pending_reviewers = list(dict.fromkeys(pending_reviewers))
        pending_set = set(pending_reviewers)

        commented_reviewers = [u for u in all_reviewers if u not in approvers_set and u not in pending_set]

        updated_dt = parse_timestamp(pr.get('updatedAt'))
        updated_at = format_relative_time(updated_dt) if updated_dt else ''

        results.append(
            {
                'number': pr.get('number'),
                'title': pr.get('title', ''),
                'url': pr.get('url', ''),
                'branch': pr.get('headRefName', ''),
                'repo': repo.get('nwo', ''),
                'repo_label': repo.get('name', ''),
                'is_primary_repo': repo.get('primary', True),
                'pr_key': make_pr_key(repo.get('nwo', ''), str(pr.get('number', ''))),
                'author': author_login,
                'isDraft': pr.get('isDraft', False),
                'ci_symbol': ci_symbol,
                'ci_class': ci_class,
                'ci_url': ci_url,
                'check_runs': check_runs,
                'updated_at': updated_at,
                'approvers': approvers,
                'pending_reviewers': pending_reviewers,
                'commented_reviewers': commented_reviewers,
                'review_status': pr.get('_review_status', 'pending'),
                'is_direct_request': pr.get('_is_direct_request', True),
                'user_approved': user_approved,
                'details_stale': pr.get('_details_stale', False),
            }
        )

    return results, True


def _fetch_review_requests_for_repo(repo: dict, force: bool = False) -> tuple[list[dict], bool]:
    """Fetch pending + already-reviewed PRs for one repo, tagged with review metadata."""
    debug = os.environ.get('PR_DASH_DEBUG', os.environ.get('WORKTREES_DEBUG', '')).lower() in ('1', 'true', 'yes')
    current_user = get_current_user()
    nwo = repo['nwo']

    pending_prs, pending_success = _fetch_pr_list(
        [
            'gh',
            'pr',
            'list',
            '--repo',
            nwo,
            '--search',
            'review-requested:@me',
            '--state',
            'open',
            '--limit',
            '100',
            '--json',
            _REVIEW_REQUEST_FIELDS_LIGHT,
        ],
        _METADATA_INTERVAL,
        force=force,
    )
    if not pending_success:
        pending_numbers, rest_success = _fetch_search_pr_numbers(nwo, f'is:pr is:open review-requested:{current_user}')
        if rest_success:
            with ThreadPoolExecutor(max_workers=_parallel_workers()) as executor:
                pending_prs = [
                    pr
                    for pr in executor.map(
                        _fetch_pr_details,
                        [(nwo, number, _REVIEW_REQUEST_FIELDS_LIGHT) for number in pending_numbers],
                    )
                    if pr
                ]
            pending_success = len(pending_prs) == len(pending_numbers)
            if debug:
                print(f'[fetch] {nwo}: REST fallback found {len(pending_prs)} pending review requests')

    reviewed_prs, reviewed_success = _fetch_pr_list(
        [
            'gh',
            'pr',
            'list',
            '--repo',
            nwo,
            '--search',
            'reviewed-by:@me -author:@me',
            '--state',
            'open',
            '--limit',
            '50',
            '--json',
            _REVIEW_REQUEST_FIELDS_LIGHT,
        ],
        _METADATA_INTERVAL,
        force=force,
    )
    if not reviewed_success:
        reviewed_numbers, rest_success = _fetch_search_pr_numbers(
            nwo, f'is:pr is:open reviewed-by:{current_user} -author:{current_user}'
        )
        if rest_success:
            with ThreadPoolExecutor(max_workers=_parallel_workers()) as executor:
                reviewed_prs = [
                    pr
                    for pr in executor.map(
                        _fetch_pr_details,
                        [(nwo, number, _REVIEW_REQUEST_FIELDS_LIGHT) for number in reviewed_numbers],
                    )
                    if pr
                ]
            reviewed_success = len(reviewed_prs) == len(reviewed_numbers)
            if debug:
                print(f'[fetch] {nwo}: REST fallback found {len(reviewed_prs)} reviewed PRs')

    if not pending_success or not reviewed_success:
        return [], False

    pending_numbers = {pr.get('number') for pr in pending_prs}
    for pr in pending_prs:
        is_direct = any(
            (req.get('login') or '').lower() == current_user.lower()
            for req in (pr.get('reviewRequests', []) or [])
            if req
        )
        pr['_review_status'] = 'pending'
        pr['_is_direct_request'] = is_direct
        pr['_repo'] = repo

    for pr in reviewed_prs:
        if pr.get('number') not in pending_numbers:
            pr['_review_status'] = 'reviewed'
            pr['_is_direct_request'] = False
            pr['_repo'] = repo
            pending_prs.append(pr)

    with ThreadPoolExecutor(max_workers=_parallel_workers()) as executor:
        return list(
            executor.map(lambda pr: _enrich_open_pr(nwo, pr, include_comments=False, force=force), pending_prs)
        ), True


def _parse_pr(pr: dict, current_user: str, repo: dict) -> dict | None:
    """Parse a single PR from gh CLI JSON output into internal format."""
    if not pr:
        return None

    reviews = list(pr.get('reviews', []) or []) + list(pr.get('latestReviews', []) or [])
    approvers = []
    all_reviewers = set()
    latest_approval_time = None
    latest_review_comment_time = None
    review_comment_count = 0
    for review in reviews:
        if not review:
            continue
        author = review.get('author', {})
        username = author.get('login', '') if author else ''
        if not username or is_bot_user(username):
            continue
        if username.lower() == current_user.lower():
            continue

        all_reviewers.add(username)
        state = review.get('state')
        review_time = parse_timestamp(review.get('submittedAt'))

        if state == 'APPROVED':
            approvers.append(username)
            if review_time and (latest_approval_time is None or review_time > latest_approval_time):
                latest_approval_time = review_time
        elif state in ('COMMENTED', 'CHANGES_REQUESTED') and review.get('body'):
            review_comment_count += 1
            if review_time and (latest_review_comment_time is None or review_time > latest_review_comment_time):
                latest_review_comment_time = review_time

    pending_reviewers = []
    for req in pr.get('reviewRequests', []) or []:
        if not req or req.get('__typename') == 'Team':
            continue
        username = req.get('login') or req.get('name', '')
        if not username or is_bot_user(username):
            continue
        if username.lower() == current_user.lower():
            continue
        pending_reviewers.append(username)

    approvers_set = set(approvers)
    pending_set = set(pending_reviewers)
    commented_reviewers = [u for u in all_reviewers if u not in approvers_set and u not in pending_set]

    check_runs = parse_status_check_rollup(pr.get('statusCheckRollup'))

    latest_comment_time = None
    other_comment_count = 0
    for comment in pr.get('comments', []) or []:
        if not comment:
            continue
        author = comment.get('author', {})
        username = author.get('login', '') if author else ''
        if username.lower() == current_user.lower() or is_bot_user(username):
            continue
        other_comment_count += 1
        comment_time = parse_timestamp(comment.get('updatedAt') or comment.get('createdAt'))
        if comment_time and (latest_comment_time is None or comment_time > latest_comment_time):
            latest_comment_time = comment_time

    other_comment_count += review_comment_count
    if latest_review_comment_time and (latest_comment_time is None or latest_review_comment_time > latest_comment_time):
        latest_comment_time = latest_review_comment_time

    mergeable = pr.get('mergeable', '')
    if mergeable == 'CONFLICTING':
        has_conflicts = True
    elif mergeable == 'MERGEABLE':
        has_conflicts = False
    else:
        has_conflicts = None

    return {
        'number': pr.get('number'),
        'repo': repo.get('nwo', ''),
        'repo_label': repo.get('name', ''),
        'is_primary_repo': repo.get('primary', True),
        'pr_key': make_pr_key(repo.get('nwo', ''), str(pr.get('number', ''))),
        'title': pr.get('title', ''),
        'state': pr.get('state'),
        'isDraft': pr.get('isDraft', False),
        'url': pr.get('url', ''),
        'mergedAt': pr.get('mergedAt'),
        'closedAt': pr.get('closedAt'),
        'updatedAt': pr.get('updatedAt'),
        'createdAt': pr.get('createdAt'),
        'head_sha': pr.get('headRefOid'),
        'details_stale': pr.get('_details_stale', False),
        'reviewDecision': pr.get('reviewDecision'),
        'last_push_at': None,
        'approvers': list(set(approvers)),
        'pending_reviewers': list(set(pending_reviewers)),
        'commented_reviewers': commented_reviewers,
        'latest_approval_time': latest_approval_time,
        'latest_comment_time': latest_comment_time,
        'check_runs': check_runs,
        'comment_count': other_comment_count,
        'has_conflicts': has_conflicts,
    }


def is_bot_user(username: str) -> bool:
    """Check if a username belongs to a bot/automated account."""
    if not username:
        return False
    username_lower = username.lower()
    if '[bot]' in username_lower:
        return True
    if username_lower.endswith('-bot') or username_lower.endswith('-ci'):
        return True
    if username_lower.endswith('-reviewers') or username_lower.endswith('_reviewers'):
        return True
    if '-github-app' in username_lower:
        return True
    known_bots = {
        'dependabot',
        'codecov',
        'github-actions',
        'renovate',
        'snyk-bot',
        'copilot',
        'cursor',
        'chatgpt-codex-connector',
        'devin-ai-integration',
    }
    # Org-specific review bots: PR_DASH_BOTS="acme-reviewer,acme-commenter"
    extra = os.environ.get('PR_DASH_BOTS', '')
    known_bots |= {b.strip().lower() for b in extra.split(',') if b.strip()}
    return username_lower in known_bots


def get_worktrees(repo_path: str = '') -> list[tuple[str, str]]:
    """Get list of worktrees and their branches for a repo checkout (default: cwd)."""
    cmd = (
        ['git', '-C', repo_path, 'worktree', 'list', '--porcelain']
        if repo_path
        else ['git', 'worktree', 'list', '--porcelain']
    )
    success, output = run_command(cmd)
    if not success:
        return []

    worktrees = []
    current_worktree = None
    current_branch = None

    for line in output.split('\n'):
        line = line.strip()
        if line.startswith('worktree '):
            current_worktree = line[9:]
        elif line.startswith('branch '):
            current_branch = line[7:].replace('refs/heads/', '')
        elif line == 'bare':
            current_branch = '(bare)'
        elif line == 'detached':
            current_branch = '(detached)'
        elif line == '' and current_worktree:
            worktrees.append((current_worktree, current_branch))
            current_worktree = None
            current_branch = None

    if current_worktree:
        worktrees.append((current_worktree, current_branch))

    return worktrees


def check_worktree_status(worktree_path: str, branch: str) -> tuple[bool, bool]:
    """Check if a worktree has uncommitted changes or unpushed commits."""
    has_dirty = False
    has_unpushed = False

    if not worktree_path or branch in ('(bare)', '(detached)'):
        return has_dirty, has_unpushed

    success, output = run_command(['git', '-C', worktree_path, 'status', '--porcelain'])
    if success and output.strip():
        has_dirty = True

    # Check if origin/<branch> exists and compare against it directly
    # This is more accurate than @{upstream} which might track a different branch
    remote_branch = f'origin/{branch}'
    success, _ = run_command(['git', '-C', worktree_path, 'rev-parse', '--verify', f'refs/remotes/{remote_branch}'])
    if success:
        success, output = run_command(['git', '-C', worktree_path, 'rev-list', f'{remote_branch}..HEAD', '--count'])
        if success and output.strip():
            try:
                if int(output.strip()) > 0:
                    has_unpushed = True
            except ValueError:
                pass

    return has_dirty, has_unpushed


def get_dirty_files(worktree_path: str) -> list[dict]:
    """Get list of dirty (uncommitted) files in a worktree with diff stats."""
    if not worktree_path:
        return []

    success, output = run_command(['git', '-C', worktree_path, 'status', '--porcelain'])
    if not success or not output.strip():
        return []

    # Get diff stats for unstaged changes
    unstaged_stats: dict[str, dict[str, int]] = {}
    success, numstat_output = run_command(['git', '-C', worktree_path, 'diff', '--numstat'])
    if success and numstat_output:
        for line in numstat_output.strip().split('\n'):
            if line:
                parts = line.split('\t')
                if len(parts) >= 3:
                    additions, deletions, filename = parts[0], parts[1], parts[2]
                    # Handle binary files (shown as '-')
                    unstaged_stats[filename] = {
                        'additions': int(additions) if additions != '-' else 0,
                        'deletions': int(deletions) if deletions != '-' else 0,
                    }

    # Get diff stats for staged changes
    staged_stats: dict[str, dict[str, int]] = {}
    success, numstat_output = run_command(['git', '-C', worktree_path, 'diff', '--cached', '--numstat'])
    if success and numstat_output:
        for line in numstat_output.strip().split('\n'):
            if line:
                parts = line.split('\t')
                if len(parts) >= 3:
                    additions, deletions, filename = parts[0], parts[1], parts[2]
                    staged_stats[filename] = {
                        'additions': int(additions) if additions != '-' else 0,
                        'deletions': int(deletions) if deletions != '-' else 0,
                    }

    status_map = {
        'M': 'modified',
        'A': 'added',
        'D': 'deleted',
        'R': 'renamed',
        'C': 'copied',
        '?': 'untracked',
        'U': 'unmerged',
    }

    files = []
    for line in output.strip().split('\n'):
        # Handle CRLF line endings
        line = line.rstrip('\r')

        # Git porcelain format: "XY filename" - exactly 2 status chars + space + filename
        if len(line) < 4:
            continue

        status = line[:2]
        # Take everything after position 2 and strip leading whitespace
        filename = line[2:].lstrip()

        if not filename:
            continue

        # Get status from first non-space character in status field
        status_char = status[0] if status[0] != ' ' else (status[1] if len(status) > 1 else '?')
        status_text = status_map.get(status_char, 'changed')

        # Combine staged and unstaged stats
        additions = 0
        deletions = 0
        if filename in staged_stats:
            additions += staged_stats[filename]['additions']
            deletions += staged_stats[filename]['deletions']
        if filename in unstaged_stats:
            additions += unstaged_stats[filename]['additions']
            deletions += unstaged_stats[filename]['deletions']

        files.append(
            {
                'filename': filename,
                'status': status_text,
                'raw_status': status.strip(),
                'additions': additions,
                'deletions': deletions,
            }
        )

    return files


def get_unpushed_commits(worktree_path: str, branch: str = '') -> list[dict]:
    """Get list of unpushed commits in a worktree."""
    if not worktree_path:
        return []

    # Get current branch if not provided
    if not branch:
        success, branch = run_command(['git', '-C', worktree_path, 'rev-parse', '--abbrev-ref', 'HEAD'])
        if not success or not branch.strip():
            return []
        branch = branch.strip()

    # Check if origin/<branch> exists
    remote_branch = f'origin/{branch}'
    success, _ = run_command(['git', '-C', worktree_path, 'rev-parse', '--verify', f'refs/remotes/{remote_branch}'])
    if not success:
        return []

    success, output = run_command(
        ['git', '-C', worktree_path, 'log', f'{remote_branch}..HEAD', '--oneline', '--format=%h|%s']
    )
    if not success or not output.strip():
        return []

    commits = []
    for line in output.strip().split('\n'):
        if '|' in line:
            sha, message = line.split('|', 1)
            commits.append({'sha': sha, 'message': message})

    return commits


def find_pr_for_branch(branch: str, repo_owner: str, repo_name: str) -> dict | None:
    """Find PR for a branch by querying GitHub.

    Returns:
        dict with PR info, or
        dict with {'_error': True} if fetch failed, or
        None if no PR exists
    """
    success, output = run_gh_command(
        [
            'gh',
            'pr',
            'list',
            '--head',
            branch,
            '--state',
            'all',
            '--limit',
            '1',
            '--json',
            'number,title,state,isDraft,url,mergedAt,closedAt,updatedAt,createdAt',
        ]
    )
    if not success:
        # Distinguish fetch failure from "no PR"
        return {'_error': True}
    if not output:
        return None
    try:
        prs = json.loads(output)
        if not prs:
            return None
        pr = prs[0]
        pr_number = pr['number']

        api_success, api_output = run_gh_command(
            [
                'gh',
                'api',
                f'repos/{repo_owner}/{repo_name}/pulls/{pr_number}',
                '--jq',
                '{comments, review_comments, updated_at, created_at, head: {sha: .head.sha}}',
            ]
        )
        if api_success and api_output:
            try:
                pr_details = json.loads(api_output)
                pr['comments'] = pr_details.get('comments', 0)
                pr['review_comments'] = pr_details.get('review_comments', 0)
                if 'updated_at' in pr_details and not pr.get('updatedAt'):
                    pr['updatedAt'] = pr_details.get('updated_at')
                if 'head' in pr_details and isinstance(pr_details['head'], dict):
                    pr['head_sha'] = pr_details['head'].get('sha')
            except (json.JSONDecodeError, TypeError):
                pass

        # Get the latest commit date (for push-based sorting, not CI events)
        head_sha = pr.get('head_sha')
        if head_sha:
            commit_success, commit_output = run_gh_command(
                [
                    'gh',
                    'api',
                    f'repos/{repo_owner}/{repo_name}/commits/{head_sha}',
                    '--jq',
                    '.commit.committer.date',
                ]
            )
            if commit_success and commit_output:
                pr['last_push_at'] = commit_output.strip()

        return pr
    except (json.JSONDecodeError, IndexError, KeyError):
        return None


def get_pr_approvals(pr_number: str, repo_owner: str, repo_name: str) -> tuple[str, datetime | None, bool]:
    """Get PR approvals (list of reviewer names) and latest approval time.

    Returns: (approvers_string, latest_approval_time, success)
    """
    success, output = run_gh_command(
        [
            'gh',
            'api',
            f'repos/{repo_owner}/{repo_name}/pulls/{pr_number}/reviews',
            '--paginate',
            '-q',
            '.[]',
        ]
    )
    if not success:
        return '', None, False
    if not output:
        return '', None, True  # No approvals, but fetch succeeded
    try:
        approvers = []
        latest_approval_time = None
        for line in output.strip().split('\n'):
            if not line.strip():
                continue
            try:
                review = json.loads(line)
                if isinstance(review, dict) and review.get('state') == 'APPROVED':
                    user = review.get('user', {})
                    if isinstance(user, dict):
                        username = user.get('login', '')
                        if username and not is_bot_user(username):
                            approvers.append(username)
                            # Track approval time
                            submitted_at = review.get('submitted_at')
                            if submitted_at:
                                approval_time = parse_timestamp(submitted_at)
                                if approval_time and (
                                    latest_approval_time is None or approval_time > latest_approval_time
                                ):
                                    latest_approval_time = approval_time
            except (json.JSONDecodeError, KeyError, TypeError):
                continue
        return ', '.join(sorted(set(approvers))), latest_approval_time, True
    except (json.JSONDecodeError, KeyError):
        return '', None, False


def get_pr_check_runs(pr_number: str, head_sha: str, repo_owner: str, repo_name: str) -> tuple[list[dict], bool]:
    """Get check runs for a PR's head commit.

    Returns: (check_runs_list, success)
    """
    if not head_sha:
        return [], True  # No SHA to check, but not a failure

    success, output = run_gh_command(
        [
            'gh',
            'api',
            f'repos/{repo_owner}/{repo_name}/commits/{head_sha}/check-runs',
            '--paginate',
            '-q',
            '.check_runs[]',
        ]
    )
    if not success:
        return [], False
    if not output:
        return [], True  # No check runs, but fetch succeeded

    check_runs = []
    for line in output.strip().split('\n'):
        if not line.strip():
            continue
        try:
            check_run = json.loads(line)
            if isinstance(check_run, dict):
                check_runs.append(
                    {
                        'name': check_run.get('name', ''),
                        'status': check_run.get('status', ''),
                        'conclusion': check_run.get('conclusion', ''),
                        'html_url': check_run.get('html_url', ''),
                        'completed_at': check_run.get('completed_at', '') or check_run.get('started_at', ''),
                    }
                )
        except (json.JSONDecodeError, TypeError):
            continue

    # Keep only latest per name
    latest_by_name = {}
    for cr in check_runs:
        name = cr['name']
        if name not in latest_by_name or cr.get('completed_at', '') > latest_by_name[name].get('completed_at', ''):
            latest_by_name[name] = cr

    return sorted(latest_by_name.values(), key=lambda x: x['name']), True


def parse_status_check_rollup(rollup: list[dict] | None) -> list[dict]:
    """Reduce a GitHub statusCheckRollup to one entry per check name.

    GitHub returns every run for the PR's head SHA, so a check name can appear
    multiple times (e.g. retries). We keep the most recent by completedAt so a
    flaky-then-passing run reports as success, not failure.
    """
    latest_by_name: dict[str, dict] = {}
    for ctx in rollup or []:
        if not ctx or ctx.get('__typename') != 'CheckRun':
            continue
        name = ctx.get('name', '')
        completed_at = ctx.get('completedAt', '') or ctx.get('startedAt', '') or ''
        existing = latest_by_name.get(name)
        if existing and existing.get('completed_at', '') >= completed_at:
            continue
        latest_by_name[name] = {
            'name': name,
            'workflow_name': ctx.get('workflowName', ''),
            'status': (ctx.get('status') or '').lower(),
            'conclusion': (ctx.get('conclusion') or '').lower(),
            'html_url': ctx.get('detailsUrl', ''),
            'completed_at': completed_at,
        }
    return sorted(latest_by_name.values(), key=lambda x: x['name'])


# The human-approval gate fails on every PR until a code owner approves, which is
# expected and not an actionable CI failure — exclude it from the status summary.
_APPROVAL_CHECK_WORKFLOW = 'pr_approval_check'


def is_approval_check_run(cr: dict) -> bool:
    return cr.get('workflow_name', '') == _APPROVAL_CHECK_WORKFLOW


def get_ci_status_summary(check_runs: list[dict]) -> tuple[str, str, str | None]:
    """Get CI/CD status summary. Returns (symbol, css_class, url)."""
    if not check_runs:
        return ('—', 'ci-none', None)

    has_failure = False
    failure_url = None
    has_running = False
    running_url = None
    has_queued = False
    queued_url = None
    all_success = True

    for cr in check_runs:
        if is_approval_check_run(cr):
            continue

        status = cr.get('status', '')
        conclusion = cr.get('conclusion', '')

        if status == 'completed':
            if conclusion == 'failure':
                has_failure = True
                if not failure_url:
                    failure_url = cr.get('html_url')
                all_success = False
            elif conclusion not in ('success', 'skipped', 'cancelled'):
                all_success = False
        elif status == 'in_progress':
            has_running = True
            if not running_url:
                running_url = cr.get('html_url')
            all_success = False
        elif status == 'queued':
            has_queued = True
            if not queued_url:
                queued_url = cr.get('html_url')
            all_success = False

    if has_failure:
        return ('✗', 'ci-fail', failure_url)
    elif has_running:
        return ('⟳', 'ci-running', running_url)
    elif has_queued:
        return ('⏳', 'ci-queued', queued_url)
    elif all_success:
        return ('✓', 'ci-pass', None)
    else:
        return ('○', 'ci-other', None)


def get_pr_comments(
    pr_data: dict, pr_number: str, repo_owner: str, repo_name: str, current_user: str = ''
) -> tuple[int, datetime | None, bool]:
    """Get PR comment count (by others only) and latest human comment time.

    Returns: (comment_count, latest_comment_time, success)
    """
    issue_cmd = ['gh', 'api', f'repos/{repo_owner}/{repo_name}/issues/{pr_number}/comments', '--paginate', '-q', '.[]']
    review_cmd = ['gh', 'api', f'repos/{repo_owner}/{repo_name}/pulls/{pr_number}/comments', '--paginate', '-q', '.[]']

    issue_success, issue_output = run_gh_command(issue_cmd)
    review_success, review_output = run_gh_command(review_cmd)

    # If both calls failed, report error
    if not issue_success and not review_success:
        return 0, None, False

    all_comments = []
    for success, output in [(issue_success, issue_output), (review_success, review_output)]:
        if success and output:
            for line in output.strip().split('\n'):
                if line.strip():
                    try:
                        all_comments.append(json.loads(line))
                    except (json.JSONDecodeError, TypeError):
                        continue

    latest_human_time = None
    other_comment_count = 0

    for comment in all_comments:
        if not isinstance(comment, dict):
            continue
        comment_user = comment.get('user', {})
        comment_username = comment_user.get('login', '') if isinstance(comment_user, dict) else ''

        # Skip my comments and bot comments
        if current_user and comment_username.lower() == current_user.lower():
            continue
        if is_bot_user(comment_username):
            continue

        # Count this comment
        other_comment_count += 1

        comment_time_str = comment.get('updated_at') or comment.get('created_at')
        if comment_time_str:
            try:
                if comment_time_str.endswith('Z'):
                    comment_time_str = comment_time_str[:-1] + '+00:00'
                comment_time = datetime.fromisoformat(comment_time_str)
                if comment_time.tzinfo is None:
                    comment_time = comment_time.replace(tzinfo=timezone.utc)
                if latest_human_time is None or comment_time > latest_human_time:
                    latest_human_time = comment_time
            except (ValueError, AttributeError, TypeError):
                continue

    return other_comment_count, latest_human_time, True


def parse_timestamp(timestamp_str: str | None) -> datetime | None:
    """Parse ISO8601 timestamp string to datetime."""
    if not timestamp_str:
        return None
    try:
        if timestamp_str.endswith('Z'):
            timestamp_str = timestamp_str[:-1] + '+00:00'
        dt = datetime.fromisoformat(timestamp_str)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except (ValueError, AttributeError, TypeError):
        return None


def format_relative_time(dt: datetime) -> str:
    """Format datetime as relative time."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    diff = now - dt

    if diff.total_seconds() < 60:
        return 'now'
    elif diff.total_seconds() < 3600:
        return f'{int(diff.total_seconds() / 60)}m ago'
    elif diff.total_seconds() < 86400:
        return f'{int(diff.total_seconds() / 3600)}h ago'
    elif diff.total_seconds() < 604800:
        return f'{int(diff.total_seconds() / 86400)}d ago'
    else:
        return dt.strftime('%b %d')


def get_relative_path(worktree_path: str) -> str:
    """Get relative path from current directory."""
    try:
        current_dir = Path.cwd()
        worktree = Path(worktree_path).resolve()
        try:
            return str(worktree.relative_to(current_dir))
        except ValueError:
            return f'../{worktree.name}'
    except Exception:
        return Path(worktree_path).name


def fetch_worktree_data(worktree: str | None, repo: dict, branch: str, display_path: str) -> dict:
    """Fetch all data for a worktree. Uses batch-fetched PR data from _pr_cache.

    Args:
        worktree: Path to the worktree, or None for virtual/deleted worktrees
        repo: Repo entry from get_repos() that owns this branch
        branch: Branch name
        display_path: Path to display in the UI (may differ from worktree for virtual entries)
    """
    result = {
        'worktree': worktree,
        'worktree_display': display_path or '-',
        'branch': branch,
        'repo': repo.get('nwo', ''),
        'repo_label': repo.get('name', ''),
        'is_primary_repo': repo.get('primary', True),
        'pr': None,
        'pr_url': '',
        'pr_title': '',
        'pr_number': '',
        'pr_key': '',
        'status': 'no-pr',
        'status_label': 'No PR',
        'approvers': [],
        'pending_reviewers': [],
        'commented_reviewers': [],
        'comment_count': 0,
        'last_comment': '',
        'ci_symbol': '—',
        'ci_class': 'ci-none',
        'ci_url': None,
        'check_runs': [],
        'has_dirty': False,
        'has_unpushed': False,
        'has_conflicts': False,
        'pr_updated_at': None,
        'updated_at': '',  # Formatted relative time for Updated column
        'updated_timestamp': None,  # ISO timestamp for sorting
        'last_comment_timestamp': None,  # ISO timestamp for Last column sorting
        'is_virtual': worktree is None,  # True if this is a virtual/deleted worktree
    }

    if branch in ('(bare)', '(detached)'):
        result['status'] = 'special'
        result['status_label'] = branch
        return result

    # Only check local status if worktree exists
    if worktree:
        has_dirty, has_unpushed = check_worktree_status(worktree, branch)
        result['has_dirty'] = has_dirty
        result['has_unpushed'] = has_unpushed

    # Look up PR from batch-fetched cache (no API call needed)
    with _pr_cache_lock:
        pr = _pr_cache.get(make_pr_key(repo.get('nwo', ''), branch))

    if pr:
        result['pr'] = pr
        result['pr_url'] = pr.get('url', '')
        result['pr_title'] = pr.get('title', '')
        result['pr_number'] = str(pr.get('number', ''))
        result['pr_key'] = pr.get('pr_key', '')
        result['pr_updated_at'] = parse_timestamp(pr.get('updatedAt'))

        pr_state = (pr.get('state') or '').upper()
        is_draft = pr.get('isDraft', False)
        merged_at = pr.get('mergedAt')

        # Approvals and pending reviewers come from batch fetch
        approvers_list = pr.get('approvers', [])
        pending_reviewers_list = pr.get('pending_reviewers', [])
        latest_approval_time = pr.get('latest_approval_time')
        review_decision = pr.get('reviewDecision')
        result['approvers'] = approvers_list
        result['pending_reviewers'] = pending_reviewers_list
        result['commented_reviewers'] = pr.get('commented_reviewers', [])

        # Handle conflict status with caching for UNKNOWN responses
        pr_conflicts = pr.get('has_conflicts')
        conflict_key = pr.get('pr_key') or make_pr_key(repo.get('nwo', ''), str(pr.get('number', '')))
        if pr_conflicts is None:
            # GitHub returned UNKNOWN - use cached value if available
            with _conflict_cache_lock:
                result['has_conflicts'] = _conflict_cache.get(conflict_key, False)
        else:
            # Definite answer from GitHub - update cache
            result['has_conflicts'] = pr_conflicts
            with _conflict_cache_lock:
                _conflict_cache[conflict_key] = pr_conflicts

        if merged_at:
            result['status'] = 'merged'
            result['status_label'] = 'Merged'
        elif pr_state == 'CLOSED':
            result['status'] = 'closed'
            result['status_label'] = 'Closed'
        elif is_draft:
            result['status'] = 'draft'
            result['status_label'] = 'Draft'
        elif review_decision == 'APPROVED':
            result['status'] = 'approved'
            result['status_label'] = 'Approved'
        else:
            result['status'] = 'open'
            result['status_label'] = 'Open'

        # Comment count from batch fetch (GraphQL gives total count, not filtered)
        result['comment_count'] = pr.get('comment_count', 0)

        # Activity timestamps for sorting and display
        last_push = parse_timestamp(pr.get('last_push_at'))
        pr_created = parse_timestamp(pr.get('createdAt'))
        latest_comment_time = pr.get('latest_comment_time')

        # Updated = max of (PR creation, latest commit, latest comment, latest approval)
        activity_times = [t for t in [pr_created, last_push, latest_comment_time, latest_approval_time] if t]
        if activity_times:
            max_activity = max(activity_times)
            result['updated_timestamp'] = max_activity.isoformat()
            result['updated_at'] = format_relative_time(max_activity)

        # Last = max of (latest comment time from others, latest approval time)
        interaction_times = [t for t in [latest_comment_time, latest_approval_time] if t]
        if interaction_times:
            last_interaction = max(interaction_times)
            result['last_comment'] = format_relative_time(last_interaction)
            result['last_comment_timestamp'] = last_interaction.isoformat()

        # Check runs from batch fetch
        check_runs = pr.get('check_runs', [])
        result['check_runs'] = check_runs
        ci_symbol, ci_class, ci_url = get_ci_status_summary(check_runs)
        result['ci_symbol'] = ci_symbol
        result['ci_class'] = ci_class
        result['ci_url'] = ci_url

    # Fallback: if no updated timestamp yet, use max of (commit time, worktree creation time)
    if not result['updated_timestamp'] and worktree:
        fallback_time = None

        # Get the latest commit time on this branch
        success, output = run_command(['git', '-C', worktree, 'log', '-1', '--format=%cI', 'HEAD'])
        if success and output.strip():
            commit_time = parse_timestamp(output.strip())
            if commit_time and (not fallback_time or commit_time > fallback_time):
                fallback_time = commit_time

        # Get worktree directory creation time
        try:
            worktree_path = Path(worktree)
            if worktree_path.exists():
                stat = worktree_path.stat()
                # Use birth time if available (macOS), otherwise use mtime
                ctime = getattr(stat, 'st_birthtime', None) or stat.st_mtime
                creation_time = datetime.fromtimestamp(ctime, tz=timezone.utc)
                if creation_time and (not fallback_time or creation_time > fallback_time):
                    fallback_time = creation_time
        except (OSError, AttributeError):
            pass

        if fallback_time:
            result['updated_timestamp'] = fallback_time.isoformat()
            result['updated_at'] = format_relative_time(fallback_time)

    return result


def refresh_cache(force: bool = False) -> None:
    """Refresh the PR data cache.

    GitHub PRs are the source of truth. Local worktrees enrich with dirty/unpushed status.
    """
    with _cache_lock:
        if _cache['updating']:
            return
        _cache['updating'] = True

    try:
        repos = get_repos()
        if not repos:
            return

        pr_data, fetch_success = fetch_user_prs(force=force)

        is_stale = any(pr.get('details_stale') for pr in pr_data.values())
        if fetch_success and pr_data:
            with _pr_cache_lock:
                _pr_cache.clear()
                _pr_cache.update(pr_data)
            with _last_successful_pr_cache_lock:
                _last_successful_pr_cache.update(pr_data)
        elif not fetch_success:
            is_stale = True
            with _last_successful_pr_cache_lock:
                pr_data = dict(_last_successful_pr_cache)
            with _pr_cache_lock:
                _pr_cache.clear()
                _pr_cache.update(pr_data)
        else:
            with _pr_cache_lock:
                _pr_cache.clear()

        repos_by_nwo = {repo['nwo']: repo for repo in repos}

        # Worktrees are per-checkout, so map them under the same repo#branch key as PRs.
        worktree_map: dict[str, str] = {}
        for repo in repos:
            if not repo.get('path'):
                continue
            for wt_path, branch in get_worktrees(repo['path']):
                if branch not in ('(bare)', '(detached)'):
                    worktree_map[make_pr_key(repo['nwo'], branch)] = wt_path

        entries: list[tuple[str | None, dict, str, str]] = []
        for key, pr in pr_data.items():
            repo = repos_by_nwo.get(pr.get('repo', ''))
            if repo is None:
                continue
            branch = key.split('#', 1)[1] if '#' in key else key
            wt_path = worktree_map.get(key)
            display_path = get_relative_path(wt_path) if wt_path else ''
            entries.append((wt_path, repo, branch, display_path))

        results = []
        with ThreadPoolExecutor(max_workers=10) as executor:
            futures = {
                executor.submit(fetch_worktree_data, wt, repo, br, display): (wt, repo, br, display)
                for wt, repo, br, display in entries
            }
            for future in as_completed(futures):
                try:
                    results.append(future.result())
                except Exception:
                    wt, repo, br, display = futures[future]
                    results.append(
                        {
                            'worktree': wt,
                            'worktree_display': display,
                            'branch': br,
                            'repo': repo.get('nwo', ''),
                            'repo_label': repo.get('name', ''),
                            'is_primary_repo': repo.get('primary', True),
                            'status': 'error',
                            'status_label': 'Error',
                            'pr_url': '',
                            'pr_title': '',
                            'pr_key': '',
                            'approvers': [],
                            'pending_reviewers': [],
                            'commented_reviewers': [],
                            'comment_count': 0,
                            'last_comment': '',
                            'ci_symbol': '—',
                            'ci_class': 'ci-none',
                            'ci_url': None,
                            'has_dirty': False,
                            'has_unpushed': False,
                            'has_conflicts': False,
                            'pr_updated_at': None,
                            'updated_at': '',
                            'updated_timestamp': None,
                            'last_comment_timestamp': None,
                        }
                    )

        def sort_key(d):
            if d.get('pr_updated_at'):
                return (-d['pr_updated_at'].timestamp(), d.get('repo', ''), d['branch'])
            return (0.0, d.get('repo', ''), d['branch'])

        results.sort(key=sort_key)

        review_requests, rr_success = fetch_review_requests(force=force)
        is_stale = is_stale or not rr_success or any(pr.get('details_stale') for pr in review_requests)

        with _cache_lock:
            _cache['data'] = results
            if rr_success:
                _cache['review_requests'] = review_requests
            _cache['last_updated'] = datetime.now(timezone.utc)
            _cache['is_stale'] = is_stale
    finally:
        with _cache_lock:
            _cache['updating'] = False


def _note_activity() -> None:
    """Wake the idle poller when a viewer returns, instead of waiting up to ten minutes."""
    now = datetime.now(timezone.utc)
    with _api_access_lock:
        previous = _api_state['last_access']
        _api_state['last_access'] = now
    if previous is None or (now - previous).total_seconds() >= 120:
        _refresh_wakeup.set()


def _refresh_interval() -> int:
    """Use the same refresh schedule for the poller and the browser countdown."""
    with _cache_lock:
        rows = _cache['data'] + _cache['review_requests']
        has_errors = _cache['is_stale'] or any(d.get('status') == 'fetch-error' for d in rows)
    if has_errors:
        return _ACTIVE_CI_INTERVAL
    with _api_access_lock:
        last_access = _api_state['last_access']
    if last_access and (datetime.now(timezone.utc) - last_access).total_seconds() < 120:
        if any(
            cr.get('status') in ('in_progress', 'queued') and not is_approval_check_run(cr)
            for row in rows
            for cr in row.get('check_runs', [])
        ):
            return _ACTIVE_CI_INTERVAL
        return _METADATA_INTERVAL
    return _CLOSED_LIST_INTERVAL


def background_refresh() -> None:
    """Refresh on the adaptive schedule, waking early when an idle viewer returns."""
    while True:
        _refresh_wakeup.clear()
        try:
            refresh_cache()
        except Exception as e:
            print(f'Error refreshing cache: {e}')

        limited_until = rate_limited_until()
        sleep_time = (
            max(15.0, (limited_until - datetime.now(timezone.utc)).total_seconds())
            if limited_until
            else _refresh_interval()
        )
        _refresh_wakeup.wait(sleep_time)


HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PR Dashboard</title>
    <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Ccircle cx='16' cy='6' r='4' fill='%2339c5cf'/%3E%3Ccircle cx='8' cy='26' r='4' fill='%23a371f7'/%3E%3Ccircle cx='24' cy='26' r='4' fill='%233fb950'/%3E%3Cpath d='M16 10v6M16 16L8 22M16 16l8 6' stroke='%238b949e' stroke-width='2' stroke-linecap='round'/%3E%3C/svg%3E">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-primary: #1a1f26;
            --bg-secondary: #22272e;
            --bg-tertiary: #2d333b;
            --bg-hover: #3a424d;
            --bg-elevated: #2d333b;
            --border-color: #30363d;
            --text-primary: #e6edf3;
            --text-secondary: #8b949e;
            --text-muted: #6e7681;
            --accent-green: #3fb950;
            --accent-blue: #58a6ff;
            --accent-purple: #a371f7;
            --accent-red: #f85149;
            --accent-yellow: #d29922;
            --accent-orange: #db6d28;
            --accent-cyan: #39c5cf;
        }

        @media (prefers-color-scheme: light) {
            :root {
                --bg-primary: #ffffff;
                --bg-secondary: #f6f8fa;
                --bg-tertiary: #ebeef1;
                --bg-hover: #e1e4e8;
                --bg-elevated: #ffffff;
                --border-color: #d0d7de;
                --text-primary: #1f2328;
                --text-secondary: #656d76;
                --text-muted: #8c959f;
                --accent-green: #1a7f37;
                --accent-blue: #0969da;
                --accent-purple: #8250df;
                --accent-red: #cf222e;
                --accent-yellow: #9a6700;
                --accent-orange: #bc4c00;
                --accent-cyan: #0891b2;
            }
        }

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            min-height: 100vh;
            padding: 2rem;
        }

        .container {
            max-width: 100%;
            margin: 0 auto;
        }

        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding-bottom: 1rem;
            flex-wrap: wrap;
            gap: 0.5rem;
            border-bottom: 1px solid var(--border-color);
        }

        .search-box {
            position: relative;
            flex: 1;
            min-width: 200px;
            max-width: 500px;
            order: 1;
        }

        .search-box input {
            width: 100%;
            height: 2.5rem;
            padding: 0 1rem 0 2.5rem;
            background: var(--bg-tertiary);
            border: 1px solid var(--border-color);
            border-radius: 8px;
            color: var(--text-primary);
            font-size: 0.875rem;
            font-family: inherit;
            transition: all 0.2s;
            box-sizing: border-box;
        }

        .search-box input::placeholder {
            color: var(--text-muted);
        }

        .search-box input:focus {
            outline: none;
            border-color: var(--accent-cyan);
            background: var(--bg-secondary);
            box-shadow: 0 0 0 3px rgba(57, 197, 207, 0.15);
        }

        .search-box .search-icon {
            position: absolute;
            left: 0.875rem;
            top: 50%;
            transform: translateY(-50%);
            color: var(--text-muted);
            font-size: 0.875rem;
            pointer-events: none;
        }

        .search-box .clear-btn {
            position: absolute;
            right: 0.5rem;
            top: 50%;
            transform: translateY(-50%);
            background: none;
            border: none;
            color: var(--text-muted);
            cursor: pointer;
            padding: 0.25rem;
            font-size: 1rem;
            line-height: 1;
            opacity: 0;
            transition: opacity 0.15s, color 0.15s;
        }

        .search-box input:not(:placeholder-shown) + .search-icon + .clear-btn {
            opacity: 1;
        }

        .search-box .clear-btn:hover {
            color: var(--text-primary);
        }

        .header-right {
            display: flex;
            align-items: center;
            gap: 0.75rem;
            flex-shrink: 0;
            order: 2;
        }


        h1 {
            font-size: 1.75rem;
            font-weight: 600;
            background: linear-gradient(135deg, var(--accent-cyan), var(--accent-purple));
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .meta {
            font-size: 0.875rem;
            color: var(--text-secondary);
        }

        .refresh-indicator {
            display: inline-flex;
            align-items: center;
            gap: 0.5rem;
            padding: 0.5rem 1rem;
            background: var(--bg-tertiary);
            border-radius: 8px;
            font-size: 0.8rem;
            color: var(--text-secondary);
            cursor: pointer;
            transition: all 0.2s;
            border: 1px solid var(--border-color);
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
            min-width: 180px;
            height: 2.5rem;
            box-sizing: border-box;
        }

        .refresh-indicator:hover {
            background: var(--bg-hover);
            border-color: var(--accent-cyan);
            transform: translateY(-1px);
            box-shadow: 0 2px 6px rgba(0, 0, 0, 0.15);
        }

        .refresh-indicator:active {
            transform: translateY(0);
            box-shadow: 0 1px 2px rgba(0, 0, 0, 0.1);
        }

        .refresh-indicator.updating {
            color: var(--accent-blue);
            pointer-events: none;
            cursor: default;
            background: var(--bg-secondary);
            border-color: var(--accent-blue);
            box-shadow: none;
            transform: none;
        }

        .refresh-indicator .dot {
            width: 10px;
            height: 10px;
            border-radius: 50%;
            background: var(--accent-green);
            flex-shrink: 0;
        }

        .refresh-indicator.updating .dot {
            background: var(--accent-blue);
            animation: pulse 1s infinite;
        }

        .refresh-indicator.has-errors .dot {
            background: var(--accent-orange);
            animation: pulse 1.5s infinite;
        }

        .refresh-indicator.has-errors {
            border-color: var(--accent-orange);
            background: rgba(219, 109, 40, 0.1);
        }

        .refresh-indicator.is-stale .dot {
            background: var(--accent-yellow);
            animation: pulse 2s infinite;
        }

        .refresh-indicator.is-stale {
            border-color: var(--accent-yellow);
            background: rgba(210, 153, 34, 0.1);
        }

        .refresh-indicator.is-stale .stale-badge {
            display: inline-block;
            background: rgba(210, 153, 34, 0.2);
            color: var(--accent-yellow);
            padding: 0.125rem 0.375rem;
            border-radius: 4px;
            font-size: 0.65rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.03em;
            margin-left: 0.25rem;
        }

        .stale-badge {
            display: none;
        }

        .refresh-icon {
            font-size: 1.25rem;
            transition: transform 0.2s, color 0.2s;
            margin-left: 0.25rem;
        }

        .refresh-indicator:not(.updating):hover .refresh-icon {
            color: var(--accent-cyan);
            transform: rotate(30deg);
        }

        .refresh-indicator.updating .refresh-icon {
            animation: spin 0.8s linear infinite;
        }

        .next-refresh {
            font-size: 0.7rem;
            color: var(--text-muted);
            min-width: 2.5rem;
            text-align: right;
        }

        .refresh-label {
            font-weight: 500;
        }

        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.4; }
        }

        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.875rem;
        }

        th {
            text-align: left;
            padding: 0.5rem 0.5rem;
            font-weight: 600;
            color: var(--text-secondary);
            border-bottom: 1px solid var(--border-color);
            background: var(--bg-secondary);
            position: sticky;
            top: 0;
            z-index: 10;
            text-transform: uppercase;
            font-size: 0.7rem;
            letter-spacing: 0.05em;
            cursor: pointer;
            user-select: none;
            transition: color 0.2s;
            white-space: nowrap;
        }

        th:hover {
            color: var(--text-primary);
        }

        th.sorted {
            color: var(--accent-cyan);
        }

        th .sort-indicator {
            margin-left: 0.25rem;
            opacity: 0.5;
        }

        th.sorted .sort-indicator {
            opacity: 1;
        }

        td {
            padding: 0.5rem 0.5rem;
            border-bottom: 1px solid var(--border-color);
            vertical-align: middle;
            white-space: nowrap;
        }

        tr.selected td {
            background: var(--bg-secondary);
        }

        tr.expanded td {
            background: var(--bg-secondary);
            border-bottom-color: transparent;
        }

        .worktree-path {
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.8rem;
            color: var(--text-secondary);
            cursor: pointer;
            position: relative;
            transition: color 0.15s;
        }

        .worktree-path:hover {
            color: var(--text-primary);
        }

        .branch {
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.8rem;
            color: var(--accent-cyan);
            cursor: pointer;
            position: relative;
            transition: color 0.15s;
        }

        .branch:hover {
            color: var(--accent-blue);
        }

        .copyable {
            cursor: pointer;
        }

        .copied-flash {
            animation: copyFlash 0.6s ease-out;
        }

        @keyframes copyFlash {
            0% { background: var(--accent-green); color: white; }
            100% { background: transparent; }
        }

        .copy-toast {
            position: fixed;
            bottom: 2rem;
            left: 50%;
            transform: translateX(-50%) translateY(100%);
            background: var(--bg-tertiary);
            border: 1px solid var(--accent-green);
            color: var(--accent-green);
            padding: 0.5rem 1rem;
            border-radius: 6px;
            font-size: 0.8rem;
            opacity: 0;
            transition: all 0.3s ease;
            z-index: 1000;
            pointer-events: none;
        }

        .copy-toast.visible {
            opacity: 1;
            transform: translateX(-50%) translateY(0);
        }

        .local-status {
            cursor: pointer;
            user-select: none;
        }

        .local-status:hover {
            opacity: 0.8;
        }

        .local-badges {
            display: inline-flex;
            gap: 0.125rem;
        }

        .badge {
            display: inline-block;
            padding: 0 0.25rem;
            border-radius: 3px;
            font-size: 0.65rem;
            font-weight: 500;
            line-height: 1.4;
        }

        .badge-dirty {
            background: rgba(248, 81, 73, 0.15);
            color: var(--accent-red);
            border: 1px solid rgba(248, 81, 73, 0.3);
        }

        .badge-unpushed {
            background: rgba(210, 153, 34, 0.15);
            color: var(--accent-yellow);
            border: 1px solid rgba(210, 153, 34, 0.3);
        }

        .badge-virtual {
            background: rgba(110, 118, 129, 0.15);
            color: var(--text-muted);
            border: 1px solid rgba(110, 118, 129, 0.3);
            font-size: 0.6rem;
            margin-left: 0.25rem;
        }

        .badge-conflicts {
            background: rgba(219, 109, 40, 0.15);
            color: var(--accent-orange);
            border: 1px solid rgba(219, 109, 40, 0.3);
            font-size: 0.6rem;
            margin-left: 0.375rem;
            cursor: default;
        }

        .badge-repo {
            background: rgba(57, 197, 207, 0.12);
            color: var(--accent-cyan);
            border: 1px solid rgba(57, 197, 207, 0.3);
            font-size: 0.6rem;
            margin-right: 0.375rem;
            cursor: default;
        }

        .status-badge {
            display: inline-block;
            padding: 0.25rem 0.625rem;
            border-radius: 9999px;
            font-size: 0.7rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.025em;
        }

        .status-open { background: rgba(88, 166, 255, 0.15); color: var(--accent-blue); }
        .status-approved { background: rgba(63, 185, 80, 0.15); color: var(--accent-green); }
        .status-draft { background: rgba(110, 118, 129, 0.15); color: var(--text-secondary); }
        .status-merged { background: rgba(163, 113, 247, 0.15); color: var(--accent-purple); }
        .status-closed { background: rgba(248, 81, 73, 0.15); color: var(--accent-red); }
        .status-no-pr { background: rgba(210, 153, 34, 0.15); color: var(--accent-yellow); }
        .status-fetch-error {
            background: rgba(248, 81, 73, 0.15);
            color: var(--accent-orange);
            animation: pulse-error 1.5s ease-in-out infinite;
            cursor: pointer;
        }
        .status-fetch-error:hover { opacity: 0.8; }
        @keyframes pulse-error {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.6; }
        }

        .pr-title-wrapper {
            position: relative;
            max-width: 400px;
        }

        .pr-title {
            color: var(--text-primary);
            text-decoration: none;
            font-weight: 500;
            display: block;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        .pr-title:hover {
            color: var(--accent-blue);
            text-decoration: underline;
        }

        .pr-title-wrapper .tooltip {
            visibility: hidden;
            opacity: 0;
            position: absolute;
            bottom: 100%;
            left: 0;
            background: var(--bg-elevated);
            color: var(--text-primary);
            padding: 0.5rem 0.75rem;
            border-radius: 6px;
            font-size: 0.85rem;
            font-weight: 400;
            white-space: normal;
            max-width: 500px;
            width: max-content;
            z-index: 1000;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
            border: 1px solid var(--border-subtle);
            margin-bottom: 4px;
            transition: opacity 0.1s, visibility 0.1s;
            pointer-events: none;
        }

        .pr-title-wrapper.truncated:hover .tooltip {
            visibility: visible;
            opacity: 1;
        }

        .ci-status {
            font-size: 1rem;
            text-align: center;
            line-height: 1;
        }

        .ci-status a,
        .ci-status .ci-link {
            text-decoration: none;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 1.5rem;
            height: 1.5rem;
            border-radius: 4px;
            transition: all 0.15s;
            vertical-align: middle;
        }

        .ci-status a:hover,
        .ci-status .ci-link:hover {
            transform: scale(1.1);
        }

        .ci-status a.ci-fail,
        .ci-status .ci-link.ci-fail {
            background: rgba(248, 81, 73, 0.15);
            border: 1px solid rgba(248, 81, 73, 0.3);
        }

        .ci-status a.ci-running,
        .ci-status .ci-link.ci-running {
            background: rgba(88, 166, 255, 0.15);
            border: 1px solid rgba(88, 166, 255, 0.3);
        }

        .ci-status a.ci-queued,
        .ci-status .ci-link.ci-queued {
            background: rgba(210, 153, 34, 0.15);
            border: 1px solid rgba(210, 153, 34, 0.3);
        }

        .ci-pass { color: var(--accent-green); }
        .ci-fail { color: var(--accent-red); }
        .ci-running { color: var(--accent-blue); }
        .ci-running .ci-icon { animation: spin 1s linear infinite; display: inline-block; }
        .ci-queued { color: var(--accent-yellow); }
        .ci-other { color: var(--text-secondary); }
        .ci-none { color: var(--text-muted); }

        @keyframes spin {
            from { transform: rotate(0deg); }
            to { transform: rotate(360deg); }
        }

        .comments {
            color: var(--text-secondary);
            font-size: 0.8rem;
        }

        .last-comment {
            color: var(--text-muted);
            font-size: 0.75rem;
        }

        .reviewers {
            font-size: 0.8rem;
        }

        .reviewer-approved {
            color: var(--accent-green);
        }

        .reviewer-commented {
            color: var(--text-primary);
        }

        .reviewer-pending {
            color: var(--text-secondary);
        }

        .user-link {
            color: inherit;
            text-decoration: none;
        }

        .user-link:hover {
            text-decoration: underline;
        }

        tr.has-new-activity td {
            background: rgba(63, 185, 80, 0.08);
        }

        tr.has-new-activity td:first-child {
            box-shadow: inset 3px 0 0 var(--accent-green);
        }

        tr.has-new-activity.selected td {
            background: rgba(63, 185, 80, 0.15);
        }

        tr.has-new-activity .last-comment {
            color: var(--accent-green);
            font-weight: 500;
        }

        .expansion-row {
            display: none;
        }

        .expansion-row.visible {
            display: table-row;
        }

        .expansion-row td {
            padding: 0;
            background: var(--bg-secondary);
        }

        .expansion-content {
            padding: 1rem 1rem 1rem 3rem;
            background: var(--bg-tertiary);
            border-radius: 0 0 8px 8px;
            margin: 0 1rem 1rem 1rem;
        }

        .expansion-content h4 {
            font-size: 0.75rem;
            font-weight: 600;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 0.05em;
            margin-bottom: 0.75rem;
        }

        .file-list, .commit-list {
            list-style: none;
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.8rem;
        }

        .file-list li, .commit-list li {
            padding: 0.375rem 0;
            display: flex;
            align-items: center;
            gap: 0.75rem;
        }

        .file-status {
            font-size: 0.7rem;
            padding: 0.125rem 0.375rem;
            border-radius: 3px;
            font-weight: 500;
            min-width: 70px;
            text-align: center;
        }

        .file-status.modified { background: rgba(88, 166, 255, 0.15); color: var(--accent-blue); }
        .file-status.added { background: rgba(63, 185, 80, 0.15); color: var(--accent-green); }
        .file-status.deleted { background: rgba(248, 81, 73, 0.15); color: var(--accent-red); }
        .file-status.untracked { background: rgba(210, 153, 34, 0.15); color: var(--accent-yellow); }
        .file-status.renamed { background: rgba(163, 113, 247, 0.15); color: var(--accent-purple); }

        .commit-sha {
            color: var(--accent-cyan);
            font-weight: 500;
        }

        .commit-message {
            color: var(--text-secondary);
        }

        .delta {
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.75rem;
            display: inline-flex;
            gap: 0.375rem;
            min-width: 70px;
        }

        .delta-add {
            color: var(--accent-green);
        }

        .delta-del {
            color: var(--accent-red);
        }

        .section-divider {
            margin: 1rem 0;
            border: none;
            border-top: 1px solid var(--border-color);
        }

        .empty-state {
            text-align: center;
            padding: 4rem 2rem;
            color: var(--text-secondary);
        }

        .loading {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 1rem;
            padding: 4rem;
            color: var(--text-secondary);
        }

        .loading-spinner {
            width: 24px;
            height: 24px;
            border: 2px solid var(--border-color);
            border-top-color: var(--accent-blue);
            border-radius: 50%;
            animation: spin 0.8s linear infinite;
        }

        .help-modal-overlay {
            position: fixed;
            inset: 0;
            background: rgba(0, 0, 0, 0.6);
            display: flex;
            align-items: center;
            justify-content: center;
            z-index: 1000;
            opacity: 0;
            visibility: hidden;
            transition: opacity 0.15s, visibility 0.15s;
        }

        .help-modal-overlay.visible {
            opacity: 1;
            visibility: visible;
        }

        .help-modal {
            background: var(--bg-elevated);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 1.5rem 2rem;
            max-width: 400px;
            box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
            transform: scale(0.95);
            transition: transform 0.15s;
        }

        .help-modal-overlay.visible .help-modal {
            transform: scale(1);
        }

        .help-modal h2 {
            margin: 0 0 1rem 0;
            font-size: 1.1rem;
            font-weight: 600;
            color: var(--text-primary);
            border-bottom: 1px solid var(--border-color);
            padding-bottom: 0.75rem;
        }

        .help-modal .shortcuts-list {
            display: grid;
            grid-template-columns: auto 1fr;
            gap: 0.375rem 1.5rem;
            align-items: baseline;
        }

        .help-modal .shortcut-key {
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.8rem;
            color: var(--accent-cyan);
            white-space: nowrap;
        }

        .help-modal .shortcut-desc {
            color: var(--text-secondary);
            font-size: 0.85rem;
        }

        .help-modal .close-hint {
            margin-top: 1rem;
            padding-top: 0.75rem;
            border-top: 1px solid var(--border-color);
            font-size: 0.75rem;
            color: var(--text-muted);
            text-align: center;
        }
        .review-section {
            margin-top: 1rem;
            margin-bottom: 0.5rem;
            border: 1px solid var(--border-color);
            border-radius: 8px;
            overflow: hidden;
            background: var(--bg-secondary);
        }

        .review-section-header {
            color: var(--accent-yellow);
            background: rgba(210, 153, 34, 0.08);
        }

        .review-section-header .count {
            background: rgba(210, 153, 34, 0.2);
            color: var(--accent-yellow);
            padding: 0.125rem 0.5rem;
            border-radius: 9999px;
            font-size: 0.7rem;
            font-weight: 600;
        }

        .review-section table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.875rem;
        }

        .review-section th {
            position: static;
            background: var(--bg-secondary);
        }

        .review-section td {
            padding: 0.375rem 0.5rem;
            border-bottom: 1px solid var(--border-color);
            vertical-align: middle;
            white-space: nowrap;
        }

        .review-section tr:last-child td {
            border-bottom: none;
        }

        .review-section tbody tr:hover td {
            background: var(--bg-hover);
        }

        .review-author {
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.8rem;
            color: var(--accent-purple);
        }

        .section-header {
            display: flex;
            align-items: center;
            gap: 0.5rem;
            padding: 0.5rem 0.75rem;
            cursor: pointer;
            user-select: none;
            font-size: 0.8rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.03em;
            border-radius: 8px 8px 0 0;
            transition: background 0.15s;
        }

        .section-header:hover {
            background: var(--bg-hover);
        }

        .section-header .chevron {
            display: inline-block;
            transition: transform 0.2s;
            font-size: 0.7rem;
        }

        .section-header.collapsed .chevron {
            transform: rotate(-90deg);
        }

        .section-header .count {
            padding: 0.125rem 0.5rem;
            border-radius: 9999px;
            font-size: 0.7rem;
            font-weight: 600;
        }

        .section-collapsed {
            display: none;
        }

        .own-prs-section {
            margin-top: 1rem;
        }

        .own-prs-header {
            color: var(--accent-cyan);
            background: rgba(57, 197, 207, 0.08);
            border: 1px solid var(--border-color);
            border-bottom: none;
        }

        .own-prs-header.collapsed {
            border-bottom: 1px solid var(--border-color);
            border-radius: 8px;
        }

        .own-prs-header .count {
            background: rgba(57, 197, 207, 0.2);
            color: var(--accent-cyan);
        }

        .filter-toggle {
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }

        .toggle-label {
            display: flex;
            align-items: center;
            gap: 0.5rem;
            cursor: pointer;
            user-select: none;
            padding: 0.5rem 0.75rem;
            background: var(--bg-tertiary);
            border: 1px solid var(--border-color);
            border-radius: 8px;
            transition: all 0.2s;
            height: 2.5rem;
            box-sizing: border-box;
            flex-shrink: 0;
        }

        .toggle-label:hover {
            background: var(--bg-hover);
            border-color: var(--accent-cyan);
        }

        .toggle-label input[type="checkbox"] {
            display: none;
        }

        .toggle-switch {
            position: relative;
            width: 28px;
            height: 14px;
            background: var(--bg-primary);
            border: 1px solid var(--border-color);
            border-radius: 7px;
            transition: all 0.2s;
            flex-shrink: 0;
        }

        .toggle-switch::after {
            content: '';
            position: absolute;
            top: 2px;
            left: 2px;
            width: 8px;
            height: 8px;
            background: var(--text-muted);
            border-radius: 50%;
            transition: all 0.2s;
        }

        .toggle-label input:checked + .toggle-switch {
            background: var(--text-secondary);
            border-color: var(--text-secondary);
        }

        .toggle-label input:checked + .toggle-switch::after {
            left: 16px;
            background: var(--bg-primary);
        }

        .toggle-text {
            font-size: 0.8rem;
            color: var(--text-secondary);
            white-space: nowrap;
            transition: color 0.2s;
        }

        .toggle-label input:checked ~ .toggle-text {
            color: var(--accent-cyan);
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>PR Dashboard</h1>
            <div class="header-right">
                <div class="filter-toggle" id="filterToggle">
                    <label class="toggle-label" for="hideClosedToggle">
                        <input type="checkbox" id="hideClosedToggle" onchange="handleFilterToggle(this.checked)">
                        <span class="toggle-switch"></span>
                        <span class="toggle-text">Active only</span>
                    </label>
                    <label class="toggle-label" for="hideDraftsToggle">
                        <input type="checkbox" id="hideDraftsToggle" onchange="handleDraftsToggle(this.checked)">
                        <span class="toggle-switch"></span>
                        <span class="toggle-text">Hide drafts</span>
                    </label>
                </div>
                <div class="refresh-indicator" id="refreshIndicator" onclick="manualRefresh()">
                    <span class="dot"></span>
                    <span class="refresh-label" id="lastUpdated">Loading...</span>
                    <span class="stale-badge" id="staleBadge">stale</span>
                    <span class="next-refresh" id="nextRefresh"></span>
                    <span class="refresh-icon">⟳</span>
                </div>
            </div>
            <div class="search-box">
                <input type="text" id="searchInput" placeholder="Search branches..." oninput="handleSearch(this.value)">
                <span class="search-icon">🔍</span>
                <button class="clear-btn" onclick="clearSearch()" title="Clear search">×</button>
            </div>
        </header>

        <div id="content">
            <div class="loading">
                <div class="loading-spinner"></div>
                <span>Loading...</span>
            </div>
        </div>
        <div class="copy-toast" id="copyToast">Copied!</div>

        <div class="help-modal-overlay" id="helpModal" onclick="hideKeyboardHelp(event)">
            <div class="help-modal" onclick="event.stopPropagation()">
                <h2>Keyboard Shortcuts</h2>
                <div class="shortcuts-list">
                    <span class="shortcut-key">/</span><span class="shortcut-desc">Focus search</span>
                    <span class="shortcut-key">Escape</span><span class="shortcut-desc">Clear / unfocus / deselect</span>
                    <span class="shortcut-key">j ↓</span><span class="shortcut-desc">Move selection down</span>
                    <span class="shortcut-key">k ↑</span><span class="shortcut-desc">Move selection up</span>
                    <span class="shortcut-key">Enter o</span><span class="shortcut-desc">Open PR in new tab</span>
                    <span class="shortcut-key">c</span><span class="shortcut-desc">Copy branch name</span>
                    <span class="shortcut-key">w</span><span class="shortcut-desc">Copy local path</span>
                    <span class="shortcut-key">x</span><span class="shortcut-desc">Toggle local changes</span>
                    <span class="shortcut-key">g</span><span class="shortcut-desc">Go to first row</span>
                    <span class="shortcut-key">G</span><span class="shortcut-desc">Go to last row</span>
                    <span class="shortcut-key">a</span><span class="shortcut-desc">Toggle active only filter</span>
                    <span class="shortcut-key">d</span><span class="shortcut-desc">Toggle hide drafts</span>
                    <span class="shortcut-key">1</span><span class="shortcut-desc">Toggle Reviews section</span>
                    <span class="shortcut-key">2</span><span class="shortcut-desc">Toggle Your PRs section</span>
                    <span class="shortcut-key">r</span><span class="shortcut-desc">Refresh data</span>
                    <span class="shortcut-key">?</span><span class="shortcut-desc">Show this help</span>
                </div>
                <div class="close-hint">Press Escape or click outside to close</div>
            </div>
        </div>
    </div>

    <script>
        let currentExpandedPath = null;  // Track by worktree path, not index
        let worktreeData = [];
        let sortColumn = 'last';  // Default sort by last interaction time
        let sortDirection = 'desc'; // Most recent first
        let searchQuery = '';  // Current search filter
        let hideClosedMerged = false;  // Always start with all entries visible
        let hideDrafts = false;
        const ACTIVE_STATUSES = ['open', 'approved', 'draft'];
        let reviewsCollapsed = false;
        let ownPrsCollapsed = false;
        let reviewRequestData = [];  // PRs waiting for current user's review
        let previousReviewNumbers = new Set();
        let previousGreenPRs = new Set();
        let isFirstLoad = true;
        const SEEN_REVIEWS_KEY = 'pr_dash_seen_reviews';
        let selectedRowIndex = -1;  // Currently selected row for keyboard nav
        let selectedWorktreePath = null;  // Track selection by path for persistence

        // Track last viewed time per PR (stored in localStorage)
        const VIEWED_STORAGE_KEY = 'worktrees_pr_last_viewed';

        function getLastViewedTimes() {
            try {
                const stored = localStorage.getItem(VIEWED_STORAGE_KEY);
                return stored ? JSON.parse(stored) : {};
            } catch (e) {
                return {};
            }
        }

        function setLastViewed(prKey) {
            if (!prKey) return;
            const times = getLastViewedTimes();
            times[prKey] = new Date().toISOString();
            try {
                localStorage.setItem(VIEWED_STORAGE_KEY, JSON.stringify(times));
            } catch (e) {
                console.error('Failed to save viewed time:', e);
            }
        }

        function prKeyOf(row) {
            // PR numbers repeat across repos, so track state by "owner/name#number".
            return row && (row.pr_key || (row.pr_number ? String(row.pr_number) : ''));
        }

        function repoBadge(row) {
            if (!row || !row.repo_label || row.is_primary_repo) return '';
            return `<span class="badge badge-repo" title="${escapeHtml(row.repo || '')}">${escapeHtml(row.repo_label)}</span>`;
        }

        function hasNewActivity(row) {
            const key = prKeyOf(row);
            if (!key || !row.last_comment_timestamp) return false;
            const times = getLastViewedTimes();
            const lastViewed = times[key];
            if (!lastViewed) return false;  // Never viewed = no baseline, don't highlight
            return new Date(row.last_comment_timestamp) > new Date(lastViewed);
        }

        function markPRViewed(prKey, rowIndex) {
            setLastViewed(prKey);
            // Remove highlight from the row
            const row = document.getElementById(`main-${rowIndex}`);
            if (row) {
                row.classList.remove('has-new-activity');
                // Also reset the last-comment styling
                const lastCommentCell = row.querySelector('.last-comment');
                if (lastCommentCell) {
                    lastCommentCell.style.color = '';
                    lastCommentCell.style.fontWeight = '';
                }
            }
        }

        function sendNotification(title, body) {
            if ('Notification' in window && Notification.permission === 'granted') {
                try { new Notification(title, { body }); } catch (e) { /* ignore */ }
            }
        }

        function getSeenReviews() {
            try {
                const stored = localStorage.getItem(SEEN_REVIEWS_KEY);
                return stored ? new Set(JSON.parse(stored)) : new Set();
            } catch (e) { return new Set(); }
        }

        function markReviewSeen(prKey) {
            if (!prKey) return;
            const seen = getSeenReviews();
            seen.add(String(prKey));
            try { localStorage.setItem(SEEN_REVIEWS_KEY, JSON.stringify([...seen])); } catch (e) { /* ignore */ }
        }

        function isNewReview(prKey) {
            if (!prKey) return false;
            return !getSeenReviews().has(String(prKey));
        }

        function cleanupSeenReviews(currentKeys) {
            const seen = getSeenReviews();
            const current = new Set(currentKeys.map(String));
            const cleaned = new Set([...seen].filter(n => current.has(n)));
            try { localStorage.setItem(SEEN_REVIEWS_KEY, JSON.stringify([...cleaned])); } catch (e) { /* ignore */ }
        }

        function formatTime(isoString) {
            if (!isoString) return '';
            const date = new Date(isoString);
            return date.toLocaleTimeString();
        }

        function handleSearch(query) {
            searchQuery = query.toLowerCase().trim();
            applyFiltersAndRender();
        }

        function clearSearch() {
            searchQuery = '';
            document.getElementById('searchInput').value = '';
            applyFiltersAndRender();
        }

        function handleFilterToggle(checked) {
            hideClosedMerged = checked;
            localStorage.setItem('pr_dash_hide_closed_merged', checked);
            applyFiltersAndRender();
        }

        function handleDraftsToggle(checked) {
            hideDrafts = checked;
            localStorage.setItem('pr_dash_hide_drafts', checked);
            applyFiltersAndRender();
        }

        function toggleCheckbox(elementId, handler) {
            const el = document.getElementById(elementId);
            el.checked = !el.checked;
            handler(el.checked);
        }

        function toggleSection(section) {
            if (section === 'reviews') {
                reviewsCollapsed = !reviewsCollapsed;
                localStorage.setItem('pr_dash_reviews_collapsed', reviewsCollapsed);
            } else {
                ownPrsCollapsed = !ownPrsCollapsed;
                localStorage.setItem('pr_dash_own_prs_collapsed', ownPrsCollapsed);
            }
            applyFiltersAndRender();
        }

        function loadCollapsedState() {
            reviewsCollapsed = localStorage.getItem('pr_dash_reviews_collapsed') === 'true';
            ownPrsCollapsed = localStorage.getItem('pr_dash_own_prs_collapsed') === 'true';
        }

        function selectRowByMouse(index) {
            // Select row on mouse hover, don't scroll
            selectRow(index, false);
        }

        function selectRow(index, scroll = true) {
            const displayedData = getDisplayedData();
            const maxIndex = displayedData.length - 1;

            // Clamp index to valid range
            if (index < 0) index = 0;
            if (index > maxIndex) index = maxIndex;
            if (maxIndex < 0) {
                selectedRowIndex = -1;
                selectedWorktreePath = null;
                return;
            }

            // Remove previous selection
            const prevSelected = document.querySelector('tr.selected');
            if (prevSelected) prevSelected.classList.remove('selected');

            // Apply new selection
            selectedRowIndex = index;
            selectedWorktreePath = displayedData[index]?.worktree || null;
            const newSelected = document.getElementById(`main-${index}`);
            if (newSelected) {
                newSelected.classList.add('selected');
                // Scroll into view if needed
                if (scroll) {
                    newSelected.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
                }
            }
        }

        function restoreSelection() {
            if (!selectedWorktreePath) return;

            const displayedData = getDisplayedData();
            const index = displayedData.findIndex(d => d.worktree === selectedWorktreePath);
            if (index >= 0) {
                selectedRowIndex = index;
                const row = document.getElementById(`main-${index}`);
                if (row) row.classList.add('selected');
            } else {
                // Selected row no longer visible, clear selection
                selectedRowIndex = -1;
                selectedWorktreePath = null;
            }
        }

        function moveSelection(delta) {
            const displayedData = getDisplayedData();
            if (displayedData.length === 0) return;

            if (selectedRowIndex < 0) {
                // No selection yet, select first or last based on direction
                selectRow(delta > 0 ? 0 : displayedData.length - 1);
            } else {
                selectRow(selectedRowIndex + delta);
            }
        }

        function openSelectedPR() {
            const displayedData = getDisplayedData();
            if (selectedRowIndex < 0 || selectedRowIndex >= displayedData.length) return;

            const row = displayedData[selectedRowIndex];
            if (row && row.pr_url) {
                markPRViewed(prKeyOf(row), selectedRowIndex);
                window.open(row.pr_url, '_blank');
            }
        }

        function copySelectedBranch() {
            const displayedData = getDisplayedData();
            if (selectedRowIndex < 0 || selectedRowIndex >= displayedData.length) return;

            const row = displayedData[selectedRowIndex];
            if (row && row.branch) {
                const branchCell = document.querySelector(`#main-${selectedRowIndex} .branch`);
                if (branchCell) {
                    copyToClipboard(row.branch, branchCell);
                }
            }
        }

        function copySelectedWorktree() {
            const displayedData = getDisplayedData();
            if (selectedRowIndex < 0 || selectedRowIndex >= displayedData.length) return;

            const row = displayedData[selectedRowIndex];
            if (row && row.worktree_display) {
                const wtCell = document.querySelector(`#main-${selectedRowIndex} .worktree-path`);
                if (wtCell) {
                    copyToClipboard(row.worktree_display, wtCell);
                }
            }
        }

        function toggleSelectedExpansion() {
            const displayedData = getDisplayedData();
            if (selectedRowIndex < 0 || selectedRowIndex >= displayedData.length) return;

            const row = displayedData[selectedRowIndex];
            if (row && (row.has_dirty || row.has_unpushed)) {
                toggleExpansion(selectedRowIndex, null);
            }
        }

        function handleKeyDown(e) {
            const searchInput = document.getElementById('searchInput');
            const isSearchFocused = document.activeElement === searchInput;

            // "/" focuses search (unless already in an input)
            if (e.key === '/' && !isSearchFocused) {
                e.preventDefault();
                searchInput.focus();
                return;
            }

            // Escape: close help modal, blur search, clear search, deselect, or clear search filter
            if (e.key === 'Escape') {
                const helpModal = document.getElementById('helpModal');
                if (helpModal.classList.contains('visible')) {
                    hideKeyboardHelp();
                } else if (isSearchFocused) {
                    if (searchQuery) {
                        clearSearch();
                    } else {
                        searchInput.blur();
                    }
                } else if (selectedRowIndex >= 0) {
                    // First Escape: clear selection
                    const prevSelected = document.querySelector('tr.selected');
                    if (prevSelected) prevSelected.classList.remove('selected');
                    selectedRowIndex = -1;
                    selectedWorktreePath = null;
                } else if (searchQuery) {
                    // Second Escape: clear search filter to show full list
                    clearSearch();
                }
                return;
            }

            // Arrow keys and Enter from search box: exit search and navigate list
            if (isSearchFocused) {
                if (e.key === 'ArrowDown') {
                    e.preventDefault();
                    searchInput.blur();
                    selectRow(0);
                    return;
                } else if (e.key === 'ArrowUp') {
                    e.preventDefault();
                    searchInput.blur();
                    const displayedData = getDisplayedData();
                    selectRow(displayedData.length - 1);
                    return;
                } else if (e.key === 'Enter') {
                    e.preventDefault();
                    searchInput.blur();
                    const displayedData = getDisplayedData();
                    if (displayedData.length > 0) {
                        selectRow(0);
                        // If only one result, open it directly
                        if (displayedData.length === 1 && displayedData[0].pr_url) {
                            window.open(displayedData[0].pr_url, '_blank');
                        }
                    }
                    return;
                }
                // Other keys: stay in search box
                return;
            }

            // Navigation keys
            switch (e.key) {
                case 'j':
                case 'ArrowDown':
                    e.preventDefault();
                    moveSelection(1);
                    break;
                case 'k':
                case 'ArrowUp':
                    e.preventDefault();
                    moveSelection(-1);
                    break;
                case 'Enter':
                case 'o':
                    if (selectedRowIndex >= 0) {
                        e.preventDefault();
                        openSelectedPR();
                    }
                    break;
                case 'c':
                    if (selectedRowIndex >= 0) {
                        e.preventDefault();
                        copySelectedBranch();
                    }
                    break;
                case 'w':
                    if (selectedRowIndex >= 0) {
                        e.preventDefault();
                        copySelectedWorktree();
                    }
                    break;
                case 'x':
                case 'Tab':
                    if (e.key === 'Tab' && selectedRowIndex < 0) break; // Allow normal tab when nothing selected
                    if (selectedRowIndex >= 0) {
                        e.preventDefault();
                        toggleSelectedExpansion();
                    }
                    break;
                case 'g':
                    // gg goes to first row (vim-style)
                    if (selectedRowIndex >= 0) {
                        e.preventDefault();
                        selectRow(0);
                    }
                    break;
                case 'G':
                    // G goes to last row
                    e.preventDefault();
                    const displayedData = getDisplayedData();
                    selectRow(displayedData.length - 1);
                    break;
                case 'r':
                    // Refresh
                    e.preventDefault();
                    manualRefresh();
                    break;
                case 'a':
                    e.preventDefault();
                    toggleCheckbox('hideClosedToggle', handleFilterToggle);
                    break;
                case 'd':
                    e.preventDefault();
                    toggleCheckbox('hideDraftsToggle', handleDraftsToggle);
                    break;
                case '1':
                    e.preventDefault();
                    toggleSection('reviews');
                    break;
                case '2':
                    e.preventDefault();
                    toggleSection('own');
                    break;
                case '?':
                    // Show help
                    e.preventDefault();
                    showKeyboardHelp();
                    break;
            }
        }

        function showKeyboardHelp() {
            document.getElementById('helpModal').classList.add('visible');
        }

        function hideKeyboardHelp(event) {
            if (!event || event.target.id === 'helpModal') {
                document.getElementById('helpModal').classList.remove('visible');
            }
        }

        // Attach keyboard listener
        document.addEventListener('keydown', handleKeyDown);

        // Restore persisted state
        loadCollapsedState();

        function filterByStatus(data) {
            if (!hideClosedMerged && !hideDrafts) return data;
            return data.filter(row => {
                if (hideClosedMerged && !ACTIVE_STATUSES.includes(row.status)) return false;
                if (hideDrafts && row.status === 'draft') return false;
                return true;
            });
        }

        function filterBySearch(data, query) {
            if (!query) return data;

            return data.filter(row => {
                // Search across multiple fields
                const searchableFields = [
                    row.worktree_display || '',
                    row.branch || '',
                    row.repo || '',
                    row.pr_title || '',
                    row.status_label || '',
                    (row.approvers || []).join(' '),
                    (row.commented_reviewers || []).join(' '),
                    (row.pending_reviewers || []).join(' '),
                    row.pr_number || '',
                ];
                const searchText = searchableFields.join(' ').toLowerCase();
                return searchText.includes(query);
            });
        }

        function getDisplayedData() {
            // Returns the currently displayed data (sorted + filtered)
            let data = sortColumn
                ? sortData(worktreeData, sortColumn, sortDirection)
                : [...worktreeData];
            data = filterByStatus(data);
            return filterBySearch(data, searchQuery);
        }

        function applyFiltersAndRender() {
            const filteredData = getDisplayedData();

            let contentHtml = renderReviewRequests(reviewRequestData);
            contentHtml += renderTable(filteredData, false);
            document.getElementById('content').innerHTML = contentHtml;
            detectTruncatedTitles();

            // Restore selection state
            restoreSelection();

            // Restore expansion state if the expanded row is still visible
            if (currentExpandedPath) {
                const expandedIndex = filteredData.findIndex(d => d.worktree === currentExpandedPath);
                if (expandedIndex >= 0) {
                    const row = document.getElementById(`expansion-${expandedIndex}`);
                    const mainRow = document.getElementById(`main-${expandedIndex}`);
                    if (row) {
                        row.classList.add('visible');
                        mainRow?.classList.add('expanded');
                        loadExpansionContent(expandedIndex, filteredData);
                    }
                }
            }
        }

        async function copyToClipboard(text, element) {
            try {
                await navigator.clipboard.writeText(text);

                // Flash the element
                element.classList.add('copied-flash');
                setTimeout(() => element.classList.remove('copied-flash'), 600);

                // Show toast
                const toast = document.getElementById('copyToast');
                toast.textContent = `Copied: ${text}`;
                toast.classList.add('visible');
                setTimeout(() => toast.classList.remove('visible'), 1500);
            } catch (err) {
                console.error('Failed to copy:', err);
            }
        }

        function toggleExpansion(index, event) {
            if (event) {
                event.stopPropagation();
                event.preventDefault();
            }
            const displayedData = getDisplayedData();
            const worktreePath = displayedData[index]?.worktree;
            const rowId = `expansion-${index}`;
            const row = document.getElementById(rowId);
            const mainRow = document.getElementById(`main-${index}`);

            // Close any other expanded row
            if (currentExpandedPath && currentExpandedPath !== worktreePath) {
                const prevIndex = displayedData.findIndex(d => d.worktree === currentExpandedPath);
                if (prevIndex >= 0) {
                    const prevRow = document.getElementById(`expansion-${prevIndex}`);
                    const prevMain = document.getElementById(`main-${prevIndex}`);
                    if (prevRow) {
                        prevRow.classList.remove('visible');
                        prevMain?.classList.remove('expanded');
                    }
                }
            }

            if (row) {
                if (row.classList.contains('visible')) {
                    row.classList.remove('visible');
                    mainRow?.classList.remove('expanded');
                    currentExpandedPath = null;
                } else {
                    row.classList.add('visible');
                    mainRow?.classList.add('expanded');
                    currentExpandedPath = worktreePath;
                    loadExpansionContent(index, displayedData);
                }
            }
        }

        async function loadExpansionContent(index, dataArray = null) {
            const data = dataArray || getDisplayedData();
            console.log('loadExpansionContent called with index:', index);
            console.log('data:', data);
            console.log('data[index]:', data[index]);

            const rowId = `expansion-${index}`;
            const content = document.querySelector(`#${rowId} .expansion-content`);
            if (!content) {
                console.log('Content element not found');
                return;
            }

            const worktreePath = data[index]?.worktree;
            console.log('worktreePath:', worktreePath);
            if (!worktreePath) {
                content.innerHTML = '<p style="color: var(--accent-red);">No local path available</p>';
                return;
            }

            content.innerHTML = '<div class="loading"><div class="loading-spinner"></div><span>Loading...</span></div>';

            try {
                const response = await fetch(`/api/details?worktree=${encodeURIComponent(worktreePath)}&type=local`);
                if (!response.ok) {
                    throw new Error(`HTTP ${response.status}`);
                }
                const data = await response.json();

                let html = '';

                if (data.dirty_files && data.dirty_files.length > 0) {
                    html += '<h4>Uncommitted Changes</h4><ul class="file-list">';
                    for (const file of data.dirty_files) {
                        let delta = '';
                        if (file.additions > 0 || file.deletions > 0) {
                            const addStr = file.additions > 0 ? `<span class="delta-add">+${file.additions}</span>` : '';
                            const delStr = file.deletions > 0 ? `<span class="delta-del">-${file.deletions}</span>` : '';
                            delta = `<span class="delta">${addStr}${delStr}</span>`;
                        } else {
                            delta = '<span class="delta"></span>';
                        }
                        html += `<li><span class="file-status ${escapeHtml(file.status)}">${escapeHtml(file.status)}</span>${delta}<span>${escapeHtml(file.filename)}</span></li>`;
                    }
                    html += '</ul>';
                }

                if (data.unpushed_commits && data.unpushed_commits.length > 0) {
                    if (html) html += '<hr class="section-divider">';
                    html += '<h4>Unpushed Commits</h4><ul class="commit-list">';
                    for (const commit of data.unpushed_commits) {
                        html += `<li><span class="commit-sha">${escapeHtml(commit.sha)}</span><span class="commit-message">${escapeHtml(commit.message)}</span></li>`;
                    }
                    html += '</ul>';
                }

                if (!html) {
                    html = '<p style="color: var(--text-muted);">No local changes</p>';
                    // Clear the stale dirty/unpushed labels from the row
                    var mainRow = document.getElementById('main-' + index);
                    if (mainRow) {
                        var localCell = mainRow.querySelector('.local-status');
                        if (localCell) localCell.innerHTML = '';
                    }
                }

                content.innerHTML = html;
            } catch (err) {
                console.error('Failed to load details:', err);
                content.innerHTML = `<p style="color: var(--accent-red);">Failed to load details: ${escapeHtml(err.message)}</p>`;
            }
        }

        function sortData(data, column, direction) {
            if (!column) return data;

            const sorted = [...data].sort((a, b) => {
                let valA, valB;

                switch (column) {
                    case 'worktree':
                        valA = a.worktree_display || '';
                        valB = b.worktree_display || '';
                        break;
                    case 'local':
                        // Sort by has_dirty first, then has_unpushed
                        valA = (a.has_dirty ? 2 : 0) + (a.has_unpushed ? 1 : 0);
                        valB = (b.has_dirty ? 2 : 0) + (b.has_unpushed ? 1 : 0);
                        break;
                    case 'branch':
                        valA = a.branch || '';
                        valB = b.branch || '';
                        break;
                    case 'status':
                        // Sort order: approved > open > draft > merged > closed > no-pr
                        const statusOrder = { 'approved': 0, 'open': 1, 'draft': 2, 'merged': 3, 'closed': 4, 'no-pr': 5 };
                        valA = statusOrder[a.status] ?? 6;
                        valB = statusOrder[b.status] ?? 6;
                        break;
                    case 'title':
                        valA = a.pr_title || '';
                        valB = b.pr_title || '';
                        break;
                    case 'ci':
                        // Sort order: fail > running > queued > pass > none
                        const ciOrder = { 'ci-fail': 0, 'ci-running': 1, 'ci-queued': 2, 'ci-other': 3, 'ci-pass': 4, 'ci-none': 5 };
                        valA = ciOrder[a.ci_class] ?? 6;
                        valB = ciOrder[b.ci_class] ?? 6;
                        break;
                    case 'updated':
                        // Use updated_timestamp for proper date sorting
                        valA = a.updated_timestamp ? new Date(a.updated_timestamp).getTime() : 0;
                        valB = b.updated_timestamp ? new Date(b.updated_timestamp).getTime() : 0;
                        break;
                    case 'comments':
                        valA = a.comment_count || 0;
                        valB = b.comment_count || 0;
                        break;
                    case 'last':
                        // Last comment time from others
                        valA = a.last_comment_timestamp ? new Date(a.last_comment_timestamp).getTime() : 0;
                        valB = b.last_comment_timestamp ? new Date(b.last_comment_timestamp).getTime() : 0;
                        break;
                    case 'reviewers':
                        valA = (a.approvers?.length || 0) * 100 + (a.commented_reviewers?.length || 0) * 10 + (a.pending_reviewers?.length || 0);
                        valB = (b.approvers?.length || 0) * 100 + (b.commented_reviewers?.length || 0) * 10 + (b.pending_reviewers?.length || 0);
                        break;
                    default:
                        return 0;
                }

                // Compare
                if (typeof valA === 'number' && typeof valB === 'number') {
                    return direction === 'asc' ? valA - valB : valB - valA;
                }

                const strA = String(valA).toLowerCase();
                const strB = String(valB).toLowerCase();
                if (strA < strB) return direction === 'asc' ? -1 : 1;
                if (strA > strB) return direction === 'asc' ? 1 : -1;
                return 0;
            });

            return sorted;
        }

        function handleSort(column) {
            if (sortColumn === column) {
                // Toggle direction
                sortDirection = sortDirection === 'asc' ? 'desc' : 'asc';
            } else {
                sortColumn = column;
                sortDirection = 'asc';
            }

            // Re-render with sorted and filtered data
            applyFiltersAndRender();
        }

        function renderReviewRequests(data) {
            if (!data || data.length === 0) return '';

            let filtered = data;
            let title = 'Reviews';
            if (hideClosedMerged) {
                filtered = data.filter(pr => pr.review_status === 'pending' && pr.is_direct_request && !pr.user_approved);
                title = 'Needs Your Review';
            }
            if (hideDrafts) {
                filtered = filtered.filter(pr => !pr.isDraft);
            }
            if (filtered.length === 0) return '';

            const collapsedClass = reviewsCollapsed ? ' collapsed' : '';
            const contentHidden = reviewsCollapsed ? ' section-collapsed' : '';

            let html = '<div class="review-section">';
            html += `<div class="section-header review-section-header${collapsedClass}" onclick="toggleSection('reviews')"><span class="chevron">▾</span><span>${title}</span><span class="count">${filtered.length}</span></div>`;
            html += `<div class="review-section-content${contentHidden}">`;
            html += '<table><thead><tr>';
            html += '<th style="position:static;background:var(--bg-secondary)">Author</th>';
            html += '<th style="position:static;background:var(--bg-secondary)">Branch</th>';
            html += '<th style="position:static;background:var(--bg-secondary)">PR Title</th>';
            html += '<th style="position:static;background:var(--bg-secondary);text-align:center">CI</th>';
            html += '<th style="position:static;background:var(--bg-secondary)">Updated</th>';
            html += '<th style="position:static;background:var(--bg-secondary)">Reviewers</th>';
            html += '</tr></thead><tbody>';

            for (const pr of filtered) {
                const draftBadge = pr.isDraft
                    ? ' <span class="status-badge status-draft" style="font-size:0.6rem;padding:0.125rem 0.375rem">Draft</span>'
                    : '';
                const authorLogin = pr.author || '';
                const authorShort = authorLogin.split('-')[0];
                const reviewNewClass = isNewReview(prKeyOf(pr)) ? ' has-new-activity' : '';
                html += `<tr class="${reviewNewClass.trim()}">`;
                html += `<td class="review-author">${authorLogin ? userPullsLink(authorLogin, escapeHtml(authorShort)) : escapeHtml(authorShort)}</td>`;
                html += `<td class="branch copyable" onclick="copyToClipboard('${escapeHtml(pr.branch)}', this)">${repoBadge(pr)}${escapeHtml(pr.branch)}</td>`;
                html += `<td><div class="pr-title-wrapper"><a href="${escapeHtml(pr.url)}" target="_blank" class="pr-title" onclick="markReviewSeen('${escapeHtml(prKeyOf(pr))}')">${escapeHtml(pr.title)}</a>${draftBadge}<span class="tooltip">${escapeHtml(pr.title)}</span></div></td>`;
                html += '<td class="ci-status">';
                if (pr.ci_url) {
                    html += `<a href="${escapeHtml(pr.ci_url)}" target="_blank" class="ci-link ${pr.ci_class}"><span class="ci-icon">${pr.ci_symbol}</span></a>`;
                } else {
                    html += `<span class="${pr.ci_class}"><span class="ci-icon">${pr.ci_symbol}</span></span>`;
                }
                html += '</td>';
                html += `<td class="last-comment">${escapeHtml(pr.updated_at)}</td>`;

                let rrHtml = '';
                const rrApprovers = (pr.approvers || []);
                const rrCommented = (pr.commented_reviewers || []).filter(r => !rrApprovers.includes(r));
                const rrPending = (pr.pending_reviewers || []).filter(r => !rrApprovers.includes(r) && !rrCommented.includes(r));
                let rrShown = 0;
                for (const name of rrApprovers) {
                    if (rrShown > 0) rrHtml += ', ';
                    rrHtml += `<span class="reviewer-approved">${userPullsLink(name, '✓' + escapeHtml(name.split('-')[0]))}</span>`;
                    rrShown++;
                }
                for (const name of rrCommented) {
                    if (rrShown > 0) rrHtml += ', ';
                    rrHtml += `<span class="reviewer-commented">${userPullsLink(name, escapeHtml(name.split('-')[0]))}</span>`;
                    rrShown++;
                }
                for (const name of rrPending) {
                    if (rrShown > 0) rrHtml += ', ';
                    rrHtml += `<span class="reviewer-pending">${userPullsLink(name, escapeHtml(name.split('-')[0]))}</span>`;
                    rrShown++;
                }
                html += `<td class="reviewers">${rrHtml}</td>`;
                html += '</tr>';
            }

            html += '</tbody></table></div></div>';
            return html;
        }

        function renderTable(data, updateGlobal = true, isUpdating = false) {
            // Store data globally for expansion lookups (only on fresh data)
            if (updateGlobal) {
                worktreeData = data;
            }

            const dataLength = (data && data.length) || 0;
            const collapsedClass = ownPrsCollapsed ? ' collapsed' : '';
            const contentHidden = ownPrsCollapsed ? ' section-collapsed' : '';

            let html = `<div class="own-prs-section">`;
            html += `<div class="section-header own-prs-header${collapsedClass}" onclick="toggleSection('own')"><span class="chevron">▾</span><span>Your PRs</span><span class="count">${dataLength}</span></div>`;
            html += `<div class="own-prs-content${contentHidden}">`;

            if (!data || data.length === 0) {
                if (isUpdating) {
                    html += '<div class="loading"><div class="loading-spinner"></div><span>Fetching PR data...</span></div>';
                } else {
                    html += '<div class="empty-state">No branches found</div>';
                }
                html += '</div></div>';
                return html;
            }

            const columns = [
                { key: 'worktree', label: 'Path', style: '' },
                { key: 'local', label: 'Local', style: '' },
                { key: 'branch', label: 'Branch', style: '' },
                { key: 'status', label: 'Status', style: '' },
                { key: 'title', label: 'PR Title', style: '' },
                { key: 'ci', label: 'CI', style: 'text-align: center;' },
                { key: 'updated', label: 'Updated', style: '' },
                { key: 'comments', label: 'C', style: 'text-align: right;' },
                { key: 'last', label: 'Last', style: '' },
                { key: 'reviewers', label: 'Reviewers', style: '' },
            ];

            let headerHtml = columns.map(col => {
                const isSorted = sortColumn === col.key;
                const cls = isSorted ? 'sorted' : '';
                const indicator = isSorted
                    ? (sortDirection === 'asc' ? '↑' : '↓')
                    : '↕';
                const style = col.style ? ` style="${col.style}"` : '';
                return `<th class="${cls}"${style} onclick="handleSort('${col.key}')">${col.label}<span class="sort-indicator">${indicator}</span></th>`;
            }).join('');
            html += `
                <table>
                    <thead>
                        <tr>${headerHtml}</tr>
                    </thead>
                    <tbody>
            `;

            for (let i = 0; i < data.length; i++) {
                const row = data[i];
                const hasLocalChanges = row.has_dirty || row.has_unpushed;
                const hasNewActivityClass = hasNewActivity(row) ? ' has-new-activity' : '';

                html += `<tr id="main-${i}" class="${hasNewActivityClass.trim()}" onmouseenter="selectRowByMouse(${i})">`;
                const virtualBadge = row.is_virtual ? '<span class="badge badge-virtual" title="No local checkout">∅</span>' : '';
                html += `<td class="worktree-path copyable" onclick="copyToClipboard('${escapeHtml(row.worktree_display)}', this)">${escapeHtml(row.worktree_display)}${virtualBadge}</td>`;

                // Local status
                html += `<td class="local-status"`;
                if (hasLocalChanges) {
                    html += ` onclick="toggleExpansion(${i}, event)"`;
                }
                html += `><span class="local-badges">`;
                if (row.has_dirty) {
                    html += `<span class="badge badge-dirty" title="Uncommitted changes">D</span>`;
                }
                if (row.has_unpushed) {
                    html += `<span class="badge badge-unpushed" title="Unpushed commits">U</span>`;
                }
                html += `</span></td>`;

                html += `<td class="branch copyable" onclick="copyToClipboard('${escapeHtml(row.branch)}', this)">${repoBadge(row)}${escapeHtml(row.branch)}</td>`;
                const conflictsBadge = row.has_conflicts ? '<span class="badge badge-conflicts" title="Has merge conflicts">⚠</span>' : '';
                html += `<td><span class="status-badge status-${row.status}">${escapeHtml(row.status_label)}</span>${conflictsBadge}</td>`;

                // PR Title with link and instant tooltip for full title (only shown if truncated)
                if (row.pr_url) {
                    html += `<td><div class="pr-title-wrapper"><a href="${escapeHtml(row.pr_url)}" target="_blank" class="pr-title" onclick="markPRViewed('${escapeHtml(prKeyOf(row))}', ${i})">${escapeHtml(row.pr_title)}</a><span class="tooltip">${escapeHtml(row.pr_title)}</span></div></td>`;
                } else {
                    html += `<td></td>`;
                }

                // CI Status - clickable for fail, running, queued
                html += `<td class="ci-status">`;
                if (row.ci_url) {
                    html += `<a href="${escapeHtml(row.ci_url)}" target="_blank" class="ci-link ${row.ci_class}"><span class="ci-icon">${row.ci_symbol}</span></a>`;
                } else {
                    html += `<span class="${row.ci_class}"><span class="ci-icon">${row.ci_symbol}</span></span>`;
                }
                html += `</td>`;

                html += `<td class="last-comment">${escapeHtml(row.updated_at)}</td>`;
                html += `<td class="comments" style="text-align: right;">${row.comment_count || ''}</td>`;
                html += `<td class="last-comment">${escapeHtml(row.last_comment)}</td>`;
                let reviewersHtml = '';
                const approvers = (row.approvers || []);
                const commented = (row.commented_reviewers || []).filter(r => !approvers.includes(r));
                const pending = (row.pending_reviewers || []).filter(r => !approvers.includes(r) && !commented.includes(r));
                const maxTotal = 6;
                let shown = 0;

                for (const name of approvers) {
                    if (shown >= maxTotal) break;
                    const shortName = name.split('-')[0];
                    if (shown > 0) reviewersHtml += ', ';
                    reviewersHtml += `<span class="reviewer-approved">${userPullsLink(name, '✓' + escapeHtml(shortName))}</span>`;
                    shown++;
                }

                for (const name of commented) {
                    if (shown >= maxTotal) break;
                    const shortName = name.split('-')[0];
                    if (shown > 0) reviewersHtml += ', ';
                    reviewersHtml += `<span class="reviewer-commented">${userPullsLink(name, escapeHtml(shortName))}</span>`;
                    shown++;
                }

                for (const name of pending) {
                    if (shown >= maxTotal) break;
                    const shortName = name.split('-')[0];
                    if (shown > 0) reviewersHtml += ', ';
                    reviewersHtml += `<span class="reviewer-pending">${userPullsLink(name, escapeHtml(shortName))}</span>`;
                    shown++;
                }

                const totalReviewers = approvers.length + commented.length + pending.length;
                if (totalReviewers > maxTotal) {
                    reviewersHtml += ` <span class="reviewer-pending">+${totalReviewers - maxTotal}</span>`;
                }

                html += `<td class="reviewers">${reviewersHtml}</td>`;
                html += `</tr>`;

                // Expansion row
                if (hasLocalChanges) {
                    html += `<tr class="expansion-row" id="expansion-${i}"><td colspan="10"><div class="expansion-content"></div></td></tr>`;
                }
            }

            html += '</tbody></table></div></div>';
            return html;
        }

        function userPullsLink(githubLogin, innerHtml) {
            return `<a href="https://github.com/pulls?q=is%3Apr+author%3A${encodeURIComponent(githubLogin)}+is%3Aopen" target="_blank" class="user-link">${innerHtml}</a>`;
        }

        function escapeHtml(str) {
            if (!str) return '';
            return String(str)
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#039;');
        }

        function detectTruncatedTitles() {
            // Find all PR title wrappers and check if the title is actually truncated
            document.querySelectorAll('.pr-title-wrapper').forEach(wrapper => {
                const titleEl = wrapper.querySelector('.pr-title');
                if (titleEl && titleEl.scrollWidth > titleEl.clientWidth) {
                    wrapper.classList.add('truncated');
                } else {
                    wrapper.classList.remove('truncated');
                }
            });
        }

        async function refreshData() {
            try {
                const response = await fetch('/api/worktrees');
                const result = await response.json();

                // Store the full data set
                worktreeData = result.data;
                reviewRequestData = result.review_requests || [];

                // Detect new review requests and own-PR activity for notifications
                const currentReviewNumbers = new Set(
                    reviewRequestData.filter(r => r.review_status === 'pending').map(r => prKeyOf(r))
                );
                const currentGreenPRs = new Set(
                    worktreeData.filter(r => hasNewActivity(r)).map(r => prKeyOf(r))
                );

                if (!isFirstLoad) {
                    const newReviewNumbers = [...currentReviewNumbers].filter(n => !previousReviewNumbers.has(n));
                    if (newReviewNumbers.length > 0) {
                        const newPRs = reviewRequestData.filter(r => newReviewNumbers.includes(prKeyOf(r)));
                        sendNotification(
                            `${newPRs.length} new review request${newPRs.length > 1 ? 's' : ''}`,
                            newPRs.map(p => `${p.author}: ${p.title}`).join('\\n')
                        );
                    }
                    const newlyGreen = [...currentGreenPRs].filter(n => !previousGreenPRs.has(n));
                    if (newlyGreen.length > 0) {
                        const greenRows = worktreeData.filter(r => newlyGreen.includes(prKeyOf(r)));
                        sendNotification(
                            `${greenRows.length} PR${greenRows.length > 1 ? 's' : ''} updated`,
                            greenRows.map(p => `${p.branch}: ${p.last_comment || 'new activity'}`).join('\\n')
                        );
                    }
                }
                previousReviewNumbers = currentReviewNumbers;
                previousGreenPRs = currentGreenPRs;
                isFirstLoad = false;
                cleanupSeenReviews([...currentReviewNumbers]);

                // Apply current sort and search filter
                const displayedData = getDisplayedData();

                let contentHtml = renderReviewRequests(reviewRequestData);
                contentHtml += renderTable(displayedData, false, result.updating);
                document.getElementById('content').innerHTML = contentHtml;
                detectTruncatedTitles();

                // Restore selection state
                restoreSelection();

                // Restore expansion state if we had one
                if (currentExpandedPath) {
                    const expandedIndex = displayedData.findIndex(d => d.worktree === currentExpandedPath);
                    if (expandedIndex >= 0) {
                        const row = document.getElementById(`expansion-${expandedIndex}`);
                        const mainRow = document.getElementById(`main-${expandedIndex}`);
                        if (row) {
                            row.classList.add('visible');
                            mainRow?.classList.add('expanded');
                            loadExpansionContent(expandedIndex, displayedData);
                        }
                    } else {
                        // Entry no longer exists in view, clear expansion
                        currentExpandedPath = null;
                    }
                }

                const indicator = document.getElementById('refreshIndicator');
                const lastUpdated = document.getElementById('lastUpdated');

                if (result.last_updated) {
                    lastUpdated.textContent = `Updated ${formatTime(result.last_updated)}`;
                }

                // Update next refresh time from server
                if (result.next_refresh) {
                    nextRefreshTime = new Date(result.next_refresh).getTime();
                }

                // Track error state for faster polling
                hasErrors = result.has_errors || false;
                isStale = result.is_stale || false;

                indicator.classList.toggle('updating', result.updating);
                indicator.classList.toggle('is-stale', result.is_stale);

                // Show error/stale state in header
                if (result.rate_limited_until) {
                    const resumeAt = new Date(result.rate_limited_until).toLocaleTimeString();
                    indicator.classList.remove('has-errors');
                    indicator.classList.add('is-stale');
                    indicator.title = `GitHub rate limit hit - showing cached data, resuming at ${resumeAt}`;
                } else if (result.is_stale) {
                    indicator.classList.remove('has-errors');
                    indicator.classList.add('is-stale');
                    indicator.title = 'GitHub API failed - showing cached data. Click to retry.';
                } else if (result.has_errors) {
                    indicator.classList.add('has-errors');
                    indicator.classList.remove('is-stale');
                    indicator.title = 'Some GitHub API calls failed - retrying automatically';
                } else {
                    indicator.classList.remove('has-errors');
                    indicator.classList.remove('is-stale');
                    indicator.title = 'Click to refresh';
                }
            } catch (err) {
                console.error('Failed to refresh:', err);
            }
        }

        let nextRefreshTime = null;
        let hasErrors = false;
        let isStale = false;
        const POLL_INTERVAL_MS = 5000; // Poll server every 5 seconds to check for updates
        const POLL_INTERVAL_ERROR_MS = 3000; // Poll faster when there are errors

        function updateNextRefreshDisplay() {
            const el = document.getElementById('nextRefresh');
            if (!el || !nextRefreshTime) return;

            const remaining = Math.max(0, Math.ceil((nextRefreshTime - Date.now()) / 1000));
            el.textContent = `(${remaining}s)`;
        }

        async function manualRefresh() {
            const indicator = document.getElementById('refreshIndicator');
            if (indicator.classList.contains('updating')) return;

            indicator.classList.add('updating');

            // Trigger a server-side refresh
            try {
                await fetch('/api/refresh', { method: 'POST' });
            } catch (e) {
                console.error('Failed to trigger refresh:', e);
                indicator.classList.remove('updating');
                return;
            }

            // Poll until refresh is complete (with timeout)
            const maxWaitMs = 120000; // 2 minutes max
            const pollIntervalMs = 500;
            const startTime = Date.now();

            const pollForCompletion = async () => {
                try {
                    const response = await fetch('/api/worktrees');
                    const result = await response.json();

                    if (!result.updating || Date.now() - startTime > maxWaitMs) {
                        // Refresh complete (or timed out), update the UI
                        worktreeData = result.data;  // Store full data
                        reviewRequestData = result.review_requests || [];
                        const displayedData = getDisplayedData();  // Apply sort + filter
                        let manualHtml = renderReviewRequests(reviewRequestData);
                        manualHtml += renderTable(displayedData, false);
                        document.getElementById('content').innerHTML = manualHtml;
                        detectTruncatedTitles();
                        restoreSelection();

                        if (result.last_updated) {
                            document.getElementById('lastUpdated').textContent = `Updated ${formatTime(result.last_updated)}`;
                        }
                        if (result.next_refresh) {
                            nextRefreshTime = new Date(result.next_refresh).getTime();
                        }

                        indicator.classList.remove('updating');

                        // Restore expansion state
                        if (currentExpandedPath) {
                            const expandedIndex = displayedData.findIndex(d => d.worktree === currentExpandedPath);
                            if (expandedIndex >= 0) {
                                const row = document.getElementById(`expansion-${expandedIndex}`);
                                const mainRow = document.getElementById(`main-${expandedIndex}`);
                                if (row) {
                                    row.classList.add('visible');
                                    mainRow?.classList.add('expanded');
                                    loadExpansionContent(expandedIndex, displayedData);
                                }
                            }
                        }
                    } else {
                        // Still updating, poll again
                        setTimeout(pollForCompletion, pollIntervalMs);
                    }
                } catch (err) {
                    console.error('Error polling for refresh completion:', err);
                    indicator.classList.remove('updating');
                }
            };

            // Start polling after a brief delay
            setTimeout(pollForCompletion, 200);
        }

        // Restore toggle state from localStorage
        hideClosedMerged = localStorage.getItem('pr_dash_hide_closed_merged') === 'true';
        hideDrafts = localStorage.getItem('pr_dash_hide_drafts') === 'true';
        document.getElementById('hideClosedToggle').checked = hideClosedMerged;
        document.getElementById('hideDraftsToggle').checked = hideDrafts;

        // Request notification permission
        if ('Notification' in window && Notification.permission === 'default') {
            Notification.requestPermission();
        }

        // Initial load
        refreshData();

        // Poll server periodically - faster when there are errors
        function schedulePoll() {
            const interval = hasErrors ? POLL_INTERVAL_ERROR_MS : POLL_INTERVAL_MS;
            setTimeout(() => {
                refreshData();
                schedulePoll();
            }, interval);
        }
        schedulePoll();

        // Update countdown display every second
        setInterval(updateNextRefreshDisplay, 1000);

        // Visibility-based heartbeat: tell server when page is actively viewed
        let isPageVisible = !document.hidden;
        let heartbeatInterval = null;

        function sendHeartbeat() {
            if (isPageVisible) {
                fetch('/api/heartbeat', { method: 'POST' }).catch(() => {});
            }
        }

        function startHeartbeat() {
            sendHeartbeat();  // Send immediately when becoming visible
            if (!heartbeatInterval) {
                heartbeatInterval = setInterval(sendHeartbeat, 30000);  // Every 30s while visible
            }
        }

        function stopHeartbeat() {
            if (heartbeatInterval) {
                clearInterval(heartbeatInterval);
                heartbeatInterval = null;
            }
        }

        document.addEventListener('visibilitychange', () => {
            isPageVisible = !document.hidden;
            if (isPageVisible) {
                startHeartbeat();
            } else {
                stopHeartbeat();
            }
        });

        // Start heartbeat if page is visible on load
        if (isPageVisible) {
            startHeartbeat();
        }
    </script>
</body>
</html>
"""


@app.route('/')
def index():
    return render_template_string(HTML_TEMPLATE)


@app.route('/api/worktrees')
def api_worktrees():
    _note_activity()

    with _cache_lock:
        data = _cache['data']
        review_requests = _cache.get('review_requests', [])
        last_updated = _cache['last_updated']
        updating = _cache['updating']
        is_stale = _cache.get('is_stale', False)

    # Check if any entries have fetch errors
    has_errors = any(d.get('status') == 'fetch-error' for d in data) or is_stale

    limited_until = rate_limited_until()
    refresh_interval = _refresh_interval()
    next_refresh = None
    if limited_until:
        next_refresh = limited_until
    elif last_updated:
        next_refresh = last_updated + timedelta(seconds=refresh_interval)

    # Serialize datetime objects
    serialized = []
    for item in data:
        d = dict(item)
        if d.get('pr_updated_at'):
            d['pr_updated_at'] = d['pr_updated_at'].isoformat()
        if d.get('pr'):
            d['pr'] = None  # Don't send full PR object
        serialized.append(d)

    return jsonify(
        {
            'data': serialized,
            'review_requests': review_requests,
            'last_updated': last_updated.isoformat() if last_updated else None,
            'next_refresh': next_refresh.isoformat() if next_refresh else None,
            'updating': updating,
            'has_errors': has_errors,
            'is_stale': is_stale,
            'rate_limited_until': limited_until.isoformat() if limited_until else None,
        }
    )


@app.route('/api/details')
def api_details():
    worktree = request.args.get('worktree', '')

    dirty_files = get_dirty_files(worktree)
    unpushed_commits = get_unpushed_commits(worktree)

    return jsonify(
        {
            'dirty_files': dirty_files,
            'unpushed_commits': unpushed_commits,
        }
    )


@app.route('/api/refresh', methods=['POST'])
def api_refresh():
    """Trigger an immediate refresh of the cache."""
    with _cache_lock:
        already_updating = _cache['updating']

    if already_updating:
        return jsonify({'status': 'refresh already in progress'})

    # A click is a deliberate probe: lift the cooldown. If GitHub is still over quota the first
    # call re-arms it and the rest of the cycle short-circuits, so the probe costs one request.
    with _rate_limit_lock:
        _rate_limit_state['until'] = None

    threading.Thread(target=refresh_cache, kwargs={'force': True}, daemon=True).start()
    return jsonify({'status': 'refresh started'})


@app.route('/api/heartbeat', methods=['POST'])
def api_heartbeat():
    """Heartbeat from frontend indicating page is actively being viewed."""
    _note_activity()

    return jsonify({'status': 'ok'})


def main():
    parser = argparse.ArgumentParser(
        description='PR Dashboard — track your GitHub PRs, worktrees, and local changes in one view.',
        epilog='Environment: PR_DASH_DEBUG=1, PR_DASH_CMD_TIMEOUT=30, PR_DASH_BATCH_SIZE=15, PR_DASH_PARALLEL=4',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('--port', type=int, default=8765, help='port to listen on (default: 8765)')
    parser.add_argument('--host', default='127.0.0.1', help='host to bind to (default: 127.0.0.1)')
    args = parser.parse_args()

    # Start background refresh thread
    refresh_thread = threading.Thread(target=background_refresh, daemon=True)
    refresh_thread.start()

    # Trigger initial refresh
    threading.Thread(target=refresh_cache, daemon=True).start()

    print(f'Starting PR dashboard at http://{args.host}:{args.port}')
    app.run(host=args.host, port=args.port, debug=False, threaded=True)


if __name__ == '__main__':
    main()
