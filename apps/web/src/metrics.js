export const numericMetrics = ['inferenceMs','emaInferenceMs','processingMs','intervalMs','inferenceCount','agreementCount','settleMs'];
export function normalizeMetric(id, raw) {
  if (!raw || raw.schemaVersion !== 1 || !Number.isFinite(raw.recordedAt) || !['active','quiescent','paused','error'].includes(raw.phase) || !numericMetrics.every(k=>Number.isFinite(raw[k]) && raw[k]>=0) || raw.intervalMs<50 || raw.intervalMs%50!==0 || raw.agreementCount>2 || raw.settleMs!==200 || !Number.isInteger(raw.inferenceCount) || !Number.isInteger(raw.agreementCount) || typeof raw.eventId!=='string' || typeof raw.sessionId!=='string') return null;
  const keys=['duplicateDiscarded','duplicateCount','duplicateOfEventId'];
  const hasDuplicates=keys.some(k=>Object.hasOwn(raw,k));
  if(hasDuplicates && (!keys.every(k=>Object.hasOwn(raw,k)) || typeof raw.duplicateDiscarded!=='boolean' || !Number.isInteger(raw.duplicateCount) || raw.duplicateCount<0 || typeof raw.duplicateOfEventId!=='string' || raw.duplicateOfEventId.length>64 || (raw.duplicateDiscarded ? raw.duplicateCount<1 || !raw.duplicateOfEventId || raw.eventId!=='' || raw.phase!=='quiescent' || raw.agreementCount!==2 : raw.duplicateOfEventId!=='')))return null;
  const hasUploads=Object.hasOwn(raw,'uploadHeldCount')||Object.hasOwn(raw,'uploadIssue');
  if(hasUploads && (!Number.isInteger(raw.uploadHeldCount)||raw.uploadHeldCount<0||typeof raw.uploadIssue!=='string'||raw.uploadIssue.length>200))return null;
  const deliveryKeys=['deliveryEventId','deliveryState','deliveryValues','deliveryDetail','deliveryAt'];
  if(deliveryKeys.some(k=>Object.hasOwn(raw,k)) && (!deliveryKeys.every(k=>Object.hasOwn(raw,k)) || typeof raw.deliveryEventId!=='string' || !raw.deliveryEventId || raw.deliveryEventId.length>64 || !['queued','delivered','rejected','queueFailed'].includes(raw.deliveryState) || typeof raw.deliveryValues!=='string' || raw.deliveryValues.length>100 || !/^([1-6](,[1-6])*)?$/.test(raw.deliveryValues) || typeof raw.deliveryDetail!=='string' || raw.deliveryDetail.length>200 || !Number.isFinite(raw.deliveryAt) || raw.deliveryAt<=0)) return null;
  return {...raw, metricId:id,duplicateCount:hasDuplicates?raw.duplicateCount:null,duplicateDiscarded:raw.duplicateDiscarded??false,duplicateOfEventId:raw.duplicateOfEventId??'',uploadHeldCount:hasUploads?raw.uploadHeldCount:null,uploadIssue:raw.uploadIssue??''};
}
export function sortedMetrics(rows) {
  return Object.entries(rows||{}).map(([id,raw])=>normalizeMetric(id,raw)).filter(Boolean).sort((a,b)=>b.recordedAt-a.recordedAt || b.metricId.localeCompare(a.metricId));
}
export function displayMs(value) { return `${value.toFixed(1)} ms`; }
