#!/usr/bin/env python3
"""Make git worktrees share disk space with their main checkout (macOS APFS).

Every linked worktree holds its own copy of each tracked file, so a repository
with N worktrees stores almost every file N+1 times. On APFS a file can instead
be a clone (clonefile(2)): a copy that shares the original's disk blocks until
either side is written, when APFS copies just the changed blocks. A clone
behaves like an ordinary independent copy, so edits never leak between
worktrees.

For each worktree this replaces every tracked file that matches the main
checkout's copy with a clone of it. A file matches when both indexes record the
same blob and mode and git sees the file as unmodified on both sides
(`git diff-files`, which also compares inode and ctime). --verify-bytes also
reads both files and compares them. A replaced file keeps its own mode and takes
the main checkout's timestamps, which is how later runs recognize files they
already cloned.

Each replacement atomically swaps the clone into place (renamex_np with
RENAME_SWAP), then checks that the swapped-out original was not modified after
it was verified; if it was, the swap is undone. Worktrees that a running process
uses as its working directory are skipped unless --fresh is given.

Usage:
  clone-worktree-files.py [options] WORKTREE...
  clone-worktree-files.py [options] --all

  --all            Every linked worktree of the repository.
  --source MAIN    Checkout to share blocks with (default: the main worktree).
  --fresh          The worktrees were just created and nothing is using them
                   yet; skip the check for processes working inside them.
  --verify-bytes   Also compare file contents before sharing (slower).
  --dry-run        Report what would be shared without changing anything.
  --quiet          Print only the summary line.
  --kib            Print only the KiB shared (or that would be), for scripts.

Sizes reported by du and Finder count each clone in full; free space (df) shows
the real saving. On other platforms and file systems this exits without doing
anything.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import contextlib
import ctypes
import ctypes.util
import errno
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time

CHUNK = 1 << 20
CLONE_NOFOLLOW = 0x0001
CLONE_NOOWNERCOPY = 0x0002
RENAME_SWAP = 0x0002
REGULAR_MODES = {'100644', '100755'}
# Set by SIGTERM or SIGINT: finish the files in flight, then stop.
STOP = threading.Event()


class CloneUnsupportedError(Exception):
    """The file system cannot clone between these paths (not APFS, or different volumes)."""


def load_libc():
    if sys.platform != 'darwin':
        return None
    libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
    libc.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
    libc.clonefile.restype = ctypes.c_int
    libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    libc.renamex_np.restype = ctypes.c_int
    return libc


LIBC = load_libc()


def clone(src: str, dst: str) -> None:
    if LIBC.clonefile(os.fsencode(src), os.fsencode(dst), CLONE_NOFOLLOW | CLONE_NOOWNERCOPY) != 0:
        err = ctypes.get_errno()
        if err in (errno.ENOTSUP, errno.EXDEV):
            raise CloneUnsupportedError(os.strerror(err))
        raise OSError(err, os.strerror(err), dst)


def swap(a: str, b: str) -> None:
    if LIBC.renamex_np(os.fsencode(a), os.fsencode(b), RENAME_SWAP) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), b)


def git(repo: Path, *args: str) -> bytes:
    return subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True).stdout


def clean_entries(repo: Path) -> dict[bytes, tuple[str, str]]:
    """Maps path to (mode, blob) for stage-0 regular files git sees as unmodified."""
    entries = {}
    for record in git(repo, 'ls-files', '--stage', '-z').split(b'\0'):
        if not record:
            continue
        meta, path = record.split(b'\t', 1)
        mode, blob, stage = meta.decode().split()
        if stage == '0' and mode in REGULAR_MODES:
            entries[path] = (mode, blob)
    for path in git(repo, 'diff-files', '--name-only', '-z').split(b'\0'):
        entries.pop(path, None)
    return entries


def worktree_paths(repo: Path) -> list[Path]:
    """The main worktree first, then linked worktrees that still exist."""
    paths = []
    for line in git(repo, 'worktree', 'list', '--porcelain').decode().splitlines():
        if line.startswith('worktree '):
            path = Path(line.removeprefix('worktree '))
            if not paths or path.is_dir():
                paths.append(path)
    return paths


def busy_directories() -> list[str]:
    """Working directories of running processes (empty if lsof is unavailable)."""
    try:
        out = subprocess.run(
            ['lsof', '-a', '-d', 'cwd', '-Fn'], capture_output=True, text=True, timeout=60, check=False
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [line[1:] for line in out.splitlines() if line.startswith('n')]


def same_contents(a: str, b: str) -> bool:
    with open(a, 'rb') as fa, open(b, 'rb') as fb:
        while True:
            chunk_a = fa.read(CHUNK)
            if chunk_a != fb.read(CHUNK):
                return False
            if not chunk_a:
                return True


def fingerprint(st: os.stat_result) -> tuple[int, int, int]:
    # Not ctime: the swap itself (a rename) updates it. Any write updates mtime.
    return (st.st_ino, st.st_size, st.st_mtime_ns)


def share_file(src: str, dst: str, scratch: str, verify_bytes: bool, dry_run: bool) -> tuple[str, int]:
    """Returns (outcome, bytes); outcome is cloned, already, differs, changed, or stopped."""
    if STOP.is_set():
        return 'stopped', 0
    try:
        src_st = os.lstat(src)
        dst_st = os.lstat(dst)
    except FileNotFoundError:
        return 'differs', 0
    if not (stat.S_ISREG(src_st.st_mode) and stat.S_ISREG(dst_st.st_mode)) or src_st.st_size != dst_st.st_size:
        return 'differs', 0
    if dst_st.st_mtime_ns == src_st.st_mtime_ns:
        return 'already', dst_st.st_size
    if verify_bytes and not same_contents(src, dst):
        return 'differs', 0
    if dry_run:
        return 'cloned', dst_st.st_size
    # The clone is made in the worktree's git directory, where `git status`
    # never lists it, so a concurrent `git add -A` cannot pick it up.
    tmp = os.path.join(scratch, str(threading.get_native_id()))
    try:
        clone(src, tmp)
        os.chmod(tmp, stat.S_IMODE(dst_st.st_mode))
        os.utime(tmp, ns=(src_st.st_atime_ns, src_st.st_mtime_ns), follow_symlinks=False)
        swap(tmp, dst)
        # tmp now holds the original. If something wrote it after it was
        # checked, put it back so the write is kept.
        if fingerprint(os.lstat(tmp)) != fingerprint(dst_st):
            swap(tmp, dst)
            return 'changed', 0
    except CloneUnsupportedError:
        raise
    except OSError:
        # The file was removed or replaced mid-run; leave whatever is there.
        return 'changed', 0
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
    return 'cloned', dst_st.st_size


def share_worktree(
    source: Path, source_entries: dict, worktree: Path, verify_bytes: bool, dry_run: bool
) -> dict[str, int]:
    counts = {
        'cloned': 0,
        'cloned_bytes': 0,
        'already': 0,
        'already_bytes': 0,
        'differs': 0,
        'changed': 0,
        'stopped': 0,
    }
    git_dir = Path(git(worktree, 'rev-parse', '--absolute-git-dir').decode().strip())
    if not os.stat(source).st_dev == os.stat(worktree).st_dev == os.stat(git_dir).st_dev:
        raise CloneUnsupportedError('not on the same volume as the main checkout')
    pairs = [
        (os.path.join(source, os.fsdecode(path)), os.path.join(worktree, os.fsdecode(path)))
        for path, entry in clean_entries(worktree).items()
        if source_entries.get(path) == entry
    ]
    # Holds clones until they are swapped in; anything left here by an
    # interrupted run is stale.
    scratch = git_dir / 'clone-worktree-files.tmp'
    shutil.rmtree(scratch, ignore_errors=True)
    if not dry_run:
        scratch.mkdir()
    try:
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = pool.map(
                lambda pair: share_file(*pair, str(scratch), verify_bytes, dry_run), pairs, chunksize=256
            )
            for outcome, size in results:
                counts[outcome] += 1
                if outcome in ('cloned', 'already'):
                    counts[f'{outcome}_bytes'] += size
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    if counts['cloned'] and not dry_run:
        refresh_index(worktree)
    return counts


def refresh_index(worktree: Path) -> None:
    """Records the replaced files' new stat data so the next `git status` does not re-hash them.

    Refreshing re-hashes every replaced file, which can take a minute, and
    `git update-index --refresh` holds index.lock all that time, so a commit in
    the worktree would fail. Instead, refresh a copy of the index, then take
    index.lock only to install the copy, and only if nobody wrote the index in
    the meantime. Best effort: otherwise git re-hashes on the next status.
    """
    index = worktree / git(worktree, 'rev-parse', '--git-path', 'index').decode().strip()
    lock = index.with_name(index.name + '.lock')
    copy = index.with_name(f'{index.name}.clone-worktree-files-{os.getpid()}')
    try:
        before = fingerprint(os.stat(index))
        shutil.copy2(index, copy)
        env = {**os.environ, 'GIT_INDEX_FILE': str(copy)}
        # Exits 1 when some entries still differ, which is expected.
        refresh = ['git', '-C', str(worktree), 'update-index', '-q', '--refresh']
        subprocess.run(refresh, env=env, capture_output=True, check=False)
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    except OSError:
        copy.unlink(missing_ok=True)
        return
    try:
        if fingerprint(os.stat(index)) == before:
            os.rename(copy, index)
    finally:
        os.close(fd)
        os.unlink(lock)
        copy.unlink(missing_ok=True)


def gib(n: int) -> str:
    return f'{n / (1 << 30):.2f}G'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('worktrees', nargs='*', type=Path)
    parser.add_argument('--all', action='store_true')
    parser.add_argument('--source', type=Path)
    parser.add_argument('--fresh', action='store_true')
    parser.add_argument('--verify-bytes', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--quiet', action='store_true')
    parser.add_argument('--kib', action='store_true')
    args = parser.parse_args()
    args.quiet = args.quiet or args.kib
    if not args.all and not args.worktrees:
        parser.error('pass worktree paths or --all')
    if LIBC is None:
        if args.kib:
            print(0)
        elif not args.quiet:
            print('clone-worktree-files: clones need macOS APFS; nothing to do')
        return 0

    repo = (args.source or (args.worktrees[0] if args.worktrees else Path.cwd())).resolve()
    all_worktrees = worktree_paths(repo)
    source = (args.source or all_worktrees[0]).resolve()
    targets = all_worktrees[1:] if args.all else [w.resolve() for w in args.worktrees]
    targets = [t for t in targets if t != source]
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: STOP.set())
    busy = [] if args.fresh else busy_directories()
    source_entries = clean_entries(source)

    total = {'cloned': 0, 'cloned_bytes': 0, 'already_bytes': 0, 'done': 0}
    began = time.monotonic()
    verb = 'would share' if args.dry_run else 'shared'
    for worktree in targets:
        if STOP.is_set():
            break
        prefix = f'{worktree}{os.sep}'
        reason = None
        if any(d == str(worktree) or d.startswith(prefix) for d in busy):
            reason = 'a running process works in it'
        else:
            try:
                counts = share_worktree(source, source_entries, worktree, args.verify_bytes, args.dry_run)
            except CloneUnsupportedError as e:
                reason = str(e)
            except subprocess.CalledProcessError as e:
                reason = f'git failed: {e.stderr.decode().strip()}'
        if reason:
            if not args.quiet:
                print(f'  skip {worktree} ({reason})')
            continue
        total['done'] += 1
        for key in ('cloned', 'cloned_bytes', 'already_bytes'):
            total[key] += counts[key]
        if not args.quiet:
            changed = f', {counts["changed"]} changed during the run' if counts['changed'] else ''
            print(
                f'  {worktree}: {verb} {counts["cloned"]} files ({gib(counts["cloned_bytes"])}), '
                f'{gib(counts["already_bytes"])} already shared, {counts["differs"]} not shared{changed}',
                flush=True,
            )
    if args.kib:
        print(total['cloned_bytes'] // 1024)
        return 0
    print(
        f'clone-worktree-files: {verb} {gib(total["cloned_bytes"])} in {total["cloned"]} files across '
        f'{total["done"]} worktrees ({gib(total["already_bytes"])} already shared, '
        f'{len(targets) - total["done"]} skipped) in {time.monotonic() - began:.0f}s'
        + (', stopped early' if STOP.is_set() else '')
    )
    return 0


if __name__ == '__main__':
    sys.exit(main())
