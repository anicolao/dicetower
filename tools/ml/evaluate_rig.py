"""Score native Vision predictions. Test scoring requires frozen selection.json."""
import argparse
import json
from pathlib import Path

from warmstart import metrics, select_threshold


def evaluate(root, path, cutoff=None, truth_manifest=None, suffix=''):
    manifest=json.loads((truth_manifest or root/'manifest.json').read_text());pred=json.loads(path.read_text())
    splits={r['split'] for r in pred['rows']}
    if 'test' in splits and not (root/'selection.json').exists():
        raise ValueError('Freeze model/threshold selection before test evaluation')
    rows=manifest['rows'];val=[r for r in pred['rows'] if r['split']=='validation'];test=[r for r in pred['rows'] if r['split']=='test']
    output={'predictionFile':str(path),'noExpectedCountSuppliedToInference':True,'truthManifest':str(truth_manifest or root/'manifest.json')}
    if val:
        best,sweep=select_threshold(rows,val)
        output.update(cutoff=best['cutoff'],validation=best,validationSweep=sweep)
    if cutoff is not None:
        output['cutoff']=cutoff
        if val:output['validation']={'cutoff':cutoff,**metrics(rows,val,cutoff)}
    if test:
        if 'cutoff' not in output:raise ValueError('Test-only evaluation needs frozen cutoff')
        output['test']=metrics(rows,test,output['cutoff'])
    lat=sorted(r['milliseconds'] for r in pred['rows'])
    output['macLatency']={'medianMs':lat[len(lat)//2],'p95Ms':lat[min(len(lat)-1,int(len(lat)*.95))],'notIPhonePerformance':True}
    out=path.with_name(path.stem+suffix+'-metrics.json');out.write_text(json.dumps(output,indent=2)+'\n')
    for split in ('validation','test'):
        if split in output:
            m=output[split];print(path.stem,split,f"{m['exactValueSets']}/{m['scenes']} exact",'count',m['exactCounts'],'F1',round(m['f1_50'],4),'cutoff',output['cutoff'])
    return output


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('predictions',type=Path);p.add_argument('--root',type=Path,default=Path('local-models/rig-2026-11-06'));p.add_argument('--cutoff',type=float);p.add_argument('--truth-manifest',type=Path);p.add_argument('--suffix',default='')
    a=p.parse_args();evaluate(a.root,a.predictions,a.cutoff,a.truth_manifest,a.suffix)
