from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from cache_lesson_grader import main
main(Path(__file__).with_name("fixture"))
