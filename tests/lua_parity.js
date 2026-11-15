#!/usr/bin/env node
/*
 * The REAPER scripts' Lua against the page's engine.js, on the same renders.
 *
 * The Lua lays out the test part; this file turns it into MIDI, renders it
 * with the made-up library, and both sides measure it. Profiles must agree
 * (and both must agree with the library's own numbers). Then both plan a
 * fix from the same profile and must make the same changes.
 *
 *   node tests/lua_parity.js        (needs lua5.4)
 */
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const NPVF = require('../src/engine.js');
const S = require('./synth.js');

const CLI = path.join(__dirname, 'lua', 'cli.lua');
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'npvf-lua-'));
const file = (name, data) => { const p = path.join(work, name); fs.writeFileSync(p, typeof data === 'string' ? data : Buffer.from(data)); return p; };
const lua = (...args) => JSON.parse(execFileSync('lua5.4', [CLI, ...args], { maxBuffer: 1 << 28 }).toString());

let passed = 0, failed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log('  ok   ' + name); } catch (e) { failed++; console.log('  FAIL ' + name + '\n       ' + (e && e.message)); }
}
const ok = (c, m) => { if (!c) throw new Error(m || 'assertion failed'); };
const med = a => { const s = a.slice().sort((x, y) => x - y); return s[s.length >> 1]; };
const max = a => a.reduce((m, v) => Math.max(m, v), -Infinity);

/** The Lua layout (seconds) as a MIDI file at 120 BPM, so one second is two beats. */
function layoutMidi(layout) {
  const ppq = 480, tick = t => Math.round(t * 2 * ppq);
  const events = [{ tick: 0, kind: 'meta', type: 0x51, data: Uint8Array.from([0x07, 0xa1, 0x20]), order: 0 }];
  let order = 1;
  for (const e of layout.events) {
    if (e.kind === 'note') {
      events.push({ tick: tick(e.t), kind: 'ch', status: 0x90 | e.chan, d1: e.pitch, d2: e.vel, order: order++ });
      events.push({ tick: tick(e.t + e.len), kind: 'ch', status: 0x80 | e.chan, d1: e.pitch, d2: 0, order: order++ });
    } else if (e.kind === 'cc') {
      events.push({ tick: tick(e.t), kind: 'ch', status: 0xb0 | e.chan, d1: e.cc, d2: e.value, order: order++ });
    } else if (e.kind === 'program') {
      events.push({ tick: tick(e.t), kind: 'ch', status: 0xc0 | e.chan, d1: e.value, d2: 0, order: order++ });
    }
  }
  events.push({ tick: tick(layout.length), kind: 'meta', type: 0x2f, data: new Uint8Array(0), order: order++ });
  return NPVF.writeMidi({ format: 0, division: ppq, tracks: [{ events }] });
}

function measureBoth(testOpts, renderOpts) {
  const optsPath = file('opts.json', JSON.stringify({ test: testOpts, meta: { instrument: 'Test strings', articulation: 'Staccato', test: testOpts } }));
  const layout = lua('layout', file('layout.json', JSON.stringify(testOpts)));
  const midi = layoutMidi(layout);
  const audio = S.render(midi, renderOpts);
  const wav = file('render.wav', NPVF.encodeWav(audio.data, audio.sampleRate));
  const t0 = Date.now();
  const L = lua('measure', wav, optsPath);
  const luaMs = Date.now() - t0;
  return { layout, midi, audio, L, luaMs };
}

const truth = (e, levelIsVel) => S.expectedOnsetMs(e.pitch, e.vel);

console.log('Measuring');

const base = measureBoth({ low: 36, high: 84, levels: [40, 80, 120], takes: 2 });

test('the Lua finds every test note, as accurately as the page', () => {
  ok(base.L.stats.found === base.L.stats.notes, base.L.stats.found + '/' + base.L.stats.notes);
  const err = base.L.profile.entries.map(e => Math.abs(e.delayMs - truth(e)));
  ok(med(err) < 1 && max(err) < 6, 'median ' + med(err) + ' worst ' + max(err));
  console.log('       (Lua took ' + (base.luaMs / 1000).toFixed(1) + ' s for ' + base.L.stats.notes + ' notes, ' + (base.audio.data.length / base.audio.sampleRate).toFixed(0) + ' s of audio)');
});

const jsResult = NPVF.analyse(NPVF.parseMidi(base.midi), base.audio, { maxDelayMs: 400, spreadMs: 400 });
const jsProfile = NPVF.learnProfile(jsResult, 'Test strings - Staccato');

