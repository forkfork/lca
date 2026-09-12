"""Portable Git snapshot. No HOME, Git hooks/config, ignored caches or credentials."""
import hashlib, json, os, stat, subprocess, tarfile
from pathlib import Path

EXCLUDED={'.lca-handoff.json','.lca-handoff.json.lock','.lca-queue.json','.lca-session.json','.lca-history'}
def git(root,*args):
    return subprocess.check_output(['git','-C',str(root),*args])
def paths(root):
    return sorted(set(git(root,'ls-files','--cached','--others','--exclude-standard','-z').decode().split('\0'))-{''})
def entry(root,name):
    if name in EXCLUDED or name.startswith(('.lca/jobs/','.lca-sessions/','.lca/replays/')):return None
    path=root/name
    if not path.exists() and not path.is_symlink():return {'deleted':True}
    if not path.parent.resolve().is_relative_to(root):raise ValueError('path escapes project: '+name)
    mode=path.lstat().st_mode
    if stat.S_ISLNK(mode):
        target=os.readlink(path)
        if os.path.isabs(target) or not (path.parent/target).resolve().is_relative_to(root):raise ValueError('external symlink: '+name)
        return {'link':target}
    if not stat.S_ISREG(mode):raise ValueError('unsupported special file: '+name)
    # Deny accidental credential files even if Git tracks them.
    if path.name in {'.env','credentials.json','.lca-credentials.json','id_rsa','id_ed25519'} or path.name.startswith('.env.') and path.name not in {'.env.example','.env.sample'}:
        raise ValueError('credential-like file requires explicit removal from project transfer: '+name)
    data=path.read_bytes()
    if b'-----BEGIN PRIVATE KEY-----' in data or b'-----BEGIN RSA PRIVATE KEY-----' in data:raise ValueError('private key: '+name)
    return {'sha256':hashlib.sha256(data).hexdigest(),'executable':bool(mode & 0o111),'bytes':len(data)}
def snapshot(root,dest,max_bytes=100*1024*1024):
    root=Path(root).resolve();dest=Path(dest);dest.mkdir(parents=True,exist_ok=False)
    if git(root,'rev-parse','--show-toplevel').decode().strip()!=str(root):raise ValueError('start from the Git repository root')
    head=git(root,'rev-parse','HEAD').decode().strip()
    branch=subprocess.run(['git','-C',str(root),'symbolic-ref','--short','-q','HEAD'],capture_output=True,text=True).stdout.strip()
    if any(x.startswith(b'160000 ') for x in git(root,'ls-files','--stage','-z').split(b'\0')):raise ValueError('submodules are not supported by this experiment')
    if git(root,'ls-files','--unmerged'):raise ValueError('resolve Git conflicts before backgrounding')
    names=paths(root)
    # HEAD paths include staged deletions, which ls-files no longer lists.
    head_names=set(git(root,'ls-tree','-r','--name-only','-z',head).decode().split('\0'))-{''}
    manifest={n:e for n in sorted(set(names)|head_names) if (e:=entry(root,n)) is not None}
    if sum(e.get('bytes',0) for e in manifest.values())>max_bytes:raise ValueError('workspace exceeds transfer limit')
    staged=git(root,'diff','--cached','--binary',head)
    (dest/'index.patch').write_bytes(staged)
    git(root,'bundle','create',str(dest/'repo.bundle'),'HEAD')
    # Keep only the current history; Git config/hooks and credential-bearing remotes never move.
    (dest/'manifest.json').write_text(json.dumps({'head':head,'branch':branch,'files':manifest},indent=2))
    with tarfile.open(dest/'files.tar','w') as out:
        for n,e in manifest.items():
            if not e.get('deleted'):out.add(root/n,arcname=n,recursive=False)
    if paths(root)!=names or any(entry(root,n)!=manifest[n] for n in manifest) or git(root,'diff','--cached','--binary',head)!=staged or git(root,'rev-parse','HEAD').decode().strip()!=head:
        raise ValueError('project changed during snapshot; retry at a stable point')
    # Git history is included; secret scanning the current tree alone is insufficient.
    if (dest/'repo.bundle').stat().st_size>max_bytes:raise ValueError('Git bundle exceeds transfer limit')
    return manifest

def extract_proof(archive,destination):
    destination=Path(destination)
    destination.mkdir(parents=True,exist_ok=False)
    with tarfile.open(archive) as source:source.extractall(destination,filter='data')
