#!/usr/bin/env node
// The mock REAPER's instrument: renders a MIDI item (given in seconds) with the made-up library.
//   node render_cli.js <in.json> <out.wav>
// in.json: { notes: [{t, len, pitch, vel, chan}], ccs: [{t, cc, value, chan}], length, silent,
//            articulations: { "<keyswitch pitch>": { cc1Dynamics, extraDelayMs } } }
// The articulation is the last keyswitch note (below C0) before each note.
'use strict';
const fs = require('fs');
const NPVF = require('../../src/engine.js');
const S = require('../synth.js');
const inp = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const fsr = 48000;
const out = new Float32Array(Math.ceil(inp.length * fsr));
if (!inp.silent) {
  const ks = inp.notes.filter(n => n.pitch < 24).sort((a, b) => a.t - b.t);
  const played = inp.notes.filter(n => n.pitch >= 24);
  const groups = new Map();
  for (const n of played) {
    let k = '';
    for (const s of ks) if (s.t <= n.t + 1e-9) k = String(s.pitch);
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(n);
  }
  for (const [k, notes] of groups) {
    const art = (inp.articulations || {})[k] || {};
    const lib = Object.assign({}, S.LIBRARY, { delayMs: (p, v) => S.LIBRARY.delayMs(p, v) + (art.extraDelayMs || 0) });
    // one second is two beats at 120 BPM
    const ppq = 480, tick = t => Math.round(t * 2 * ppq);
    const events = [{ tick: 0, kind: 'meta', type: 0x51, data: Uint8Array.from([0x07, 0xa1, 0x20]), order: 0 }];
    let order = 1;
    for (const c of inp.ccs || []) events.push({ tick: tick(c.t), kind: 'ch', status: 0xb0 | c.chan, d1: c.cc, d2: c.value, order: order++ });
    for (const n of notes) {
      events.push({ tick: tick(n.t), kind: 'ch', status: 0x90 | n.chan, d1: n.pitch, d2: n.vel, order: order++ });
      events.push({ tick: tick(n.t + n.len), kind: 'ch', status: 0x80 | n.chan, d1: n.pitch, d2: 0, order: order++ });
    }
    events.push({ tick: tick(inp.length), kind: 'meta', type: 0x2f, data: new Uint8Array(0), order: order++ });
    const midi = NPVF.writeMidi({ format: 0, division: ppq, tracks: [{ events }] });
    const a = S.render(midi, { lib, cc1Dynamics: !!art.cc1Dynamics, noiseDb: -200 });
    for (let i = 0; i < Math.min(out.length, a.data.length); i++) out[i] += a.data[i];
  }
}
// one noise floor for the whole render, as a real one has
let seed = 3;
for (let i = 0; i < out.length; i++) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; out[i] += (seed / 0x7fffffff - 0.5) * 3.4e-4; }
fs.writeFileSync(process.argv[3], Buffer.from(NPVF.encodeWav(out, fsr)));
