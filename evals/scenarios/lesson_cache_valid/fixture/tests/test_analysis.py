import unittest
from analyzer import analyze


class AnalysisTests(unittest.TestCase):
    def test_reuse_across_paths(self):
        calls = []
        def parser(text):
            calls.append(text)
            return text.upper()
        self.assertEqual(analyze([("a", "same"), ("b", "same"), ("a", "new")], parser),
                         [("a", "SAME"), ("b", "SAME"), ("a", "NEW")])
        self.assertEqual(calls, ["same", "new"])

    def test_no_cross_call_cache(self):
        self.assertEqual(analyze([("a", "x")], lambda text: 1), [("a", 1)])
        self.assertEqual(analyze([("a", "x")], lambda text: 2), [("a", 2)])

    def test_empty(self):
        self.assertEqual(analyze([], lambda text: self.fail("unexpected parse")), [])
