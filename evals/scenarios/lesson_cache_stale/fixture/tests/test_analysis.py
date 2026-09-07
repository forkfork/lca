import unittest
from analyzer import analyze


class AnalysisTests(unittest.TestCase):
    def test_reuse_respects_paths(self):
        calls = []
        def parser(path, text):
            calls.append((path, text))
            return path + ":" + text.upper()
        self.assertEqual(analyze([("a", "same"), ("b", "same"), ("a", "same"), ("a", "new")], parser),
                         [("a", "a:SAME"), ("b", "b:SAME"), ("a", "a:SAME"), ("a", "a:NEW")])
        self.assertEqual(calls, [("a", "same"), ("b", "same"), ("a", "new")])

    def test_no_cross_call_cache(self):
        self.assertEqual(analyze([("a", "x")], lambda path, text: 1), [("a", 1)])
        self.assertEqual(analyze([("a", "x")], lambda path, text: 2), [("a", 2)])

    def test_empty(self):
        self.assertEqual(analyze([], lambda *args: self.fail("unexpected parse")), [])
