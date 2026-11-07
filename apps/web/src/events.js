export function normalizeEvent(id, raw) {
  if (!raw || raw.schemaVersion !== 1 || !Number.isFinite(raw.capturedAt)) return null;
  const dice = Object.values(raw.dice || {});
  if (dice.length !== raw.count || !dice.every(d => Number.isInteger(d.value) && d.value >= 1 && d.value <= 6 && d.box && ['x','y','width','height'].every(k=>Number.isFinite(d.box[k])) && d.box.x >= 0 && d.box.y >= 0 && d.box.width > 0 && d.box.height > 0 && d.box.x + d.box.width <= 1.000001 && d.box.y + d.box.height <= 1.000001)) return null;
  const total = dice.reduce((sum, die) => sum + die.value, 0);
  if (raw.total !== total || typeof raw.thumbnail !== 'string' || !/^data:image\/jpeg;base64,[a-zA-Z0-9+/=]+$/.test(raw.thumbnail)) return null;
  return {...raw, eventId: id, dice, total};
}
export function mergeEvents(existing, incoming) {
  const all = new Map(existing.map(event => [event.eventId,event]));
  incoming.forEach(event => { if (event) all.set(event.eventId,event); });
  return [...all.values()].sort((a,b) => b.capturedAt-a.capturedAt || b.eventId.localeCompare(a.eventId));
}
export function towerLink(id, base = location.href) {
  const url = new URL(base); url.search = ''; url.searchParams.set('tower',id); url.hash = ''; return url.href;
}
