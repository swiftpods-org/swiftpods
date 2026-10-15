"""External CRuby selection shared by build and verification scripts."""
import json
import os
from pathlib import Path
import platform
import subprocess


def clean_environment(original):
    return {key: value for key, value in original.items()
            if not key.startswith(('BUNDLE_', 'GEM_')) and key not in
            ('RUBYOPT', 'RUBYLIB', 'RUBYPATH', 'RUBYHOME', 'RUBYGEMS_GEMDEPS')}


def select_ruby(profile, original=None):
    original = os.environ if original is None else original
    policy = profile['runtime']
    explicit = original.get('SWIFTPODS_RUBY')
    if explicit is not None:
        if not explicit.startswith('/'):
            raise RuntimeError('SWIFTPODS_RUBY must be an absolute executable path')
        candidates = [Path(explicit)]
    else:
        candidates = [Path('/opt/homebrew/opt/ruby@3.4/bin/ruby'), Path('/usr/local/opt/ruby@3.4/bin/ruby')]
        candidates += [Path(part) / 'ruby' for part in original.get('PATH', '').split(':') if part.startswith('/')]
    ruby = next((path.resolve() for path in candidates if path.is_file() and os.access(path, os.X_OK)), None)
    if ruby is None:
        raise RuntimeError('Install ruby@3.4 with Homebrew, or set SWIFTPODS_RUBY explicitly')
    code = "require 'json'; require 'rbconfig'; puts({engine: RUBY_ENGINE, version: RUBY_VERSION, abi: RbConfig::CONFIG.fetch('ruby_version'), architecture: RbConfig::CONFIG.fetch('host_cpu'), platform: RUBY_PLATFORM, library: (RbConfig::CONFIG['ENABLE_SHARED'] == 'yes' ? File.join(RbConfig::CONFIG.fetch('libdir'), RbConfig::CONFIG.fetch('LIBRUBY_SO')) : '')}.to_json)"
    metadata = json.loads(subprocess.check_output([str(ruby), '-e', code], env=clean_environment(original), timeout=30))
    version = lambda value: tuple(int(item) for item in value.split('.'))
    if (metadata['engine'] != 'ruby' or metadata['abi'] != policy['abi'] or
            not version(policy['minimum_version']) <= version(metadata['version']) < version(policy['maximum_version_exclusive'])):
        raise RuntimeError('Requires external CRuby >= ' + policy['minimum_version'] + ', < ' + policy['maximum_version_exclusive'] + '; selected ' + metadata['version'])
    if metadata['architecture'] != platform.machine():
        raise RuntimeError('Ruby architecture must match the SwiftPods build host')
    metadata['path'] = str(ruby)
    return ruby, metadata
