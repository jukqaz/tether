import test from 'node:test';
import assert from 'node:assert/strict';
import {disconnectPreview, connectPreview} from '../src/power-preview.js';
const active={state:'manual',power:'ac',disconnect:'all',remaining:2700,batteryRemaining:6300,batteryLimit:'120',auto:true,untimed:false};
test('unplug: end-all clears the timer; reconnect never resurrects it',()=>{const end=disconnectPreview(active);assert.equal(end.state,'unplugged');assert.equal(end.remaining,0);assert.equal(connectPreview(end).state,'automatic');assert.equal(connectPreview(end).remaining,0);});
test('both allowed policies preserve a permitted manual deadline',()=>{for(const disconnect of ['automatic','allowed']) {const next=disconnectPreview({...active,disconnect});assert.equal(next.state,'manual');assert.equal(next.remaining,2700);assert.equal(next.power,'battery');}});
test('untimed session becomes finite and repeated power changes do not refill its cap',()=>{let next=disconnectPreview({...active,disconnect:'allowed',untimed:true,batteryRemaining:600});assert.equal(next.remaining,600);assert.equal(next.untimed,false);next=disconnectPreview({...connectPreview(next),remaining:300});assert.equal(next.remaining,300);});
test('automatic-only never turns into a new battery session',()=>{for(const disconnect of ['all','automatic','allowed'])assert.equal(disconnectPreview({...active,state:'automatic',disconnect}).state,'unplugged');});
test('protection and explicit all-stop survive power events',()=>{for(const state of ['protected','stopped'])assert.equal(connectPreview(disconnectPreview({...active,state})).state,state);});

test('an AC-only unlimited picker cannot seed a zero-second battery timer',()=>{assert.equal(disconnectPreview({...active,selectedDuration:'untimed'}).selectedDuration,30);});
