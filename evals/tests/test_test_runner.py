"""Exercise quiet reporting with real child processes, not the project suites."""
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
RUNNER = ROOT / 'scripts' / 'test.py'


class TestRunnerTests(unittest.TestCase):
    def invoke(self, source, verbose=False):
        with tempfile.TemporaryDirectory() as directory:
            fixture = pathlib.Path(directory) / 'fixture.py'
            fixture.write_text(source)
            command = [sys.executable, str(RUNNER), '--lua', sys.executable]
            if verbose:
                command.append('--verbose')
            return subprocess.run(command + [str(fixture)], capture_output=True, text=True)

    def test_success_is_quiet_and_verbose_is_available(self):
        source = "import sys\nprint('chatty success')\nprint('chatty stderr', file=sys.stderr)\n"
        quiet = self.invoke(source)
        self.assertEqual(quiet.returncode, 0)
        self.assertEqual(len(quiet.stdout.splitlines()), 1)
        self.assertTrue(quiet.stdout.startswith('PASS '))
        self.assertNotIn('chatty', quiet.stdout + quiet.stderr)
        verbose = self.invoke(source, verbose=True)
        self.assertEqual(verbose.returncode, 0)
        self.assertIn('chatty success', verbose.stdout)
        self.assertIn('chatty stderr', verbose.stderr)

    def test_failure_preserves_output_and_exit_status(self):
        result = self.invoke("import sys\nprint('failure details')\nprint('error details', file=sys.stderr)\nsys.exit(7)\n")
        self.assertEqual(result.returncode, 7)
        self.assertIn('FAIL ', result.stdout)
        self.assertIn('failure details', result.stdout)
        self.assertIn('error details', result.stdout)


class CommandRunnerTests(TestRunnerTests):
    def invoke(self, source, verbose=False):
        command = [sys.executable, str(RUNNER), '--label', 'local fixture']
        if verbose:
            command.append('--verbose')
        return subprocess.run(command + ['--command', sys.executable, '-c', source],
                              capture_output=True, text=True)

    def test_empty_command_is_rejected(self):
        result = subprocess.run([sys.executable, str(RUNNER), '--command'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('needs a command', result.stderr)

if __name__ == '__main__':
    unittest.main()
