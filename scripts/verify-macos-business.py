#!/usr/bin/env python3
"""Independent expected synthetic vectors for production Swift code. No real chat or network."""
from pathlib import Path
import json, subprocess, uuid, zipfile, stat, hashlib
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'run-output/mac-app';OUT.mkdir(parents=True,exist_ok=True)
base=OUT/('business-'+str(uuid.uuid4()));fixtures=base/'fixtures';fixtures.mkdir(parents=True)
text='2026-10-29 08:00:01 甲: 第一条\n续行\n2026-10-29 08:01 乙: 第二条\n2026-10-29 08:02:03 甲: 第三条'
with zipfile.ZipFile(fixtures/'valid.zip','w',zipfile.ZIP_DEFLATED) as z:z.writestr('records/chat.txt',text)
with zipfile.ZipFile(fixtures/'partial.zip','w',zipfile.ZIP_DEFLATED) as z:
 z.writestr('chat.txt',text);z.writestr('empty.txt','')
for name,entry,content in [('traversal.zip','../escape.txt','x'),('absolute.zip','/escape.txt','x'),('ratio.zip','bomb.txt','0'*2_000_000)]:
 with zipfile.ZipFile(fixtures/name,'w',zipfile.ZIP_DEFLATED) as z:z.writestr(entry,content)
with zipfile.ZipFile(fixtures/'link.zip','w') as z:
 i=zipfile.ZipInfo('link');i.create_system=3;i.external_attr=(stat.S_IFLNK|0o777)<<16;z.writestr(i,'/tmp')
b=bytearray((fixtures/'valid.zip').read_bytes());b[45]^=0xff;(fixtures/'corrupt.zip').write_bytes(b)
def message(i):return f'2026-10-29 {8+i//60:02}:{i%60:02}:00 甲: 消息{i}'
(fixtures/'a.txt').write_text('\n'.join(message(i) for i in range(100)))
(fixtures/'b.txt').write_text('\n'.join(message(i) for i in range(80,180)))
(fixtures/'native-a.txt').write_text('\n\n'.join(f'·甲\n2026年10月29日 {8+i//60:02}:{i%60:02}\n消息{i}' for i in range(100)))
(fixtures/'native-b.txt').write_text('\n\n'.join(f'·甲\n2026年10月29日 {8+i//60:02}:{i%60:02}\n消息{i}' for i in range(80,180)))
(fixtures/'minute-a.txt').write_text('·甲\n2026年10月29日 08:05\n复读')
(fixtures/'minute-b.txt').write_text('·甲\n2026年10月29日 08:05\n复读\n\n·甲\n2026年10月29日 08:05\n复读')
(fixtures/'repeat.txt').write_text(message(0)+'\n'+message(0))
vector={'z':'中文\n\t\x01/"\\','array':[True,False,None,42],'a':'🧭'}
expected=json.dumps(vector,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
(fixtures/'golden.json').write_text(json.dumps({'input':vector,'hash':hashlib.sha256(expected).hexdigest()},ensure_ascii=False))
with zipfile.ZipFile(fixtures/'large-media.zip','w',zipfile.ZIP_DEFLATED) as z:
 z.writestr('chat.txt','2026-10-29 08:00:00 甲: [视频] media/video.mp4\n2026-10-29 08:01:00 乙: [视频] media/video.mp4\n2026-10-29 08:02:00 乙: 这个视频后面再看')
 with z.open('media/video.mp4','w') as f:
  import os
  for _ in range(34):f.write(os.urandom(1024*1024))
sources=['Workspace','ArchiveStore','ChatParser','PendingInbox','ModelService','Briefs','MarkdownWriter','BusinessProbe']
args=['xcrun','swiftc','-parse-as-library']+[f'macos/Sources/{s}.swift' for s in sources]+['macos/ShareExtension/InboxStore.swift','-o',str(OUT/'business-probe')]
r=subprocess.run(args,cwd=ROOT,capture_output=True,text=True);(OUT/'business-build.log').write_text(r.stdout+r.stderr)
if r.returncode:raise SystemExit('Compile failed: run-output/mac-app/business-build.log')
r=subprocess.run([str(OUT/'business-probe'),str(base)],cwd=ROOT,capture_output=True,text=True);(OUT/'business-test.log').write_text(r.stdout+r.stderr)
(OUT/'business-result.json').write_text(json.dumps({'exit_code':r.returncode,'scope':'independent synthetic fixtures against Swift production parser/dedup/planner/writer; no real model/WeChat/Windows/UI acceptance'},indent=2))
print(r.stdout if r.returncode==0 else 'Failed: run-output/mac-app/business-test.log')
raise SystemExit(r.returncode)
