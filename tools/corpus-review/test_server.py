import json
from pathlib import Path
import tempfile
import unittest

from server import Corpus


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.capture = {'id': 'sample', 'width': 100, 'height': 100, 'revision': 0, 'status': 'pending',
                        'sourceSHA256': 'source', 'dice': [], 'notes': ''}
        (self.root/'proposals.json').write_text(json.dumps({'captures': [self.capture],
            'coordinateSystem': 'top-left xywh', 'boxDefinition': 'upper face'}))
        self.corpus = Corpus(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_approval_persists_and_demotion_withdraws_master(self):
        body = {**self.capture, 'status': 'approved', 'dice': [{'value': 6, 'box': [10,20,30,40]}]}
        saved = self.corpus.save('sample', body)
        master = self.root/'golden-masters/sample/expected.json'
        self.assertEqual(json.loads(master.read_text())['expectedTotal'], 6)
        self.assertEqual(Corpus(self.root).row('sample')['status'], 'approved')
        self.corpus.save('sample', {**saved, 'status': 'pending'})
        self.assertFalse(master.exists())

    def test_rejects_stale_revision_without_overwrite(self):
        self.corpus.save('sample', self.capture)
        with self.assertRaises(RuntimeError):
            self.corpus.save('sample', {**self.capture, 'status': 'approved'})
        self.assertEqual(self.corpus.row('sample')['revision'], 1)

    def test_incomplete_values_and_out_of_bounds_boxes_cannot_be_approved(self):
        for die in [{'value': None, 'box': [1,1,5,5]}, {'value': 7, 'box': [1,1,5,5]},
                    {'value': 1, 'box': [90,90,20,20]}, {'value': 1, 'box': [0,0,float('nan'),5]}]:
            with self.assertRaises(ValueError):
                self.corpus.save('sample', {**self.capture, 'status': 'approved', 'dice': [die]})
        self.assertEqual(self.corpus.row('sample')['revision'], 0)

    def test_empty_scene_is_valid_negative_master(self):
        row = self.corpus.save('sample', {**self.capture, 'status': 'approved'})
        self.assertEqual(self.corpus.golden(row)['expectedCount'], 0)
        self.assertEqual(self.corpus.golden(row)['expectedTotal'], 0)


if __name__ == '__main__':
    unittest.main()
