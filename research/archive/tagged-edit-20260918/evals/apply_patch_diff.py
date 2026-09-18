"""Eval-only, pure candidate generation; the Lua caller owns all file mutations."""
import json
from pathlib import Path
import sys
from vendor.openai_apply_diff import apply_diff

if __name__ == '__main__':
    try:
        request = json.loads(Path(sys.argv[1]).read_text())
        content = apply_diff(request['input'], request['diff'],
                             'create' if request['type'] == 'create_file' else 'default')
        print(json.dumps({'content': content}))
    except (ValueError, KeyError, TypeError) as error:
        print(json.dumps({'error': str(error)}))