test('Lua and JavaScript profiles agree key by key', () => {
  const L = base.L.profile.entries, Jp = jsProfile.entries;
  ok(L.length === Jp.length, 'entries ' + L.length + ' vs ' + Jp.length);
  let worstD = 0, worstV = 0, worstL = 0;
  for (let i = 0; i < L.length; i++) {
    ok(L[i].pitch === Jp[i].pitch && L[i].vel === Jp[i].vel, 'same keys in the same order at ' + i);
    worstD = Math.max(worstD, Math.abs(L[i].delayMs - Jp[i].delayMs));
    worstV = Math.max(worstV, Math.abs(L[i].deviationDb - Jp[i].deviationDb));
    worstL = Math.max(worstL, Math.abs(L[i].loudDb - Jp[i].loudDb));
  }
  ok(worstD <= 0.5, 'delay differs by up to ' + worstD.toFixed(3) + ' ms');
  ok(worstV <= 0.3 && worstL <= 0.3, 'loudness differs by up to ' + worstL.toFixed(3) + ' dB, deviation ' + worstV.toFixed(3) + ' dB');
  ok(Math.abs(base.L.profile.dbPerVelocity - jsProfile.dbPerVelocity) < 0.01, 'dB per velocity step');
});

test('both sides also note where the sound starts, and where the attack is done', () => {
  const L = base.L.profile.entries, Jp = jsProfile.entries;
  let worst = 0;
  const peakDiff = [];
  for (let i = 0; i < L.length; i++) {
    worst = Math.max(worst, Math.abs(L[i].startMs - Jp[i].startMs), Math.abs(L[i].attackMs - Jp[i].attackMs));
    peakDiff.push(Math.abs(L[i].peakMs - Jp[i].peakMs));
    ok(L[i].startMs < L[i].attackMs && L[i].attackMs < L[i].peakMs, 'start, then attack, then its end at ' + L[i].pitch);
    ok(L[i].attackMs === L[i].delayMs, 'lined up on the attack');
  }
  ok(worst <= 0.6, 'start and attack differ by up to ' + worst.toFixed(3) + ' ms');
  // the attack's end is fuzzier where the top of the attack ripples
  ok(med(peakDiff) <= 0.1 && max(peakDiff) <= 3, 'attack end differs by a median ' + med(peakDiff).toFixed(3) + ', at most ' + max(peakDiff).toFixed(2) + ' ms');
  // the start of the sound is where the library's sample really begins (its delay), give or take the 3 ms window
  const err = L.map(e => e.startMs - S.LIBRARY.delayMs(e.pitch, e.vel));
  ok(med(err) > -1 && med(err) < 6, 'start of sound vs the sample start: median ' + med(err).toFixed(2));
});

test('a version 2 profile: every take, the range, and a summary', () => {
  const p = base.L.profile;
  ok(p.version === 2 && p.range.low === 36 && p.range.high === 84 && p.silentKeys.length === 0, 'range');
  ok(p.entries.every(e => e.takesMs.length === 2 && e.takes === 2), 'both takes kept');
  ok(p.summary.found === p.summary.notes && p.summary.byLevel.length === 3, 'summary');
  ok(p.summary.byLevel[0].delayMs > p.summary.byLevel[2].delayMs, 'soft notes speak later');
  ok(JSON.stringify(p.summary.offKeys) === JSON.stringify([64, 67, 71]), 'the faulty keys: ' + p.summary.offKeys);
  ok(p.test && p.test.low === 36 && p.test.takes === 2, 'how it was tested');
});

test('the Lua profile opens in the page and says where it came from', () => {
  const p = NPVF.checkProfile(base.L.profile);
  ok(p.instrument === 'Test strings' && p.articulation === 'Staccato' && p.name === 'Test strings - Staccato', p.name);
  ok(p.measuredIn === 'REAPER' && p.dynamics === 'velocity');
  for (const [pitch, fault] of Object.entries(S.LIBRARY.faults)) {
    for (const e of p.entries.filter(e => e.pitch === +pitch)) ok(Math.abs(e.deviationDb - fault) < 0.5, 'key ' + pitch + ': ' + e.deviationDb);
  }
});

