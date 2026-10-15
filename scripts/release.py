#!/usr/bin/env python3
"""Prepare release assets, checksums and a Homebrew tap; never publishes them."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def homebrew_formula(version, assets):
    # Select the oldest available build for each architecture. An actual OS
    # guard stays in install; a newer build is never presented as an older one.
    selected = {}
    for asset in assets:
        architecture = asset['architecture']
        if architecture not in selected or tuple(map(int, asset['minimum_macos'].split('.'))) < tuple(map(int, selected[architecture]['minimum_macos'].split('.'))):
            selected[architecture] = asset
    lines = ['class Swiftpods < Formula', '  desc "Dependency manager for Apple platform projects"',
             '  homepage "https://swiftpods.org"', '  version ' + json.dumps(version),
             '  depends_on :macos', '  depends_on "ruby@3.4"', '  skip_clean "libexec"']
    if len(selected) == 1:
        lines += ['  depends_on arch: :' + ('arm64' if 'arm64' in selected else 'x86_64')]
    for architecture, condition in [('arm64', 'on_arm'), ('x86_64', 'on_intel')]:
        if architecture not in selected:
            continue
        asset = selected[architecture]
        lines += ['  ' + condition + ' do', '    url ' + json.dumps(asset['url']),
                  '    sha256 ' + json.dumps(asset['sha256']), '  end']
    floors = {architecture: asset['minimum_macos'] for architecture, asset in selected.items()}
    lines += ['', '  def install', '    minimum = ' + repr(floors).replace("'", '"').replace(': ', ' => ') ,
              '    architecture = Hardware::CPU.arm? ? "arm64" : "x86_64"',
              '    odie "No release for this architecture" unless minimum.key?(architecture)',
              '    odie "Requires macOS #{minimum.fetch(architecture)} or newer" if MacOS.version < minimum.fetch(architecture)',
              '    libexec.install Dir["*"]',
              '    # Prevent Homebrew from moving verified metafiles out of libexec.',
              '    (prefix/"README.md").write (libexec/"README.md").read',
              '    (bin/"swiftpods").write_env_script libexec/"bin/swiftpods",',
              '      SWIFTPODS_RUBY: Formula["ruby@3.4"].opt_bin/"ruby", SWIFTPODS_BUNDLE: libexec',
              '    system bin/"swiftpods", "runtime", "verify", "--json"', '  end', '',
              '  test do', '    assert_match "SwiftPods", shell_output("#{bin}/swiftpods --version")',
              '    system bin/"swiftpods", "runtime", "verify", "--json"', '  end', 'end', '']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--bundle', type=Path, action='append', default=[])
    parser.add_argument('--archive', type=Path, action='append', default=[])
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--development', action='store_true', help='Prepare explicitly unpublished development fixtures from a dirty checkout')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?', args.version):
        parser.error('Explicit release version required, without a leading v')
    if not args.bundle and not args.archive:
        parser.error('At least one --bundle or --archive is required')
    destination = args.destination.absolute()
    destination.mkdir(parents=True, exist_ok=False)
    archives = list(args.archive)
    for index, bundle in enumerate(args.bundle):
        temporary = destination / ('input-' + str(index) + '.zip')
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(bundle.resolve()), str(temporary)], check=True)
        archives.append(temporary)
    assets, seen, source = [], set(), None
    for archive in archives:
        with zipfile.ZipFile(archive) as reader:
            paths = [name for name in reader.namelist() if len(Path(name).parts) == 2 and name.endswith('/compatibility.json')]
            if len(paths) != 1:
                raise RuntimeError('Archive must have exactly one compatibility manifest')
            metadata = json.loads(reader.read(paths[0]))
        if metadata['swiftpods_version'] != args.version or metadata['runtime']['mode'] != 'external':
            raise RuntimeError('Release version/runtime mode differs from package')
        revision = metadata['swiftpods_source']
        from reporting import source_digest
        if revision['files_digest'] != source_digest():
            raise RuntimeError('Package source digest differs from the preparation checkout')
        if not args.development and (revision['worktree_has_changes'] or subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT).strip()):
            raise RuntimeError('Release preparation requires a clean committed revision; use --development only for unpublished fixtures')
        fingerprint = (revision['base_commit'], revision['files_digest'])
        if source is not None and fingerprint != source:
            raise RuntimeError('Release architectures were built from different source snapshots')
        source = fingerprint
        if revision['base_commit'] != subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip():
            raise RuntimeError('Package source revision differs from release preparation checkout')
        if any(name.startswith('runtime/') for name in metadata['files']):
            raise RuntimeError('Embedded Ruby must not be released')
        architecture = metadata['build_host']['architecture']
        minimum = metadata['minimum_macos']
        if architecture not in ('arm64', 'x86_64') or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', minimum):
            raise RuntimeError('Invalid release platform metadata')
        key = architecture, minimum
        if key in seen:
            raise RuntimeError('Duplicate release architecture/OS floor')
        seen.add(key)
        filename = 'swiftpods-' + args.version + '-macos-' + minimum + '-' + architecture + '.zip'
        target = destination / filename
        if archive.parent == destination:
            archive.rename(target)
        else:
            shutil.copy2(archive, target)
        sha256 = hashlib.sha256(target.read_bytes()).hexdigest()
        assets.append({'os': 'macos', 'architecture': architecture, 'minimum_macos': minimum, 'filename': filename,
                       'sha256': sha256, 'url': 'https://github.com/swiftpods-org/swiftpods-release/releases/download/v' + args.version + '/' + filename})
    assets.sort(key=lambda asset: (asset['architecture'], asset['minimum_macos']))
    shutil.copy2(ROOT / 'scripts/install.py', destination / 'install.py')
    release = {'schema_version': 1, 'development': args.development, 'publishable': False, 'source_revision': {'commit': source[0], 'digest': source[1]}, 'version': args.version, 'runtime_mode': 'external', 'assets': assets,
               'installer_sha256': hashlib.sha256((destination / 'install.py').read_bytes()).hexdigest()}
    (destination / 'release.json').write_text(json.dumps(release, indent=2) + '\n')
    checksums = []
    for path in sorted(destination.iterdir()):
        if path.is_file():
            checksums.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name)
    (destination / 'SHA256SUMS').write_text('\n'.join(checksums) + '\n')
    formula = destination / 'homebrew-tap/Formula/swiftpods.rb'
    formula.parent.mkdir(parents=True)
    formula.write_text(homebrew_formula(args.version, assets))
    (formula.parents[1] / 'README.md').write_text('''# SwiftPods Homebrew tap

Install [SwiftPods](https://swiftpods.org), a dependency manager for Apple
platform projects, with Homebrew.

## Installation

```sh
brew tap swiftpods-org/release https://github.com/swiftpods-org/swiftpods-release.git
brew trust --formula swiftpods-org/release/swiftpods
brew install swiftpods
```

On Homebrew versions without `brew trust`, omit that step. Ruby is installed as
a separate Homebrew dependency.

## Upgrade

```sh
brew upgrade swiftpods
```

[Website](https://swiftpods.org) ·
[Project](https://github.com/swiftpods-org/swiftpods-code)
''')
    print('Prepared', destination)
    print('Manifest SHA-256:', hashlib.sha256((destination / 'release.json').read_bytes()).hexdigest())
    print('Installer SHA-256:', release['installer_sha256'])


if __name__ == '__main__':
    main()
