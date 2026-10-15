#!/usr/bin/env python3
"""Ensure the differential comparator preserves unknown fields and flag order."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from integration import canonical_project


class ComparatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / 'project.pbxproj'
        self.document = {'archiveVersion': '1', 'objectVersion': '60', 'rootObject': 'ROOT',
                         'objects': {'ROOT': {'isa': 'PBXProject', 'targets': ['TARGET']},
                                     'TARGET': {'isa': 'PBXNativeTarget', 'name': 'Demo', 'settings': 'SETTINGS'},
                                     'SETTINGS': {'isa': 'XCBuildConfiguration', 'buildSettings': {'OTHER_LDFLAGS': ['-first', '-second']}}}}

    def tearDown(self):
        self.temporary.cleanup()

    def canonical(self, document):
        self.path.write_text(json.dumps(document))
        return canonical_project(self.path)

    def test_only_identifier_renaming_is_ignored(self):
        original = self.canonical(self.document)
        renamed = json.loads(json.dumps(self.document).replace('ROOT', 'ABC123').replace('TARGET', 'DEF456').replace('SETTINGS', '7890AB'))
        self.assertEqual(original, self.canonical(renamed))

    def test_unknown_fields_are_retained(self):
        changed = copy.deepcopy(self.document)
        changed['objects']['TARGET']['future_xcode_field'] = {'nested': ['new', 'value']}
        self.assertNotEqual(self.canonical(self.document), self.canonical(changed))

    def test_linker_flag_order_is_retained(self):
        changed = copy.deepcopy(self.document)
        changed['objects']['SETTINGS']['buildSettings']['OTHER_LDFLAGS'].reverse()
        self.assertNotEqual(self.canonical(self.document), self.canonical(changed))


if __name__ == '__main__':
    unittest.main()
