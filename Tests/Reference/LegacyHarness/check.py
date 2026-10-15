#!/usr/bin/env python3
"""Run the reproducible acceptance corpus; a failed stage cannot retain a green report."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
from reporting import ROOT, execute


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-apple', action='store_true', help='Explicitly omit the simulator/device build matrix')
    parser.add_argument('--package', type=Path, help='Also assemble and relocate a fresh development bundle')
    args = parser.parse_args()
    commands = [['swift', 'test', '-Xswiftc', '-warnings-as-errors', '-Xcc', '-Wall', '-Xcc', '-Wextra', '-Xcc', '-Werror']]
    commands += [[sys.executable, 'scripts/' + name + '.py'] for name in [
        'test_comparator', 'runtime_tests', 'upstream_tests', 'integration', 'workflow_tests', 'migration_tests',
        'source_tests', 'environment_tests', 'behavior', 'safety_tests', 'doctor_tests', 'spm_tests', 'cmake_tests', 'traceability']]
    if not args.skip_apple:
        commands.append([sys.executable, 'scripts/apple_matrix.py'])
    if args.package:
        commands += [[sys.executable, 'scripts/package.py', '--destination', str(args.package)],
                     [sys.executable, 'scripts/portability.py', str(args.package)],
                     [sys.executable, 'scripts/distribution_tests.py', str(args.package)],
                     [sys.executable, 'scripts/homebrew_tests.py', str(args.package)]]
    results = []
    for index, command in enumerate(commands):
        print('Running:', ' '.join(command), flush=True)
        started = time.monotonic()
        log = ROOT / 'test-results' / ('check-' + str(index) + '.log')
        with log.open('wb') as output:
            result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
        results.append({'command': command, 'exit_status': result.returncode, 'seconds': time.monotonic() - started, 'log': str(log)})
        if result.returncode:
            raise RuntimeError('Stage failed: ' + ' '.join(command) + '; see ' + str(log))
    report = {'schema_version': 1, 'status': 'passed', 'stages': results, 'apple_matrix_omitted': args.skip_apple}
    (ROOT / 'test-results/check.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    execute(main, 'check.json')
