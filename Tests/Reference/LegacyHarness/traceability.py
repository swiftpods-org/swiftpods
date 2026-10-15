#!/usr/bin/env python3
"""Produce DSL/attribute/option -> exact executed upstream spec locations."""
import json
from pathlib import Path
import subprocess
import tempfile
from integration import ROOT, RUBY, environment
from upstream_tests import pinned_checkout


def main():
    home = Path(tempfile.mkdtemp(prefix='trace-home-', dir=ROOT / '.build'))
    env = environment(home)
    env.pop('BUNDLE_WITHOUT', None)
    env.pop('COCOAPODS_SKIP_UPDATE_MESSAGE', None)
    env.update(GIT_AUTHOR_NAME='Tests', GIT_AUTHOR_EMAIL='tests@example.invalid', GIT_COMMITTER_NAME='Tests', GIT_COMMITTER_EMAIL='tests@example.invalid',
               TOOLCHAINS='com.apple.dt.toolchain.XcodeDefault')
    merged, cases, suites = {}, {}, []
    for name, patterns in [('cocoapods-core', ['spec/**/*_spec.rb']), ('cocoapods', ['spec/unit/**/*_spec.rb', 'spec/functional/**/*_spec.rb'])]:
        checkout = pinned_checkout(name)
        files = sorted({path for pattern in patterns for path in checkout.glob(pattern)})
        if name == 'cocoapods':
            files += sorted((ROOT / 'Tests/Compatibility').glob('*_spec.rb'))
        output = ROOT / 'test-results' / (name + '-trace.json')
        with (ROOT / 'test-results' / (name + '-trace.log')).open('wb') as log:
            result = subprocess.run([str(RUBY), str(ROOT / 'scripts/traceability.rb'), str(checkout), str(output), *map(str, files)],
                                    cwd=checkout, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=900)
        assert result.returncode == 0, 'Observed upstream suite failed: ' + str(output)
        suite = json.loads(output.read_text())
        assert suite['status'] == 'passed', suite
        suites.append({key: value for key, value in suite.items() if key not in ('inventory', 'cases')})
        cases.update(suite['cases'])
        for key, entry in suite['inventory'].items():
            previous = merged.get(key, {})
            entry['cases'] = sorted(set(entry['cases']) | set(previous.get('cases', [])))
            entry['status'] = 'observed_in_baseline_assertions' if entry['cases'] else 'unverified'
            merged[key] = entry
    for case in cases.values():
        case['file'] = str(Path(case['file']).relative_to(ROOT))
    normalized = {}
    for key, entry in merged.items():
        normalized[key] = {**entry, 'cases': [cases[id] for id in entry['cases']]}
    report = {'schema_version': 1, 'status': 'passed', 'suites': suites, 'inventory': normalized,
              'unverified': sorted(key for key, value in normalized.items() if value['status'] == 'unverified'),
              'scope': 'Executed baseline assertions; full integration/build matrix remains a separate gate'}
    (ROOT / 'test-results/traceability.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Traceable entries:', len(normalized), 'unverified:', len(report['unverified']))
    print('\n'.join(report['unverified']))


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'traceability.json')
