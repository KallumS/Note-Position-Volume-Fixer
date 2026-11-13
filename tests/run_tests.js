#!/usr/bin/env node
/*
 * The engine's tests. No dependencies: `node tests/run_tests.js`.
 *
 * Most use the made-up library in synth.js, whose right answers are known:
 * each test renders a part, measures it, fixes it, renders the fixed part and
 * checks the sound now lands on the grid ("true after" below is measured
 * against the library's own numbers, not against the tool's opinion of
 * itself).
 */
'use strict';
const NPVF = require('../src/engine.js');
const S = require('./synth.js');

let passed = 0, failed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log('  ok   ' + name); }
  catch (e) { failed++; console.log('  FAIL ' + name + '\n       ' + (e && e.message)); }
}
function ok(cond, msg) { if (!cond) throw new Error(msg || 'assertion failed'); }
function near(a, b, tol, msg) { ok(Math.abs(a - b) <= tol, (msg || '') + ' expected ' + b + ' ± ' + tol + ', got ' + a); }
const med = a => { const s = a.slice().sort((x, y) => x - y); return s.length ? s[s.length >> 1] : NaN; };
const max = a => a.reduce((m, v) => Math.max(m, v), -Infinity);

const LINE = [60, 62, 64, 65, 67, 69, 71, 72, 71, 69, 67, 65, 64, 62, 60, 64, 67, 72, 67, 64];
const eighths = (shift) => LINE.map((p, i) => ({ beat: 4 + i * 0.5, beats: 0.25, pitch: p + (shift || 0), vel: [70, 90, 110][i % 3] }));
const trueAfter = p => p.changes.filter(c => c.note.found).map(c => Math.abs(c.shiftMs + S.expectedOnsetMs(c.note.pitch, c.newVel)));
const CHORDS = [[48, 52, 55], [50, 53, 57], [52, 55, 59], [53, 57, 60], [55, 59, 62], [48, 52, 55]];
const chordPart = () => { const l = []; CHORDS.forEach((c, i) => c.forEach(p => l.push({ beat: 4 + i * 2, beats: 1.5, pitch: p, vel: 90 }))); return l; };

console.log('MIDI');

test('a file reads back exactly as written', () => {
  const bytes = S.part(eighths());
  const again = NPVF.writeMidi(NPVF.parseMidi(bytes));
  ok(Buffer.compare(Buffer.from(bytes), Buffer.from(again)) === 0, 'bytes differ');
});

test('running status, format 1 and several tracks are read', () => {
  const b = [0x4d, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 1, 0, 2, 0, 96,
    0x4d, 0x54, 0x72, 0x6b, 0, 0, 0, 11, 0, 0xff, 0x51, 3, 0x07, 0xa1, 0x20, 0, 0xff, 0x2f, 0,
    0x4d, 0x54, 0x72, 0x6b, 0, 0, 0, 17, 0, 0x90, 60, 100, 48, 62, 90, 48, 60, 0, 0, 62, 0, 0, 0xff, 0x2f, 0];
  const midi = NPVF.parseMidi(Uint8Array.from(b));
  const notes = NPVF.collectNotes(midi);
  ok(notes.length === 2, 'two notes, got ' + notes.length);
  ok(notes[0].pitch === 60 && notes[0].endTick === 96 && notes[1].pitch === 62 && notes[1].startTick === 48, 'pairs');
  near(NPVF.tempoMap(midi).bpmAtStart, 120, 1e-9);
});

test('ticks and seconds convert both ways across a tempo change', () => {
  const ev = [
    { tick: 0, kind: 'meta', type: 0x51, data: Uint8Array.from([0x07, 0xa1, 0x20]), order: 0 }, // 120
    { tick: 960, kind: 'meta', type: 0x51, data: Uint8Array.from([0x0f, 0x42, 0x40]), order: 1 }, // 60
  ];
  const tm = NPVF.tempoMap({ division: 480, tracks: [{ events: ev }] });
  near(tm.toSec(960), 1, 1e-9);
  near(tm.toSec(1440), 2, 1e-9);
  near(tm.toTick(1.5), 1200, 1e-6);
  near(tm.toTick(-0.1), -96, 1e-6, 'before the start');
});

