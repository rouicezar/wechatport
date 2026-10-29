"""Validate the authoritative task ledger and its requirement traceability."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
plan = (root / 'docs/颗粒级开发与验证计划.md').read_text()
matrix = (root / 'docs/工程需求矩阵.md').read_text()
tasks = {}
for line in plan.splitlines():
    if not re.match(r'^\| P[0-8]-\d{2} \|', line):
        continue
    cols = [part.strip() for part in line.split('|')[1:-1]]
    assert len(cols) == 10, f'Invalid platform columns: {line}'
    task, platform, prerequisites = cols[:3]
    assert task not in tasks, f'Duplicate task: {task}'
    tasks[task] = re.findall(r'P\d-\d{2}', prerequisites)
    if platform == '双':
        assert cols[7] == '—' and cols[8] != '—' and cols[9] != '—', task
assert len(tasks) == 79, len(tasks)
visited, active = set(), set()
def visit(task):
    assert task in tasks, f'Unknown prerequisite: {task}'
    assert task not in active, f'Dependency cycle at {task}'
    if task in visited:
        return
    active.add(task)
    for dependency in tasks[task]:
        visit(dependency)
    active.remove(task)
    visited.add(task)
for task in tasks:
    visit(task)

def mappings(text):
    rows = {}
    for key, value in re.findall(r'^\| ([RA]\d{2}) \| (.+) \|$', text, re.M):
        assert key not in rows, f'Duplicate baseline ID: {key}'
        rows[key] = value
    return rows
index = plan.split('## 5. 需求及验收追踪索引')[1].split('## 6.')[0]
expected = {f'R{i:02}' for i in range(1, 10)} | {f'A{i:02}' for i in range(1, 15)}
assert set(mappings(index)) == expected
assert mappings(matrix) == mappings(index), 'Traceability matrix drift'
for value in mappings(matrix).values():
    for task in re.findall(r'P\d-\d{2}', value):
        assert task in tasks, f'Unknown mapped task: {task}'
print('PASS: 79 unique tasks, valid acyclic dependencies, independent platform columns, 9 R + 14 A mappings consistent.')
