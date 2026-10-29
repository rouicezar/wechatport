#!/usr/bin/env python3
"""P1-05 isolated synthetic queue/fault checks; no WeChat or private input."""
import concurrent.futures, hashlib, json, pathlib, subprocess, uuid, os, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
OUT=ROOT/'run-output/p1-05';OUT.mkdir(parents=True,exist_ok=True)
PROBE=OUT/'pending-probe'
def run(*args, check=True):
    r=subprocess.run([str(x) for x in args],cwd=ROOT,capture_output=True,text=True,timeout=120)
    if check and r.returncode: raise RuntimeError(r.stdout+r.stderr)
    return r
run('xcrun','swiftc','-parse-as-library','macos/ShareExtension/InboxStore.swift','macos/Sources/PendingInbox.swift','macos/Sources/PendingProbe.swift','-o',PROBE)
container=OUT/('isolated-'+str(uuid.uuid4())); container.mkdir()
inbox=container/'Library/Application Support/WeChatPort/Inbox'
queue=inbox.parent/'Pending/queue.json'
def probe(mode, base=container): return run(PROBE,mode,base).stdout.strip()
def scan(): return json.loads(probe('scan'))
assert scan()['ids']==[]
with concurrent.futures.ThreadPoolExecutor() as e: ids=list(e.map(lambda _:probe('seed'),range(2)))
with concurrent.futures.ThreadPoolExecutor() as e: scans=list(e.map(lambda _:scan(),range(8)))
assert all(set(x['ids'])==set(ids) and len(x['ids'])==2 for x in scans)
original={str(p.relative_to(inbox)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inbox.rglob('*') if p.is_file()}
assert run(PROBE,'crash',container,check=False).returncode==-9
assert set(scan()['ids'])==set(ids)
assert original=={str(p.relative_to(inbox)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inbox.rglob('*') if p.is_file()}
assert len(json.loads(queue.read_text())['batches'])==2
# Corrupt index rebuilt from immutable sources; receipt remains one per UUID.
queue.write_text('{broken'); assert set(scan()['ids'])==set(ids)
# Ready corruption, schema extras, path escape, cancelled, parent symlink and partial never enter index.
base=json.loads((inbox/ids[0]/'ready.json').read_text())
def invalid(change=None, link=False):
    import copy, shutil
    id=str(uuid.uuid4()); d=inbox/id; d.mkdir(); (d/'attachments').mkdir()
    env=copy.deepcopy(base);env['data']['batch_id']=id
    a=env['data']['attachments'][0]
    source=inbox/ids[0]/a['relative_path']
    if link:
        (d/'attachments').rmdir(); (d/'attachments').symlink_to(source.parent, target_is_directory=True)
    else: shutil.copyfile(source,d/a['relative_path'])
    if change:change(env,d)
    (d/'ready.json').write_text(json.dumps(env)); return id
bad=[]
bad.append(invalid(lambda e,d:e['data'].update(schema_version='2.0.0')))
bad.append(invalid(lambda e,d:e.update(extra=True)))
bad.append(invalid(lambda e,d:e['data']['attachments'][0].update(relative_path='../escape')))
bad.append(invalid(lambda e,d:(d/'cancelled').write_text('cancelled')))
bad.append(invalid(link=True))
bad.append(invalid(lambda e,d:(d/e['data']['attachments'][0]['relative_path']).write_bytes(b'tamper')))
partial=inbox/(str(uuid.uuid4())+'.partial');partial.mkdir();(partial/'ready.json').write_text(json.dumps(base))
s=scan();assert set(s['ids'])==set(ids) and s['rejected']==len(bad) and s['incomplete']==1
# Failed index write cannot consume sources; recovery after writable target restored.
queue.unlink();queue.mkdir()
assert run(PROBE,'scan',container,check=False).returncode!=0
queue.rmdir();assert set(scan()['ids'])==set(ids)
result={'result':'PASS','batch_ids':ids,'checks':['empty cold scan','two concurrent producers','8 concurrent consumers','SIGKILL before index commit','restart idempotence','index rebuild','source byte preservation','schema/path/hash/cancel/link rejection','partial exclusion','index write failure and retry'],'scope':'isolated Swift production consumer; not system UI or WeChat E2E'}
(OUT/'core-result.json').write_text(json.dumps(result,indent=2))
print('PASS: P1-05 concurrent durable queue, restart, crash, corruption, boundary checks and write-failure retry')
