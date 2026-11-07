export const numericMetrics = ['inferenceMs','emaInferenceMs','processingMs','intervalMs','inferenceCount','agreementCount','settleMs'];
export function normalizeMetric(id, raw) {
  if (!raw || raw.schemaVersion !== 1 || !Number.isFinite(raw.recordedAt) || !['active','quiescent','paused','error'].includes(raw.phase) || !numericMetrics.every(k=>Number.isFinite(raw[k]) && raw[k]>=0) || raw.intervalMs<50 || raw.intervalMs%50!==0 || raw.agreementCount>2 || raw.settleMs!==200 || !Number.isInteger(raw.inferenceCount) || !Number.isInteger(raw.agreementCount) || typeof raw.eventId!=='string' || typeof raw.sessionId!=='string') return null;
  return {...raw, metricId:id};
}
export function sortedMetrics(rows) {
  return Object.entries(rows||{}).map(([id,raw])=>normalizeMetric(id,raw)).filter(Boolean).sort((a,b)=>b.recordedAt-a.recordedAt || b.metricId.localeCompare(a.metricId));
}
export function displayMs(value) { return `${value.toFixed(1)} ms`; }