test('note names follow Ableton and Cubase (middle C is C3)', () => {
  ok(NPVF.noteName(60) === 'C3' && NPVF.noteName(21) === 'A-1' && NPVF.noteName(61) === 'C#3');
});

console.log('Audio files');

function wav(bits, float, channels, frames) {
  const bps = bits / 8, n = frames * channels;
  const b = Buffer.alloc(44 + n * bps);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n * bps, 4); b.write('WAVE', 8); b.write('fmt ', 12);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(float ? 3 : 1, 20); b.writeUInt16LE(channels, 22);
  b.writeUInt32LE(44100, 24); b.writeUInt32LE(44100 * channels * bps, 28); b.writeUInt16LE(channels * bps, 32); b.writeUInt16LE(bits, 34);
  b.write('data', 36); b.writeUInt32LE(n * bps, 40);
  for (let i = 0; i < frames; i++) for (let c = 0; c < channels; c++) {
    const v = (c === 0 ? 0.5 : -0.25) * (i % 2 ? -1 : 1), p = 44 + (i * channels + c) * bps;
    if (float) b.writeFloatLE(v, p);
    else if (bits === 16) b.writeInt16LE(Math.round(v * 32767), p);
    else if (bits === 24) b.writeIntLE(Math.round(v * 8388607), p, 3);
  }
  return b;
}

test('WAV: 16-bit, 24-bit and float, stereo mixed to mono', () => {
  for (const [bits, float] of [[16, false], [24, false], [32, true]]) {
    const a = NPVF.decodeAudio(wav(bits, float, 2, 10));
    ok(a.sampleRate === 44100 && a.data.length === 10, bits + '-bit length');
    near(a.data[0], 0.125, 1e-3, bits + '-bit value');
    near(a.data[1], -0.125, 1e-3, bits + '-bit value');
  }
});

test('AIFF: 16-bit big-endian at 48 kHz', () => {
  const frames = 4, b = Buffer.alloc(12 + 26 + 16 + frames * 2);
  b.write('FORM', 0); b.writeUInt32BE(b.length - 8, 4); b.write('AIFF', 8);
  b.write('COMM', 12); b.writeUInt32BE(18, 16); b.writeUInt16BE(1, 20); b.writeUInt32BE(frames, 22); b.writeUInt16BE(16, 26);
  Buffer.from([0x40, 0x0e, 0xbb, 0x80, 0, 0, 0, 0, 0, 0]).copy(b, 28); // 48000
  b.write('SSND', 38); b.writeUInt32BE(8 + frames * 2, 42); b.writeUInt32BE(0, 46); b.writeUInt32BE(0, 50);
  for (let i = 0; i < frames; i++) b.writeInt16BE(i * 8192, 54 + i * 2);
  const a = NPVF.decodeAudio(b);
  ok(a.sampleRate === 48000, 'rate ' + a.sampleRate);
  near(a.data[2], 0.5, 1e-4);
});

test('anything else is refused with a reason', () => {
  let msg = '';
  try { NPVF.decodeAudio(Buffer.from('ID3 not a wav at all')); } catch (e) { msg = e.message; }
  ok(/WAV or AIFF/.test(msg), msg);
});

console.log('Finding notes in a render');

const line = S.part(eighths());
const lineAudio = S.render(line);
const lineResult = NPVF.analyse(NPVF.parseMidi(line), lineAudio);

test('a staccato line: nearly every note found, to within a few ms', () => {
  ok(lineResult.stats.found >= 19, 'found ' + lineResult.stats.found);
  const err = lineResult.measured.filter(n => n.found).map(n => Math.abs(n.delay * 1000 - S.expectedOnsetMs(n.pitch, n.vel)));
  ok(med(err) <= 2, 'median error ' + med(err));
  ok(max(err) <= 10, 'worst error ' + max(err));
});

