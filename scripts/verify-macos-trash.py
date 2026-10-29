#!/usr/bin/env python3
"""Isolated reversible-delete tests using production Swift store/models; no real chat."""
from pathlib import Path
import subprocess,uuid
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'run-output/mac-app';OUT.mkdir(exist_ok=True,parents=True)
sources=['Workspace','ArchiveStore','ChatParser','PendingInbox','ModelService','Briefs','MarkdownWriter','TrashProbe']
args=['xcrun','swiftc','-parse-as-library']+[f'macos/Sources/{s}.swift' for s in sources]+['macos/ShareExtension/InboxStore.swift','-o',str(OUT/'trash-probe')]
r=subprocess.run(args,cwd=ROOT,capture_output=True,text=True);(OUT/'trash-build.log').write_text(r.stdout+r.stderr)
if r.returncode:raise SystemExit('Compile failed: run-output/mac-app/trash-build.log')
r=subprocess.run([str(OUT/'trash-probe'),str(OUT/('trash-'+str(uuid.uuid4())))],cwd=ROOT,capture_output=True,text=True)
(OUT/'trash-test.log').write_text(r.stdout+r.stderr)
print(r.stdout if r.returncode==0 else 'Failed: run-output/mac-app/trash-test.log');raise SystemExit(r.returncode)
