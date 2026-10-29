#!/usr/bin/env python3
"""Install only this signed product locally. Preserve previous app; never touch user data or WeChat."""
from pathlib import Path
import argparse,datetime,json,os,plistlib,shutil,signal,subprocess,uuid
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--source',type=Path,default=ROOT/'run-output/p1-02/arm64/WeChatPort.app')
SOURCE=parser.parse_args().source.resolve()
DEST=Path.home()/'Applications/WeChatPort.app'
LS='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
def run(*args):return subprocess.check_output([str(x) for x in args],text=True,stderr=subprocess.STDOUT)
info=plistlib.loads((SOURCE/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='com.rouice.wechatport'
assert info['WeChatPortAppGroup']=='625QHA2P78.com.rouice.wechatport'
run('codesign','--verify','--deep','--strict','-R=anchor apple generic and identifier \"com.rouice.wechatport\" and certificate leaf[subject.OU] = \"625QHA2P78\"',SOURCE)
run('codesign','--verify','--deep','--strict',SOURCE)
if DEST.exists():
 assert not DEST.is_symlink()
 assert plistlib.loads((DEST/'Contents/Info.plist').read_bytes())['CFBundleIdentifier']==info['CFBundleIdentifier']
# Exact product name and verified executable paths only; no global process inventory.
r=subprocess.run(['pgrep','-x','WeChatPort'],text=True,capture_output=True)
allowed={str(SOURCE/'Contents/MacOS/WeChatPort'),str(DEST/'Contents/MacOS/WeChatPort')}
for token in r.stdout.split():
 pid=int(token);exe=run('ps','-p',pid,'-o','comm=').strip()
 if str(Path(exe).absolute()) in allowed:os.kill(pid,signal.SIGTERM)
OUT=ROOT/'run-output/icons';OUT.mkdir(parents=True,exist_ok=True)
run('xcrun','swiftc',ROOT/'scripts/product-registration.swift','-o',OUT/'product-registration')
registered=json.loads(run(OUT/'product-registration'))
DEST.parent.mkdir(parents=True,exist_ok=True)
staging=DEST.parent/('.WeChatPort.install-'+str(uuid.uuid4()))
shutil.copytree(SOURCE,staging,symlinks=True)
run('codesign','--verify','--deep','--strict',staging)
backup=None
if DEST.exists():
 folder=ROOT/'run-output/install-backups';folder.mkdir(parents=True,exist_ok=True)
 backup=folder/('WeChatPort-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+str(uuid.uuid4())+'.app')
 os.rename(DEST,backup)
try:os.rename(staging,DEST)
except Exception:
 if backup is not None:os.rename(backup,DEST)
 raise
# Avoid registering the same identity from build and installed locations.
for legacy in (ROOT/'run-output/p1-01/arm64/WeChatPort.app',SOURCE,ROOT/'run-output/p1-02/x86_64/WeChatPort.app'):
 if legacy.exists():
  if str(legacy) in registered:run(LS,'-u',legacy)
  ext=legacy/'Contents/PlugIns/WeChatPortShare.appex'
  if ext.exists():
   subprocess.run(['pluginkit','-r',str(ext)],check=False,capture_output=True)
run(LS,'-f',DEST)
run('pluginkit','-a',DEST/'Contents/PlugIns/WeChatPortShare.appex')
run('codesign','--verify','--deep','--strict',DEST)
registered_after=json.loads(run(OUT/'product-registration'))
assert registered_after==[str(DEST)], registered_after
record={'installed':str(DEST),'build':info['CFBundleVersion'],'backup':str(backup) if backup else None,'registered_main_paths':registered_after,'data':'no App Group/Inbox migration, access or deletion','registration':run('pluginkit','-m','-v','-i','com.rouice.wechatport.share')}
OUT=ROOT/'run-output/icons';OUT.mkdir(parents=True,exist_ok=True);(OUT/('installed-build'+info['CFBundleVersion']+'.json')).write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n');print(json.dumps(record,ensure_ascii=False,indent=2))
