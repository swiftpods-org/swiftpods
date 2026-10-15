#!/usr/bin/env python3
"""Install/test/uninstall the generated formula in a unique, keg-only local tap."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid
from integration import ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    args = parser.parse_args()
    if not shutil.which('brew'):
        raise RuntimeError('Homebrew is required for the release formula installation check')
    directory = Path(tempfile.mkdtemp(prefix='homebrew-check-', dir=ROOT / '.build'))
    version = json.loads((args.bundle / 'compatibility.json').read_text())['swiftpods_version']
    release = directory / 'release'
    subprocess.run([sys.executable, str(ROOT / 'scripts/release.py'), '--version', version,
                    '--bundle', str(args.bundle), '--destination', str(release)], check=True)
    metadata = json.loads((release / 'release.json').read_text())
    formula = (release / 'homebrew-tap/Formula/swiftpods.rb').read_text()
    nonce = uuid.uuid4().hex[:12]
    tap = 'swiftpods-validation/local-' + nonce
    formula_name = 'swiftpods-validation-' + nonce
    name = tap + '/' + formula_name
    # A unique keg-only name prevents touching any installed SwiftPods or PATH
    # symlinks. The original payload, install method, wrapper and tests remain.
    formula = formula.replace('class Swiftpods < Formula', 'class SwiftpodsValidation' + nonce.capitalize() + ' < Formula\n  keg_only "Temporary release installation check"')
    for asset in metadata['assets']:
        formula = formula.replace(asset['url'], (release / asset['filename']).as_uri())
    env = {**os.environ, 'HOMEBREW_NO_AUTO_UPDATE': '1', 'HOMEBREW_NO_INSTALL_CLEANUP': '1',
           'XDG_CONFIG_HOME': str(directory / 'config')}
    created, installed = False, False
    try:
        subprocess.run(['brew', 'tap-new', tap], env=env, check=True)
        created = True
        taproot = Path(subprocess.check_output(['brew', '--repository', tap], env=env, text=True).strip())
        (taproot / ('Formula/' + formula_name + '.rb')).write_text(formula)
        # Homebrew 7 refuses short names from untrusted third-party taps.
        # Trust only this formula in an isolated, temporary trust store.
        if subprocess.run(['brew', 'help', 'trust'], env=env, capture_output=True).returncode == 0:
            subprocess.run(['brew', 'trust', '--formula', name], env=env, check=True)
        subprocess.run(['brew', 'install', '--build-from-source', formula_name], env=env, check=True)
        installed = True
        subprocess.run(['brew', 'test', name], env=env, check=True)
        prefix = Path(subprocess.check_output(['brew', '--prefix', name], env=env, text=True).strip())
        selected = {**env, 'SWIFTPODS_BUNDLE': '/nonexistent/old-profile', 'SWIFTPODS_RUBY': '/nonexistent/old-ruby'}
        result = json.loads(subprocess.check_output([str(prefix / 'bin/swiftpods'), 'runtime', 'verify', '--json'], env=selected))
        assert result['runtime_mode'] == 'external' and not (prefix / 'libexec/runtime').exists()
        assert Path(result['ruby']['path']).is_file()
    finally:
        if installed:
            subprocess.run(['brew', 'uninstall', name], env=env, check=True)
        if created:
            subprocess.run(['brew', 'untap', tap], env=env, check=True)
    report = {'schema_version': 1, 'status': 'passed', 'verified': [
        'actual_homebrew_formula_install', 'short_formula_name_after_tap', 'homebrew_formula_test', 'external_ruby_dependency_and_wrapper',
        'inventory_survives_homebrew_metafile_processing', 'explicit_bundle_selection',
        'isolated_keg_only_formula', 'temporary_installation_and_tap_removed'],
        'scope': 'Actual local Homebrew install with a local release URL; no remote publication'}
    (ROOT / 'test-results/homebrew.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Passed actual Homebrew install/test/uninstall')


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'homebrew.json')
