#!/usr/bin/env python3
"""Read-only distribution preflight. Never installs, registers extensions, or changes security policy."""
from pathlib import Path
import argparse, hashlib, json, plistlib, subprocess
p=argparse.ArgumentParser()
p.add_argument('--app',type=Path,required=True)
p.add_argument('--dmg',type=Path)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args()
results=[]
def assess(name,argv):
    try:
        r=subprocess.run([str(x) for x in argv],capture_output=True,text=True,timeout=60)
        result={'check':name,'passed':r.returncode==0,'exitCode':r.returncode,'details':(r.stdout+r.stderr).strip()[-4000:]}
    except (OSError,subprocess.TimeoutExpired) as error:
        result={'check':name,'passed':False,'error':type(error).__name__}
    results.append(result)
try:
    info=plistlib.loads((a.app/'Contents/Info.plist').read_bytes())
    identity=info.get('CFBundleIdentifier')=='com.rouice.wechatport'
except Exception:
    info={};identity=False
results.append({'check':'product_identity','passed':identity})
assess('bundle_signature',['codesign','--verify','--deep','--strict',a.app])
assess('gatekeeper_execute',['spctl','--assess','--type','execute','--verbose=4',a.app])
assess('app_stapled_ticket',['xcrun','stapler','validate',a.app])
if a.dmg:
    assess('dmg_checksum',['hdiutil','verify',a.dmg])
    assess('dmg_gatekeeper',['spctl','--assess','--type','open','--context','context:primary-signature','--verbose=4',a.dmg])
    assess('dmg_stapled_ticket',['xcrun','stapler','validate',a.dmg])
passed=all(r['passed'] for r in results)
record={'technicalPreflightPassed':passed,'formalAcceptance':'not_proven',
        'version':info.get('CFBundleShortVersionString'),'build':info.get('CFBundleVersion'),
        'dmgSHA256':hashlib.sha256(a.dmg.read_bytes()).hexdigest() if a.dmg and a.dmg.is_file() else None,
        'checks':results,'notProven':['clean-user installation/first launch','automatic OS registration without development install scripts','user-enabled share entry','real WeChat cold/hot/multi-batch share','model configuration/real generation/save/restart on clean Mac','Intel/minimum macOS runtime','user acceptance']}
a.output.parent.mkdir(parents=True,exist_ok=True)
a.output.write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'technicalPreflightPassed':passed,'formalAcceptance':'not_proven','checks':[{'check':r['check'],'passed':r['passed']} for r in results],'record':str(a.output)},ensure_ascii=False))
raise SystemExit(0 if passed else 1)
