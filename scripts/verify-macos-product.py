#!/usr/bin/env python3
"""Reviewed local-test suite: isolated synthetic files and HTTP fixtures only."""
from pathlib import Path
import subprocess, argparse
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--signed-update',action='store_true');args=parser.parse_args()
scripts=['verify-macos-workspace.py','verify-macos-business.py','verify-macos-model.py','verify-macos-generation.py','verify-macos-pending.py','verify-macos-trash.py']
if args.signed_update:scripts.append('verify-macos-update.py')
for script in scripts:
 subprocess.run(['python3',str(ROOT/'scripts'/script)],cwd=ROOT,check=True)
print('PASS isolated Mac product suite; real installed app flow is recorded separately')
