#!/usr/bin/env python3
"""Verify current built icon resources/signatures and system-resolved own product icons.
No rebuild, process mutation, private input or WeChat access.
"""
from pathlib import Path
import hashlib,json,plistlib,subprocess
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'run-output/icons';OUT.mkdir(parents=True,exist_ok=True)
def run(*args):return subprocess.check_output([str(x) for x in args],text=True,stderr=subprocess.STDOUT)
records={}
for arch in ('arm64','x86_64'):
 app=ROOT/f'run-output/p1-02/{arch}/WeChatPort.app';ext=app/'Contents/PlugIns/WeChatPortShare.appex'
 run('codesign','--verify','--deep','--strict',app)
 for bundle in (app,ext):
  info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes());assert info['CFBundleVersion']=='7'
  assert info['CFBundleIconFile']=='AppIcon' and info['CFBundleIconName']=='AppIcon'
  assets=bundle/'Contents/Resources/Assets.car'
  assert assets.stat().st_size>0
  records[str(assets.relative_to(ROOT))]=hashlib.sha256(assets.read_bytes()).hexdigest()
  for name in ('AppIcon.icns','ShareMark.png','ShareMark@2x.png'):
   p=bundle/'Contents/Resources'/name;assert p.read_bytes()==((app.parent/'icon-catalog'/name) if name=='AppIcon.icns' else (ROOT/'macos/Resources'/name)).read_bytes()
   records[str(p.relative_to(ROOT))]=hashlib.sha256(p.read_bytes()).hexdigest()
 # Permission boundary remains just the same sandbox + App Group.
 ent=run('codesign','-d','--entitlements',':-',app)
 plist=ent[ent.index('<?xml'):];e=plistlib.loads(plist.encode())
 assert e=={'com.apple.security.app-sandbox':True,'com.apple.security.application-groups':['625QHA2P78.com.rouice.wechatport']}
installed=Path.home()/'Applications/WeChatPort.app'
run('codesign','--verify','--deep','--strict',installed)
run('xcrun','swiftc',ROOT/'scripts/product-registration.swift','-o',OUT/'product-registration')
assert json.loads(run(OUT/'product-registration'))==[str(installed)]
registration=run('pluginkit','-m','-v','-i','com.rouice.wechatport.share')
assert str(installed/'Contents/PlugIns/WeChatPortShare.appex') in registration
assert str(ROOT/'run-output/p1-02') not in registration
source=ROOT/'run-output/p1-02/arm64/WeChatPort.app'
for file in source.rglob('*'):
 if file.is_file():assert file.read_bytes()==(installed/file.relative_to(source)).read_bytes()
run('xcrun','swiftc',ROOT/'scripts/inspect-macos-icons.swift','-o',OUT/'inspect')
sample=OUT/'icon-enumeration.txt';sample.write_text('WeChatPort synthetic icon enumeration\n')
result=run(OUT/'inspect',installed,ROOT/'evidence/P1-06/macos/icons',sample)
assert 'service_count=1' in result
(OUT/'verification.json').write_text(json.dumps({'result':'PASS','resources':records,'system':result,'scope':'current dual signed bundles; ARM64 own app/service icon resolution; not WeChat menu or Windows or user acceptance'},indent=2)+'\n')
print('PASS: build7 installed + dual signed icon resources, unchanged entitlements, ARM64 own app/share icon resolution; not WeChat/Windows acceptance')
