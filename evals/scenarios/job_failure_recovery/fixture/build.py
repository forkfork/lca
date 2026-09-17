import argparse
import hashlib
import json
from pathlib import Path
import sys
p=argparse.ArgumentParser()
p.add_argument('--target',choices=['inventory'],required=True)
p.add_argument('--check-reservations',action='store_true',required=True)
p.add_argument('--check-negative-stock',action='store_true',required=True)
p.add_argument('--emit-receipt',required=True)
p.add_argument('--stdout-lines',type=int,required=True)
p.add_argument('--stderr-diagnostics',choices=['detailed'],required=True)
p.add_argument('--log-format',choices=['plain'],required=True)
p.add_argument('--receipt-format',choices=['json'],required=True)
a=p.parse_args()
for n in range(a.stdout_lines): print(f'build progress record {n:05d}',flush=True)
from inventory import available
for stock,reserved in [(9,4),(2,7),(0,0),(50,0),(7,7)]:
    actual=available(stock,reserved)
    if actual != max(0,stock-reserved):
        print(f'BUILD ERROR: available({stock}, {reserved}) returned {actual}; subtract reservations and clamp at zero',file=sys.stderr,flush=True)
        sys.exit(7)
Path(a.emit_receipt).write_text(json.dumps({'sha256':hashlib.sha256(Path('inventory.py').read_bytes()).hexdigest(),'passed':True}))
print('BUILD VERIFIED',flush=True)