test('the fixed line, rendered again, lands on the grid', () => {
  const p = NPVF.plan(lineResult);
  const t = trueAfter(p);
  ok(med(t) <= 3, 'median ' + med(t));
  ok(max(t) <= 12, 'worst ' + max(t));
  const again = NPVF.analyse(NPVF.parseMidi(line), S.render(NPVF.applyPlan(p)));
  ok(Math.abs(again.stats.medianMs) <= 3, 'measured median after ' + again.stats.medianMs);
});

test('the louder and quieter keys are the ones flagged, by about the right amount', () => {
  for (const [pitch, fault] of Object.entries(S.LIBRARY.faults)) {
    const devs = lineResult.measured.filter(n => n.found && n.pitch === +pitch).map(n => n.deviationDb);
    ok(devs.length, 'key ' + pitch + ' measured');
    near(med(devs), fault, 1.5, 'key ' + pitch);
  }
  const clean = lineResult.measured.filter(n => n.found && !S.LIBRARY.faults[n.pitch]).map(n => Math.abs(n.deviationDb));
  ok(med(clean) < 1, 'clean keys median ' + med(clean));
});

test('velocity changes even the loudness out when rendered again', () => {
  const p = NPVF.plan(lineResult, { timingMode: 'off' });
  ok(p.summary.velocityChanged >= 8, 'changed ' + p.summary.velocityChanged);
  const again = NPVF.analyse(NPVF.parseMidi(line), S.render(NPVF.applyPlan(p)));
  ok(again.stats.loudSdDb < lineResult.stats.loudSdDb / 3, lineResult.stats.loudSdDb + ' -> ' + again.stats.loudSdDb);
});

test('low and high registers', () => {
  for (const shift of [-24, 19]) {
    const m = S.part(eighths(shift));
    const r = NPVF.analyse(NPVF.parseMidi(m), S.render(m));
    ok(r.stats.found >= 18, 'shift ' + shift + ' found ' + r.stats.found);
    const t = trueAfter(NPVF.plan(r));
    ok(med(t) <= 4 && max(t) <= 20, 'shift ' + shift + ' median ' + med(t) + ' worst ' + max(t));
  }
});

test('fast sixteenths, each sound starting after the next note is written', () => {
  const list = LINE.concat(LINE).map((p, i) => ({ beat: 4 + i * 0.25, beats: 0.125, pitch: p, vel: [70, 90, 110][i % 3] }));
  const m = S.part(list, { bpm: 140 });
  const r = NPVF.analyse(NPVF.parseMidi(m), S.render(m));
  ok(r.stats.found >= 30, 'found ' + r.stats.found);
  const t = trueAfter(NPVF.plan(r));
  ok(med(t) <= 4, 'median ' + med(t));
});

test('legato, each note overlapping the next', () => {
  const m = S.part(LINE.map((p, i) => ({ beat: 4 + i, beats: 1.05, pitch: p, vel: [70, 90, 110][i % 3] })));
  const r = NPVF.analyse(NPVF.parseMidi(m), S.render(m));
  ok(r.stats.found >= 18, 'found ' + r.stats.found);
  const t = trueAfter(NPVF.plan(r));
  ok(med(t) <= 8 && max(t) <= 15, 'median ' + med(t) + ' worst ' + max(t));
});

