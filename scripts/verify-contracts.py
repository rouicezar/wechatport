"""Check P0 contract shape and risky invalid payloads; not product tests."""
from pathlib import Path
from copy import deepcopy
import json
import hashlib
from jsonschema import Draft202012Validator, FormatChecker

root = Path(__file__).resolve().parents[1]
base = root / 'shared/contracts/v1'
schema = json.loads((base / 'contract.schema.json').read_text())
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema, format_checker=FormatChecker())
examples = {}
for path in sorted((base / 'examples').glob('*.json')):
    payload = json.loads(path.read_text())
    validator.validate(payload)
    examples[path.stem] = payload
checks = 0
for path in ('../secret', '/etc/passwd', 'C:/secret', 'a/../../secret', 'a\\secret'):
    payload = deepcopy(examples['ready'])
    payload['data']['attachments'][0]['relative_path'] = path
    assert not validator.is_valid(payload), path
    checks += 1
for mutate in (
    lambda p: p['data'].update(state='receiving'),
    lambda p: p['data'].update(attachments=[]),
    lambda p: p['data'].update(received_at='2026-10-27T03:00:00'),
    lambda p: p['data'].update(api_key='synthetic-forbidden'),
    lambda p: p['data']['attachments'][0].update(byte_count=-1),
):
    payload = deepcopy(examples['ready'])
    mutate(payload)
    assert not validator.is_valid(payload)
    checks += 1
counts = examples['event']['data']['counts']
assert counts['imported'] == counts['confirmed_duplicate'] + counts['new'] + counts['unparsed']
assert counts['suspected'] <= counts['new']
print(f'PASS: schema valid, {len(examples)} synthetic examples valid, {checks} unsafe/invalid shapes rejected; example count equation valid.')
print('NOT VERIFIED: native implementations, file persistence/hash, runtime semantic invariants, actual sharing or model calls.')

snapshot = dict(examples['golden-snapshot']['data'])
expected_hash = snapshot.pop('snapshot_hash')
canonical = json.dumps(snapshot, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')
assert hashlib.sha256(canonical).hexdigest() == expected_hash
snapshot['template_snapshot'] += 'changed'
assert hashlib.sha256(json.dumps(snapshot, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')).hexdigest() != expected_hash
print('PASS: snapshot golden hash matches; template change invalidates hash.')
