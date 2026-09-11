import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from operational_screen import grade
print(json.dumps(grade(Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text()), Path(__file__).with_name("fixture"))))
