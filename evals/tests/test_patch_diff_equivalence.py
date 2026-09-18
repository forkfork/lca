"""Offline equivalence against the frozen upstream parser; Python is test-only."""
import importlib.util
import json
from pathlib import Path
import random
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
REFERENCE = ROOT / 'research/archive/tagged-edit-20260918/evals/vendor/openai_apply_diff.py'
spec = importlib.util.spec_from_file_location('patch_reference', REFERENCE)
reference = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = reference
spec.loader.exec_module(reference)


class PatchDiffEquivalenceTests(unittest.TestCase):
    def test_frozen_reference_equivalence(self):
        cases = []
        def add(source, diff, mode='default'):
            cases.append(dict(source=source, diff=diff, mode=mode))
        for source in ('', 'a', 'a\n', 'a\nb\n', 'a\r\nb\r\n', 'a\r\nb', 'a\nb\r\n'):
            for diff in ('', '@@', '@@\n', '@@\n+a', '@@\n-a\n+A', '@@\n a\n+b',
                         '@@\n-b\n+B\n*** End of File', '@@\n+tail\n*** End of File',
                         '@@ missing\n-a\n+A', '@@ missing\n@@\n-a\n+A',
                         '@@\n-a\n+A\n@@\n-missing\n+B', 'bad', '***', '*** bad',
                         '*** End Patch\nignored', '@@\n\n+blank', '@@\n-a\n+A\n*** End Patch'):
                for ending in ('\n', '\r\n'):
                    add(source, diff.replace('\n', ending))
        for diff in ('', '+', '+hello', '+a\n+b\n', 'invalid', '+a\n*** End Patch\nignored', '+a\n\n', '+λ\r\n+世界'):
            add('', diff, 'create')
        add('class A\n method\n old\nclass B\n method\n old\n', '@@ class B\n@@ method\n- old\n+ new')
        add('a\nb\nc\n', '@@\n-c\n+C\n@@\n-a\n+A\n*** End of File')
        for space in (' ', '\t', '\v', '\f', '\r', '\x1c', '\x1f', '\x85', '\xa0', '\u1680',
                      *map(chr, range(0x2000, 0x200b)), '\u2028', '\u2029', '\u202f', '\u205f', '\u3000'):
            add(space + 'anchor' + space + '\n' + space + 'old' + space + '\n', '@@ anchor\n-old\n+new')
            add('old' + space + '\n', '@@\n-old\n+new')
        rng = random.Random(918)
        for _ in range(800):
            lines = [rng.choice(['a', 'b', '', ' same ', '\tindented', 'λ', '世界']) for _ in range(rng.randint(1, 18))]
            first = rng.randrange(len(lines)); last = rng.randrange(first + 1, len(lines) + 1)
            before = [' ' + line for line in lines[max(0, first - 2):first]]
            removed = ['-' + line for line in lines[first:last]]
            added = ['+' + rng.choice(['new', '', 'λ']) for _ in range(rng.randrange(4))]
            after = [' ' + line for line in lines[last:last + 2]]
            diff = '\n'.join(['@@'] + before + removed + added + after)
            if rng.random() < .2: diff += '\n*** End of File'
            if rng.random() < .2: diff += '\n@@\n-missing\n+bad'
            ending = rng.choice(['\n', '\r\n'])
            source = ending.join(lines) + rng.choice(['', ending])
            add(source, diff)
        program = """
package.path = './lua/?.lua;' .. package.path
local parser = require('agent.patch_diff')
local json = require('agent.util.json')
for line in io.lines() do
 local case = json.decode(line)
 local ok, result = pcall(parser.apply, case.source, case.diff, case.mode)
 print(json.encode({ok=ok, result=result}))
end
"""
        result = subprocess.run(['lua5.5', '-e', program], cwd=ROOT, text=True,
                                input=''.join(json.dumps(case) + '\n' for case in cases),
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = [json.loads(line) for line in result.stdout.rstrip('\n').split('\n')]
        self.assertEqual(len(actual), len(cases))
        for case, observed in zip(cases, actual):
            try:
                expected = dict(ok=True, result=reference.apply_diff(case['source'], case['diff'], case['mode']))
            except ValueError as error:
                expected = dict(ok=False, result=str(error))
            self.assertEqual(observed, expected, case)
