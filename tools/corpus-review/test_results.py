import unittest

from results import associate


class AssociationTests(unittest.TestCase):
    def test_wrong_value_matches_location_and_duplicate_is_extra(self):
        truth = [{'value': 3, 'box': [0, 0, 10, 10]}]
        predictions = [{'label': '4', 'score': .95, 'box': [0, 0, 10, 10]},
                       {'label': '4', 'score': .8, 'box': [0, 0, 10, 10]}]
        result = associate(truth, predictions)
        self.assertEqual(result['extraPredictions'], [1])
        self.assertFalse(result['matches'][0]['correctValue'])
        self.assertEqual(result['missedTruth'], [])

    def test_no_overlap_is_both_missed_face_and_extra_prediction(self):
        result = associate([{'value': 1, 'box': [0, 0, 10, 10]}],
                           [{'label': '1', 'score': .9, 'box': [100, 100, 10, 10]}])
        self.assertEqual(result['extraPredictions'], [0])
        self.assertEqual(result['missedTruth'], [0])


if __name__ == '__main__':
    unittest.main()
