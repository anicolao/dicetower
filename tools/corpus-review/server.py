"""Local-only capture review. Python 3.9+, no third-party runtime dependencies."""
import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
from pathlib import Path
import threading
from urllib.parse import urlparse

WEB = Path(__file__).parent / 'web'


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    temp.replace(path)


class Corpus:
    def __init__(self, root):
        self.root = root.resolve()
        self.manifest = json.loads((root / 'proposals.json').read_text())
        self.rows = {c['id']: c for c in self.manifest['captures']}
        self.lock = threading.Lock()

    def row(self, ident):
        row = dict(self.rows[ident])
        state = self.root / 'reviews' / f'{ident}.json'
        if state.exists():
            row.update(json.loads(state.read_text()))
        return row

    def all(self):
        return {**self.manifest, 'captures': [self.row(i) for i in self.rows]}

    def save(self, ident, body):
        with self.lock:
            current = self.row(ident)
            if body.get('revision') != current['revision']:
                raise RuntimeError('This capture changed in another tab. Reload before saving.')
            status = body.get('status')
            if status not in ('pending', 'approved', 'flagged'):
                raise ValueError('Invalid review status')
            dice = body.get('dice')
            if not isinstance(dice, list) or len(dice) > 100:
                raise ValueError('Invalid dice list')
            cleaned = []
            for index, die in enumerate(dice):
                value = die.get('value')
                if value is not None and (type(value) is not int or not 1 <= value <= 6):
                    raise ValueError('Each value must be a pip d6 result (1–6)')
                if status == 'approved' and value is None:
                    raise ValueError('Assign every face value before approving')
                box = die.get('box')
                if not isinstance(box, list) or len(box) != 4 or any(type(v) not in (int, float) or not math.isfinite(v) for v in box):
                    raise ValueError('Invalid box')
                x, y, w, h = box
                if min(x, y) < 0 or min(w, h) < 1 or x+w > current['width']+.01 or y+h > current['height']+.01:
                    raise ValueError('Box must fit within the oriented image')
                cleaned.append({'id': str(index+1), 'value': value, 'box': [round(v, 2) for v in box],
                                'provenance': die.get('provenance', 'reviewer correction')})
            notes = body.get('notes', '')
            if not isinstance(notes, str) or len(notes) > 10000:
                raise ValueError('Invalid notes')
            state = {'status': status, 'revision': current['revision']+1, 'dice': cleaned, 'notes': notes,
                     'reviewedAt': datetime.now(timezone.utc).isoformat(), 'reviewer': 'local human review'}
            atomic_json(self.root / 'reviews' / f'{ident}.json', state)
            # Review state is authoritative. Export reads it and never promotes a proposal.
            expected = self.root / 'golden-masters' / ident / 'expected.json'
            if status == 'approved':
                atomic_json(expected, self.golden({**current, **state}))
            elif expected.exists():
                expected.unlink()
            audit = {'captureID': ident, **state}
            with (self.root / 'review-history.jsonl').open('a') as stream:
                stream.write(json.dumps(audit)+'\n')
            return self.row(ident)

    def golden(self, row):
        return {'schemaVersion': 1, 'captureID': row['id'], 'status': 'approved',
                'reviewedAt': row['reviewedAt'], 'revision': row['revision'],
                'sourceSHA256': row['sourceSHA256'], 'image': f"../../{row['id']}/image.jpg",
                'normalizedSHA256': row.get('normalizedSHA256'),
                'sourceArchiveSHA256': self.manifest.get('sourceArchiveSHA256'),
                'coordinateSystem': self.manifest['coordinateSystem'], 'width': row['width'], 'height': row['height'],
                'boxDefinition': self.manifest['boxDefinition'], 'dice': row['dice'],
                'expectedCount': len(row['dice']), 'expectedTotal': sum(d['value'] for d in row['dice']),
                'notes': row['notes'], 'sessionGroup': row.get('sessionGroup', 'rig-2026-11-06'),
                'split': 'unassigned; keep session together until dataset allocation'}


def handler(corpus):
    class Handler(BaseHTTPRequestHandler):
        def send(self, code, data, content_type='application/json'):
            if isinstance(data, (dict, list)):
                data = json.dumps(data).encode()
            self.send_response(code)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store' if content_type == 'application/json' else 'no-cache')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if not self.local_host():
                return self.send(403, {'error': 'Local host required'})
            path = urlparse(self.path).path
            if path == '/api/manifest':
                return self.send(200, corpus.all())
            if path == '/api/approved':
                return self.send(200, [corpus.golden(c) for c in corpus.all()['captures'] if c['status'] == 'approved'])
            parts = path.strip('/').split('/')
            if len(parts) == 3 and parts[0] == 'images' and parts[1] in corpus.rows and parts[2] in ('image.jpg', 'preview.jpg'):
                return self.send(200, (corpus.root / parts[1] / parts[2]).read_bytes(), 'image/jpeg')
            assets = {'/': ('index.html', 'text/html; charset=utf-8'),
                      '/app.js': ('app.js', 'text/javascript; charset=utf-8'), '/style.css': ('style.css', 'text/css; charset=utf-8')}
            if path in assets:
                name, mime = assets[path]
                return self.send(200, (WEB/name).read_bytes(), mime)
            self.send(404, {'error': 'Not found'})

        def do_POST(self):
            # Only the local review page may submit decisions; no permissive CORS.
            if not self.local_host():
                return self.send(403, {'error': 'Local host required'})
            origin = self.headers.get('Origin')
            if origin and origin != f"http://{self.headers.get('Host')}":
                return self.send(403, {'error': 'Cross-origin review denied'})
            if self.headers.get('X-DiceTower-Review') != '1':
                return self.send(403, {'error': 'Missing review header'})
            parts = urlparse(self.path).path.strip('/').split('/')
            if len(parts) != 3 or parts[:2] != ['api', 'captures'] or parts[2] not in corpus.rows:
                return self.send(404, {'error': 'Unknown capture'})
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 200000:
                    raise ValueError('Invalid request size')
                result = corpus.save(parts[2], json.loads(self.rfile.read(size)))
                self.send(200, result)
            except RuntimeError as error:
                self.send(409, {'error': str(error)})
            except (ValueError, TypeError, KeyError) as error:
                self.send(400, {'error': str(error)})

        def local_host(self):
            host = self.headers.get('Host', '').split(':')[0].lower()
            return host in ('localhost', '127.0.0.1')
    return Handler


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--data', type=Path, default=Path('local-data/rig-review'))
    parser.add_argument('--port', type=int, default=8765)
    options = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', options.port), handler(Corpus(options.data)))
    print(f'DiceTower review: http://127.0.0.1:{options.port}', flush=True)
    server.serve_forever()
