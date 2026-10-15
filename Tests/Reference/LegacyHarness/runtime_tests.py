#!/usr/bin/env python3
"""Verify external Ruby selection fails before project evaluation or mutation."""
import json
import platform
from pathlib import Path
import subprocess
import tempfile
from integration import ROOT, CLI, BUNDLE, RUBY, environment


def main():
    project = Path(tempfile.mkdtemp(prefix='external-ruby-', dir=ROOT / '.build'))
    (project / 'Podfile').write_text("File.write('executed', 'unexpected')\nraise 'must not evaluate'\n")
    env = environment(project)

    def invoke(arguments, override=None, expected=0):
        result = subprocess.run([str(CLI), *arguments, '--json'], cwd=project,
                                env={**env, **(override or {})}, capture_output=True, timeout=30)
        assert result.returncode == expected, result.stderr.decode()
        assert not (project / 'executed').exists()
        assert not (project / '.swiftpods').exists(), 'Runtime failure changed project state'
        return json.loads(result.stdout)

    report = invoke(['runtime', 'verify'], {'RUBYOPT': '-r/invalid', 'RUBYGEMS_GEMDEPS': '/invalid'})
    assert report['runtime_mode'] == 'external' and report['ruby']['path'] == str(RUBY)
    assert not (BUNDLE / 'runtime').exists()
    for value, code in [('/no/such/swiftpods-ruby', 'SP-RUBY-MISSING'), ('relative/ruby', 'SP-RUBY-PATH'),
                        ('/usr/bin/ruby', 'SP-RUBY-VERSION')]:
        failure = invoke(['install'], {'SWIFTPODS_RUBY': value}, 1)
        assert failure['diagnostic']['code'] == code, failure
    # A configured interpreter is never silently replaced by another Ruby.
    fake = project / 'wrong-architecture-ruby'
    fake.write_text('#!/bin/sh\n' + "echo '{\"engine\":\"ruby\",\"version\":\"3.4.11\",\"abi\":\"3.4.0\",\"architecture\":\"wrong-arch\"}'\n")
    fake.chmod(0o755)
    failure = invoke(['install'], {'SWIFTPODS_RUBY': str(fake)}, 1)
    assert failure['diagnostic']['code'] == 'SP-RUBY-ARCH'
    metadata = {'engine': 'ruby', 'version': '3.4.11', 'abi': '3.4.0',
                'architecture': platform.machine(), 'library': '/wrong-installation/libruby.3.4.dylib'}
    fake.write_text("#!/bin/sh\necho '" + json.dumps(metadata) + "'\n")
    failure = invoke(['install'], {'SWIFTPODS_RUBY': str(fake)}, 1)
    assert failure['diagnostic']['code'] == 'SP-RUBY-LINKAGE'
    # Exercise RubyGems/Bundler with a different consumer Darwin version.
    # Native metadata must still find the shipped compiled extensions.
    code = "require 'rubygems'; require 'bundler/setup'; Gem::Platform.instance_variable_set(:@local, Gem::Platform.new('" + platform.machine() + "-darwin-999')); require 'bigdecimal'; require 'json'; require 'nkf'; abort 'extension missing' if Gem.loaded_specs.values.any?(&:missing_extensions?); abort 'private extension not loaded' unless Gem.loaded_specs.fetch('bigdecimal').full_gem_path.start_with?(ENV.fetch('GEM_HOME') + '/'); puts BigDecimal('1.25').to_s"
    result = subprocess.run([str(RUBY), '-e', code], env=env, capture_output=True, timeout=30)
    assert result.returncode == 0 and b'0.125e1' in result.stdout, result.stderr.decode()
    assert b'Ignoring' not in result.stderr
    result = {'schema_version': 1, 'status': 'passed', 'verified': [
        'external_ruby_selected', 'no_embedded_runtime', 'inherited_ruby_options_sanitized',
        'missing_ruby_diagnostic', 'relative_path_rejected', 'incompatible_ruby_rejected',
        'architecture_mismatch_rejected', 'native_library_mismatch_rejected', 'native_extensions_across_darwin_versions',
        'no_silent_fallback', 'failure_before_project_code_or_state']}
    (ROOT / 'test-results/runtime.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Passed external Ruby checks')


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'runtime.json')
