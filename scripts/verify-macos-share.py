#!/usr/bin/env python3
"""Rebuild and verify isolated signed local extension. Registration is explicit and local."""
import argparse, hashlib, json, pathlib, plistlib, subprocess, zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
OUT=ROOT/'run-output/p1-02'
p=argparse.ArgumentParser();p.add_argument('--identity',required=True);a=p.parse_args()
def run(*args):
    r=subprocess.run(args,cwd=ROOT,text=True,capture_output=True)
    if r.returncode: raise RuntimeError(f'{args[0]} exit={r.returncode}: {r.stdout}{r.stderr}')
    return r.stdout+r.stderr
for arch in ('arm64','x86_64'):
    run('python3','scripts/macos-share.py','--arch',arch,'--identity',a.identity)
    app=OUT/arch/'WeChatPort.app'
    run('codesign','--verify','--deep','--strict',str(app))
app=OUT/'arm64/WeChatPort.app'; ext=app/'Contents/PlugIns/WeChatPortShare.appex'
assert 'group_probe_pass' in run(str(app/'Contents/MacOS/WeChatPort'),'--probe-group')
run('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-f',str(app))
run('pluginkit','-a',str(ext));run('pluginkit','-e','use','-i','com.rouice.wechatport.share')
plugins=run('pluginkit','-m','-v','-i','com.rouice.wechatport.share')
assert str(ext) in plugins
(OUT/'registration.txt').write_text(plugins)
run('xcrun','swiftc','macos/ShareExtension/EnumerationProbe.swift','-o',str(OUT/'enumerate'))
(OUT/'synthetic.txt').write_text('WeChatPort synthetic data\n')
with zipfile.ZipFile(OUT/'synthetic.zip','w') as z:z.writestr('synthetic.txt','Synthetic data')
for file in ('synthetic.txt','synthetic.zip'):
    assert 'matching_services=1' in run(str(OUT/'enumerate'),str(OUT/file))
assert 'matching_services=0' in run(str(OUT/'enumerate'),'--text')
# Wrong signing identity must fail without changing final arm64/x86_64 bundles.
r=subprocess.run(['codesign','--dryrun','--sign','WeChatPort-INTENTIONALLY-MISSING',str(ext)],capture_output=True,text=True)
assert r.returncode != 0 and 'no identity found' in (r.stdout+r.stderr)
hashes={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in app.rglob('*') if f.is_file()}
(OUT/'hashes.json').write_text(json.dumps(hashes,indent=2))
print('PASS: both signed builds; arm64 sandbox group read/write; plugin registration; TXT/ZIP enumerate; plain text rejected; missing signing identity rejected. No product receive/E2E/CI/release acceptance.')
