import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from obligation_discrimination import grade
p = Path(sys.argv[2])
print(json.dumps(grade(Path(sys.argv[1]), p.parent, Path(__file__).with_name("fixture"))))
