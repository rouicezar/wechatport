#!/usr/bin/env python3
"""Isolated synthetic workspace and archive verification; never reads real batches."""
from pathlib import Path
import subprocess, uuid, json
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'run-output/mac-app';OUT.mkdir(parents=True,exist_ok=True)
args=['xcrun','swiftc','-parse-as-library','macos/Sources/Workspace.swift','macos/Sources/ArchiveStore.swift','macos/Sources/ChatParser.swift','macos/Sources/ModelService.swift','macos/Sources/Briefs.swift','macos/Sources/MarkdownWriter.swift','macos/Sources/PendingInbox.swift','macos/ShareExtension/InboxStore.swift','macos/Sources/WorkspaceProbe.swift','-o',str(OUT/'workspace-probe')]
r=subprocess.run(args,cwd=ROOT,capture_output=True,text=True)
(OUT/'workspace-build.log').write_text(r.stdout+r.stderr)
if r.returncode: raise SystemExit('Compile failed: run-output/mac-app/workspace-build.log')
base=OUT/('test-'+str(uuid.uuid4()));base.mkdir()
r=subprocess.run([str(OUT/'workspace-probe'),str(base)],cwd=ROOT,capture_output=True,text=True)
(OUT/'workspace-test.log').write_text(r.stdout+r.stderr)
(OUT/'workspace-result.json').write_text(json.dumps({'exit_code':r.returncode,'scope':'isolated synthetic Swift production workspace/SQLite/archive; no UI, WeChat or user acceptance'},indent=2))
print(r.stdout if r.returncode==0 else 'Failed: run-output/mac-app/workspace-test.log')
raise SystemExit(r.returncode)
