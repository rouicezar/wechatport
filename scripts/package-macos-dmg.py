#!/usr/bin/env python3
"""Package already-built signed local bundles; never publish, install, or touch chat data."""
from pathlib import Path
import argparse, hashlib, json, plistlib, shutil, subprocess, uuid
ROOT = Path(__file__).resolve().parents[1]
VERSION = json.loads((ROOT/'shared/version.json').read_text())
p = argparse.ArgumentParser()
p.add_argument('--identity', required=True, help='Local certificate identity, never a private key')
a = p.parse_args()
def run(*args):
    return subprocess.check_output([str(x) for x in args], stderr=subprocess.STDOUT)
def verify(app):
    run('codesign', '--verify', '--deep', '--strict',
        '-R=anchor apple generic and identifier "com.rouice.wechatport" and certificate leaf[subject.OU] = "625QHA2P78"', app)
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    assert (info['CFBundleShortVersionString'],info['CFBundleVersion'],info['WeChatPortReleaseLabel']) == (VERSION['version'],VERSION['build'],VERSION['label'])
    return info
sources = [ROOT/f'run-output/p1-02/{arch}/WeChatPort.app' for arch in ('arm64','x86_64')]
assert verify(sources[0]) == verify(sources[1])
out = ROOT/'run-output/releases'/('Beta1.0-build'+VERSION['build']+'-'+str(uuid.uuid4())[:8])
stage = out/'image'; stage.mkdir(parents=True)
app = stage/'WeChatPort.app'
shutil.copytree(sources[0],app,symlinks=True)
for relative in ('Contents/MacOS/WeChatPort','Contents/PlugIns/WeChatPortShare.appex/Contents/MacOS/WeChatPortShare'):
    run('lipo','-create',*(source/relative for source in sources),'-output',app/relative)
    assert set(run('lipo','-archs',app/relative).decode().split()) == {'arm64','x86_64'}
ext = app/'Contents/PlugIns/WeChatPortShare.appex'
run('codesign','--force','--sign',a.identity,'--entitlements',ROOT/'run-output/p1-02/local.entitlements',ext)
run('codesign','--force','--sign',a.identity,'--entitlements',ROOT/'run-output/p1-02/host.entitlements',app)
verify(app)
(stage/'Applications').symlink_to('/Applications',target_is_directory=True)
shutil.copy2(ROOT/'LICENSE',stage/'LICENSE.txt')
(stage/'安装说明.txt').write_text('''WeChatPort Beta 1.0（个人非商业使用）

将 WeChatPort.app 拖到 Applications 或本人的 Applications 文件夹。
已有版本请先退出 WeChatPort，再替换；不需要退出或操作微信。
首次使用由你手动选择工作空间。应用只处理主动分享/导入的文件。

兼容目标：macOS 14及以上，包含Apple Silicon与Intel二进制。
当前只在Apple Silicon开发机器运行验证，Intel和最低系统待验。
本包为Apple Development开发签名，未经Developer ID签名/公证，
不能视为面向其他Mac的正式分发包；若系统不允许打开，请保留提示，
不要关闭系统保护。本机开发安装可用不保证其他设备能打开。

仅限个人非商业使用，不得商用或擅自再分发，详见LICENSE.txt。
Windows、真实微信完整冷热/连续分享及用户质量验收仍待完成。
''')
dmg = out/('WeChatPort-Beta1.0-macOS-universal.dmg')
run('hdiutil','create','-srcfolder',stage,'-volname','WeChatPort Beta 1.0','-format','UDZO','-fs','HFS+',dmg)
run('hdiutil','verify',dmg)
mount = out/'mounted'; mount.mkdir()
run('hdiutil','attach','-readonly','-nobrowse','-noautoopen','-mountpoint',mount,dmg)
try:
    verify(mount/'WeChatPort.app')
    for source in app.rglob('*'):
        if source.is_file() and not source.is_symlink():
            assert hashlib.sha256(source.read_bytes()).digest() == hashlib.sha256((mount/'WeChatPort.app'/source.relative_to(app)).read_bytes()).digest()
    assert (mount/'LICENSE.txt').read_bytes() == (ROOT/'LICENSE').read_bytes()
    assert (mount/'Applications').is_symlink()
finally:
    run('hdiutil','detach',mount)
record = {'dmg':str(dmg),'app':str(app),'version':VERSION,'sha256':hashlib.sha256(dmg.read_bytes()).hexdigest(),
          'architectures':['arm64','x86_64'],'verified':['hdiutil checksum','readonly mount','every app file byte hash','Apple Team/main+extension signature','embedded personal noncommercial license'],
          'not_proven':['Developer ID/notarization','Intel/macOS14 runtime','WeChat E2E','user acceptance'],'published':False}
(out/'verification.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(record,ensure_ascii=False,indent=2))
