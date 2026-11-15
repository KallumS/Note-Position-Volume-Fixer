#!/usr/bin/env node
/*
 * The Mac app's bridge (mac/Sources/NPVFBridge + the Lua it loads), built
 * with the C compiler here and driven through tests/c/bridge_test.c.
 *
 * The app measures with the same Lua as the REAPER scripts, so the bridge
 * must give exactly what tests/lua/cli.lua gives, and be stoppable.
 *
 *   node tests/bridge_test.js      (needs cc and lua5.4)
 */
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');
const NPVF = require('../src/engine.js');
const S = require('./synth.js');

const ROOT = path.join(__dirname, '..');
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'npvf-bridge-'));
const file = (name, data) => { const p = path.join(work, name); fs.writeFileSync(p, typeof data === 'string' ? data : Buffer.from(data)); return p; };

let passed = 0, failed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log('  ok   ' + name); } catch (e) { failed++; console.log('  FAIL ' + name + '\n       ' + (e && e.message)); }
}
const ok = (c, m) => { if (!c) throw new Error(m || 'assertion failed'); };
const med = a => { const s = a.slice().sort((x, y) => x - y); return s[s.length >> 1]; };
const max = a => a.reduce((m, v) => Math.max(m, v), -Infinity);

// build: Lua, the bridge and the test driver, as the app's Package.swift does
const lua = path.join(work, 'lua');
execFileSync('sh', [path.join(ROOT, 'tools/stage_lua.sh'), lua]);
const exe = path.join(work, 'bridge_test');
const csrc = fs.readdirSync(path.join(ROOT, 'mac/Sources/CLua')).filter(f => f.endsWith('.c')).map(f => path.join(ROOT, 'mac/Sources/CLua', f));
const define = process.platform === 'darwin' ? '-DLUA_USE_MACOSX' : '-DLUA_USE_LINUX';
const cc = spawnSync('cc', ['-O2', '-std=c99', define, '-Wall', '-Wextra', '-Werror',
  '-I' + path.join(ROOT, 'mac/Sources/CLua/include'), '-I' + path.join(ROOT, 'mac/Sources/CLua'),
  '-I' + path.join(ROOT, 'mac/Sources/NPVFBridge/include'),
  ...csrc.map(f => ['-Wno-error', f]).flat().filter((x, i, a) => x !== '-Wno-error' || i === a.indexOf(x)),
  path.join(ROOT, 'mac/Sources/NPVFBridge/npvf_bridge.c'), path.join(ROOT, 'tests/c/bridge_test.c'),
  '-o', exe, '-lm'].concat(process.platform === 'darwin' ? [] : ['-ldl']), { encoding: 'utf8' });
if (cc.status !== 0) { console.log(cc.stderr); process.exit(1); }

const call = (fn, args) => JSON.parse(execFileSync(exe, [lua, 'call', fn, file('args.json', JSON.stringify(args))], { maxBuffer: 1 << 28 }).toString());
const cli = (...a) => JSON.parse(execFileSync('lua5.4', [path.join(ROOT, 'tests/lua/cli.lua'), ...a], { maxBuffer: 1 << 28 }).toString());

function layoutMidi(layout) {
  const ppq = 480, tick = t => Math.round(t * 2 * ppq);
  const events = [{ tick: 0, kind: 'meta', type: 0x51, data: Uint8Array.from([0x07, 0xa1, 0x20]), order: 0 }];
  let order = 1;
  for (const e of layout.events) {
    if (e.kind === 'note') {
      events.push({ tick: tick(e.t), kind: 'ch', status: 0x90 | e.chan, d1: e.pitch, d2: e.vel, order: order++ });
      events.push({ tick: tick(e.t + e.len), kind: 'ch', status: 0x80 | e.chan, d1: e.pitch, d2: 0, order: order++ });
    } else if (e.kind === 'cc') events.push({ tick: tick(e.t), kind: 'ch', status: 0xb0 | e.chan, d1: e.cc, d2: e.value, order: order++ });
  }
  events.push({ tick: tick(layout.length), kind: 'meta', type: 0x2f, data: new Uint8Array(0), order: order++ });
  return NPVF.writeMidi({ format: 0, division: ppq, tracks: [{ events }] });
}

console.log('The Mac app\'s bridge');

const testOpts = { low: 48, high: 72, levels: [40, 110], takes: 2 };
const layout = call('layout', Object.assign({ skipKeys: [] }, testOpts));

