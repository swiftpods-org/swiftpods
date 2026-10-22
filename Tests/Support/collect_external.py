#!/usr/bin/env python3
"""Attach verified external gate artifacts to an existing full evidence archive."""
import argparse
import json
import platform
import sys
import tempfile
import zipfile
from pathlib import Path


def augment(evidence, external, destination):
    from scripts.support.acceptance import external_gates, summarize
    from scripts.support.evidence import collect_external_artifacts, digest, validate
    from scripts.support.reporting import (
        contract_digest,
        source_digest,
        source_revision,
        toolchain_identity,
    )
    destination = destination.absolute()
    if destination.exists():
        raise RuntimeError('Destination already exists; original evidence is preserved')
    index = validate(evidence)
    if index['source_digest'] != source_digest() or index['source_revision'] != source_revision() or index['contract_digest'] != contract_digest():
        raise RuntimeError('Source checkout does not match the full evidence snapshot')
    with zipfile.ZipFile(evidence) as archive:
        files = {name: archive.read(name) for name in archive.namelist() if name != 'index.json'}
    if {name: digest(data) for name, data in files.items()} != index['files']:
        raise RuntimeError('Full evidence archive changed during collection')
    original = json.loads(files['acceptance.json'])
    if original['host'] != {'os': platform.mac_ver()[0], 'architecture': platform.machine()} or original['toolchain'] != toolchain_identity():
        raise RuntimeError('External collection differs from the full run host/toolchain/revision')
    external_bytes = external.read_bytes()
    supplied = external_gates(external)
    gates = dict(original.get('external_gates', {}), **supplied)
    # validate() checked report bytes, identities and the package index. Their
    # executable/runner paths need not survive the original full run.
    content = {entry['report']: json.loads(files['reports/' + entry['report']])
               for entry in original['reports']}
    augmented = summarize(original['reports'], content, original['source_revision'], gates)
    files['external/manifest.json'] = external_bytes
    artifacts = collect_external_artifacts(
        augmented, files, archived_artifacts=index.get('external_artifacts', [])
    )
    retained = {entry['archive_path'] for entry in artifacts}
    for entry in index.get('external_artifacts', []):
        if entry['archive_path'] not in retained:
            files.pop(entry['archive_path'], None)
    original.update(augmented)
    original['external_collection'] = {'manifest_sha256': digest(external_bytes), 'source_checkout_revision': source_revision()}
    files['acceptance.json'] = (json.dumps(original, indent=2) + '\n').encode()
    files['external/collector.py'] = Path(__file__).read_bytes()
    index['stable_acceptance'] = original['stable_acceptance']
    index['external_artifacts'] = artifacts
    index['files'] = {name: digest(data) for name, data in sorted(files.items())}
    if external_gates(external) != supplied or external.read_bytes() != external_bytes:
        raise RuntimeError('Verification inputs changed during collection')
    if source_digest() != index['source_digest'] or contract_digest() != index['contract_digest'] or source_revision() != index['source_revision']:
        raise RuntimeError('Source or contract changed during collection')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix='.external-evidence-', dir=destination.parent, delete=False) as temporary:
        pending = Path(temporary.name)
    try:
        with zipfile.ZipFile(pending, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('index.json', json.dumps(index, indent=2) + '\n')
            for name, data in sorted(files.items()):
                archive.writestr(name, data)
        validate(pending)
        pending.replace(destination)
    finally:
        pending.unlink(missing_ok=True)
    return {'archive': str(destination), 'sha256': digest(destination.read_bytes()),
                      'stable_acceptance': original['stable_acceptance'],
                      'passed_external_gates': [name for name, gate in original['external_gates'].items() if gate['status'] == 'passed']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-checkout', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--external-evidence', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.source_checkout.resolve()))
    print(json.dumps(augment(args.evidence, args.external_evidence, args.destination)))


if __name__ == '__main__':
    main()
