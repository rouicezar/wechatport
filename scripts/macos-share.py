#!/usr/bin/env python3
"""Isolated local signed bundles; no account mutation, upload or WeChat access."""
import argparse, os, pathlib, plistlib, subprocess, shutil, json
ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'run-output/p1-02'
VERSION = json.loads((ROOT/'shared/version.json').read_text())

def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True)

def build(arch, identity):
    app = OUT / arch / 'WeChatPort.app'
    ext = app / 'Contents/PlugIns/WeChatPortShare.appex'
    for bundle in (app, ext):
        (bundle / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    for bundle in (app, ext):
        resources = bundle / 'Contents/Resources'
        resources.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT/'LICENSE', resources/'LICENSE.txt')
        for name in ('AppIcon.icns', 'ShareMark.png', 'ShareMark@2x.png'):
            shutil.copy2(ROOT/'macos/Resources'/name, resources/name)
    catalog = app.parent/'icon-catalog'
    catalog.mkdir(parents=True, exist_ok=True)
    run('xcrun', 'actool', str(ROOT/'macos/Resources/Assets.xcassets'), '--compile', str(catalog),
        '--platform', 'macosx', '--minimum-deployment-target', '14.0', '--app-icon', 'AppIcon',
        '--output-partial-info-plist', str(catalog/'icon-info.plist'))
    for bundle in (app, ext):
        for name in ('Assets.car', 'AppIcon.icns'):
            shutil.copy2(catalog/name, bundle/'Contents/Resources'/name)
    sdk = run('xcrun', '--sdk', 'macosx', '--show-sdk-path').strip()
    run('xcrun', 'swiftc', '-parse-as-library', str(ROOT/'macos/Sources/WeChatPortApp.swift'), str(ROOT/'macos/Sources/PendingInbox.swift'), str(ROOT/'macos/Sources/Workspace.swift'), str(ROOT/'macos/Sources/ArchiveStore.swift'), str(ROOT/'macos/Sources/ChatParser.swift'), str(ROOT/'macos/Sources/ModelService.swift'), str(ROOT/'macos/Sources/Briefs.swift'), str(ROOT/'macos/Sources/MarkdownWriter.swift'), str(ROOT/'macos/Sources/BriefView.swift'), str(ROOT/'macos/Sources/GroupPreferences.swift'), str(ROOT/'macos/Sources/AppBehavior.swift'), str(ROOT/'macos/Sources/AppUpdates.swift'), str(ROOT/'macos/ShareExtension/InboxStore.swift'), '-sdk', sdk,
        '-target', arch+'-apple-macosx14.0', '-o', str(app/'Contents/MacOS/WeChatPort'))
    run('xcrun', 'swiftc', '-parse-as-library', '-emit-executable', '-Xlinker', '-e', '-Xlinker', '_NSExtensionMain', '-application-extension', str(ROOT/'macos/ShareExtension/ShareViewController.swift'),
        str(ROOT/'macos/ShareExtension/InboxStore.swift'), str(ROOT/'macos/Sources/PendingInbox.swift'), '-module-name', 'WeChatPortShare', '-sdk', sdk, '-target', arch+'-apple-macosx14.0',
        '-o', str(ext/'Contents/MacOS/WeChatPortShare'))
    icon_info = plistlib.loads((catalog/'icon-info.plist').read_bytes())
    base = dict(CFBundleShortVersionString=VERSION['version'], CFBundleVersion=VERSION['build'], WeChatPortReleaseLabel=VERSION['label'], LSMinimumSystemVersion='14.0',
                CFBundleInfoDictionaryVersion='6.0', CFBundleDevelopmentRegion='zh-Hans', **icon_info)
    host = dict(base, CFBundleExecutable='WeChatPort', CFBundleIdentifier='com.rouice.wechatport',
        CFBundleName='WeChatPort', CFBundleDisplayName='WeChatPort', CFBundlePackageType='APPL', NSHighResolutionCapable=True)
    share = dict(base, CFBundleExecutable='WeChatPortShare', CFBundleIdentifier='com.rouice.wechatport.share',
        CFBundleName='收集到 WeChatPort', CFBundleDisplayName='收集到 WeChatPort', CFBundlePackageType='XPC!',
        NSExtension=dict(NSExtensionPointIdentifier='com.apple.share-services',
            NSExtensionPrincipalClass='ShareViewController',
            NSExtensionAttributes=dict(NSExtensionActivationRule=
                'SUBQUERY(extensionItems, $item, SUBQUERY($item.attachments, $attachment, ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.file-url" OR ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.zip-archive").@count == $item.attachments.@count AND $item.attachments.@count > 0).@count == extensionItems.@count AND extensionItems.@count > 0')))
    for bundle, info in ((app,host),(ext,share)):
        with (bundle/'Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
    # Obtain actual TeamIdentifier from a signature, never infer from certificate display suffix.
    run('codesign','--force','--sign',identity,str(ext))
    details=run('codesign','-d','--verbose=4',str(ext))
    team=next(x.split('=',1)[1] for x in details.splitlines() if x.startswith('TeamIdentifier='))
    if not team or team == 'not set': raise RuntimeError('No actual signing TeamIdentifier')
    group=team+'.com.rouice.wechatport'
    host['WeChatPortAppGroup']=group
    share['WeChatPortAppGroup']=group
    with (ext/'Contents/Info.plist').open('wb') as f: plistlib.dump(share,f)
    with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(host,f)
    ent=dict({'com.apple.security.app-sandbox':True, 'com.apple.security.application-groups':[group]})
    entitlement=OUT/'local.entitlements'
    with entitlement.open('wb') as f: plistlib.dump(ent,f)
    host_ent = OUT/'host.entitlements'
    with host_ent.open('wb') as f: plistlib.dump(dict(ent, **{'com.apple.security.files.user-selected.read-write':True, 'com.apple.security.files.bookmarks.app-scope':True, 'com.apple.security.network.client':True}), f)
    for bundle in (ext,app):
        selected_entitlement = host_ent if bundle == app else entitlement
        run('codesign','--force','--sign',identity,'--entitlements',str(selected_entitlement),str(bundle))
        run('codesign','--verify','--strict',str(bundle))
    (app.parent/'signing.txt').write_text(run('codesign','-d','--verbose=4',str(app)))
    (app.parent/'group.txt').write_text(group+'\n')
    print(app)
    return app

if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--arch',choices=['arm64','x86_64'],default='arm64')
    p.add_argument('--identity',required=True,help='Local development certificate SHA-1; never a private key')
    a=p.parse_args(); OUT.mkdir(parents=True,exist_ok=True)
    try: build(a.arch,a.identity)
    except subprocess.CalledProcessError as e:
        print(e.output); raise SystemExit(e.returncode)
