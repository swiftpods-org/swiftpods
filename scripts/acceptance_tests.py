#!/usr/bin/env python3
"""Exercise missing, stale, changed and incomplete acceptance evidence."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import acceptance
from reporting import ROOT, execute


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'test-results').mkdir(); (self.root / 'Profiles').mkdir()
        self.binary = self.root / 'swiftpods'; self.binary.write_bytes(b'fixture executable')
        self.report = {'status': 'passed', 'source_digest': 'source', 'contract_digest': 'contract',
                       'host': {'architecture': 'arm64'}, 'toolchain': {'swift': 'fixture'},
                       'executable': {'path': str(self.binary), 'sha256': hashlib.sha256(self.binary.read_bytes()).hexdigest()},
                       'source_revision': {'commit': 'fixed', 'dirty': False}, 'test_count': 1, 'verified_cases': ['method']}
        self.names = ['native-units.json', 'fixture.json']
        self.revision = self.report['source_revision']
        for name in self.names: self.write(name, self.report)
        registry = {'requirements': [{'id': 'T-001', 'reports': self.names}], 'external_gates': ['physical_devices'],
                    'api': {'methods': {'method': {'report': 'fixture.json'}}}, 'coverage_policy': 'bounded fixture'}
        (self.root / 'Profiles/contract.json').write_text(json.dumps(registry))
        patches = [patch.object(acceptance, 'ROOT', self.root), patch.object(acceptance, 'source_digest', return_value='source'), patch.object(acceptance, 'contract_digest', return_value='contract'), patch.object(acceptance, 'source_revision', side_effect=lambda: self.revision)]
        for replacement in patches:
            replacement.start(); self.addCleanup(replacement.stop)

    def write(self, name, value):
        (self.root / 'test-results' / name).write_text(json.dumps(value))

    def testPassingLocalReportsLeaveExternalGateUnverified(self):
        result = acceptance.collect(self.names)
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(result['stable_acceptance'], 'not_established')
        self.assertEqual(result['external_gates']['physical_devices']['status'], 'unverified')

    def testMissingAndFailedReportsAreRejected(self):
        for report in [dict(self.report, status='skipped'), dict(self.report, status='failed'), dict(self.report, status='running')]:
            self.write('fixture.json', report)
            with self.assertRaises(RuntimeError): acceptance.collect(self.names)
        (self.root / 'test-results/fixture.json').unlink()
        with self.assertRaises(RuntimeError): acceptance.collect(self.names)

    def testStaleContractSourceToolchainAndBinaryAreRejected(self):
        for key, value in [('contract_digest', 'old'), ('source_digest', 'old'), ('toolchain', {'swift': 'another'})]:
            self.write('fixture.json', dict(self.report, **{key: value}))
            with self.assertRaises(RuntimeError): acceptance.collect(self.names)
        self.write('fixture.json', self.report)
        self.binary.write_bytes(b'replaced executable')
        with self.assertRaises(RuntimeError): acceptance.collect(self.names)

    def testSuppliedExternalEvidenceMustMatchItsHash(self):
        evidence = self.root / 'device.log'; evidence.write_text('fixture')
        supplied = self.root / 'external.json'
        supplied.write_text(json.dumps({'source_digest': 'source', 'contract_digest': 'contract', 'gates': {'physical_devices': {'status': 'passed', 'evidence': [{'path': str(evidence), 'sha256': '0' * 64}]}}}))
        with self.assertRaises(RuntimeError): acceptance.collect(self.names, supplied)

    def testAnotherRevisionOrNewDirtyStateIsRejected(self):
        self.revision = {'commit': 'another', 'dirty': False}
        with self.assertRaises(RuntimeError): acceptance.collect(self.names)
        self.revision = {'commit': 'fixed', 'dirty': True}
        with self.assertRaises(RuntimeError): acceptance.collect(self.names)

    def testDirtyRevisionCannotBecomeStableEvenWithVerifiedExternalGate(self):
        self.revision = {'commit': 'fixed', 'dirty': True}
        for name in self.names: self.write(name, dict(self.report, source_revision={'commit': 'fixed', 'dirty': True}))
        evidence = self.root / 'device.log'; evidence.write_text('fixture')
        supplied = self.root / 'external.json'
        supplied.write_text(json.dumps({'source_digest': 'source', 'contract_digest': 'contract', 'gates': {'physical_devices': {'status': 'passed', 'evidence': [{'path': str(evidence), 'sha256': hashlib.sha256(evidence.read_bytes()).hexdigest()}]}}}))
        self.assertEqual(acceptance.collect(self.names, supplied)['stable_acceptance'], 'not_established')


def main():
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(EvidenceTests))
    if not result.wasSuccessful(): raise RuntimeError('Acceptance evidence tests failed')
    (ROOT / 'test-results/native-acceptance-harness.json').write_text(json.dumps({'status': 'passed', 'test_count': result.testsRun, 'verified': ['missing, failed and skipped evidence rejected', 'stale source, contract and toolchain rejected', 'replaced executable rejected', 'external artifact hash checked', 'unverified external gates and dirty revisions cannot establish stable acceptance']}, indent=2) + '\n')


if __name__ == '__main__': execute(main, 'native-acceptance-harness.json')