test('a chord is heard as one attack and its notes move together', () => {
  const m = S.part(chordPart());
  const r = NPVF.analyse(NPVF.parseMidi(m), S.render(m));
  ok(r.chords === CHORDS.length, 'chords ' + r.chords);
  const p = NPVF.plan(r);
  for (let i = 0; i < CHORDS.length; i++) {
    const cs = p.changes.filter(c => c.note.chord === p.changes[i * 3].note.chord);
    const heard = cs.map(c => c.note.onset * 1000 + c.shiftMs);
    ok(max(heard) - Math.min.apply(null, heard) < 0.6, 'chord ' + i + ' notes land together');
    const first = Math.min.apply(null, cs.map(c => c.shiftMs + S.expectedOnsetMs(c.note.pitch, c.newVel)));
    ok(Math.abs(first) <= 10, 'chord ' + i + ' first attack at ' + first);
  }
});

test('repeated notes on one key', () => {
  const m = S.part(Array.from({ length: 16 }, (_, i) => ({ beat: 4 + i * 0.5, beats: 0.2, pitch: 62, vel: [60, 100][i % 2] })));
  const r = NPVF.analyse(NPVF.parseMidi(m), S.render(m));
  ok(r.stats.found === 16, 'found ' + r.stats.found);
  ok(max(trueAfter(NPVF.plan(r))) <= 3);
});

test('an unpitched sound is measured on the whole sound', () => {
  const m = S.part(Array.from({ length: 12 }, (_, i) => ({ beat: 4 + i * 0.5, beats: 0.2, pitch: 60, vel: 100 })));
  const fs = 48000, out = new Float32Array(fs * 6);
  let s = 7;
  const rnd = () => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff - 0.5; };
  for (let i = 0; i < 12; i++) {
    const t0 = 2 + i * 0.25 + 0.06 + 0.002 * i;
    for (let k = 0; k < fs * 0.1; k++) out[Math.floor(t0 * fs) + k] += rnd() * Math.exp(-k / fs * 40);
  }
  const r = NPVF.analyse(NPVF.parseMidi(m), { sampleRate: fs, data: out });
  ok(r.stats.found === 12, 'found ' + r.stats.found);
  r.measured.forEach((n, i) => near(n.delay * 1000, 60 + 2 * i, 2, 'note ' + i));
});

test('"Start of sound" finds the earliest sound, before the attack', () => {
  const r = NPVF.analyse(NPVF.parseMidi(line), lineAudio, { alignTo: 'start' });
  const diffs = r.measured.filter(n => n.found).map(n => n.delay * 1000 - S.LIBRARY.delayMs(n.pitch, n.vel));
  ok(med(diffs) >= -1 && med(diffs) <= 8, 'median after sample start ' + med(diffs));
  const att = lineResult.measured.filter(n => n.found).map(n => n.delay);
  ok(med(r.measured.filter(n => n.found).map(n => n.delay)) < med(att), 'earlier than the attack');
});

test('audio that starts later than the MIDI can be lined up', () => {
  const pad = Math.round(0.5 * lineAudio.sampleRate);
  const data = new Float32Array(lineAudio.data.length + pad);
  data.set(lineAudio.data, pad);
  const r = NPVF.analyse(NPVF.parseMidi(line), { sampleRate: lineAudio.sampleRate, data }, { audioOffsetMs: 500 });
  near(r.stats.medianMs, lineResult.stats.medianMs, 0.5);
});

test('audio that starts too early gets a warning', () => {
  const cut = Math.round(0.15 * lineAudio.sampleRate);
  const r = NPVF.analyse(NPVF.parseMidi(line), { sampleRate: lineAudio.sampleRate, data: lineAudio.data.subarray(cut) }, { maxDelayMs: 400 });
  ok(r.warnings.some(w => /before the first note/.test(w)), r.warnings.join(' | '));
});

console.log('Writing the fixed file');

test('notes moved before the start push the part later by whole bars', () => {
  const m = S.part([{ beat: 0, beats: 0.5, pitch: 60, vel: 90 }, { beat: 1, beats: 0.5, pitch: 62, vel: 90 }]);
  const r = NPVF.analyse(NPVF.parseMidi(m), S.render(m));
  const p = NPVF.plan(r);
  ok(p.barsAdded === 1, 'bars ' + p.barsAdded);
  const out = NPVF.parseMidi(NPVF.applyPlan(p));
  const notes = NPVF.collectNotes(out);
  ok(notes[0].startTick > 0 && notes[0].startTick < 1920, 'first note ' + notes[0].startTick);
  const tempo = out.tracks[0].events.find(e => e.kind === 'meta' && e.type === 0x51);
  ok(tempo.tick === 0, 'tempo stays at the start');
});

