import {test} from 'node:test';
import assert from 'node:assert/strict';
import {normalizeMetric, sortedMetrics, displayMs} from './metrics.js';
const metric = {schemaVersion:1,recordedAt:100,phase:'quiescent',sessionId:'s',eventId:'e',inferenceMs:12.5,emaInferenceMs:13,processingMs:19,intervalMs:50,inferenceCount:2,agreementCount:2,settleMs:200};
test('metrics are separate from recognition payloads and preserve roll association',()=>{
 const result=normalizeMetric('m',metric);assert.equal(result.eventId,'e');assert.equal(result.metricId,'m');assert.equal(displayMs(result.inferenceMs),'12.5 ms');
});
test('malformed timing, phases and non-50ms cadence are rejected',()=>{
 for(const override of [{inferenceMs:NaN},{phase:'<script>'},{intervalMs:51},{settleMs:1200},{agreementCount:3},{inferenceCount:1.5}])assert.equal(normalizeMetric('m',{...metric,...override}),null);
});
test('timing snapshots sort by sample time with deterministic ties',()=>{
 assert.deepEqual(sortedMetrics({old:metric,new:{...metric,recordedAt:200},bad:{}}).map(x=>x.metricId),['new','old']);
});
test('legacy metrics remain readable and duplicate decisions carry a match and session count',()=>{
 assert.equal(normalizeMetric('old',metric).duplicateCount,null);
 const duplicate={...metric,eventId:'',duplicateDiscarded:true,duplicateCount:3,duplicateOfEventId:'original'};
 const result=normalizeMetric('m',duplicate);
 assert.equal(result.duplicateDiscarded,true);assert.equal(result.duplicateCount,3);assert.equal(result.duplicateOfEventId,'original');
 for(const override of [{duplicateCount:-1},{duplicateCount:1.5},{duplicateCount:0},{duplicateDiscarded:'yes'},{duplicateOfEventId:''},{eventId:'new'},{phase:'active'},{agreementCount:1}])assert.equal(normalizeMetric('bad',{...duplicate,...override}),null);
 assert.equal(normalizeMetric('partial',{...metric,duplicateCount:1}),null);
});
