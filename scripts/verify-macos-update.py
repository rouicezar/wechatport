#!/usr/bin/env python3
"""Isolated updater tests against already signed local bundles; never replaces installed app."""
from pathlib import Path
import json,subprocess,uuid
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'run-output/mac-app';OUT.mkdir(exist_ok=True,parents=True)
record=json.loads((OUT/'update-test-bundles.json').read_text())
sources=['AppUpdates','ChatParser','PendingInbox','UpdateProbe']
args=['xcrun','swiftc','-parse-as-library']+[str(ROOT/f'macos/Sources/{s}.swift') for s in sources]+[str(ROOT/'macos/ShareExtension/InboxStore.swift'),'-o',str(OUT/'update-probe')]
r=subprocess.run(args,cwd=ROOT,capture_output=True,text=True);(OUT/'update-build.log').write_text(r.stdout+r.stderr)
if r.returncode:raise SystemExit('Compile failed: run-output/mac-app/update-build.log')
r=subprocess.run([str(OUT/'update-probe'),record['new'],record['old'],str(OUT/('update-'+str(uuid.uuid4())))],cwd=ROOT,capture_output=True,text=True)
(OUT/'update-test.log').write_text(r.stdout+r.stderr)
print(r.stdout if r.returncode==0 else 'Failed: run-output/mac-app/update-test.log');raise SystemExit(r.returncode)
