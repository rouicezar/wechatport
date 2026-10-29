#!/usr/bin/env python3
"""Production scheduler + SQLite with in-process transport fixtures; no real key/network."""
from pathlib import Path
import subprocess,uuid
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'run-output/mac-app';OUT.mkdir(parents=True,exist_ok=True)
names=['Workspace','ArchiveStore','ChatParser','PendingInbox','ModelService','Briefs','MarkdownWriter','GenerationProbe']
r=subprocess.run(['xcrun','swiftc','-parse-as-library']+[f'macos/Sources/{n}.swift' for n in names]+['macos/ShareExtension/InboxStore.swift','-o',str(OUT/'generation-probe')],cwd=ROOT,capture_output=True,text=True)
(OUT/'generation-build.log').write_text(r.stdout+r.stderr)
if r.returncode:raise SystemExit('Compile failed: run-output/mac-app/generation-build.log')
r=subprocess.run([str(OUT/'generation-probe'),str(OUT/('generation-'+str(uuid.uuid4())))],cwd=ROOT,capture_output=True,text=True,timeout=45)
(OUT/'generation-test.log').write_text(r.stdout+r.stderr)
print(r.stdout if r.returncode==0 else 'Failed: run-output/mac-app/generation-test.log')
raise SystemExit(r.returncode)
