#!/usr/bin/env python3
"""Observe current signed app + synthetic system extension; no WeChat access."""
import hashlib,json,pathlib,subprocess,time,uuid,concurrent.futures
ROOT=pathlib.Path(__file__).resolve().parents[1]; OUT=ROOT/'run-output/p1-05';OUT.mkdir(parents=True,exist_ok=True)
APP=ROOT/'run-output/p1-02/arm64/WeChatPort.app'
GROUP=(APP.parent/'group.txt').read_text().strip()
INBOX=pathlib.Path.home()/'Library/Group Containers'/GROUP/'Library/Application Support/WeChatPort/Inbox'
QUEUE=INBOX.parent/'Pending/queue.json'
def run(args):return subprocess.run([str(x) for x in args],cwd=ROOT,capture_output=True,text=True,check=True,timeout=75).stdout
run(['xcrun','swiftc','macos/ShareExtension/ReceiveActivationProbe.swift','-o',OUT/'receive-host'])
def share():
    file=OUT/('synthetic-'+str(uuid.uuid4())+'.txt');file.write_bytes(b'P1-05 synthetic system attachment\0\r\n')
    before={p.name for p in INBOX.iterdir()}
    log=run([OUT/'receive-host',file]);assert 'event=share_completed' in log
    new={p.name for p in INBOX.iterdir()}-before;assert len(new)==1
    batch=new.pop();ready=json.loads((INBOX/batch/'ready.json').read_text())['data']
    item=ready['attachments'][0];assert (INBOX/batch/item['relative_path']).read_bytes()==file.read_bytes()
    assert item['sha256']==hashlib.sha256(file.read_bytes()).hexdigest()
    return batch
# Cold receipt while main app is not running (caller has quit it).
cold=share()
log=(OUT/'app.log').open('w')
child=subprocess.Popen([str(APP/'Contents/MacOS/WeChatPort')],stdout=log,stderr=log)
def wait(ids):
    deadline=time.monotonic()+20
    while time.monotonic()<deadline:
        try:
            records=json.loads(QUEUE.read_text())['batches'];got=[x['id'] for x in records]
            if set(ids)<=set(got):
                assert len(got)==len(set(got));assert all(x['state']=='waiting_workspace' for x in records);return
        except (OSError,ValueError):pass
        time.sleep(.15)
    raise RuntimeError('queue did not receive expected synthetic batches')
try:
    wait([cold]);hot=share();wait([cold,hot])
    # Actual main app running: two near-simultaneous independent receiver processes.
    with concurrent.futures.ThreadPoolExecutor() as e:
        ids=list(e.map(lambda _:run([OUT/'pending-probe','seed',INBOX.parents[3]]).strip(),range(2)))
    wait([cold,hot,*ids])
    child.kill();child.wait(timeout=10)
    offset=(OUT/'app.log').stat().st_size
    # Restart reconstructs the exact same unique receipts from Inbox.
    child=subprocess.Popen([str(APP/'Contents/MacOS/WeChatPort')],stdout=log,stderr=log)
    wait([cold,hot,*ids])
    deadline=time.monotonic()+15
    while 'event=pending_scan ready=' not in (OUT/'app.log').read_text()[offset:]:
        assert time.monotonic()<deadline
        time.sleep(.1)
    assert child.poll() is None
    (OUT/'app-pid.json').write_text(json.dumps({'pid':child.pid,'binary':str(APP/'Contents/MacOS/WeChatPort')}))
    (OUT/'system-result.json').write_text(json.dumps({'result':'PASS','cold_system_batch':cold,'hot_system_batch':hot,'concurrent_batches':ids,'pid':child.pid,'checks':['signed main cold scan','actual system extension cold and hot receipt with byte/hash check','two simultaneous synthetic receiver processes while app live','main SIGKILL and restart','unique persistent waiting_workspace records'],'scope':'ARM64 local signed app and synthetic system sharing; no WeChat/G1/user acceptance'},indent=2))
    print('PASS: signed main cold/hot receive, concurrent producers, SIGKILL and restart; left app running for UI observation')
except:
    child.terminate();child.wait(timeout=10);raise
finally:log.close()
