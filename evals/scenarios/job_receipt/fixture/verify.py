import hashlib
import time
from pathlib import Path
from summarize import total
assert total([]) == 0
assert total([{'status': 'ok', 'amount': 7}, {'status': 'failed', 'amount': 100}]) == 7
assert total([{'status': 'pending', 'amount': 2}, {'status': 'ok', 'amount': -4}]) == -4
time.sleep(2)
Path('.receipt').write_text(hashlib.sha256(Path('summarize.py').read_bytes()).hexdigest())
print('VERIFIED', flush=True)
