"""Freeze approved rig labels, group similar arrangements, split before augmentation."""
import argparse
from collections import Counter
import hashlib
import itertools
import json
import math
from pathlib import Path
import random

from PIL import Image, ImageEnhance


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(source, output):
    if (output/'manifest.json').exists():
        raise ValueError('Experiment already prepared; choose a new output directory')
    output.mkdir(parents=True, exist_ok=True)
    proposal = json.loads((source/'proposals.json').read_text())
    rows = []
    for row in proposal['captures']:
        review_path = source/'reviews'/f"{row['id']}.json"
        review = json.loads(review_path.read_text())
        if review['status'] != 'approved':
            continue
        row = {**row, **review}
        image_path = source/row['id']/'image.jpg'
        if digest(image_path) != row['normalizedSHA256']:
            raise ValueError(f"Image changed after labeling: {row['id']}")
        row['reviewSHA256'] = digest(review_path)
        row['imagePath'] = str(image_path.resolve())
        row['source'] = 'approved-iphone-rig'
        row['annotations'] = [{'label': str(d['value']), 'coordinates': {
            'x': d['box'][0]+d['box'][2]/2, 'y': d['box'][1]+d['box'][3]/2,
            'width': d['box'][2], 'height': d['box'][3]}} for d in row['dice']]
        rows.append(row)
    # Conservative arrangement grouping, independent of face values. This is not
    # proof of session independence: every image still belongs to one session.
    parent = list(range(len(rows)))
    def find(i):
        while parent[i] != i:
            i = parent[i]
        return i
    close_pairs = []
    for i, a in enumerate(rows):
        if not a['dice'] or len(a['dice']) > 7:
            continue
        for j in range(i+1, len(rows)):
            b = rows[j]
            if len(a['dice']) != len(b['dice']):
                continue
            def points(c):
                return [((d['box'][0]+d['box'][2]/2)/c['width']*900,
                         (d['box'][1]+d['box'][3]/2)/c['height']*1200) for d in c['dice']]
            pa, pb = points(a), points(b)
            distance = min(sum(math.dist(pa[k], pb[v]) for k, v in enumerate(p))
                           for p in itertools.permutations(range(len(pb))))/len(pb)
            if distance < 75 or a['normalizedSHA256'] == b['normalizedSHA256']:
                parent[find(j)] = find(i)
                close_pairs.append({'captures': [a['index'], b['index']], 'meanCenterDistance900': distance})
    groups = {}
    for i, row in enumerate(rows):
        groups.setdefault(find(i), []).append(row)
    negative_groups = [g for g in groups.values() if any(not r['dice'] for r in g)]
    nonempty_groups = [g for g in groups.values() if g not in negative_groups]
    rng = random.Random(20261106)
    total = Counter(a['label'] for r in rows for a in r['annotations'])
    best = None
    # Deterministic search balances scene counts, face values, and lower-light
    # captures. Labels influence stratification only, never model selection.
    for _ in range(10000):
        shuffled = rng.sample(nonempty_groups, len(nonempty_groups))
        candidate = {'train': [r for g in negative_groups for r in g], 'validation': [], 'test': []}
        for group in shuffled:
            split = max(candidate, key=lambda s: ({'train':30,'validation':10,'test':10}[s]-len(candidate[s]), s=='train'))
            candidate[split].extend(group)
        score = 0
        for split, rs in candidate.items():
            target = {'train':30,'validation':10,'test':10}[split]
            hist = Counter(a['label'] for r in rs for a in r['annotations'])
            score += abs(len(rs)-target)*100
            score += sum(abs(hist[v]-total[v]*target/50) for v in total)
            score += abs(sum(r['index']>=39 for r in rs)-12*target/50)*2
            if any(hist[v] == 0 for v in total): score += 10000
        if best is None or score < best[0]:
            best = (score, candidate)
    for split, rs in best[1].items():
        for row in rs:
            row['split'] = split
    for group in groups.values():
        key = 'arrangement-'+'-'.join(str(r['index']) for r in group)
        for row in group: row['group'] = key

    annotations = {split: [] for split in best[1]}
    for row in rows:
        image = Image.open(row['imagePath']).convert('RGB')
        # Fixed geometry chosen from tray edges, not ground-truth die positions.
        x0,y0,x1,y1 = [round(v*row['width']/900) for v in (20,140,700,1080)]
        crop = image.crop((x0,y0,x1,y1))
        scale = min(416/crop.width, 416/crop.height)
        w,h = round(crop.width*scale), round(crop.height*scale)
        ox,oy = (416-w)//2,(416-h)//2
        sx,sy = w/crop.width,h/crop.height
        canvas = Image.new('RGB',(416,416));canvas.paste(crop.resize((w,h),Image.Resampling.LANCZOS),(ox,oy))
        row['transform'] = dict(size=416,width=w,height=h,offsetX=ox,offsetY=oy,scaleX=sx,scaleY=sy,cropX=x0,cropY=y0,cropWidth=crop.width,cropHeight=crop.height)
        split = row['split'];folder=output/'data'/split;folder.mkdir(parents=True,exist_ok=True)
        for angle in ([0,90,180,270] if split=='train' else [0]):
            anns=[]
            for ann in row['annotations']:
                c=ann['coordinates'];x=(c['x']-x0)*sx+ox;y=(c['y']-y0)*sy+oy;bw=c['width']*sx;bh=c['height']*sy
                for _ in range(angle//90):x,y,bw,bh=y,416-x,bh,bw
                anns.append({'label':ann['label'],'coordinates':dict(x=x,y=y,width=bw,height=bh)})
            filename=f"{row['id']}-r{angle}.png"
            canvas.rotate(angle).save(folder/filename)
            annotations[split].append({'image':filename,'annotations':anns})
        # Ground-truth crops are classifier training data only. End-to-end
        # evaluation must use detector-predicted boxes, never these crops.
        for i,die in enumerate(row['dice']):
            x,y,bw,bh=die['box'];pad=max(bw,bh)*.08
            face=image.crop((x-pad,y-pad,x+bw+pad,y+bh+pad)).resize((128,128),Image.Resampling.LANCZOS)
            class_folder=output/'faces'/split/str(die['value']);class_folder.mkdir(parents=True,exist_ok=True)
            for angle in ([0,90,180,270] if split=='train' else [0]):
                face.rotate(angle).save(class_folder/f"{row['id']}-{i}-r{angle}.png")
    for split, anns in annotations.items():
        folder=output/'data'/split
        (folder/'annotations.json').write_text(json.dumps(anns,indent=2)+'\n')
        one=output/'single'/ 'data'/split;one.mkdir(parents=True,exist_ok=True)
        data=json.loads(json.dumps(anns))
        for row in data:
            for ann in row['annotations']:ann['label']='die'
            (one/row['image']).symlink_to((folder/row['image']).resolve())
        (one/'annotations.json').write_text(json.dumps(data,indent=2)+'\n')
    manifest={'seed':20261106,'sourceArchiveSHA256':proposal['sourceArchiveSHA256'],
              'splitPolicy':'30/10/10 scenes; conservative arrangement groups stay together; empty tray in train; balance face values and lower light with deterministic search',
              'limitations':'All captures from one session. Test measures within-session generalization only. One empty scene cannot measure empty-tray false-positive rate.',
              'preprocessing':'Fixed normalized tray crop (20,140)-(700,1080) in 900x1200 coordinates; RGB aspect-fit to416 with black padding; train-only quarter rotations.',
              'closePairs':close_pairs,'rows':rows}
    (output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    for split, rs in best[1].items():
        print(split,len(rs),'scenes',sum(len(r['dice']) for r in rs),'dice',dict(Counter(a['label'] for r in rs for a in r['annotations'])), 'indices',sorted(r['index'] for r in rs))


if __name__ == '__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,default=Path('local-data/rig-review'));p.add_argument('--output',type=Path,default=Path('local-models/rig-2026-11-06'))
    a=p.parse_args();prepare(a.source,a.output)
