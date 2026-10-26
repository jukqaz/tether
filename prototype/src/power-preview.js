// UI-only transitions. No Mac power APIs are called.
export function disconnectPreview(model) {
  if (model.power !== 'ac') return model;
  const next = {...model, power: 'battery', lastPowerEvent: 'unplugged', selectedDuration: model.selectedDuration === 'untimed' ? 30 : Math.min(Number(model.selectedDuration) || 30, Number(model.batteryLimit))};
  if (model.state === 'protected' || model.state === 'stopped') return {...next, lastPowerEvent: null};
  const keepManual = model.disconnect !== 'all' && model.state === 'manual';
  if (!keepManual) return {...next, state: 'unplugged', remaining: 0, untimed: false};
  const cap = model.batteryRemaining ?? Number(model.batteryLimit) * 60;
  const remaining = model.untimed ? cap : Math.min(model.remaining, cap);
  return {...next, state: remaining > 0 ? 'manual' : 'unplugged', remaining, untimed: false};
}
export function connectPreview(model) {
  if (model.power === 'ac') return model;
  const state = ['protected', 'stopped', 'manual'].includes(model.state) ? model.state
    : model.auto && !model.autoRest ? 'automatic' : 'waiting';
  return {...model, power: 'ac', state, lastPowerEvent: null};
}
