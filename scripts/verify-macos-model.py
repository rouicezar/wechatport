#!/usr/bin/env python3
"""URLProtocol fixtures and UUID-scoped synthetic Keychain lifecycle; no network or user credential access."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'run-output/mac-app';OUT.mkdir(parents=True,exist_ok=True)
r=subprocess.run(['xcrun','swiftc','-parse-as-library','macos/Sources/ModelService.swift','macos/Sources/ModelProbe.swift','-o',str(OUT/'model-probe')],cwd=ROOT,capture_output=True,text=True)
(OUT/'model-build.log').write_text(r.stdout+r.stderr)
if r.returncode:raise SystemExit('Compile failed: run-output/mac-app/model-build.log')
r=subprocess.run([str(OUT/'model-probe')],cwd=ROOT,capture_output=True,text=True,timeout=45)
(OUT/'model-test.log').write_text(r.stdout+r.stderr)
print(r.stdout if r.returncode==0 else 'Failed: run-output/mac-app/model-test.log')
raise SystemExit(r.returncode)
