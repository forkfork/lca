#!/usr/bin/env python3
"""Quiet suite runner; use --verbose for live output or paths for focused Lua tests."""
import argparse
import glob
import os
import shlex
import subprocess
import sys
import tempfile
import time


def run_suite(name, command, verbose=False):
    started = time.monotonic()
    with tempfile.TemporaryFile() as output:
        result = subprocess.run(command, stdout=None if verbose else output,
                                stderr=None if verbose else subprocess.STDOUT)
        elapsed = time.monotonic() - started
        print(f"{'PASS' if result.returncode == 0 else 'FAIL'} {name} ({elapsed:.1f}s)", flush=True)
        if result.returncode and not verbose:
            output.seek(0)
            while chunk := output.read(65536):
                sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
        return result.returncode if result.returncode >= 0 else 128 - result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lua', default=os.environ.get('LUA', 'lua5.5'))
    parser.add_argument('--verbose', action='store_true')
    parser.add_argument('--label', default='command')
    parser.add_argument('--command', nargs=argparse.REMAINDER,
                        help='report an arbitrary command instead of running tests')
    parser.add_argument('paths', nargs='*', help='Lua test files (default: all suites)')
    args = parser.parse_args()
    if args.command is not None:
        if not args.command or args.paths:
            parser.error('--command needs a command and cannot be combined with test paths')
        return run_suite(args.label, args.command, args.verbose)
    paths = args.paths or sorted(glob.glob('tests/test_*.lua'))
    if not paths:
        parser.error('no Lua tests found; run from the project root')
    suites = [(path, shlex.split(args.lua) + [path]) for path in paths]
    if not args.paths:
        suites.append(('Python eval tests', [sys.executable, '-m', 'unittest', 'discover',
                                            '-s', 'evals/tests', '-p', 'test_*.py']))
    for name, command in suites:
        code = run_suite(name, command, args.verbose)
        if code:
            return code
    return 0


if __name__ == '__main__':
    sys.exit(main())