test('a keyswitch moves ahead of the note it switches', () => {
  const m = S.part([{ beat: 4, beats: 0.5, pitch: 60, vel: 90 }, { beat: 4, beats: 0.1, pitch: 12, vel: 100 }, { beat: 6, beats: 0.5, pitch: 62, vel: 90 }]);
  const r = NPVF.analyse(NPVF.parseMidi(m), S.render(m), { keyswitchMax: 23 });
  ok(r.measured.length === 2, 'keyswitch not measured');
  const out = NPVF.collectNotes(NPVF.parseMidi(NPVF.applyPlan(NPVF.plan(r))));
  const ks = out.find(n => n.pitch === 12), n60 = out.find(n => n.pitch === 60);
  ok(n60.startTick < 1920, 'note moved');
  ok(ks.startTick <= n60.startTick, 'keyswitch at ' + ks.startTick + ', note at ' + n60.startTick);
});

test('an articulation CC on the note moves with it; a CC1 curve elsewhere stays', () => {
  const extra = [{ beat: 4, kind: 'ch', status: 0xb0, d1: 32, d2: 5 }, { beat: 3.9, kind: 'ch', status: 0xb0, d1: 1, d2: 64 }];
  const m = S.part([{ beat: 4, beats: 0.5, pitch: 60, vel: 90 }, { beat: 6, beats: 0.5, pitch: 62, vel: 90 }], { extra });
  const r = NPVF.analyse(NPVF.parseMidi(m), S.render(m));
  const outMidi = NPVF.parseMidi(NPVF.applyPlan(NPVF.plan(r)));
  const evs = outMidi.tracks[0].events;
  const cc32 = evs.find(e => e.kind === 'ch' && e.d1 === 32 && (e.status & 0xf0) === 0xb0);
  const cc1 = evs.find(e => e.kind === 'ch' && e.d1 === 1 && (e.status & 0xf0) === 0xb0);
  const on = evs.find(e => e.kind === 'ch' && (e.status & 0xf0) === 0x90 && e.d1 === 60);
  ok(cc32.tick === on.tick && evs.indexOf(cc32) < evs.indexOf(on), 'CC32 with and before the note');
  ok(cc1.tick === Math.round(3.9 * 480), 'CC1 left alone');
});

test('a note moved under the same key\'s previous note shortens that note', () => {
  const fake = {
    options: Object.assign({}, NPVF.ANALYSE_DEFAULTS), model: { dbPerVelocity: 0.25 },
    midi: NPVF.parseMidi(S.part([{ beat: 0, beats: 1, pitch: 60, vel: 90 }, { beat: 1, beats: 1, pitch: 60, vel: 90 }])),
  };
  fake.tempo = NPVF.tempoMap(fake.midi); fake.timeSig = NPVF.timeSignature(fake.midi);
  fake.notes = fake.measured = NPVF.collectNotes(fake.midi).map((n, i) => Object.assign(n, { found: true, delay: i ? 0.2 : 0, deviationDb: 0 }));
  const p = NPVF.plan(fake);
  ok(p.changes[0].newEndTick <= p.changes[1].newStartTick, 'end ' + p.changes[0].newEndTick + ' start ' + p.changes[1].newStartTick);
  const out = NPVF.collectNotes(NPVF.parseMidi(NPVF.applyPlan(p)));
  ok(out.length === 2, 'both notes survive: ' + out.length);
});

