import test from 'node:test';
import assert from 'node:assert/strict';
import {reconcilePreview} from '../src/preview-state.js';
import {disconnectPreview, connectPreview} from '../src/power-preview.js';
import {protectionCopy} from '../src/menu-copy.js';

const base = {state:'automatic', power:'ac', auto:true, autoRest:false, remaining:2700, untimed:false,
  recording:false, disconnect:'all', batteryLimit:'120', batteryRemaining:6300, updateState:'available',
  updatePreparation:'idle', channel:'stable', currentVersion:'1.0.0', availableVersion:'1.0.1'};
const change = (model, patch) => reconcilePreview(model, {...model, ...patch});

test('pause -> OFF -> ON cancels the pause and starts automatic again', () => {
  const paused = change(base, {autoRest:'30분'});
  assert.equal(paused.state, 'waiting');
  const off = change(paused, {auto:false});
  assert.equal(off.autoRest, false);
  assert.equal(off.state, 'waiting');
  assert.equal(change(off, {auto:true}).state, 'automatic');
});
test('automatic OFF does not end a manual timer or override all-stop/protection', () => {
  const manual = change({...base, state:'manual'}, {auto:false});
  assert.equal(manual.state, 'manual');
  assert.equal(manual.remaining, 2700);
  for (const state of ['stopped','protected']) assert.equal(change({...base, state, auto:false}, {auto:true}).state, state);
});
test('power changes invalidate confirmation even while its UI is absent', () => {
  let model = {...base, state:'manual', updatePreparation:'confirm'};
  model = reconcilePreview(model, disconnectPreview(model));
  assert.equal(model.updatePreparation, 'idle');
  assert.equal(model.updatePreparationNotice, 'safety');
  model = reconcilePreview(model, connectPreview(model));
  assert.equal(model.updatePreparation, 'idle');
  assert.equal(model.remaining, 0);
});
test('ready -> new session -> stop cannot restore an old preparation result', () => {
  let model = {...base, state:'stopped', remaining:0, updatePreparation:'ready'};
  model = change(model, {state:'automatic'});
  assert.equal(model.updatePreparation, 'idle');
  model = change(model, {state:'manual', remaining:1800});
  model = change(model, {state:'stopped'});
  assert.equal(model.updatePreparation, 'idle');
  assert.equal(model.remaining, 0);
});
test('explicit confirmation may atomically stop sessions and prepare', () => {
  const confirm = {...base, state:'manual', recording:true, updatePreparation:'confirm'};
  const preparing = change(confirm, {state:'stopped', recording:false, remaining:0, updatePreparation:'preparing', updatePreparationNotice:''});
  assert.equal(preparing.updatePreparation, 'preparing');
  assert.equal(preparing.remaining, 0);
  assert.equal(change(preparing, {updatePreparation:'ready'}).updatePreparation, 'ready');
  assert.equal(change({...confirm, power:'battery'}, {state:'stopped', recording:false, updatePreparation:'preparing'}).updatePreparation, 'idle');
});
test('recording, release, and safety changes invalidate prior preparation', () => {
  for (const patch of [{recording:true}, {channel:'beta'}, {availableVersion:'1.0.2'}, {state:'protected'}]) {
    assert.equal(change({...base, state:'stopped', remaining:0, updatePreparation:'ready'}, patch).updatePreparation, 'idle');
  }
});
test('language, appearance, and new battery limits preserve the running deadline', () => {
  const old = {...base, state:'manual', updatePreparation:'confirm', language:'ko', appearance:'light'};
  const next = change(old, {language:'en', appearance:'dark', batteryLimit:'30'});
  assert.equal(next.remaining, 2700);
  assert.equal(next.batteryRemaining, 6300);
  assert.equal(next.updatePreparation, 'confirm');
  assert.deepEqual(reconcilePreview(next, next), next);
});
test('protection copy separates the historical stop from a changed current limit in both locales', () => {
  const snapshot = {battery:18, threshold:20};
  for (const locale of ['ko','en']) {
    const copy = protectionCopy(locale, snapshot, '30');
    assert.match(copy.reason, /18%/);
    assert.match(copy.reason, /20%/);
    assert.match(copy.current, /30%/);
    assert.equal(protectionCopy(locale, snapshot, '20').current, '');
  }
  assert.deepEqual(snapshot, {battery:18, threshold:20});
});
