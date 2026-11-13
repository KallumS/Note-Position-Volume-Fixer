#!/usr/bin/env node
/*
 * Drives the built page in Chromium (Playwright) the way a person would:
 * files in, results read, a note chosen from the keyboard, the fixed file
 * downloaded and checked; then a profile learned from the test MIDI.
 *
 *   node tools/build.js && node tests/ui_test.js [screenshot-folder]
 *
 * Needs Playwright (`require('playwright')`), which is not a dependency of
 * the app itself.
 */
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { chromium } = require('playwright');
const NPVF = require('../src/engine.js');
const S = require('./synth.js');

const root = path.join(__dirname, '..');
const shots = process.argv[2];
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'npvf-ui-'));
const write = (name, bytes) => { const p = path.join(work, name); fs.writeFileSync(p, Buffer.from(bytes)); return p; };

let failed = 0;
const check = (cond, msg) => { console.log((cond ? '  ok   ' : '  FAIL ') + msg); if (!cond) failed++; };

(async () => {
  const LINE = [60, 62, 64, 65, 67, 69, 71, 72, 71, 69, 67, 65, 64, 62, 60, 64, 67, 72, 67, 64];
  const midiBytes = S.part(LINE.map((p, i) => ({ beat: 4 + i * 0.5, beats: 0.25, pitch: p, vel: [70, 90, 110][i % 3] })));
  const audio = S.render(midiBytes);
  const midiPath = write('Violins staccato.mid', midiBytes);
  const wavPath = write('Violins staccato.wav', NPVF.encodeWav(audio.data, audio.sampleRate));

  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1180, height: 1500 }, deviceScaleFactor: shots ? 2 : 1, acceptDownloads: true });
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto('file://' + path.join(root, 'Note-Position-Volume-Fixer.html'));

  await page.setInputFiles('#midi-input', midiPath);
  await page.waitForFunction(() => /Now add the render/.test(document.getElementById('status').textContent));
  check(true, 'asks for the render once the MIDI is in');
  await page.setInputFiles('#audio-input', wavPath);
  await page.waitForSelector('#results:not(.hidden)', { timeout: 20000 });
  const statusText = await page.textContent('#status');
  check(/Measured (19|20) of 20 notes/.test(statusText), 'measures the part: ' + statusText);
  const rows = await page.$$eval('#table tbody tr', r => r.length);
  check(rows === 20, 'one table row a note: ' + rows);
  const tiles = await page.$$eval('.tile', t => t.map(x => x.textContent.replace(/\s+/g, ' ').trim()));
  check(tiles.length === 4, 'four summary tiles: ' + tiles.join(' | '));

  // the keyboard steps through notes
  await page.focus('#table tbody tr[tabindex="0"]');
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('ArrowDown');
  const sel = await page.$eval('#table tbody tr[aria-selected="true"]', tr => +tr.dataset.i);
  check(sel === 2, 'arrow keys move the selection: row ' + sel);
  const detail = await page.textContent('#detail-text');
  check(/^E3 at 2\.2\.1, velocity 110: heard \d+ ms after it was written, \d+\.\d dB louder/.test(detail), 'describes the note: ' + detail);
  if (shots) await page.screenshot({ path: path.join(shots, 'results.png'), fullPage: true });

  // the fixed file
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#download')]);
  check(dl.suggestedFilename() === 'Violins staccato (fixed).mid', 'file name: ' + dl.suggestedFilename());
  const fixed = fs.readFileSync(await dl.path());
  const again = NPVF.analyse(NPVF.parseMidi(midiBytes), S.render(fixed));
  const close = again.measured.filter(n => n.found && Math.abs(n.delay) < 0.01).length;
  check(Math.abs(again.stats.medianMs) < 3 && close >= 18, 'the downloaded file lands on the grid: median ' + again.stats.medianMs.toFixed(1) + ' ms, ' + close + ' of 20 notes within 10 ms');

  // a fixing setting re-plans without re-measuring
  await page.click('label[for=t-off]');
  await page.waitForFunction(() => /Nothing needs|velocit/.test(document.getElementById('status').textContent));
  const moved = await page.$$eval('#table tbody tr td:nth-child(7)', t => t.filter(x => x.textContent !== '–').length);
  check(moved === 0, "Don't move moves nothing");
  await page.click('label[for=t-note]');

  // learning a profile
  await page.click('label[for=src-profile]');
  await page.waitForSelector('#learn:not(.hidden)');
  check(await page.$eval('#learn', d => d.open), 'the learning steps open when there are no profiles');
  await page.fill('#cal-low', 'C2'); await page.fill('#cal-high', 'C4');
  await page.fill('#cal-vels', '50, 100'); await page.fill('#cal-takes', '1');
  const [calDl] = await Promise.all([page.waitForEvent('download'), page.click('#cal-download')]);
  check(calDl.suggestedFilename() === 'Test notes C2-C4.mid', 'test MIDI: ' + calDl.suggestedFilename());
  const calMidi = fs.readFileSync(await calDl.path());
  const calAudio = S.render(calMidi);
  await page.setInputFiles('#cal-input', write('Test render.wav', NPVF.encodeWav(calAudio.data, calAudio.sampleRate)));
  await page.waitForFunction(() => !document.getElementById('cal-learn').disabled);
  await page.fill('#cal-title', 'Synth strings staccato');
  await page.click('#cal-learn');
  await page.waitForFunction(() => /^Learned/.test(document.getElementById('cal-status').textContent), null, { timeout: 30000 });
  const learned = await page.textContent('#cal-status');
  check(/from 50 of 50 notes/.test(learned) && /E3/.test(learned) && /G3/.test(learned), 'learns and names the faulty keys: ' + learned);
  await page.waitForFunction(() => /Looked up 20 of 20/.test(document.getElementById('status').textContent), null, { timeout: 10000 });
  check(true, 'the part is fixed from the profile');
  const opts = await page.$$eval('#profile-select option', o => o.map(x => x.textContent));
  check(opts.includes('Synth strings staccato'), 'the profile is listed');
  if (shots) await page.screenshot({ path: path.join(shots, 'profile.png'), fullPage: true });

  // kept between visits
  await page.reload();
  const kept = await page.$$eval('#profile-select option', o => o.map(x => x.textContent));
  check(kept.includes('Synth strings staccato'), 'the profile is still there after reloading');

  // errors say what to do
  await page.setInputFiles('#midi-input', wavPath);
  await page.waitForFunction(() => document.getElementById('midi-error').textContent.length > 0);
  const err = await page.textContent('#midi-error');
  check(/isn't a MIDI file\. Choose a Standard MIDI File/.test(err), 'a wrong file says what to do: ' + err);

  check(errors.length === 0, 'no script errors' + (errors.length ? ': ' + errors.join('; ') : ''));
  await browser.close();
  fs.rmSync(work, { recursive: true, force: true });
  console.log(failed ? failed + ' failed' : 'all passed');
  process.exit(failed ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