test('CC11 instead of velocity: one value per note, lower on the loud key', () => {
  const p = NPVF.plan(lineResult, { volumeTarget: 'cc11', timingMode: 'off' });
  ok(p.summary.velocityChanged === 0, 'velocities untouched');
  ok(p.summary.cc11Written === lineResult.stats.found, 'one CC11 a note');
  const loud = p.changes.find(c => c.note.pitch === 64 && c.note.found);
  ok(loud.cc11 < 100 - 10, 'key 64 turned down: ' + loud.cc11);
  const evs = NPVF.parseMidi(NPVF.applyPlan(p)).tracks[0].events;
  const i = evs.findIndex(e => e.kind === 'ch' && (e.status & 0xf0) === 0x90 && e.d1 === 64);
  ok(evs[i - 1].d1 === 11 && (evs[i - 1].status & 0xf0) === 0xb0, 'CC11 just before the note');
});

test('velocities stay between 1 and 127', () => {
  const p = NPVF.plan(lineResult, { dbPerVelocity: 0.01 });
  ok(p.changes.every(c => c.newVel >= 1 && c.newVel <= 127));
});

test('Each key and Whole part modes', () => {
  const pk = NPVF.plan(lineResult, { timingMode: 'pitch' });
  const same = pk.changes.filter(c => c.note.pitch === 62 && c.note.vel === 90 && c.note.found).map(c => c.shiftMs);
  ok(same.length >= 2 && max(same) - Math.min.apply(null, same) < 1.1, 'one shift per key and velocity');
  const whole = NPVF.plan(lineResult, { timingMode: 'part' });
  const shifts = whole.changes.filter(c => c.note.found).map(c => c.shiftMs);
  ok(max(shifts) - Math.min.apply(null, shifts) < 1.1, 'one shift for all');
});

test('only the chosen track is measured and moved', () => {
  const a = NPVF.parseMidi(line);
  const other = NPVF.parseMidi(S.part([{ beat: 4.25, beats: 0.25, pitch: 40, vel: 90 }]));
  const two = NPVF.parseMidi(NPVF.writeMidi({ format: 1, division: 480, tracks: [a.tracks[0], { events: other.tracks[0].events.filter(e => e.kind === 'ch' || e.type === 0x2f) }] }));
  ok(NPVF.noteTracks(two).length === 2, 'two tracks with notes');
  const r = NPVF.analyse(two, lineAudio, { track: 0 });
  ok(r.measured.length === LINE.length, 'measured ' + r.measured.length);
  const out = NPVF.collectNotes(NPVF.parseMidi(NPVF.applyPlan(NPVF.plan(r))));
  ok(out.find(n => n.pitch === 40).startTick === Math.round(4.25 * 480), 'other track untouched');
});

test('a part played at another tempo than its file says', () => {
  const at90 = S.part(eighths(), { bpm: 90 });
  const audio90 = S.render(at90);
  const r = NPVF.analyse(NPVF.parseMidi(line), audio90, { tempoBpm: 90 }); // the file says 120
  ok(r.stats.found >= 19, 'found ' + r.stats.found);
  near(r.stats.medianMs, lineResult.stats.medianMs, 3);
  const out = NPVF.collectNotes(NPVF.parseMidi(NPVF.applyPlan(NPVF.plan(r))));
  const tm90 = NPVF.tempoMap(NPVF.parseMidi(line), 90);
  const c = NPVF.plan(r).changes[0];
  near((tm90.toSec(out[0].startTick) - tm90.toSec(c.note.startTick)) * 1000, c.shiftMs, 1.2, 'shift at 90 BPM');
});

console.log('Learned profiles');

const cal = NPVF.calibrationMidi({ low: 36, high: 84, velocities: [40, 80, 120] });
const calResult = NPVF.analyse(NPVF.parseMidi(cal), S.render(cal));
const profile = NPVF.learnProfile(calResult, 'Test strings');

