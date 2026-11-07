"""Read-only local inspection of frozen test predictions and approved truth."""
import argparse
import hashlib
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
from urllib.parse import urlparse

from server import Corpus, WEB, handler, atomic_json


def overlap(a, b):
    x, y = max(a[0], b[0]), max(a[1], b[1])
    right, bottom = min(a[0]+a[2], b[0]+b[2]), min(a[1]+a[3], b[1]+b[3])
    inter = max(0, right-x)*max(0, bottom-y)
    union = a[2]*a[3]+b[2]*b[3]-inter
    return inter/union if union > 0 else 0


def associate(dice, predictions):
    """Display associations ignore value, so misclassified faces stay visible.

    Match highest-confidence predictions first, as NMS/scoring does. These
    associations explain a photo; frozen metrics remain the evaluation authority.
    """
    used = set()
    matches = []
    extras = []
    for index in sorted(range(len(predictions)), key=lambda i: -predictions[i]['score']):
        pred = predictions[index]
        score, target = max(((overlap(d['box'], pred['box']), i) for i, d in enumerate(dice) if i not in used), default=(0, -1))
        if score >= .5:
            used.add(target)
            matches.append({'truthIndex': target, 'predictionIndex': index, 'iou': score,
                            'correctValue': dice[target]['value'] == int(pred['label'])})
        else:
            extras.append(index)
    return {'matches': matches, 'extraPredictions': extras,
            'missedTruth': [i for i in range(len(dice)) if i not in used]}


def load_results(root):
    load = lambda name: json.loads((root/name).read_text())
    selection = load('selection.json')
    manifest = load('manifest.json')
    if hashlib.sha256((root/'manifest.json').read_bytes()).hexdigest() != selection['manifestSHA256']:
        raise ValueError('Frozen manifest hash mismatch')
    audit = load('truth-audit.json') if (root/'truth-audit.json').exists() else None
    if audit:
        if audit['baseManifestSHA256'] != selection['manifestSHA256']:
            raise ValueError('Label audit does not refer to the frozen dataset')
        audited = root/audit['manifest']
        if hashlib.sha256(audited.read_bytes()).hexdigest() != audit['manifestSHA256']:
            raise ValueError('Audited manifest hash mismatch')
        manifest = json.loads(audited.read_text())
    truth = {row['id']: row for row in manifest['rows'] if row['split'] == 'test'}
    models = []
    for ident, title, filename, cutoff in [
        ('fine', 'Fine-tuned model', 'selected-native-test', selection['confidenceThreshold']),
        ('baseline', 'Existing model', 'baseline-native-test', selection['baselineConfidenceThreshold'])
    ]:
        predictions = load(filename+'.json')['rows']
        metrics = load(filename+(audit['metricsSuffix'] if audit else '')+'-metrics.json')
        assert metrics['cutoff'] == cutoff
        assert {p['id'] for p in predictions} == set(truth)
        per_scene = {row['id']: row for row in metrics['test']['perScene']}
        captures = []
        for result in predictions:
            row = truth[result['id']]
            retained = [p for p in result['predictions'] if p['score'] >= cutoff]
            captures.append({'id': row['id'], 'index': row['index'], 'width': row['width'], 'height': row['height'],
                             'transform': row['transform'], 'dice': row['dice'], 'metrics': per_scene[row['id']],
                             'predictions': retained, 'suppressed': [p for p in result['predictions'] if p['score'] < cutoff],
                             **associate(row['dice'], retained)})
        models.append({'id': ident, 'title': title, 'cutoff': cutoff, 'summary': metrics['test'], 'captures': captures})
    return {'models': models, 'frozenAt': selection['frozenAt'], 'nmsIoU': selection['nmsIoU'],
            'truthVersion': audit['version'] if audit else 1,
            'labelFindings': load('review-findings.json') if (root/'review-findings.json').exists() else {},
            'description': 'Frozen native Vision results. Green = approved truth; red = model. No new inference or threshold tuning.'}


def results_handler(corpus, results, experiment=None):
    base = handler(corpus)
    class ResultsHandler(base):
        def do_GET(self):
            if not self.local_host():
                return self.send(403, {'error': 'Local host required'})
            path = urlparse(self.path).path
            if path == '/api/results':
                notes = {}
                if experiment:
                    for file in (experiment/'review-notes').glob('*.json'):
                        notes[file.stem] = json.loads(file.read_text())
                return self.send(200, {**results, 'reviewNotes': notes})
            assets = {'/': ('results.html', 'text/html; charset=utf-8'),
                      '/results.js': ('results.js', 'text/javascript; charset=utf-8'),
                      '/results.css': ('results.css', 'text/css; charset=utf-8')}
            if path in assets:
                name, mime = assets[path]
                return self.send(200, (WEB/name).read_bytes(), mime)
            if path.startswith('/images/'):
                return super().do_GET()
            return self.send(404, {'error': 'Not found'})

        def do_POST(self):
            path = urlparse(self.path).path
            ident = path.removeprefix('/api/review-notes/')
            ids = {c['id'] for c in results['models'][0]['captures']}
            if not experiment or not path.startswith('/api/review-notes/') or ident not in ids:
                return self.send(405, {'error': 'Frozen labels and metrics are read-only'})
            if not self.local_host() or self.headers.get('X-DiceTower-Review') != '1':
                return self.send(403, {'error': 'Local review required'})
            origin = self.headers.get('Origin')
            if origin and origin != f"http://{self.headers.get('Host')}":
                return self.send(403, {'error': 'Cross-origin review denied'})
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 20000:
                    raise ValueError('Invalid request size')
                note = json.loads(self.rfile.read(size)).get('note')
                if not isinstance(note, str) or len(note) > 10000:
                    raise ValueError('Invalid note')
                record = {'note': note, 'savedAt': datetime.now(timezone.utc).isoformat()}
                with corpus.lock:
                    atomic_json(experiment/'review-notes'/f'{ident}.json', record)
                self.send(200, record)
            except (ValueError, TypeError) as error:
                self.send(400, {'error': str(error)})
    return ResultsHandler


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--data', type=Path, default=Path('local-data/rig-review'))
    p.add_argument('--experiment', type=Path, default=Path('local-models/rig-2026-11-06'))
    p.add_argument('--port', type=int, default=8767)
    args = p.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), results_handler(Corpus(args.data), load_results(args.experiment), args.experiment))
    print(f'DiceTower test review: http://127.0.0.1:{args.port}', flush=True)
    server.serve_forever()
