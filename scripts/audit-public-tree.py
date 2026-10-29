#!/usr/bin/env python3
"""Review only tracked/staged public files; never open ignored local data."""
import argparse, re, subprocess
from pathlib import PurePosixPath
p=argparse.ArgumentParser();p.add_argument('--staged',action='store_true');a=p.parse_args()
args=['git','ls-files','-z'] if a.staged else ['git','ls-tree','-r','--name-only','-z','HEAD']
paths=[s for s in subprocess.check_output(args).decode().split('\0') if s]
allowed_roots={'.github','macos','scripts','shared','assets'}
allowed_files={'.gitignore','README.md','LICENSE'}
allowed_md={'README.md','macos/README.md','shared/branding/README.md','shared/contracts/v1/README.md'}
patterns={
 'private local path':r'/(?:Users|home)/[A-Za-z0-9_.-]+/',
 'session identifier':r'01a[0-9a-f]{5}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
 'credential material':r'(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY)',
}
problems=[]
for s in paths:
 path=PurePosixPath(s)
 if path.parts[0] not in allowed_roots and s not in allowed_files:problems.append((s,'not in public allowlist'))
 if path.suffix=='.md' and s not in allowed_md:problems.append((s,'unreviewed document'))
 if path.suffix.lower() in {'.zip','.dmg','.db','.sqlite','.log','.pem','.key','.p12','.pfx'}:problems.append((s,'private/build data type'))
 content=subprocess.check_output(['git','show',(':'+s) if a.staged else ('HEAD:'+s)])
 if path.suffix.lower() in {'.png','.jpg','.jpeg','.icns','.ico'}:continue # Require separate visual review for images.
 try:text=content.decode('utf-8')
 except UnicodeDecodeError:problems.append((s,'unexpected binary'));continue
 for label,pattern in patterns.items():
  if re.search(pattern,text):problems.append((s,label))
for s,label in problems:print(f'REJECT {s}: {label}')
if problems:raise SystemExit(1)
print(f'PASS {len(paths)} public files: allowlist, document boundary, local paths, session identifiers, credential patterns. Images still require visual review; pattern checks do not prove absence of all sensitive data.')
