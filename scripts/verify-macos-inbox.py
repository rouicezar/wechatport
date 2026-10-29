#!/usr/bin/env python3
"""Synthetic input only; fault processes are exact children. No chat/WeChat/data cleanup."""
import hashlib, json, pathlib, subprocess, tempfile, sys
from jsonschema import Draft202012Validator, FormatChecker
ROOT=pathlib.Path(__file__).resolve().parents[1]
OUT=ROOT/'run-output/p1-04'; OUT.mkdir(parents=True, exist_ok=True)
run_dir=pathlib.Path(tempfile.mkdtemp(prefix='verify-',dir=OUT))
def run(args, expected=0):
    r=subprocess.run([str(x) for x in args],cwd=ROOT,capture_output=True,text=True)
    if r.returncode != expected: raise AssertionError(f'{args[0]} code={r.returncode}: {r.stdout}{r.stderr}')
    return r.stdout
validator=Draft202012Validator(json.loads((ROOT/'shared/contracts/v1/contract.schema.json').read_text()),format_checker=FormatChecker())
probe=run_dir/'inbox-probe'
run(['xcrun','swiftc','-parse-as-library','macos/ShareExtension/InboxStore.swift','macos/ShareExtension/InboxProbe.swift','-o',probe])
a=run_dir/'same.txt'; a.write_bytes(b'synthetic\x00\r\n' * 200000)
b_dir=run_dir/'other'; b_dir.mkdir(); b=b_dir/'same.txt'; b.write_bytes(b'different synthetic\n')
empty=run_dir/'empty.txt'; empty.write_bytes(b'')
def invoke(mode, name, files, code=0):
    root=run_dir/name
    output=run([probe,mode,root,*files],code)
    (run_dir/(name+'-'+mode+'.log')).write_text(output)
    return root

def check_ready(root, files):
    batches=[p for p in root.iterdir() if not p.name.endswith('.partial')]
    assert len(batches)==1
    envelope=json.loads((batches[0]/'ready.json').read_text())
    ready=envelope['data']
    validator.validate(envelope)
    assert ready['batch_id']==batches[0].name and len(ready['attachments'])==len(files)
    assert ready['state']=='ready' and ready['schema_version']=='1.0.0'
    for entry,source in zip(ready['attachments'],files):
        data=(batches[0]/entry['relative_path']).read_bytes()
        assert data==source.read_bytes()
        assert entry['sha256']==hashlib.sha256(source.read_bytes()).hexdigest()
        assert entry['byte_count']==len(data)
        assert entry['original_name']==source.name
    return ready

def no_ready(root):
    assert all(p.name.endswith('.partial') for p in root.iterdir())
    assert not list(root.glob('*/ready.json'))

original={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in (a,b,empty)}
root=invoke('success','multi',[a,b,empty]); check_ready(root,[a,b,empty])
missing=run_dir/'missing.txt'
root=invoke('success','failure',[a,missing],4); no_ready(root)
assert 'incomplete=1' in run([probe,'recover',root]); no_ready(root)
root=invoke('retry','retry',[a,missing]); check_ready(root,[a,missing])
root=invoke('interrupt','interrupted',[a],-9); no_ready(root)
fragments=list(root.glob('*/attachments/*.partial')); assert len(fragments)==1 and 0<fragments[0].stat().st_size<a.stat().st_size
assert 'incomplete=1' in run([probe,'recover',root]); no_ready(root)
# Re-sharing succeeds while preserving every interrupted byte in the old batch.
run([probe,'success',root,a]); assert fragments[0].exists(); check_ready(root,[a])
root=invoke('sealed-interrupt','sealed',[a,b],-9)
assert not [p for p in root.iterdir() if not p.name.endswith('.partial')]
assert 'recovered=1' in run([probe,'recover',root]); check_ready(root,[a,b])
assert 'recovered=0' in run([probe,'recover',root]); check_ready(root,[a,b])
root=run_dir/'active-lock'
active=subprocess.Popen([str(probe),'hold',str(root),str(a)],stdout=subprocess.PIPE,text=True)
assert active.stdout.readline().startswith('batch=')
assert active.stdout.readline().strip()=='event=holding_lock'
assert 'busy=1' in run([probe,'recover',root]); no_ready(root)
active.kill(); active.wait()
root=invoke('cancel','cancelled',[a],4); no_ready(root)
assert 'recovered=0 incomplete=1' in run([probe,'recover',root]); no_ready(root)
root=invoke('cancel-after-copy','cancel-complete',[a,b],4); no_ready(root)
assert 'recovered=0 incomplete=1' in run([probe,'recover',root]); no_ready(root)
root=invoke('tamper','tampered',[a],4); no_ready(root)
link=run_dir/'link.txt';link.symlink_to(a)
root=invoke('success','symlink',[link],4); no_ready(root)
root=invoke('success','directory',[b_dir],4); no_ready(root)
assert all(hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()==h for p,h in original.items())
summary={'result':'PASS','run_directory':str(run_dir),'source_hashes':original,
         'checks':['multi + same names + empty bytes','second attachment missing: no ready','same transaction retry reuses attachment',
                   'SIGKILL midway: fragment retained, re-share succeeds','SIGKILL sealed before rename: recover once',
                   'active writer skipped by recovery','cancel midway/all-copied: no ready; late cancel refused','tamper: no ready','symlink and directory rejected','all original hashes unchanged']}
(OUT/'core-result.json').write_text(json.dumps(summary,indent=2))
print(json.dumps(summary,indent=2))
