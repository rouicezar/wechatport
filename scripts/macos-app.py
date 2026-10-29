#!/usr/bin/env python3
"""Local unsigned development bundle. No installation, network or WeChat access."""
import argparse
import json
import os
import shutil
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'run-output' / 'p1-01'
VERSION = json.loads((ROOT/'shared/version.json').read_text())
SOURCE = ROOT / 'macos' / 'Sources' / 'WeChatPortApp.swift'

def build(arch, source=SOURCE, suffix=''):
    app = OUT / (arch + suffix) / 'WeChatPort.app'
    binary = app / 'Contents' / 'MacOS' / 'WeChatPort'
    binary.parent.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    cmd = ['xcrun', 'swiftc', '-parse-as-library', str(source), str(ROOT/'macos/Sources/PendingInbox.swift'), str(ROOT/'macos/Sources/Workspace.swift'), str(ROOT/'macos/Sources/ArchiveStore.swift'), str(ROOT/'macos/Sources/ChatParser.swift'), str(ROOT/'macos/Sources/ModelService.swift'), str(ROOT/'macos/Sources/Briefs.swift'), str(ROOT/'macos/Sources/MarkdownWriter.swift'), str(ROOT/'macos/Sources/BriefView.swift'), str(ROOT/'macos/Sources/GroupPreferences.swift'), str(ROOT/'macos/Sources/AppBehavior.swift'), str(ROOT/'macos/Sources/AppUpdates.swift'), str(ROOT/'macos/ShareExtension/InboxStore.swift'), '-sdk', sdk,
           '-target', arch + '-apple-macosx14.0', '-o', str(binary)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    (app.parent / 'build.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        print('build_failed: see ' + str(app.parent / 'build.log'), file=sys.stderr)
        print(result.stdout + result.stderr, file=sys.stderr)
        return result.returncode
    resources = app/'Contents/Resources'
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT/'macos/Resources/AppIcon.icns', resources/'AppIcon.icns')
    shutil.copy2(ROOT/'LICENSE', resources/'LICENSE.txt')
    subprocess.run(['xcrun','actool',str(ROOT/'macos/Resources/Assets.xcassets'),'--compile',str(resources),
                    '--platform','macosx','--minimum-deployment-target','14.0','--app-icon','AppIcon',
                    '--output-partial-info-plist',str(app.parent/'icon-info.plist')],check=True)
    with (app / 'Contents' / 'Info.plist').open('wb') as f:
        plistlib.dump(dict(CFBundleExecutable='WeChatPort', CFBundleIdentifier='com.rouice.wechatport',
            CFBundleName='WeChatPort', CFBundleDisplayName='WeChatPort', CFBundlePackageType='APPL',
            CFBundleShortVersionString=VERSION['version'], CFBundleVersion=VERSION['build'], WeChatPortReleaseLabel=VERSION['label'], LSMinimumSystemVersion='14.0',
            NSHighResolutionCapable=True, CFBundleIconFile='AppIcon.icns', CFBundleIconName='AppIcon'), f)
    print(app)
    return 0

def launch():
    binary = OUT / 'arm64/WeChatPort.app/Contents/MacOS/WeChatPort'
    if not binary.exists():
        raise SystemExit('Build arm64 first')
    # Keep exact child PID; never enumerate other applications or processes.
    with (OUT / 'app.log').open('a') as log:
        child = subprocess.Popen([str(binary)], stdout=log, stderr=log, start_new_session=True)
    (OUT / 'pid.json').write_text(json.dumps({'pid': child.pid, 'binary': str(binary)}))
    time.sleep(2)
    if child.poll() is not None:
        raise SystemExit('App exited before startup observation')
    print('started pid=' + str(child.pid))

def stop():
    # NSRunningApplication resolves only the previously launched PID, checks bundle URL,
    # and requests normal termination. It never reads global app/window inventory.
    state = json.loads((OUT / 'pid.json').read_text())
    helper = '''import AppKit
let pid = pid_t(CommandLine.arguments[1])!
let expected = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
 guard let app = NSRunningApplication(processIdentifier: pid) else { exit(0) }
 guard app.bundleURL?.standardizedFileURL == expected else { exit(3) }
 guard app.terminate() else { exit(4) }
for _ in 0..<50 { if app.isTerminated { print("terminated"); exit(0) }; RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
exit(5)
'''
    with tempfile.TemporaryDirectory(prefix='wechatport-stop-') as d:
        src = Path(d) / 'stop.swift'
        src.write_text(helper)
        subprocess.run(['xcrun', 'swiftc', str(src), '-o', str(Path(d) / 'stop')], check=True)
        subprocess.run([str(Path(d) / 'stop'), str(state['pid']), str(Path(state['binary']).parents[2])], check=True)

def verify_build():
    for arch in ('arm64', 'x86_64'):
        if build(arch): return 1
    # Mutate a private copy of the current native source; original source remains intact.
    with tempfile.TemporaryDirectory(prefix='wechatport-invalid-') as d:
        bad = Path(d) / 'WeChatPortApp.swift'
        bad.write_text(SOURCE.read_text() + '\n#error("P1-01 expected compiler failure")\n')
        if build('arm64', bad, '-expected-failure') == 0:
            raise SystemExit('Expected invalid source to fail')
    log = (OUT / 'arm64-expected-failure/build.log').read_text()
    assert 'P1-01 expected compiler failure' in log
    print('arm64/x86_64 builds passed; invalid-source diagnostic confirmed')
    return 0

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['build', 'launch', 'stop', 'verify-build'])
    parser.add_argument('--arch', choices=['arm64', 'x86_64'], default='arm64')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.action == 'build': sys.exit(build(args.arch))
    elif args.action == 'launch': launch()
    elif args.action == 'stop': stop()
    else: sys.exit(verify_build())
