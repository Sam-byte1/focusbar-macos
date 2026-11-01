#!/usr/bin/env python3
"""Read only isolated QA state; never opens the production data directory."""
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
doc = json.loads(path.read_text())
assert doc['schemaVersion'] == 1
ids = [r['id'] for r in doc['history']]
assert len(ids) == len(set(ids)), 'duplicate history'
for record in doc['history']:
    seconds = sum(s['seconds'] for s in record['segments'])
    assert 0 <= seconds <= record['plannedSeconds'] + .01
    if record['outcome'] == 'completed':
        assert abs(seconds - record['plannedSeconds']) < .01, (seconds, record['plannedSeconds'])
        assert abs(record['segments'][-1]['end'] - record['endedAt']) < .01
print('History:', len(ids), 'unique records; active:', bool(doc.get('active')))
for r in doc['history']:
    print(r['typeName'], r['outcome'], round(sum(s['seconds'] for s in r['segments']), 3), 'seconds')
