import json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from job_acceptance import grade
print(json.dumps(grade(Path(sys.argv[1]),json.loads(Path(sys.argv[2]).read_text()),'job_overlap_edit')))
