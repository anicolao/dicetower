"""Checks for failures that can hide behind correct sums or count filtering."""
import unittest
import json
import tempfile
from pathlib import Path

from warmstart import metrics
from evaluate_rig import evaluate


class MetricTests(unittest.TestCase):
    def test_explicit_cutoff_scores_validation_at_that_cutoff(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            truth={'id':'a','index':1,'dice':[{'value':1,'box':[0,0,10,10]}]}
            (root/'manifest.json').write_text(json.dumps({'rows':[truth]}))
            path=root/'predictions.json'
            path.write_text(json.dumps({'rows':[{'id':'a','split':'validation','milliseconds':1,
                'predictions':[{'label':'1','score':.6,'box':[0,0,10,10]}]}]}))
            result=evaluate(root,path,.75)
            self.assertEqual(result['cutoff'],.75)
            self.assertEqual(result['validation']['exactValueSets'],0)

    def test_same_sum_does_not_hide_wrong_faces(self):
        truth=[{'id':'a','index':1,'dice':[{'value':2,'box':[0,0,10,10]},{'value':4,'box':[20,0,10,10]}]}]
        pred=[{'id':'a','predictions':[{'label':'3','score':.9,'box':[0,0,10,10]},{'label':'3','score':.9,'box':[20,0,10,10]}]}]
        result=metrics(truth,pred,.5)
        self.assertEqual(result['exactCounts'],1)
        self.assertEqual(result['exactValueSets'],0)
        self.assertEqual(result['truePositiveFaces50'],0)

    def test_extra_die_is_not_truncated_to_expected_count(self):
        truth=[{'id':'a','index':1,'dice':[{'value':2,'box':[0,0,10,10]}]}]
        pred=[{'id':'a','predictions':[{'label':'2','score':.9,'box':[0,0,10,10]},{'label':'2','score':.8,'box':[20,0,10,10]}]}]
        result=metrics(truth,pred,.5)
        self.assertEqual(result['exactCounts'],0)
        self.assertEqual(result['falsePositiveFaces50'],1)

    def test_correct_values_at_wrong_locations_fail_localization(self):
        truth=[{'id':'a','index':1,'dice':[{'value':2,'box':[0,0,10,10]},{'value':4,'box':[20,0,10,10]}]}]
        pred=[{'id':'a','predictions':[{'label':'4','score':.9,'box':[0,0,10,10]},{'label':'2','score':.9,'box':[20,0,10,10]}]}]
        result=metrics(truth,pred,.5)
        self.assertEqual(result['exactValueSets'],1)
        self.assertEqual(result['exactLocalizedScenes'],0)

    def test_empty_scene_penalizes_any_false_detection(self):
        truth=[{'id':'a','index':1,'dice':[]}]
        pred=[{'id':'a','predictions':[{'label':'1','score':.9,'box':[0,0,10,10]}]}]
        self.assertEqual(metrics(truth,pred,.5)['exactValueSets'],0)


if __name__=='__main__':unittest.main()