test('the test render is measured completely and accurately', () => {
  ok(calResult.stats.found === calResult.stats.notes, calResult.stats.found + '/' + calResult.stats.notes);
  const err = profile.entries.map(e => Math.abs(e.delayMs - S.expectedOnsetMs(e.pitch, e.vel)));
  ok(med(err) < 1 && max(err) < 6, 'median ' + med(err) + ' worst ' + max(err));
});

test('the profile names the faulty keys', () => {
  for (const [pitch, fault] of Object.entries(S.LIBRARY.faults)) {
    for (const e of profile.entries.filter(e => e.pitch === +pitch)) near(e.deviationDb, fault, 0.5, 'key ' + pitch);
  }
  ok(profile.entries.filter(e => !S.LIBRARY.faults[e.pitch]).every(e => Math.abs(e.deviationDb) < 0.6), 'clean keys clean');
});

test('a profile survives saving as JSON', () => {
  const back = NPVF.checkProfile(JSON.parse(JSON.stringify(profile)));
  ok(back.entries.length === profile.entries.length && back.name === 'Test strings');
  let msg = '';
  try { NPVF.checkProfile({ hello: 1 }); } catch (e) { msg = e.message; }
  ok(/isn't a profile/.test(msg), msg);
});

test('in between the measured velocities, values are interpolated', () => {
  const a = NPVF.profileAt(profile, 60, 40).delayMs, b = NPVF.profileAt(profile, 60, 80).delayMs;
  near(NPVF.profileAt(profile, 60, 60).delayMs, (a + b) / 2, 1e-9);
  ok(NPVF.profileAt(profile, 100, 80).outside, 'beyond the range');
});

test('a profile fixes lines, legato and chords without rendering them', () => {
  const parts = {
    line: eighths(),
    legato: LINE.map((p, i) => ({ beat: 4 + i, beats: 1.05, pitch: p, vel: [70, 90, 110][i % 3] })),
    chords: chordPart(),
  };
  for (const [name, list] of Object.entries(parts)) {
    const p = NPVF.plan(NPVF.fromProfile(NPVF.parseMidi(S.part(list)), profile));
    const t = p.changes.map(c => Math.abs(c.shiftMs + S.expectedOnsetMs(c.note.pitch, c.newVel)));
    ok(max(t) <= 3, name + ' worst ' + max(t));
    const loud = p.changes.map(c => S.LIBRARY.gainDb(c.note.pitch, c.newVel) - (-34 + 0.25 * c.note.vel - 0.08 * (c.note.pitch - 60)));
    ok(max(loud.map(Math.abs)) <= 0.5, name + ' loudness off by ' + max(loud.map(Math.abs)));
  }
});

test('a profile measured on CC1 is looked up by each note\'s CC1, not its velocity', () => {
  const cc1Profile = Object.assign({}, profile, { dynamics: 'cc1' });
  const extra = [{ beat: 3.5, kind: 'ch', status: 0xb0, d1: 1, d2: 40 }, { beat: 5.5, kind: 'ch', status: 0xb0, d1: 1, d2: 120 }];
  const m = NPVF.parseMidi(S.part([{ beat: 4, beats: 1, pitch: 64, vel: 100 }, { beat: 6, beats: 1, pitch: 64, vel: 100 }], { extra }));
  const r = NPVF.fromProfile(m, cc1Profile);
  ok(r.preferCC11, 'asks for CC11');
  near(r.measured[0].delay * 1000, NPVF.profileAt(profile, 64, 40).delayMs, 1e-9, 'CC1 40');
  near(r.measured[1].delay * 1000, NPVF.profileAt(profile, 64, 120).delayMs, 1e-9, 'CC1 120');
  const p = NPVF.plan(r, { volumeTarget: 'cc11' });
  ok(p.changes.every(c => c.newVel === 100) && p.changes.every(c => c.cc11 < 100), 'velocity kept, CC11 down on the loud key');
});

console.log('\n' + passed + ' passed, ' + failed + ' failed');
process.exit(failed ? 1 : 0);
