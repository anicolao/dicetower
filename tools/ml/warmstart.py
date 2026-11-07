"""Fine-tune the existing Create ML TinyYOLO weights without changing its graph.

Reads the exported Core ML network, verifies PyTorch/Core ML inference parity,
fine-tunes existing convolution weights on approved train images, and writes
weights back into the original Core ML graph. No model conversion is used.
"""
import argparse
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import random
import time

import coremltools as ct
import numpy as np
from PIL import Image, ImageEnhance
import torch
from torch import nn
import torch.nn.functional as F
from torchvision.ops import nms, box_iou


def now(): return datetime.now(timezone.utc).isoformat()
def log(message): print(f'[{now()}] {message}', flush=True)
def weights(p):
    return np.asarray(p.floatValue, dtype=np.float32) if p.floatValue else np.frombuffer(p.float16Value, dtype='<f2').astype(np.float32)


class ExistingDetector(nn.Module):
    def __init__(self, path):
        super().__init__()
        self.spec = ct.utils.load_spec(str(path))
        graph = self.spec.pipeline.models[0]
        self.ops = nn.ModuleDict()
        self.sequence = []
        self.anchors = None
        for layer in graph.neuralNetwork.layers:
            typ=layer.WhichOneof('layer');name=layer.name
            if name=='__tc_internal__c_anchors':
                self.anchors=torch.tensor(weights(layer.loadConstant.data).reshape(2,15,13,13)[:,:,0,0].T.copy())
            if typ=='convolution':
                c=layer.convolution
                assert c.WhichOneof('ConvolutionPaddingType')=='same' and list(c.stride)==[1,1]
                kh,kw=c.kernelSize
                op=nn.Conv2d(c.kernelChannels,c.outputChannels,(kh,kw),padding=(kh//2,kw//2),bias=c.hasBias)
                op.weight.data.copy_(torch.from_numpy(weights(c.weights).reshape(op.weight.shape)))
                if c.hasBias:op.bias.data.copy_(torch.from_numpy(weights(c.bias)))
            elif typ=='batchnorm':
                b=layer.batchnorm;op=nn.BatchNorm2d(b.channels,eps=b.epsilon)
                for field,target in [('gamma',op.weight),('beta',op.bias),('mean',op.running_mean),('variance',op.running_var)]:
                    target.data.copy_(torch.from_numpy(weights(getattr(b,field))))
            elif typ=='activation' and layer.activation.WhichOneof('NonlinearityType')=='leakyReLU':
                op=nn.LeakyReLU(layer.activation.leakyReLU.alpha)
            elif typ=='pooling':
                p=layer.pooling
                if p.WhichOneof('PoolingPaddingType')=='same':
                    op=nn.Sequential(nn.ConstantPad2d((0,1,0,1),float('-inf')), nn.MaxPool2d(2,1))
                else:op=nn.MaxPool2d(2,2)
            else:continue
            self.ops[name]=op;self.sequence.append(name)
            if name=='conv8_fwd':break
        # The decoding constants occur after the last convolution.
        for layer in graph.neuralNetwork.layers:
            if layer.name=='__tc_internal__c_anchors':
                self.anchors=torch.tensor(weights(layer.loadConstant.data).reshape(2,15,13,13)[:,:,0,0].T.copy())
        assert self.anchors is not None and len(self.sequence)==31
        self.eval()

    def forward(self,x):
        # Core ML graph divides camera RGB bytes by 255. Training tensors are
        # already RGB floats in [0,1], so no additional channel normalization.
        for name in self.sequence:x=self.ops[name](x)
        return x.reshape(x.shape[0],15,11,13,13).permute(0,1,3,4,2).contiguous()

    def export(self,path):
        spec=deepcopy(self.spec)
        for layer in spec.pipeline.models[0].neuralNetwork.layers:
            if layer.name not in self.ops:continue
            op=self.ops[layer.name];typ=layer.WhichOneof('layer')
            fields=[]
            if typ=='convolution':
                fields=[(layer.convolution.weights,op.weight)]
                if op.bias is not None:fields.append((layer.convolution.bias,op.bias))
            elif typ=='batchnorm':
                fields=[(getattr(layer.batchnorm,f),v) for f,v in [('gamma',op.weight),('beta',op.bias),('mean',op.running_mean),('variance',op.running_var)]]
            for parameter,tensor in fields:
                del parameter.floatValue[:]
                parameter.float16Value=tensor.detach().cpu().numpy().astype('<f2').tobytes()
        spec.description.metadata.shortDescription='DiceTower rig fine-tune from the selected historical 6000-iteration detector. Experimental; see local report.'
        ct.utils.save_spec(spec,str(path))


def decode(raw,anchors):
    device=raw.device;g=13
    yy,xx=torch.meshgrid(torch.arange(g,device=device),torch.arange(g,device=device),indexing='ij')
    grid=torch.stack((xx,yy),dim=-1).reshape(1,1,g,g,2)
    xy=(raw[...,:2].sigmoid()+grid)/g
    wh=raw[...,2:4].clamp(-10,10).exp()*anchors.to(device).reshape(1,15,1,1,2)/g
    boxes=torch.cat((xy,wh),dim=-1).reshape(raw.shape[0],-1,4)
    scores=(raw[...,4:5].sigmoid()*raw[...,5:].softmax(-1)).reshape(raw.shape[0],-1,6)
    return boxes,scores


def tensor_image(path):
    a=np.array(Image.open(path).convert('RGB'),dtype=np.float32)/255
    return torch.from_numpy(a).permute(2,0,1)


def verify_parity(model,image_path,output):
    image=Image.open(image_path).convert('RGB')
    raw_spec=deepcopy(model.spec.pipeline.models[0])
    native=ct.models.MLModel(raw_spec,compute_units=ct.ComputeUnit.CPU_ONLY)
    result=native.predict({'imagePath':image})
    with torch.no_grad(): boxes,scores=decode(model(tensor_image(image_path)[None]),model.anchors)
    score_error=float(np.abs(scores[0].numpy()-result['raw_confidence']).max())
    # Extremely low-confidence proposals can have huge widths. Measure relative
    # error over all boxes and absolute error for practically retained boxes.
    coords=np.asarray(result['raw_coordinates']);pred=boxes[0].numpy()
    relative=float((np.abs(pred-coords)/(1+np.abs(coords))).max())
    keep=np.asarray(result['raw_confidence']).max(1)>.01
    box_error=float(np.abs(pred[keep]-coords[keep]).max()) if keep.any() else 0
    evidence={'scoreMaxAbsoluteError':score_error,'boxMaxRelativeError':relative,'retainedBoxMaxAbsoluteError':box_error,'retainedAtFloor01':int(keep.sum()),'input':str(image_path)}
    Path(output).write_text(json.dumps(evidence,indent=2)+'\n')
    log(f'Parity {evidence}')
    if score_error>.003 or box_error>.01 or relative>.01:raise RuntimeError('Core ML/PyTorch parity failed')


def xyxy(boxes):return torch.cat((boxes[...,:2]-boxes[...,2:]/2,boxes[...,:2]+boxes[...,2:]/2),-1)


def predict(model,root,rows,device):
    result=[];model.eval()
    with torch.no_grad():
        for row in rows:
            path=root/'data'/row['split']/f"{row['id']}-r0.png"
            t=time.perf_counter();raw=model(tensor_image(path)[None].to(device));boxes,scores=decode(raw,model.anchors)
            boxes=boxes[0].cpu();scores,labels=scores[0].cpu().max(-1)
            keep=scores>=.01;boxes,scores,labels=boxes[keep],scores[keep],labels[keep]
            kept=nms(xyxy(boxes),scores,.30) # Core ML pickTop uses class-agnostic NMS.
            tr=row['transform'];ps=[]
            for k in kept.tolist():
                cx,cy,w,h=(boxes[k]*416).tolist()
                x=(cx-w/2-tr['offsetX'])/tr['scaleX']+tr['cropX'];y=(cy-h/2-tr['offsetY'])/tr['scaleY']+tr['cropY']
                ps.append({'label':str(labels[k].item()+1),'score':scores[k].item(),'box':[x,y,w/tr['scaleX'],h/tr['scaleY']]})
            result.append({'id':row['id'],'split':row['split'],'source':row['source'],'milliseconds':(time.perf_counter()-t)*1000,'predictions':ps})
    return result


def iou(a,b):
    x=max(a[0],b[0]);y=max(a[1],b[1]);r=min(a[0]+a[2],b[0]+b[2]);bot=min(a[1]+a[3],b[1]+b[3]);inter=max(0,r-x)*max(0,bot-y)
    union=a[2]*a[3]+b[2]*b[3]-inter
    return inter/union if union>0 else 0


def metrics(rows,predictions,cutoff):
    truths={r['id']:r for r in rows};per=[];tp=fp=fn=loc_tp=0
    for result in predictions:
        truth=truths[result['id']];gt=truth['dice'];ps=[p for p in result['predictions'] if p['score']>=cutoff]
        pairs=[];used=set();loc_used=set()
        for p in sorted(ps,key=lambda p:-p['score']):
            opts=[(iou(p['box'],g['box']),j) for j,g in enumerate(gt) if j not in used and p['label']==str(g['value'])]
            overlap,j=max(opts,default=(0,-1))
            if overlap>=.5:used.add(j);pairs.append(j)
            opts=[(iou(p['box'],g['box']),j) for j,g in enumerate(gt) if j not in loc_used]
            overlap,j=max(opts,default=(0,-1))
            if overlap>=.5:loc_used.add(j)
        tp+=len(used);loc_tp+=len(loc_used);fp+=len(ps)-len(used);fn+=len(gt)-len(used)
        exact=sorted(int(p['label']) for p in ps)==sorted(g['value'] for g in gt)
        per.append({'id':truth['id'],'index':truth['index'],'expected':[g['value'] for g in gt],'predicted':[int(p['label']) for p in ps],'exactValues':exact,'exactCount':len(ps)==len(gt),'exactLocalized':len(used)==len(gt)==len(ps)})
    precision=tp/(tp+fp) if tp+fp else 0;recall=tp/(tp+fn) if tp+fn else 0
    return {'scenes':len(per),'exactValueSets':sum(p['exactValues'] for p in per),'exactCounts':sum(p['exactCount'] for p in per),'exactLocalizedScenes':sum(p['exactLocalized'] for p in per),'truePositiveFaces50':tp,'falsePositiveFaces50':fp,'missedFaces50':fn,'precision50':precision,'recall50':recall,'f1_50':2*precision*recall/(precision+recall) if precision+recall else 0,'localizationOnlyMatched50':loc_tp,'perScene':per}


def select_threshold(rows,predictions):
    sweep=[{'cutoff':i/20,**metrics(rows,predictions,i/20)} for i in range(1,20)]
    best=max(sweep,key=lambda s:(s['exactValueSets'],s['f1_50'],s['cutoff']))
    return best,sweep


def train_loss(raw,targets,anchors):
    device=raw.device;batch=raw.shape[0]
    obj=torch.zeros(raw.shape[:-1],dtype=torch.bool,device=device)
    target_xy=torch.zeros((*raw.shape[:-1],2),device=device);target_wh=torch.zeros_like(target_xy)
    target_class=torch.zeros(raw.shape[:-1],dtype=torch.long,device=device)
    anchors=anchors.to(device)
    for bi,anns in enumerate(targets):
        for ann in anns:
            c=ann['coordinates'];gx=c['x']/32;gy=c['y']/32;gw=c['width']/32;gh=c['height']/32
            ix=min(12,max(0,int(gx)));iy=min(12,max(0,int(gy)))
            inter=torch.minimum(anchors[:,0],torch.tensor(gw,device=device))*torch.minimum(anchors[:,1],torch.tensor(gh,device=device))
            overlap=inter/(anchors.prod(1)+gw*gh-inter)
            # Choose the next shape anchor if touching faces share a grid cell.
            candidates=overlap.argsort(descending=True).tolist()
            ai=next((a for a in candidates if not obj[bi,a,iy,ix]),None)
            if ai is None:continue
            obj[bi,ai,iy,ix]=True;target_xy[bi,ai,iy,ix]=torch.tensor([gx-ix,gy-iy],device=device)
            target_wh[bi,ai,iy,ix]=torch.log(torch.tensor([gw,gh],device=device)/anchors[ai])
            target_class[bi,ai,iy,ix]=int(ann['label'])-1
    # Ignore alternate anchors already overlapping a true face; they are not
    # background simply because another anchor was assigned the positive target.
    negative=~obj
    with torch.no_grad():
        decoded,_=decode(raw,anchors)
        for bi,anns in enumerate(targets):
            if not anns:continue
            gt=torch.tensor([[a['coordinates'][k]/416 for k in ('x','y','width','height')] for a in anns],device=device)
            overlap=box_iou(xyxy(decoded[bi].detach().cpu()),xyxy(gt.detach().cpu())).max(1).values.to(device)
            negative[bi]&=(overlap.reshape(15,13,13)<.5)
    noobj=F.binary_cross_entropy_with_logits(raw[...,4][negative],torch.zeros_like(raw[...,4][negative]))
    if not obj.any():return noobj
    xy=F.binary_cross_entropy_with_logits(raw[...,:2][obj],target_xy[obj])
    wh=F.smooth_l1_loss(raw[...,2:4][obj],target_wh[obj])
    confidence=F.binary_cross_entropy_with_logits(raw[...,4][obj],torch.ones_like(raw[...,4][obj]))
    classes=F.cross_entropy(raw[...,5:][obj],target_class[obj])
    return 5*xy+5*wh+confidence+classes+2*noobj


def main():
    p=argparse.ArgumentParser();p.add_argument('--root',type=Path,default=Path('local-models/rig-2026-11-06'));p.add_argument('--initial',type=Path,default=Path('local-models/prototype-2026-11-06/DiceTowerD6.mlmodel'));p.add_argument('--steps',type=int,default=1200);p.add_argument('--name',default='warm-last3');p.add_argument('--lr',type=float,default=.0001);p.add_argument('--unfreeze',type=int,default=6)
    p.add_argument('--cutoff',type=float,help='Freeze a pre-existing inference cutoff instead of tuning it on validation')
    args=p.parse_args();root=args.root;run=root/'runs'/args.name;run.mkdir(parents=True,exist_ok=False)
    random.seed(20261106);np.random.seed(20261106);torch.manual_seed(20261106);torch.set_num_threads(6)
    manifest=json.loads((root/'manifest.json').read_text());val=[r for r in manifest['rows'] if r['split']=='validation']
    model=ExistingDetector(args.initial)
    first=root/'data'/'validation'/f"{val[0]['id']}-r0.png"
    verify_parity(model,first,run/'parity.json')
    device='mps' if torch.backends.mps.is_available() else 'cpu';model.to(device)
    baseline=predict(model,root,val,device);baseline_best,baseline_sweep=select_threshold(val,baseline)
    if args.cutoff is not None:baseline_best={'cutoff':args.cutoff,**metrics(val,baseline,args.cutoff)}
    (run/'baseline-validation.json').write_text(json.dumps({'rows':baseline,'best':baseline_best,'sweep':baseline_sweep},indent=2))
    log(f"Unchanged historical weights: {baseline_best['exactValueSets']}/{len(val)} exact validation scenes, F1 {baseline_best['f1_50']:.3f}")
    training=json.loads((root/'data'/'train'/'annotations.json').read_text())
    cache=[(tensor_image(root/'data'/'train'/r['image']),r['annotations']) for r in training]
    for name,op in model.ops.items():
        enabled=name.startswith('conv') and int(name.split('_')[0][4:])>=args.unfreeze
        for parameter in op.parameters():parameter.requires_grad=enabled
    optimizer=torch.optim.AdamW([p for p in model.parameters() if p.requires_grad],lr=args.lr,weight_decay=.0001)
    best_key=(baseline_best['exactValueSets'],baseline_best['f1_50']);best_info={'step':0,'metrics':baseline_best,'cutoff':baseline_best['cutoff'],'run':args.name};start=time.monotonic();history=[]
    model.export(run/'DiceTowerD6.mlmodel');torch.save(model.state_dict(),run/'best.pt');(run/'selected.json').write_text(json.dumps(best_info,indent=2))
    recipe={**vars(args),'root':str(root),'initial':str(args.initial),'startedAt':now(),'device':device,'initialSHA256':hashlib.sha256(args.initial.read_bytes()).hexdigest(),'manifestSHA256':hashlib.sha256((root/'manifest.json').read_bytes()).hexdigest(),'frozenBatchNormStatistics':True,'optimizer':'AdamW','batchSize':8,'selection':'validation exact value sets, then class-correct localization F1; no test-set predictions during training'}
    (run/'recipe.json').write_text(json.dumps(recipe,indent=2,default=str))
    for step in range(1,args.steps+1):
        chosen=random.sample(cache,8);images=[];targets=[]
        for image,anns in chosen:
            # Train-only exposure/contrast perturbation, not validation transforms.
            exposure=random.uniform(.75,1.25);contrast=random.uniform(.85,1.15)
            images.append(((image-.5)*contrast+.5).mul(exposure).clamp(0,1));targets.append(anns)
        optimizer.zero_grad(set_to_none=True)
        raw=model(torch.stack(images).to(device));loss=train_loss(raw,targets,model.anchors)
        if not torch.isfinite(loss):raise RuntimeError('Nonfinite training loss')
        loss.backward();nn.utils.clip_grad_norm_([p for p in model.parameters() if p.requires_grad],5);optimizer.step()
        if step%25==0:log(f"step {step}/{args.steps}, loss {loss.item():.4f}, elapsed {time.monotonic()-start:.0f}s")
        if step%100==0 or step==args.steps:
            preds=predict(model,root,val,device);best,sweep=select_threshold(val,preds)
            if args.cutoff is not None:best={'cutoff':args.cutoff,**metrics(val,preds,args.cutoff)}
            record={'step':step,'elapsedSeconds':time.monotonic()-start,'loss':loss.item(),'metrics':best}
            history.append(record);(run/'history.json').write_text(json.dumps(history,indent=2))
            log(f"validation step {step}: {best['exactValueSets']}/{len(val)} exact, counts {best['exactCounts']}, F1 {best['f1_50']:.3f}, cutoff {best['cutoff']}")
            (run/f'validation-{step}.json').write_text(json.dumps({'rows':preds,'best':best,'sweep':sweep},indent=2))
            key=(best['exactValueSets'],best['f1_50'])
            if key>best_key:
                best_key=key;best_info={**record,'cutoff':best['cutoff'],'run':args.name};model.export(run/'DiceTowerD6.mlmodel');torch.save(model.state_dict(),run/'best.pt')
                (run/'selected.json').write_text(json.dumps(best_info,indent=2))
            (root/'STATUS.json').write_text(json.dumps({'phase':'fine-tuning','run':args.name,'step':step,'steps':args.steps,'updatedAt':now(),'bestValidation':best_info},indent=2))
    model.export(run/'final.mlmodel')
    (run/'complete.json').write_text(json.dumps({'completedAt':now(),'elapsedSeconds':time.monotonic()-start,'best':best_info},indent=2))
    log(f'Done: {best_info}')


if __name__=='__main__':main()
