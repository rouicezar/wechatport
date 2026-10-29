#!/usr/bin/env python3
"""Reviewed local-only P1-05 verification, synthetic data retained; no external apps."""
import argparse,pathlib,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1];OUT=ROOT/'run-output/p1-05';OUT.mkdir(parents=True,exist_ok=True)
p=argparse.ArgumentParser();p.add_argument('--identity',required=True);a=p.parse_args()
for name,args in [
 ('signed-build',['scripts/verify-macos-share.py','--identity',a.identity]),
 ('unsigned-build',['scripts/macos-app.py','verify-build']),
 ('receive-regression',['scripts/verify-macos-inbox.py']),
 ('pending-core',['scripts/verify-macos-pending.py']),
 ('pending-system',['scripts/verify-macos-pending-system.py'])]:
    r=subprocess.run(['python3',*args],cwd=ROOT,capture_output=True,text=True,timeout=120)
    (OUT/(name+'.log')).write_text(r.stdout+r.stderr)
    if r.returncode:raise SystemExit(f'FAIL: {name}; see local synthetic log')
print('PASS P1-05: signed/unsigned dual builds; receive regression; queue concurrency/crash/boundary/write failure; ARM64 main cold/hot synthetic system sharing/restart. No WeChat/Windows/CI/release/user acceptance.')