test('a keyswitch, a CC and a program change are played first, in the lead-in', () => {
  for (const sw of [{ type: 'keyswitch', value: 24 }, { type: 'cc', cc: 32, value: 7 }, { type: 'program', value: 3 }]) {
    const lay = lua('layout', file('l.json', JSON.stringify({ low: 60, high: 60, levels: [90], takes: 1, switch: sw })));
    const first = lay.events.filter(e => e.kind !== 'cc' || e.cc !== 1).sort((a, b) => a.t - b.t)[0];
    ok(first.t < lay.notes[0].t, sw.type + ' before the first note');
    ok(sw.type === 'keyswitch' ? first.pitch === 24 : first.value === sw.value, sw.type + ' value');
  }
  const ch = lua('layout', file('l.json', JSON.stringify({ low: 60, high: 60, levels: [90], takes: 1, switch: { type: 'channel', value: 3 } })));
  ok(ch.events.every(e => e.chan === 2), 'channel 3 is MIDI channel index 2');
  // from a map: several outputs at once, in order, with velocity, on the articulation's channel
  const send = [{ kind: 'note', pitch: 24, vel: 127 }, { kind: 'note', pitch: 90, vel: 127 }, { kind: 'note', pitch: 0, vel: 42 }, { kind: 'cc', cc: 20, value: 5 }];
  const m = lua('layout', file('l.json', JSON.stringify({ low: 60, high: 60, levels: [90], takes: 1, send, outChannel: 4 })));
  const outs = m.events.filter(e => e.t < m.notes[0].t && !(e.kind === 'cc' && e.cc === 1)).sort((a, b) => a.t - b.t);
  ok(outs.length === 4 && outs[0].pitch === 24 && outs[1].pitch === 90 && outs[2].vel === 42 && outs[3].cc === 20, 'all four outputs, in order');
  ok(m.events.every(e => e.chan === 3), 'on channel 4');
});

test('long notes with dynamics on CC1: measured per CC1 value', () => {
  const r = measureBoth({ low: 48, high: 72, levels: [40, 80, 120], takes: 1, dynamics: 'cc1', velocity: 100 }, { cc1Dynamics: true });
  const p = r.L.profile;
  ok(p.dynamics === 'cc1' && p.dbPerVelocity === undefined, 'a CC1 profile');
  const err = p.entries.map(e => Math.abs(e.delayMs - S.expectedOnsetMs(e.pitch, e.vel)));
  ok(med(err) < 1 && max(err) < 6, 'median ' + med(err) + ' worst ' + max(err));
  for (const e of p.entries.filter(e => e.pitch === 64)) ok(Math.abs(e.deviationDb - 5) < 0.6, 'key 64 at CC1 ' + e.vel + ': ' + e.deviationDb);
});

console.log('Fixing');

const LINE = [60, 62, 64, 65, 67, 69, 71, 72, 71, 69, 67, 65, 64, 62, 60, 64, 67, 72, 67, 64];
const partBytes = S.part(LINE.map((p, i) => ({ beat: 4 + i * 0.5, beats: 0.25, pitch: p, vel: [70, 90, 110][i % 3] })));

test('the same profile makes the same changes in Lua and JavaScript', () => {
  const midi = NPVF.parseMidi(partBytes);
  const jp = NPVF.plan(NPVF.fromProfile(midi, jsProfile));
  const notes = jp.changes.map((c, i) => ({ id: i + 1, t: c.note.t, tEnd: c.note.tEnd, pitch: c.note.pitch, vel: c.note.vel, chan: c.note.ch }));
  const out = lua('fix', file('fix.json', JSON.stringify({ notes, events: [], profiles: [jsProfile], fallback: 1, options: {} })));
  let worst = 0;
  jp.changes.forEach((c, i) => {
    const l = out.changes[String(i + 1)];
    ok(l.newVel === c.newVel, 'note ' + (i + 1) + ' velocity ' + l.newVel + ' vs ' + c.newVel);
    worst = Math.max(worst, Math.abs(l.shiftMs - c.shiftMs));
  });
  ok(worst <= 1.1, 'moves differ by up to ' + worst.toFixed(2) + ' ms (the page rounds to ticks)');
});

test('the Lua plan puts the library\'s sound on the grid', () => {
  const midi = NPVF.parseMidi(partBytes);
  const tm = NPVF.tempoMap(midi);
  const notes = NPVF.collectNotes(midi).map((n, i) => ({ id: i + 1, t: tm.toSec(n.startTick), tEnd: tm.toSec(n.endTick), pitch: n.pitch, vel: n.vel, chan: n.ch }));
  const out = lua('fix', file('fix.json', JSON.stringify({ notes, events: [], profiles: [base.L.profile], fallback: 1, options: {} })));
  const err = notes.map(n => { const c = out.changes[String(n.id)]; return Math.abs(c.shiftMs + S.expectedOnsetMs(n.pitch, c.newVel)); });
  ok(max(err) <= 3, 'worst ' + max(err).toFixed(2) + ' ms');
});

fs.rmSync(work, { recursive: true, force: true });
console.log('\n' + passed + ' passed, ' + failed + ' failed');
process.exit(failed ? 1 : 0);
