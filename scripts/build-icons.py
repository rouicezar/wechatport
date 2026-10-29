#!/usr/bin/env python3
"""Render project-owned SVGs with AppKit and iconutil; no network or application access."""
from pathlib import Path
import subprocess,json,shutil
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'run-output/icons'
RES=ROOT/'macos/Resources'
OUT.mkdir(parents=True,exist_ok=True);RES.mkdir(parents=True,exist_ok=True)
render=OUT/'render'
subprocess.run(['xcrun','swiftc',str(ROOT/'scripts/render-icon.swift'),'-o',str(render)],check=True)
def png(source,target,size):
    subprocess.run([str(render),str(ROOT/source),str(target),str(size)],check=True)
iconset=OUT/'AppIcon.iconset';iconset.mkdir(exist_ok=True)
for size in (16,32,128,256,512):
    for scale in (1,2):
        suffix='@2x' if scale==2 else ''
        png('shared/branding/wechatport-app.svg',iconset/f'icon_{size}x{size}{suffix}.png',size*scale)
subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(RES/'AppIcon.icns')],check=True)
png('shared/branding/wechatport-app.svg',RES/'AppIcon.png',1024)
for scale in (1,2):
    suffix='@2x' if scale==2 else ''
    png('shared/branding/wechatport-mark.svg',RES/f'ShareMark{suffix}.png',32*scale)
print('Rendered AppIcon.icns, AppIcon.png, ShareMark.png and ShareMark@2x.png')

assets=RES/'Assets.xcassets/AppIcon.appiconset';assets.mkdir(parents=True,exist_ok=True)
images=[]
for size in (16,32,128,256,512):
    for scale in (1,2):
        suffix='@2x' if scale==2 else ''
        name=f'icon_{size}x{size}{suffix}.png'
        shutil.copy2(iconset/name,assets/name)
        images.append({'idiom':'mac','size':f'{size}x{size}','scale':f'{scale}x','filename':name})
(assets/'Contents.json').write_text(json.dumps({'images':images,'info':{'version':1,'author':'wechatport'}},indent=2)+'\n')
(assets.parent/'Contents.json').write_text(json.dumps({'info':{'version':1,'author':'wechatport'}},indent=2)+'\n')
