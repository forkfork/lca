"""Three-way workspace/index return. Conflicts are planned before local writes."""
import base64
import json
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
from pathlib import Path
from workspace import EXCLUDED, git, paths

class Conflict(RuntimeError):
    pass

def ignored(name):
    return name in EXCLUDED or name.startswith(('.git/', '.lca/jobs/', '.lca-sessions/', '.lca/replays/'))

def value(root, name):
    path = Path(root) / name
    if Path(name).is_absolute() or '..' in Path(name).parts or name == '.git':
        raise Conflict('unsafe project path: ' + name)
    current = Path(root)
    for part in Path(name).parts[:-1]:
        current /= part
        if current.is_symlink():
            raise Conflict('symlink parent requires manual reconciliation: ' + name)
    if not path.exists() and not path.is_symlink():
        return None
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode):
        target = os.readlink(path)
        if os.path.isabs(target) or not (path.parent / target).resolve().is_relative_to(Path(root).resolve()):
            raise Conflict('external symlink: ' + name)
        return ('120000', target.encode())
    if not stat.S_ISREG(mode):
        raise Conflict('directory or special-file change requires manual reconciliation: ' + name)
    return ('100755' if mode & 0o111 else '100644', path.read_bytes())

def merge(base, local, remote, name):
    if local == remote or remote == base:
        return local
    if local == base:
        return remote
    if any(v is None or v[0] == '120000' for v in (base, local, remote)):
        raise Conflict(name + ': conflicting creation, deletion or symlink change')
    modes = [v[0] for v in (base, local, remote)]
    mode = modes[1] if modes[1] == modes[2] or modes[2] == modes[0] else modes[2]
    if any(b'\0' in v[1] for v in (base, local, remote)):
        raise Conflict(name + ': conflicting binary changes')
    with tempfile.TemporaryDirectory() as directory:
        files = []
        for label, v in zip(('base', 'local', 'remote'), (base, local, remote)):
            path = Path(directory) / label
            path.write_bytes(v[1]); files.append(str(path))
        r = subprocess.run(['git', 'merge-file', '-p', files[1], files[0], files[2]], capture_output=True)
        if r.returncode:
            raise Conflict(name + ': overlapping edits')
        return (mode, r.stdout)

def index_values(root):
    result = {}
    for row in git(root, 'ls-files', '--stage', '-z').split(b'\0'):
        if not row:
            continue
        meta, name = row.split(b'\t', 1)
        mode, oid, stage = meta.decode().split()
        name = name.decode()
        if stage != '0' or mode == '160000':
            raise Conflict('unmerged index or submodule: ' + name)
        if not ignored(name):
            result[name] = (mode, git(root, 'cat-file', 'blob', oid))
    return result

def pack(v):
    return None if v is None else [v[0], base64.b64encode(v[1]).decode()]

def unpack(v):
    return None if v is None else (v[0], base64.b64decode(v[1], validate=True))

