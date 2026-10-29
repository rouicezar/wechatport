#!/usr/bin/env python3
"""P1-04 local synthetic integration. Builds/registers this app only; no external app access."""
import argparse, hashlib, json, pathlib, subprocess, uuid, zipfile
from jsonschema import Draft202012Validator, FormatChecker
ROOT=pathlib.Path(__file__).resolve().parents[1]
OUT=ROOT/'run-output/p1-04';OUT.mkdir(parents=True,exist_ok=True)
p=argparse.ArgumentParser();p.add_argument('--identity',required=True);args=p.parse_args()
def run(argv, name, timeout=180):
    r=subprocess.run([str(x) for x in argv],cwd=ROOT,capture_output=True,text=True,timeout=timeout)
    (OUT/name).write_text(r.stdout+r.stderr)
    if r.returncode: raise RuntimeError(f'{name}: exit {r.returncode}; inspect local synthetic log')
    return r.stdout
run(['python3','scripts/verify-macos-inbox.py'],'core.log')
run(['python3','scripts/verify-macos-share.py','--identity',args.identity],'signed-build.log')
run(['xcrun','swiftc','macos/ShareExtension/ReceiveActivationProbe.swift','-o',OUT/'receive-host'],'host-build.log')
# Resolve exact group recorded by the signed build. Inspect only newly created synthetic batches.
group=(ROOT/'run-output/p1-02/arm64/group.txt').read_text().strip()
inbox=pathlib.Path.home()/'Library/Group Containers'/group/'Library/Application Support/WeChatPort/Inbox'
before=set(inbox.iterdir()) if inbox.exists() else set()
fixture=OUT/('system-'+str(uuid.uuid4()));fixture.mkdir()
a=fixture/'synthetic.txt';a.write_bytes(b'P1-04 synthetic\x00\r\n')
b=fixture/'synthetic.zip'
with zipfile.ZipFile(b,'w') as z:z.writestr('synthetic.txt','Synthetic attachment only')
source_hashes={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in (a,b)}
log=run([OUT/'receive-host',a,b],'system-success.log',70)
assert 'event=share_completed' in log
new=set(inbox.iterdir())-before
assert len(new)==1
batch=new.pop();assert not batch.name.endswith('.partial')
envelope=json.loads((batch/'ready.json').read_text())
ready=envelope['data']
validator=Draft202012Validator(json.loads((ROOT/'shared/contracts/v1/contract.schema.json').read_text()),format_checker=FormatChecker())
validator.validate(envelope)
assert ready['batch_id']==batch.name and len(ready['attachments'])==2
for item,source in zip(ready['attachments'],(a,b)):
    copied=(batch/item['relative_path']).read_bytes()
    assert copied==source.read_bytes() and hashlib.sha256(copied).hexdigest()==item['sha256']
    assert item['byte_count']==len(copied) and item['original_name']==source.name
(OUT/'system-result.json').write_text(json.dumps({'result':'PASS','batch_id':batch.name,'group':group,
    'source_hashes':source_hashes,'ready':ready,'host_log':log,'scope':'ARM64 synthetic NSSharingService real extension receive; not WeChat/G1/user acceptance'},indent=2))
print('PASS: signed dual builds, core fault/recovery scenarios, actual ARM64 system extension multi-file receive; independent hashes/schema verified. No WeChat/Windows/CI/release/user acceptance.')
