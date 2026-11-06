"""Prepare local, unapproved review candidates from an iOS capture export.

Requires Pillow and OpenCV. The white-face segmentation is a labeling aid for
this rig, not the recognition model. Never writes approved golden masters.
"""
import argparse
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageOps

parser = argparse.ArgumentParser()
parser.add_argument('source', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
if (args.output / 'proposals.json').exists():
    parser.error('Output already contains proposals. Choose a new directory to preserve curation and reviews.')
args.output.mkdir(parents=True, exist_ok=True)
rows = sorted(args.source.glob('*/captures/*/capture.json'),
              key=lambda p: json.loads(p.read_text())['capturedAt'])
manifest = {'schemaVersion': 1, 'coordinateSystem': 'EXIF-normalized image, top-left pixels, xywh',
            'boxDefinition': 'Axis-aligned enclosure of visible upper face; review and adjust before approval.',
            'proposalMethod': 'Rig-specific white-face segmentation plus visual pip inspection; not ML predictions.',
            'captures': []}
for index, source in enumerate(rows):
    metadata = json.loads(source.read_text())
    original = source.parent / 'image.jpg'
    digest = hashlib.sha256(original.read_bytes()).hexdigest()
    if digest != metadata['sha256']:
        raise ValueError(f'Capture hash mismatch: {original}')
    image = ImageOps.exif_transpose(Image.open(original)).convert('RGB')
    w, h = image.size
    target = args.output / metadata['id']
    target.mkdir(exist_ok=True)
    image.save(target / 'image.jpg', quality=95)
    preview = image.copy()
    preview.thumbnail((1200, 1600))
    preview.save(target / 'preview.jpg', quality=90)
    small = image.resize((900, 1200))
    gray = cv2.cvtColor(np.array(small), cv2.COLOR_RGB2GRAY)
    # Interior of this fixed rig, avoiding the bright wooden rim.
    mask = np.zeros_like(gray)
    cv2.rectangle(mask, (53, 187), (678, 1013), 255, -1)
    binary = ((gray > 125) & (mask > 0)).astype('uint8') * 255
    binary = cv2.morphologyEx(binary, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    boxes = []
    for contour in contours:
        area = cv2.contourArea(contour)
        x, y, bw, bh = cv2.boundingRect(contour)
        if area < 700 or bw < 30 or bh < 30:
            continue
        boxes.append([x, y, bw, bh])
    boxes.sort(key=lambda b: (b[1], b[0]))
    dice = []
    for n, (x, y, bw, bh) in enumerate(boxes):
        dice.append({'id': str(n + 1), 'value': None,
                     'box': [round(x*w/900), round(y*h/1200), round(bw*w/900), round(bh*h/1200)],
                     'provenance': 'segmentation proposal; requires visual review'})
    manifest['captures'].append({'id': metadata['id'], 'index': index + 1, 'capturedAt': metadata['capturedAt'],
                                'width': w, 'height': h, 'sourceSHA256': digest,
                                'sourceMetadata': metadata, 'status': 'pending', 'revision': 0,
                                'notes': '', 'dice': dice})
(args.output / 'proposals.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Prepared', len(rows), 'captures:', [(c['index'], len(c['dice'])) for c in manifest['captures']])