def plan(root, remote, artifact, destination):
    root, remote, artifact, destination = map(Path, (root, remote, artifact, destination))
    manifest = json.loads((artifact / 'manifest.json').read_text())
    head = manifest['head']
    if git(root, 'rev-parse', 'HEAD').decode().strip() != head or git(remote, 'rev-parse', 'HEAD').decode().strip() != head:
        raise Conflict('Git HEAD changed since backgrounding; reconcile commits explicitly before returning')
    expected_index = Path(git(root, 'rev-parse', '--path-format=absolute', '--git-path', 'index').decode().strip()).read_bytes()
    with tempfile.TemporaryDirectory() as temp:
        base = Path(temp) / 'base'
        subprocess.run(['git', '-c', 'advice.detachedHead=false', 'clone', '-q', str(artifact / 'repo.bundle'), str(base)], check=True)
        if (artifact / 'index.patch').stat().st_size:
            subprocess.run(['git', '-C', str(base), 'apply', '--cached', str(artifact / 'index.patch')], check=True)
        base_index = index_values(base)
        # Recreate baseline working files independently of baseline staging.
        for name, item in manifest['files'].items():
            if item.get('deleted'):
                (base / name).unlink(missing_ok=True)
        with tarfile.open(artifact / 'files.tar') as archive:
            archive.extractall(base, filter='data')
        names = sorted(set(manifest['files']) | set(paths(remote)) | set(paths(root)))
        changes, conflicts = {}, []
        for name in names:
            if ignored(name):
                continue
            try:
                before = value(root, name)
                after = merge(value(base, name), before, value(remote, name), name)
                if after != before:
                    changes[name] = {'before': pack(before), 'after': pack(after)}
            except Conflict as e:
                conflicts.append(str(e))
        local_index, remote_index = index_values(root), index_values(remote)
        merged_index = {}
        for name in sorted(set(base_index) | set(local_index) | set(remote_index)):
            try:
                merged_index[name] = merge(base_index.get(name), local_index.get(name), remote_index.get(name), 'index: ' + name)
            except Conflict as e:
                conflicts.append(str(e))
        if conflicts:
            raise Conflict('\n'.join(conflicts))
        new_index = Path(temp) / 'index'
        new_index.write_bytes(expected_index)
        env = dict(os.environ, GIT_INDEX_FILE=str(new_index))
        updates = []
        for name, v in merged_index.items():
            if v == local_index.get(name):
                continue
            if v is None:
                updates.append(b'0 ' + b'0' * len(head) + b'\t' + name.encode() + b'\0')
            else:
                oid = subprocess.check_output(['git', '-C', str(root), 'hash-object', '-w', '--stdin'], input=v[1]).strip()
                updates.append(v[0].encode() + b' ' + oid + b'\t' + name.encode() + b'\0')
        if updates:
            subprocess.run(['git', '-C', str(root), 'update-index', '-z', '--index-info'], input=b''.join(updates), env=env, check=True)
        result = {'head': head, 'changes': changes,
                  'index_before': base64.b64encode(expected_index).decode(),
                  'index_after': base64.b64encode(new_index.read_bytes()).decode()}
        from handoff import atomic
        atomic(destination, result)
        return result

def write_value(root, name, item):
    path = Path(root) / name
    if item is None:
        path.unlink(missing_ok=True)
        directory=os.open(path.parent,os.O_RDONLY)
        try: os.fsync(directory)
        finally: os.close(directory)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    mode, data = item
    fd, tmp = tempfile.mkstemp(prefix='.lca-return-', dir=path.parent)
    try:
        if mode == '120000':
            os.close(fd); os.unlink(tmp); os.symlink(data.decode(), tmp)
        else:
            with os.fdopen(fd, 'wb') as f:
                f.write(data); f.flush(); os.fchmod(f.fileno(), 0o755 if mode == '100755' else 0o644); os.fsync(f.fileno())
        os.replace(tmp, path)
        directory=os.open(path.parent,os.O_RDONLY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        if os.path.lexists(tmp): os.unlink(tmp)

def apply(root, transaction):
    root = Path(root)
    if git(root, 'rev-parse', 'HEAD').decode().strip() != transaction['head']:
        raise Conflict('Git HEAD changed during return; project remains fenced')
    index = Path(git(root, 'rev-parse', '--path-format=absolute', '--git-path', 'index').decode().strip())
    before = base64.b64decode(transaction['index_before'])
    after = base64.b64decode(transaction['index_after'])
    lock = index.with_name('index.lock')
    fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        if index.read_bytes() not in (before, after):
            raise Conflict('Git index changed during return; project remains fenced')
        # Validate all paths first. Retry accepts already-applied entries only.
        for name, change in transaction['changes'].items():
            if value(root, name) not in (unpack(change['before']), unpack(change['after'])):
                raise Conflict(name + ': changed during return; project remains fenced')
        for name, change in transaction['changes'].items():
            current = value(root, name)
            if current == unpack(change['after']): continue
            if current != unpack(change['before']): raise Conflict(name + ': concurrent edit during return')
            write_value(root, name, unpack(change['after']))
        with os.fdopen(fd, 'wb') as f:
            fd = None; f.write(after); f.flush(); os.fsync(f.fileno())
        os.replace(lock, index)
        directory = os.open(index.parent, os.O_RDONLY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        if fd is not None: os.close(fd)
        lock.unlink(missing_ok=True)
