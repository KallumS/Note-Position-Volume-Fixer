/*
 * A made-up sample library with the faults the tool is meant to fix, so the
 * tests know the right answer.
 *
 * Each note's sound starts late by an amount that depends on its pitch and
 * velocity (as real samples do), its attack takes a while to rise, and a few
 * pitches are recorded louder or quieter than their neighbours. Rendering the
 * same MIDI twice gives the same audio, so a corrected file can be rendered
 * again to check the fix really lands.
 */
'use strict';
const NPVF = require('../src/engine.js');

function hash(n) {
  let x = Math.imul(n ^ 0x9e3779b9, 0x85ebca6b);
  x ^= x >>> 13; x = Math.imul(x, 0xc2b2ae35); x ^= x >>> 16;
  return (x >>> 0) / 4294967296;
}

const LIBRARY = {
  // ms of silence before the sample starts making sound
  delayMs: (p, v) => 45 + 70 * hash(p * 7 + 1) + (127 - v) * 0.12,
  // ms for the attack to rise to full
  attackMs: p => 12 + 30 * hash(p * 13 + 5),
  // dB: velocity curve, a gentle pitch slope, and faulty samples
  gainDb: (p, v) => -34 + 0.25 * v - 0.08 * (p - 60) + (LIBRARY.faults[p] || 0),
  faults: { 64: 5, 67: -4, 71: 3.5 },
};

/** When, after the MIDI note, the 'attack' point (12 dB below the peak) is reached. */
function expectedOnsetMs(p, v, lib) {
  lib = lib || LIBRARY;
  // amplitude rises as a raised cosine; power is 12 dB down where amplitude is 0.2512
  const tau = Math.acos(1 - 2 * Math.pow(10, -12 / 20)) / Math.PI;
  return lib.delayMs(p, v) + tau * lib.attackMs(p);
}

function render(midiBytes, opts) {
  const o = Object.assign({ fs: 48000, lib: LIBRARY, tail: 1.5, noiseDb: -80, decay: 6, seed: 1 }, opts || {});
  const midi = NPVF.parseMidi(midiBytes);
  const tm = NPVF.tempoMap(midi);
  const notes = NPVF.collectNotes(midi);
  const end = notes.reduce((m, n) => Math.max(m, tm.toSec(n.endTick)), 0) + o.tail;
  const out = new Float32Array(Math.ceil(end * o.fs));
  let s = o.seed;
  const rnd = () => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff - 0.5; };
  const noise = Math.pow(10, o.noiseDb / 20) * 3.4;
  for (let i = 0; i < out.length; i++) out[i] = rnd() * noise;
  for (const n of notes) {
    if (n.pitch < 24) continue; // keyswitches make no sound
    const f0 = 440 * Math.pow(2, (n.pitch - 69) / 12);
    const t0 = tm.toSec(n.startTick) + o.lib.delayMs(n.pitch, n.vel) / 1000;
    const t1 = tm.toSec(n.endTick) + o.lib.delayMs(n.pitch, n.vel) / 1000;
    const A = o.lib.attackMs(n.pitch) / 1000;
    const amp = Math.pow(10, o.lib.gainDb(n.pitch, n.vel) / 20);
    const i0 = Math.floor(t0 * o.fs);
    const i1 = Math.min(out.length, Math.ceil((t1 + 0.6) * o.fs));
    const phases = [1, 2, 3, 4, 5, 6].map(h => hash(n.pitch * 31 + h) * 6.283);
    for (let i = Math.max(0, i0); i < i1; i++) {
      const t = i / o.fs - t0;
      if (t < 0) continue;
      let env = t < A ? 0.5 * (1 - Math.cos(Math.PI * t / A)) : Math.exp(-(t - A) * o.decay * 0.1);
      const tr = i / o.fs - t1;
      if (tr > 0) env *= Math.exp(-tr * 12);
      let v = 0;
      for (let h = 1; h <= 6; h++) {
        if (h * f0 > o.fs * 0.45) break;
        v += Math.sin(6.283185307 * h * f0 * t + phases[h - 1]) / h;
      }
      out[i] += amp * env * v * 0.5;
    }
  }
  return { sampleRate: o.fs, data: out };
}

/** Build a MIDI file from [{beat, beats, pitch, vel}] at a tempo. */
function part(list, o) {
  o = Object.assign({ bpm: 120, ppq: 480, extra: [] }, o || {});
  const events = [];
  let order = 0;
  const uspq = Math.round(60e6 / o.bpm);
  events.push({ tick: 0, kind: 'meta', type: 0x51, data: new Uint8Array([(uspq >> 16) & 255, (uspq >> 8) & 255, uspq & 255]), order: order++ });
  events.push({ tick: 0, kind: 'meta', type: 0x58, data: new Uint8Array([4, 2, 24, 8]), order: order++ });
  for (const e of o.extra) events.push(Object.assign({ order: order++ }, e, { tick: Math.round(e.beat * o.ppq) }));
  for (const n of list) {
    const t = Math.round(n.beat * o.ppq);
    events.push({ tick: t, kind: 'ch', status: 0x90, d1: n.pitch, d2: n.vel, order: order++ });
    events.push({ tick: t + Math.round(n.beats * o.ppq), kind: 'ch', status: 0x80, d1: n.pitch, d2: 0, order: order++ });
  }
  events.push({ tick: 0, kind: 'meta', type: 0x2f, data: new Uint8Array(0), order: order++ });
  return NPVF.writeMidi({ format: 0, division: o.ppq, tracks: [{ events }] });
}

module.exports = { LIBRARY, render, part, expectedOnsetMs, hash };
