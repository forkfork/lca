import argparse
import hashlib
import json
from pathlib import Path
import sys
import time
p=argparse.ArgumentParser()
p.add_argument('--name',required=True,choices=['alpha','beta'])
p.add_argument('--receipt',required=True)
p.add_argument('--release-file',required=True)
p.add_argument('--stdout-records',required=True,type=int)
p.add_argument('--stderr-records',required=True,type=int)
p.add_argument('--poll-interval-ms',required=True,type=int)
p.add_argument('--deadline-seconds',required=True,type=int)
p.add_argument('--log-format',choices=['plain'],required=True)
p.add_argument('--receipt-format',choices=['json'],required=True)
a=p.parse_args()
print(a.name+' started',flush=True)
deadline=time.monotonic()+a.deadline_seconds
while not Path(a.release_file).exists():
    if time.monotonic()>deadline:sys.exit(8)
    time.sleep(a.poll_interval_ms/1000)
for n in range(a.stdout_records): print(f'{a.name} out {n}',flush=True)
for n in range(a.stderr_records): print(f'{a.name} diagnostic {n}',file=sys.stderr,flush=True)
Path(a.receipt).write_text(json.dumps({'name':a.name,'sha256':hashlib.sha256(Path('labels.py').read_bytes()).hexdigest(),'passed':True}))
print(a.name+' VERIFIED',flush=True)
