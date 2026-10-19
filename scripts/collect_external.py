#!/usr/bin/env python3
"""Attach verified external gate artifacts to an existing full evidence archive."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import sys
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-checkout', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--external-evidence', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    destination = args.destination.absolute()
    if destination.exists(): parser.error('Destination already exists; original evidence is preserved')
    source = args.source_checkout.resolve()
    sys.path.insert(0, str(source / 'scripts'))
    from acceptance import collect
    from evidence import validate, digest
    from reporting import source_digest, source_revision, contract_digest, toolchain_identity
    index = validate(args.evidence)
    if index['source_digest'] != source_digest() or index['source_revision'] != source_revision() or index['contract_digest'] != contract_digest():
        raise RuntimeError('Source checkout does not match the full evidence snapshot')
    with zipfile.ZipFile(args.evidence) as archive:
        files = {name: archive.read(name) for name in archive.namelist() if name != 'index.json'}
    original = json.loads(files['acceptance.json'])
    names = [entry['report'] for entry in original['reports']]
    external_bytes = args.external_evidence.read_bytes()
    augmented = collect(names, args.external_evidence)
    if augmented['reports'] != original['reports']:
        raise RuntimeError('Full acceptance reports changed before external collection')
    if augmented['source_revision'] != original['source_revision'] or original['host'] != {'os': platform.mac_ver()[0], 'architecture': platform.machine()} or original['toolchain'] != toolchain_identity():
        raise RuntimeError('External collection differs from the full run host/toolchain/revision')
    expected_gates = json.loads(json.dumps(augmented['external_gates']))
    files['external/manifest.json'] = external_bytes
    for name, gate in augmented['external_gates'].items():
        if gate['status'] != 'passed': continue
        for number, item in enumerate(gate['evidence']):
            path = Path(item['path'])
            data = path.read_bytes()
            if digest(data) != item['sha256']:
                raise RuntimeError('External evidence changed during collection: ' + str(path))
            archive_path = 'external/' + name + '/' + str(number) + '-' + path.name
            files[archive_path] = data
            item['archive_path'] = archive_path
    original.update(augmented)
    original['external_collection'] = {'manifest_sha256': digest(external_bytes), 'source_checkout_revision': source_revision()}
    files['acceptance.json'] = (json.dumps(original, indent=2) + '\n').encode()
    files['external/collector.py'] = Path(__file__).read_bytes()
    index['stable_acceptance'] = original['stable_acceptance']
    index['files'] = {name: digest(data) for name, data in sorted(files.items())}
    # Recheck current binaries, source, reports and the supplied artifact hashes.
    rechecked = collect(names, args.external_evidence)
    if rechecked['reports'] != augmented['reports'] or rechecked['source_revision'] != augmented['source_revision'] or rechecked['external_gates'] != expected_gates or args.external_evidence.read_bytes() != external_bytes:
        raise RuntimeError('Verification inputs changed during collection')
    if source_digest() != index['source_digest'] or contract_digest() != index['contract_digest']:
        raise RuntimeError('Source or contract changed during collection')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix='.external-evidence-', dir=destination.parent, delete=False) as temporary:
        pending = Path(temporary.name)
    try:
        with zipfile.ZipFile(pending, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('index.json', json.dumps(index, indent=2) + '\n')
            for name, data in sorted(files.items()): archive.writestr(name, data)
        validate(pending)
        pending.replace(destination)
    finally:
        pending.unlink(missing_ok=True)
    print(json.dumps({'archive': str(destination), 'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
                      'stable_acceptance': original['stable_acceptance'],
                      'passed_external_gates': [name for name, gate in original['external_gates'].items() if gate['status'] == 'passed']}))


if __name__ == '__main__': main()
