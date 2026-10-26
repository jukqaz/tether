// UI-only invariants shared by every model entry point, independent of open tabs.
const sessionFields = ['state', 'recording', 'remaining', 'untimed', 'auto', 'autoRest', 'stopRequested'];
const releaseFields = ['channel', 'currentVersion', 'currentBuild', 'availableVersion', 'updateState'];
const changed = (before, after, fields) => fields.some(key => before[key] !== after[key]);

export function reconcilePreview(before, candidate) {
  const next = {...candidate};
  // Turning automatic start off also cancels its temporary pause. A later ON is fresh.
  if (!next.auto) next.autoRest = false;
  if (next.state === 'automatic' && (!next.auto || next.autoRest)) next.state = 'waiting';
  if (next.state === 'waiting' && next.power === 'ac' && next.auto && !next.autoRest) next.state = 'automatic';
  if (next.state === 'stopped') {
    next.remaining = 0;
    next.untimed = false;
    next.lastPowerEvent = null;
  }

  const safetyChanged = before.power !== next.power || (before.state === 'protected') !== (next.state === 'protected');
  const sessionChanged = changed(before, next, sessionFields);
  const releaseChanged = changed(before, next, releaseFields);
  const hadPreparation = before.updatePreparation && before.updatePreparation !== 'idle';
  // This is the one intentional transaction that ends activity while preparing.
  const confirmed = before.updatePreparation === 'confirm' && next.updatePreparation === 'preparing'
    && !safetyChanged && !releaseChanged && next.power === 'ac' && next.updateState === 'available'
    && next.state === 'stopped' && !next.recording;
  if (hadPreparation && next.updatePreparation !== 'idle' && !confirmed && (safetyChanged || sessionChanged || releaseChanged)) {
    next.updatePreparation = 'idle';
    next.updatePreparationNotice = safetyChanged ? 'safety' : releaseChanged ? 'release' : 'session';
  }
  return next;
}