test('the test part is the same as the REAPER scripts\'', () => {
  const r = cli('layout', file('l.json', JSON.stringify(testOpts)));
  ok(JSON.stringify(layout.events) === JSON.stringify(r.events) && JSON.stringify(layout.notes) === JSON.stringify(r.notes));
  ok(Math.abs(layout.seconds - layout.length) < 1e-9, 'its length');
});

const audio = S.render(layoutMidi(layout));
const wav = file('render.wav', NPVF.encodeWav(audio.data, audio.sampleRate));
const meta = { instrument: 'Test strings', library: 'Test Library', articulation: 'Staccato', plugin: 'Fake (Test)', measuredBy: 'bridge test' };
const req = file('req.json', JSON.stringify({ layout, measure: {}, meta }));
const got = JSON.parse(execFileSync(exe, [lua, 'measure', wav, req], { maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'pipe'] }).toString());

test('a render measured through the bridge gives the REAPER scripts\' profile', () => {
  ok(!got.error, got.error);
  ok(got.file === 'Test Library - Test strings - Staccato.json', got.file);
  const r = cli('measure', wav, file('o.json', JSON.stringify({ test: testOpts, meta })));
  const strip = p => JSON.stringify(Object.assign({}, p, { created: 0, measuredIn: 0, sampleRate: 0, test: 0 }));
  const a = JSON.parse(strip(got.profile)), b = JSON.parse(strip(r.profile));
  const diff = Object.keys(Object.assign({}, a, b)).filter(k => JSON.stringify(a[k]) !== JSON.stringify(b[k]));
  ok(diff.length === 0, 'identical apart from when and where; differs in ' + diff.map(k => k + ': ' + JSON.stringify(a[k]) + ' vs ' + JSON.stringify(b[k])).join('; ').slice(0, 600));
  ok(got.profile.measuredIn === 'Note Fixer for Mac' && got.profile.sampleRate === 48000, 'says where it was measured');
});

test('and it is right about the library', () => {
  const err = got.profile.entries.map(e => Math.abs(e.delayMs - S.expectedOnsetMs(e.pitch, e.vel)));
  ok(med(err) < 1 && max(err) < 6, 'median ' + med(err) + ' worst ' + max(err));
  ok(got.stats.found === got.stats.notes, 'every note');
});

test('Stop stops it', () => {
  const r = spawnSync(exe, [lua, 'measure', wav, req, '5'], { encoding: 'utf8', maxBuffer: 1 << 28 });
  const out = JSON.parse(r.stdout);
  ok(out.error === 'stopped', JSON.stringify(out).slice(0, 200));
  ok(/progress calls: 5 of 100/.test(r.stderr), r.stderr);
});

test('maps are read through it, with each articulation in words', () => {
  const text = fs.readFileSync(path.join(ROOT, 'tests/fixtures/Test Strings.reabank'), 'utf8');
  const m = call('parseMap', { text, filename: 'Test Strings.reabank', name: 'Cellos' });
  ok(m.format === 'reaticulate' && m.banks.length === 2 && m.best === 2, 'banks, and the one named like the instrument');
  ok(m.banks[0].articulations[0].describe === 'C-1 + D2', m.banks[0].articulations[0].describe);
  const bad = call('parseMap', { text: 'hello', filename: 'x.txt' });
  ok(/expressionmap/.test(bad.error), bad.error);
});

test('the index and the file names are the REAPER scripts\'', () => {
  const idx = call('index', { files: [{ file: 'a.json', profile: got.profile }, { file: 'junk.json', profile: { hello: 1 } }], now: 'then' });
  ok(idx.kind === 'note-position-volume-fixer/library' && idx.profiles.length === 1 && idx.updated === 'then');
  ok(idx.profiles[0].file === 'Profiles/a.json' && idx.profiles[0].medianMs === got.profile.summary.medianMs);
  ok(call('profileFileName', { instrument: 'Violins: 1', articulation: 'Spic/Stac' }).file === 'Violins- 1 - Spic-Stac.json');
});

test('broken input comes back as an error, not a crash', () => {
  const r = JSON.parse(execFileSync(exe, [lua, 'call', 'layout', file('bad.json', '{"low": ')]).toString());
  ok(typeof r.error === 'string', JSON.stringify(r));
  const missing = spawnSync(exe, [path.join(work, 'nowhere'), 'call', 'layout', file('x.json', '{}')], { encoding: 'utf8' });
  ok(/openError/.test(missing.stdout), missing.stdout);
});

fs.rmSync(work, { recursive: true, force: true });
console.log('\n' + passed + ' passed, ' + failed + ' failed');
process.exit(failed ? 1 : 0);
