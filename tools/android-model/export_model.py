#!/usr/bin/env python3
"""Export the shipped Core ML weights to ONNX without retraining, then verify parity."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time
import platform
import shutil

import numpy as np
import onnx
import onnxruntime as ort
import torch
from PIL import Image
from torch import nn
from torchvision.ops import nms

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/ml'))
from warmstart import ExistingDetector, decode

SOURCE_SHA = '416678e1d7e4e7f7b867e1513fce072744a49c6feca3cdfb90b12417be8091b9'

class ExportDetector(nn.Module):
    def __init__(self, source):
        super().__init__()
        self.detector = ExistingDetector(source)
        self.register_buffer('anchors', self.detector.anchors.clone())
    def forward(self, image):
        return decode(self.detector(image), self.anchors)

def detections(boxes, scores):
    boxes = torch.as_tensor(boxes)
    scores, labels = torch.as_tensor(scores).max(-1)
    keep = scores >= .75
    boxes, scores, labels = boxes[keep], scores[keep], labels[keep]
    xyxy = torch.cat((boxes[:, :2] - boxes[:, 2:] / 2, boxes[:, :2] + boxes[:, 2:] / 2), -1)
    indices = nms(xyxy, scores, .30).tolist()
    return [{'value':int(labels[i])+1,'score':float(scores[i]),'box':boxes[i].tolist()} for i in indices]

def box_iou(a,b):
    ax,ay,aw,ah=a;bx,by,bw,bh=b
    overlap=max(0,min(ax+aw/2,bx+bw/2)-max(ax-aw/2,bx-bw/2))*max(0,min(ay+ah/2,by+bh/2)-max(ay-ah/2,by-bh/2))
    return overlap/(aw*ah+bw*bh-overlap) if aw*ah+bw*bh>overlap else 0

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--source',type=Path,default=ROOT/'local-models/rig-2026-11-06/DiceTowerD6.mlmodel')
    p.add_argument('--corpus',type=Path,default=ROOT/'local-models/session-772337F9')
    p.add_argument('--output',type=Path,default=ROOT/'apps/android/app/src/main/assets')
    p.add_argument('--report',type=Path,default=ROOT/'local-models/android/parity.json')
    p.add_argument('--fixture-index',type=int,help='Also copy this approved held-out capture into ignored Android test assets')
    args=p.parse_args()
    if hashlib.sha256(args.source.read_bytes()).hexdigest()!=SOURCE_SHA:
        raise RuntimeError('Source is not the selected shipping model. Do not substitute a later candidate.')
    torch.set_num_threads(4)
    model=ExportDetector(args.source).eval()
    args.output.mkdir(parents=True,exist_ok=True)
    output=args.output/'DiceTowerD6.onnx'
    with torch.no_grad():
        torch.onnx.export(model,torch.zeros(1,3,416,416),str(output),input_names=['image'],output_names=['boxes','scores'],opset_version=17,dynamo=False)
    onnx.checker.check_model(onnx.load(str(output)))
    session=ort.InferenceSession(str(output),providers=['CPUExecutionProvider'])
    rows=json.loads((args.corpus/'manifest.json').read_text())['rows']
    rows=[r for r in rows if r['split'] in ['validation','test']]
    if not rows: raise RuntimeError('No held-out parity images found')
    native=None
    if platform.system()=='Darwin':
        import coremltools as ct
        native=ct.models.MLModel(model.detector.spec.pipeline.models[0],compute_units=ct.ComputeUnit.CPU_ONLY)
    evidence=[]
    for row in rows:
        path=args.corpus/'data'/row['split']/f"{row['id']}-r0.png"
        image=Image.open(path).convert('RGB')
        x=np.asarray(image,dtype=np.float32).transpose(2,0,1)[None]/255
        with torch.no_grad(): tboxes,tscores=model(torch.from_numpy(x))
        start=time.perf_counter(); boxes,scores=session.run(None,{'image':x}); ms=(time.perf_counter()-start)*1000
        expected=detections(tboxes[0],tscores[0]); actual=detections(boxes[0],scores[0])
        score_error=float(np.abs(scores-tscores.numpy()).max())
        retained=tscores.numpy().max(-1)>=.01
        box_error=float(np.abs(boxes[retained]-tboxes.numpy()[retained]).max()) if retained.any() else 0
        if score_error>.0001 or box_error>.001: raise RuntimeError(f'ONNX/PyTorch parity failed: {row["id"]}')
        native_error=None
        native_retained_error=None
        native_min_iou=None
        if native is not None:
            raw=native.predict({'imagePath':image})
            native_error=float(np.abs(scores[0]-raw['raw_confidence']).max())
            native_faces=detections(raw['raw_coordinates'],raw['raw_confidence'])
            retained_native=(raw['raw_confidence'].max(-1)>=.75)|(scores[0].max(-1)>=.75)
            native_retained_error=float(np.abs(scores[0][retained_native]-raw['raw_confidence'][retained_native]).max()) if retained_native.any() else 0
            if native_retained_error>.003 or sorted(d['value'] for d in native_faces)!=sorted(d['value'] for d in actual):
                raise RuntimeError(f'Core ML/ONNX detection parity failed: {row["id"]}; max score error={native_error}; native={native_faces}; onnx={actual}')
            remaining=list(actual);overlaps=[]
            for expected_face in native_faces:
                candidates=[(box_iou(expected_face['box'],face['box']),i) for i,face in enumerate(remaining) if face['value']==expected_face['value']]
                overlap,index=max(candidates,default=(0,None));overlaps.append(overlap)
                if index is not None:remaining.pop(index)
            native_min_iou=min(overlaps,default=1.0)
            if native_min_iou<.99:raise RuntimeError(f'Core ML/ONNX retained box parity failed: {row["id"]}')
            expected=native_faces
        if sorted(d['value'] for d in expected)!=sorted(d['value'] for d in actual):raise RuntimeError('Detection conclusions changed')
        evidence.append({'id':row['id'],'split':row['split'],'expectedValues':sorted(d['value'] for d in expected),'values':sorted(d['value'] for d in actual),'scoreMaxError':score_error,'retainedBoxMaxError':box_error,'coreMLScoreMaxError':native_error,'coreMLRetainedScoreMaxError':native_retained_error,'coreMLRetainedBoxMinIoU':native_min_iou,'cpuInferenceMs':ms})
    model_sha=hashlib.sha256(output.read_bytes()).hexdigest()
    info={'schemaVersion':1,'sourceModelSHA256':SOURCE_SHA,'onnxSHA256':model_sha,'input':'RGB float32 NCHW [1,3,416,416], divided by255','outputs':'boxes [1,2535,4] center xywh normalized top-left; joint scores [1,2535,6]','confidenceThreshold':.75,'nmsIoU':.30,'classAgnosticNMS':True,'opset':17,'noRetraining':True}
    (args.output/'model-info.json').write_text(json.dumps(info,indent=2)+'\n')
    report={**info,'coreMLCompared':native is not None,'runtime':ort.__version__,'images':len(evidence),'exactDetectionValueParity':True,'rows':evidence}
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,indent=2)+'\n')
    if args.fixture_index is not None:
        row=next((r for r in rows if r['index']==args.fixture_index and r['status']=='approved'),None)
        if row is None:raise RuntimeError('Fixture must be an approved validation/test capture')
        fixture=ROOT/'apps/android/app/src/androidTest/assets'
        fixture.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(args.corpus/'data'/row['split']/f"{row['id']}-r0.png",fixture/'golden.png')
        (fixture/'golden.json').write_text(json.dumps({'values':sorted(d['value'] for d in row['dice'])},indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='rows'},indent=2))
if __name__=='__main__':main()
