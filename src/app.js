/*
 * The page: files in, settings, results drawn, fixed MIDI out.
 * All measuring is the engine's (NPVF); this file only wires it to the window.
 */
(function () {
  'use strict';
  const $ = id => document.getElementById(id);
  const C = {
    roll: '#111419', rule: '#3A404A', thumb: '#6D7581', control: '#A9AFBA', text: '#DDE1E7',
    dim: '#B0B6C0', focus: '#F2F4F7', accent: '#FFF200', warn: '#D2483F',
  };
  const state = {
    source: 'render', midi: null, midiName: '', track: -1, audio: null, audioName: '', lossy: false,
    profiles: [], profile: null, result: null, plan: null, selected: -1,
    calAudio: null, calName: '', calParams: null,
  };

  // ---------------------------------------------------------------- helpers

  const fmt = (v, d) => (isFinite(v) ? v.toFixed(d === undefined ? 1 : d) : '–');
  const signed = (v, d) => {
    if (!isFinite(v)) return '–';
    const t = Math.abs(v).toFixed(d === undefined ? 1 : d);
    return (+t === 0 ? '' : v > 0 ? '+' : '−') + t;
  };
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const radio = name => document.querySelector('input[name="' + name + '"]:checked').value;
  const num = (id, dflt) => { const v = parseFloat($(id).value); return isFinite(v) ? v : dflt; };
  const later = () => new Promise(r => setTimeout(r, 30));
  const baseName = n => n.replace(/\.[^.]+$/, '');

  function parseNote(s) {
    const m = /^\s*([A-Ga-g])\s*([#b♯♭]?)\s*(-?\d+)\s*$/.exec(s || '');
    if (!m) return null;
    const base = { c: 0, d: 2, e: 4, f: 5, g: 7, a: 9, b: 11 }[m[1].toLowerCase()];
    const acc = (m[2] === '#' || m[2] === '♯') ? 1 : (m[2] === 'b' || m[2] === '♭') ? -1 : 0;
    const p = base + acc + (parseInt(m[3], 10) + 2) * 12;
    return p >= 0 && p <= 127 ? p : null;
  }

  function download(bytes, name, type) {
    const url = URL.createObjectURL(new Blob([bytes], { type }));
    const a = document.createElement('a');
    a.href = url; a.download = name;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 5000);
  }

  function status(text) { $('status').textContent = text; }
  function messages(list) {
    $('messages').innerHTML = list.map(m => '<p class="' + (m.info ? 'note-box' : 'msg') + '">' + esc(m.text || m) + '</p>').join('');
  }

  // --------------------------------------------------------------- storage

  function loadProfiles() {
    try { const v = JSON.parse(localStorage.getItem('npvf.profiles') || '[]'); return Array.isArray(v) ? v : []; } catch (e) { return []; }
  }
  function storeProfiles() {
    try { localStorage.setItem('npvf.profiles', JSON.stringify(state.profiles)); return true; } catch (e) { return false; }
  }
  function addProfile(p) {
    const i = state.profiles.findIndex(q => q.name === p.name);
    if (i >= 0) state.profiles[i] = p; else state.profiles.push(p);
    state.profiles.sort((a, b) => a.name.localeCompare(b.name));
    const saved = storeProfiles();
    state.profile = p;
    fillProfiles();
    if (!saved) $('profile-error').textContent = "This browser won't keep profiles between visits. Use Save Profile File… to keep it.";
  }
  function fillProfiles() {
    const sel = $('profile-select');
    sel.innerHTML = state.profiles.length
      ? state.profiles.map((p, i) => '<option value="' + i + '"' + (p === state.profile ? ' selected' : '') + '>' + esc(p.name) + '</option>').join('')
      : '<option value="">None saved yet</option>';
    if (!state.profile && state.profiles.length) state.profile = state.profiles[0];
    const p = state.profile;
    $('profile-save').disabled = $('profile-delete').disabled = !p;
    if (p) {
      const keys = new Set(p.entries.map(e => e.pitch));
      const lo = Math.min.apply(null, Array.from(keys)), hi = Math.max.apply(null, Array.from(keys));
      const d = p.entries.map(e => e.delayMs);
      $('profile-info').textContent = keys.size + ' keys from ' + NPVF.noteName(lo) + ' to ' + NPVF.noteName(hi) +
        ', heard ' + fmt(Math.min.apply(null, d), 0) + ' to ' + fmt(Math.max.apply(null, d), 0) + ' ms late. Learned ' + new Date(p.created).toLocaleDateString() + '.';
    } else {
      $('profile-info').textContent = 'A profile is learned once per patch from a test render, then fixes any part played on that patch without rendering it.';
    }
  }

  // ----------------------------------------------------------------- files

  async function decodeAudioFile(buf, name) {
    try { return { audio: NPVF.decodeAudio(new Uint8Array(buf)), lossy: false }; } catch (e) {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) throw new Error("Couldn't read " + name + '. Use a WAV or AIFF file.');
      const ctx = new Ctx();
      try {
        const ab = await ctx.decodeAudioData(buf.slice(0));
        const n = ab.length, ch = ab.numberOfChannels, out = new Float32Array(n);
        for (let c = 0; c < ch; c++) { const d = ab.getChannelData(c); for (let i = 0; i < n; i++) out[i] += d[i] / ch; }
        return { audio: { sampleRate: ab.sampleRate, channels: ch, data: out }, lossy: /\.(mp3|m4a|aac|ogg)$/i.test(name) };
      } catch (e2) {
        throw new Error("Couldn't read " + name + '. Use a WAV or AIFF file.');
      } finally { if (ctx.close) ctx.close(); }
    }
  }

  async function takeMidi(file) {
    $('midi-error').textContent = '';
    try {
      const midi = NPVF.parseMidi(new Uint8Array(await file.arrayBuffer()));
      const tracks = NPVF.noteTracks(midi);
      if (!tracks.length) throw new Error(file.name + ' has no notes in it.');
      state.midi = midi; state.midiName = file.name;
      state.track = tracks.length > 1 ? tracks[0].index : -1;
      $('midi-name').textContent = file.name;
      const tm = NPVF.tempoMap(midi);
      const notes = NPVF.collectNotes(midi).length;
      let info = notes + (notes === 1 ? ' note' : ' notes') + ', ' + fmt(tm.bpmAtStart, tm.bpmAtStart % 1 ? 2 : 0) + ' BPM' + (tm.segs.length > 1 ? ' at the start (tempo changes)' : '') + '.';
      if (!tm.hasTempo) info += ' The file has no tempo, so 120 BPM is assumed.';
      $('midi-info').textContent = info;
      $('bpm').value = tm.segs.length > 1 ? '' : +tm.bpmAtStart.toFixed(2);
      let pick = $('track-pick');
      if (pick) pick.remove();
      if (tracks.length > 1) {
        pick = document.createElement('label');
        pick.className = 'field'; pick.id = 'track-pick';
        pick.innerHTML = '<span>The file has ' + tracks.length + ' tracks with notes. Fix</span><select id="track">' +
          tracks.map(t => '<option value="' + t.index + '">' + esc(t.name || 'Track ' + (t.index + 1)) + ' (' + t.notes + ' notes)</option>').join('') + '</select>';
        $('midi-info').after(pick);
        $('track').addEventListener('change', e => { state.track = +e.target.value; schedule(); });
      }
      schedule();
    } catch (e) {
      $('midi-error').textContent = (e.message || String(e)) + ' Choose a Standard MIDI File (.mid).';
    }
  }

  async function takeAudio(file) {
    $('audio-error').textContent = '';
    $('audio-name').textContent = file.name;
    $('audio-info').textContent = 'Reading…';
    try {
      const { audio, lossy } = await decodeAudioFile(await file.arrayBuffer(), file.name);
      state.audio = audio; state.audioName = file.name; state.lossy = lossy;
      $('audio-info').textContent = fmt(audio.data.length / audio.sampleRate, 1) + ' seconds at ' + (audio.sampleRate / 1000) + ' kHz.';
      schedule();
    } catch (e) {
      state.audio = null;
      $('audio-info').textContent = '';
      $('audio-error').textContent = e.message;
    }
  }

  async function takeProfileFile(file) {
    $('profile-error').textContent = '';
    try {
      const p = NPVF.checkProfile(JSON.parse(await file.text()));
      addProfile(p);
      schedule();
    } catch (e) {
      $('profile-error').textContent = (e instanceof SyntaxError ? file.name + " isn't a profile." : e.message) + ' Open a .json file saved from here.';
    }
  }

  async function takeCalAudio(file) {
    $('cal-error').textContent = '';
    $('cal-name').textContent = file.name + ' (reading…)';
    try {
      const { audio } = await decodeAudioFile(await file.arrayBuffer(), file.name);
      state.calAudio = audio; state.calName = file.name;
      $('cal-name').textContent = file.name + ', ' + fmt(audio.data.length / audio.sampleRate, 0) + ' seconds';
      if (!$('cal-title').value) $('cal-title').value = baseName(file.name);
    } catch (e) {
      state.calAudio = null;
      $('cal-name').textContent = 'No test render yet';
      $('cal-error').textContent = e.message;
    }
    $('cal-learn').disabled = !state.calAudio;
  }

  function wireDrop(zone, take, accept) {
    const el = $(zone);
    el.addEventListener('dragover', e => { e.preventDefault(); e.stopPropagation(); el.classList.add('over'); });
    el.addEventListener('dragleave', () => el.classList.remove('over'));
    el.addEventListener('drop', e => {
      e.preventDefault(); e.stopPropagation(); el.classList.remove('over');
      const f = Array.from(e.dataTransfer.files).find(accept) || e.dataTransfer.files[0];
      if (f) take(f);
    });
  }
  const isMidi = f => /\.midi?$/i.test(f.name);
  const isJson = f => /\.json$/i.test(f.name);
  const isAudio = f => !isMidi(f) && !isJson(f);

  // ------------------------------------------------------------- measuring

  function analyseOptions() {
    const ks = parseNote($('ksmax').value);
    return {
      alignTo: $('align').value, maxDelayMs: num('maxdelay', 400), spreadMs: num('spread', 120),
      audioOffsetMs: num('offset', 0), keyswitchMax: ks === null ? -1 : ks, method: $('method').value, track: state.track,
      tempoBpm: tempoOverride(),
    };
  }
  /** The tempo typed in, if it differs from the file's (a file with tempo changes keeps them unless one is typed). */
  function tempoOverride() {
    const v = parseFloat($('bpm').value);
    if (!(v >= 20 && v <= 400) || !state.midi) return 0;
    const tm = NPVF.tempoMap(state.midi);
    return tm.segs.length === 1 && Math.abs(tm.bpmAtStart - v) < 0.005 ? 0 : v;
  }

  function planOptions() {
    const dbv = parseFloat($('dbvel').value);
    return {
      timingMode: radio('timing'), timingStrength: num('strength', 100) / 100, targetMs: num('target', 0), moveEnds: $('moveends').checked,
      volumeMode: radio('volume'), volumeTarget: radio('using'), toleranceDb: num('tolerance', 1),
      dbPerVelocity: isFinite(dbv) && dbv > 0 ? dbv : null, cc11Base: num('cc11base', 100), dbPerCC: num('dbcc', 0.3),
    };
  }

  let timer = 0, token = 0;
  function schedule() { clearTimeout(timer); timer = setTimeout(measure, 120); }

  async function measure() {
    const my = ++token;
    state.result = state.plan = null;
    $('download').disabled = true;
    $('download-note').textContent = '';
    $('results').classList.add('hidden');
    messages([]);
    if (!state.midi) return status(state.source === 'render' ? 'Add a MIDI file and its render to begin.' : 'Add a MIDI file and choose a profile to begin.');
    if (state.source === 'render' && !state.audio) return status('Now add the render of this part.');
    if (state.source === 'profile' && !state.profile) return status('Now choose a profile, or learn one below.');
    status(state.source === 'render' ? 'Measuring every note…' : 'Looking up every note…');
    await later();
    if (my !== token) return;
    try {
      const r = state.source === 'render'
        ? NPVF.analyse(state.midi, state.audio, analyseOptions())
        : NPVF.fromProfile(state.midi, state.profile, analyseOptions());
      if (my !== token) return;
      state.result = r;
      state.selected = -1;
      replan();
    } catch (e) {
      status('');
      messages([e.message || String(e)]);
    }
  }

  function replan() {
    const r = state.result;
    if (!r) return;
    state.plan = NPVF.plan(r, planOptions());
    const p = state.plan;
    if (state.selected < 0 || state.selected >= p.changes.length) {
      const first = p.changes.findIndex(c => c.note.found);
      state.selected = first < 0 ? 0 : first;
    }
    const s = p.summary;
    const parts = [];
    if (s.moved) parts.push(s.moved + (s.moved === 1 ? ' note moves' : ' notes move'));
    if (s.velocityChanged) parts.push(s.velocityChanged + (s.velocityChanged === 1 ? ' velocity changes' : ' velocities change'));
    if (s.cc11Written) parts.push(s.cc11Written + ' CC11 values written');
    status((r.profile ? 'Looked up ' : 'Measured ') + r.stats.found + ' of ' + r.stats.notes + ' notes. ' + (parts.length ? parts.join(', ') + '.' : 'Nothing needs changing.'));
    const msgs = r.warnings.slice();
    if (state.lossy) msgs.push('Compressed audio (MP3, AAC, Ogg) can start with a little added silence. Render a WAV or AIFF for exact timing.');
    if (p.barsAdded) msgs.push({ info: true, text: 'Some notes now start before the clip did, so the fixed file begins ' + p.barsAdded + (p.barsAdded === 1 ? ' bar' : ' bars') + ' earlier. Place it ' + p.barsAdded + (p.barsAdded === 1 ? ' bar' : ' bars') + ' before where the original starts.' });
    if (!r.profile && s.velocityChanged && radio('timing') !== 'off') msgs.push({ info: true, text: 'A new velocity can play a different sample with its own delay. Render the fixed part and check it here again; a second pass is usually smaller.' });
    if (r.chords) msgs.push({ info: true, text: r.chords + (r.chords === 1 ? ' chord was' : ' chords were') + ' measured as one attack and moved together. A learned profile can also line up the notes inside a chord.' });
    if (!r.profile && r.model && !r.model.fitted && radio('volume') !== 'off') msgs.push({ info: true, text: 'Volume is left alone: too few notes were found to judge.' });
    messages(msgs);
    $('download').disabled = false;
    $('download-note').textContent = baseName(state.midiName) + ' (fixed).mid';
    $('results').classList.remove('hidden');
    drawAll();
    fillTable();
  }

  // --------------------------------------------------------------- results

  function tiles() {
    const r = state.result, s = state.plan.summary;
    const t = [];
    t.push(['Notes found', r.stats.found + ' <span class="arrow">of</span> ' + r.stats.notes]);
    t.push([r.profile ? 'Typical delay (profile)' : 'Typically heard late by', fmt(r.stats.medianMs, 0) + ' ms']);
    t.push(['Spread between notes', fmt(s.timingSpreadBeforeMs, 0) + ' <span class="arrow">→</span> ' + fmt(s.timingSpreadAfterMs, 0) + ' ms']);
    if (radio('volume') !== 'off' && isFinite(s.loudSdAfterDb) && (r.model.fitted || r.profile)) {
      t.push(['Unintended loudness', fmt(s.loudSdBeforeDb, 1) + ' <span class="arrow">→</span> ' + fmt(s.loudSdAfterDb, 1) + ' dB']);
    }
    $('tiles').innerHTML = t.map(([k, v]) => '<div class="tile"><div class="dim">' + k + '</div><div class="big">' + v + '</div></div>').join('');
  }

  function prep(c) {
    const dpr = window.devicePixelRatio || 1;
    const w = c.clientWidth, h = c.clientHeight;
    if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) { c.width = Math.round(w * dpr); c.height = Math.round(h * dpr); }
    const ctx = c.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = C.roll; ctx.fillRect(0, 0, w, h);
    ctx.font = '12px -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif';
    return { ctx, w, h };
  }

  function span() {
    const r = state.result;
    const notes = r.measured;
    const t0 = Math.max(0, Math.min.apply(null, notes.map(n => n.t)) - 0.3);
    let t1 = Math.max.apply(null, notes.map(n => (n.found ? Math.max(n.onset || n.t + n.delay, n.tEnd) : n.tEnd))) + 0.3;
    if (r.duration) t1 = Math.min(t1, r.duration);
    return [t0, Math.max(t1, t0 + 0.5)];
  }

  function drawLevel(ctx, env, x, t0, t1, top, bottom, w) {
    if (!env) return;
    let lo = -70, hi = -Infinity;
    for (let k = 0; k < env.db.length; k++) hi = Math.max(hi, env.db[k]);
    lo = Math.max(lo, hi - 60);
    ctx.fillStyle = C.thumb;
    ctx.beginPath();
    ctx.moveTo(x(t0), bottom);
    const step = Math.max(1, Math.floor((t1 - t0) / env.hop / w));
    for (let px = 0; px <= w; px++) {
      const ta = t0 + (t1 - t0) * px / w;
      const ka = Math.max(0, Math.floor((ta - env.t0) / env.hop));
      let m = -Infinity;
      for (let k = ka; k < Math.min(env.db.length, ka + step); k++) m = Math.max(m, env.db[k]);
      const v = isFinite(m) ? Math.max(0, (m - lo) / (hi - lo)) : 0;
      ctx.lineTo(px, bottom - v * (bottom - top));
    }
    ctx.lineTo(w, bottom);
    ctx.closePath();
    ctx.fill();
  }

  function drawOverview() {
    const c = $('overview');
    const { ctx, w, h } = prep(c);
    const r = state.result, p = state.plan;
    const [t0, t1] = span();
    const x = t => (t - t0) / (t1 - t0) * w;
    drawLevel(ctx, r.envelope, x, t0, t1, 34, h - 4, w);
    p.changes.forEach((ch, i) => {
      const n = ch.note;
      const sel = i === state.selected;
      ctx.fillStyle = sel ? C.accent : C.control;
      ctx.fillRect(Math.round(x(n.t)) - (sel ? 1 : 0.5), 4, sel ? 3 : 1.5, 16);
      if (!n.found) return;
      const heard = n.onset !== undefined ? n.onset : n.t + n.delay;
      ctx.strokeStyle = sel ? C.accent : C.control;
      ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(x(n.t), 21); ctx.lineTo(x(heard), 29); ctx.stroke();
      ctx.fillStyle = sel ? C.accent : C.focus;
      ctx.fillRect(Math.round(x(heard)) - (sel ? 1 : 0.5), 29, sel ? 3 : 1.5, h - 33);
    });
    const n = p.changes[state.selected] && p.changes[state.selected].note;
    c.setAttribute('aria-label', 'The whole part: ' + p.changes.length + ' notes from ' + fmt(t0, 1) + ' to ' + fmt(t1, 1) + ' seconds.' + (n ? ' Selected: ' + NPVF.noteName(n.pitch) + '.' : ''));
  }

  function drawDetail() {
    const c = $('detail');
    const { ctx, w, h } = prep(c);
    const r = state.result, p = state.plan;
    const ch = p.changes[state.selected];
    if (!ch) return;
    const n = ch.note;
    const heard = n.found ? (n.onset !== undefined ? n.onset : n.t + n.delay) : NaN;
    const t0 = n.t - 0.08;
    const t1 = Math.max(isFinite(heard) ? heard : n.t + 0.2, n.t) + 0.3;
    const x = t => (t - t0) / (t1 - t0) * w;
    drawLevel(ctx, r.envelope, x, t0, t1, 28, h - 22, w);
    // a ruler in ms from the written note
    ctx.fillStyle = C.dim; ctx.strokeStyle = C.rule; ctx.lineWidth = 1;
    const stepMs = (t1 - t0) > 0.6 ? 100 : 50;
    for (let ms = Math.ceil((t0 - n.t) * 1000 / stepMs) * stepMs; ms <= (t1 - n.t) * 1000; ms += stepMs) {
      const px = Math.round(x(n.t + ms / 1000)) + 0.5;
      ctx.beginPath(); ctx.moveTo(px, h - 20); ctx.lineTo(px, h - 14); ctx.stroke();
      ctx.fillText((ms > 0 ? '+' : '') + ms + ' ms', px + 3, h - 6);
    }
    // other notes nearby, faintly
    for (const o of p.changes) {
      if (o === ch || o.note.t < t0 || o.note.t > t1) continue;
      ctx.fillStyle = C.rule; ctx.fillRect(Math.round(x(o.note.t)), 4, 1, h - 26);
    }
    const line = (t, colour, label, dash, row) => {
      const px = Math.round(x(t)) + 0.5;
      ctx.strokeStyle = colour; ctx.lineWidth = 2; ctx.setLineDash(dash || []);
      ctx.beginPath(); ctx.moveTo(px, 4); ctx.lineTo(px, h - 22); ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillStyle = colour;
      const tw = ctx.measureText(label).width;
      ctx.fillText(label, Math.max(4, px + 6 + tw > w ? px - 6 - tw : px + 6), 16 + row * 15);
    };
    line(n.t, C.control, 'Written', null, 0);
    if (isFinite(heard)) line(heard, C.focus, (r.profile ? 'Expected ' : 'Heard ') + fmt(n.delay * 1000, 0) + ' ms late', null, 1);
    if (ch.shiftMs) line(n.t + ch.shiftMs / 1000, C.control, 'Moves to ' + signed(ch.shiftMs, 0) + ' ms', [4, 3], 2);
    c.setAttribute('aria-label', detailText());
    $('detail-text').textContent = detailText();
  }

  function detailText() {
    const ch = state.plan.changes[state.selected];
    if (!ch) return '';
    const n = ch.note, r = state.result;
    let s = NPVF.noteName(n.pitch) + ' at ' + NPVF.position(n.startTick, r.midi, r.timeSig) + ', velocity ' + n.vel + ': ';
    if (!n.found) return s + "not found in the audio, so it's left alone.";
    s += (r.profile ? 'expected ' : 'heard ') + fmt(n.delay * 1000, 0) + ' ms after it was written';
    if (isFinite(n.deviationDb)) s += ', ' + (Math.abs(n.deviationDb) < 0.5 ? 'as loud as expected' : fmt(Math.abs(n.deviationDb), 1) + ' dB ' + (n.deviationDb > 0 ? 'louder' : 'quieter') + ' than expected');
    s += '. ';
    const acts = [];
    if (ch.shiftMs) acts.push('moves ' + fmt(Math.abs(ch.shiftMs), 0) + ' ms ' + (ch.shiftMs < 0 ? 'earlier' : 'later'));
    if (ch.velChange) acts.push('velocity ' + n.vel + ' → ' + ch.newVel);
    if (ch.cc11 !== null && ch.cc11 !== undefined) acts.push('CC11 ' + ch.cc11);
    s += acts.length ? 'It ' + acts.join(', ') + '.' : 'It stays as it is.';
    if (n.check) s += ' Worth a listen: ' + (n.under ? 'it was measured under other notes.' : n.atEdge ? 'it was found at the edge of where it could be.' : 'it differs from other notes on the same key.');
    return s;
  }

  function fillTable() {
    const r = state.result, p = state.plan;
    const rows = p.changes.map((ch, i) => {
      const n = ch.note;
      const sel = i === state.selected;
      const cells = [
        i + 1, NPVF.noteName(n.pitch), NPVF.position(n.startTick, r.midi, r.timeSig), n.vel,
        n.found ? fmt(n.delay * 1000, 1) : '<span class="none">not found</span>',
        n.found && isFinite(n.deviationDb) ? signed(n.deviationDb, 1) : '–',
        ch.shiftMs ? signed(ch.shiftMs, 1) : '–',
        ch.velChange ? ch.newVel : (ch.cc11 !== null && ch.cc11 !== undefined ? 'CC11 ' + ch.cc11 : '–'),
        esc(n.measuredOn || '–'),
      ];
      return '<tr data-i="' + i + '" tabindex="' + (sel ? 0 : -1) + '" aria-selected="' + sel + '">' + cells.map(v => '<td>' + v + '</td>').join('') +
        '<td class="check">' + (n.check ? 'Check' : '') + '</td></tr>';
    });
    $('table').tBodies[0].innerHTML = rows.join('');
    $('th-late').textContent = r.profile ? 'Expected late (ms)' : 'Heard late (ms)';
  }

  function select(i, focus) {
    const p = state.plan;
    if (!p || i < 0 || i >= p.changes.length) return;
    state.selected = i;
    const body = $('table').tBodies[0];
    for (const tr of body.rows) {
      const on = +tr.dataset.i === i;
      tr.setAttribute('aria-selected', on);
      tr.tabIndex = on ? 0 : -1;
      if (on) { tr.scrollIntoView({ block: 'nearest' }); if (focus) tr.focus(); }
    }
    drawAll(true);
  }

  function drawAll(skipTiles) {
    if (!state.plan) return;
    if (!skipTiles) tiles();
    drawOverview();
    drawDetail();
  }

  // ------------------------------------------------------------- learning

  function calParams() {
    const low = parseNote($('cal-low').value), high = parseNote($('cal-high').value);
    const vels = $('cal-vels').value.split(/[^0-9]+/).map(Number).filter(v => v >= 1 && v <= 127);
    const ksText = $('cal-ks').value.trim();
    const ks = ksText ? parseNote(ksText) : null;
    const takes = Math.max(1, Math.min(8, Math.round(num('cal-takes', 2))));
    if (low === null || high === null || high < low) return { error: 'Write the keys as note names, such as C1 and C6, lowest first.' };
    if (!vels.length) return { error: 'Write at least one velocity between 1 and 127.' };
    if (ksText && ks === null) return { error: 'Write the keyswitch as a note name, such as C-1, or leave it empty.' };
    const bpm = num('cal-bpm', 120);
    if (!(bpm >= 20 && bpm <= 400)) return { error: "Write your project's tempo, between 20 and 400 BPM." };
    return { low, high, velocities: Array.from(new Set(vels)).sort((a, b) => a - b), repeats: takes, keyswitch: ks, bpm };
  }

  function updateCalLength() {
    const c = calParams();
    if (c.error) { $('cal-length').textContent = c.error; return; }
    const sec = NPVF.calibrationLength(c);
    const notes = (c.high - c.low + 1) * c.velocities.length * c.repeats;
    $('cal-length').textContent = notes + ' notes, ' + (sec >= 90 ? Math.round(sec / 60) + ' minutes' : Math.round(sec) + ' seconds');
  }

  async function learn() {
    const c = state.calParams || calParams();
    $('cal-error').textContent = '';
    if (c.error) { $('cal-error').textContent = c.error; return; }
    const name = $('cal-title').value.trim() || baseName(state.calName) || 'Untitled';
    $('cal-status').textContent = 'Measuring every test note…';
    $('cal-learn').disabled = true;
    await later();
    try {
      const midi = NPVF.parseMidi(NPVF.calibrationMidi(c));
      const o = analyseOptions();
      const r = NPVF.analyse(midi, state.calAudio, {
        alignTo: o.alignTo, maxDelayMs: Math.max(o.maxDelayMs, 400), spreadMs: Math.max(o.maxDelayMs, 400),
        audioOffsetMs: o.audioOffsetMs, method: o.method, keyswitchMax: c.keyswitch === null ? -1 : c.keyswitch,
      });
      const prof = NPVF.learnProfile(r, name);
      if (r.stats.found < r.stats.notes * 0.8) {
        throw new Error('Only ' + r.stats.found + ' of ' + r.stats.notes + ' test notes were found. Check the render matches the test MIDI you downloaded, starts at its first bar, and has the same keys and velocities.');
      }
      addProfile(prof);
      const odd = prof.entries.filter(e => Math.abs(e.deviationDb) >= 1.5);
      const oddKeys = Array.from(new Set(odd.map(e => NPVF.noteName(e.pitch))));
      $('cal-status').textContent = 'Learned "' + name + '" from ' + r.stats.found + ' of ' + r.stats.notes + ' notes: heard ' +
        fmt(r.stats.minMs, 0) + ' to ' + fmt(r.stats.maxMs, 0) + ' ms late. ' +
        (oddKeys.length ? 'Keys 1.5 dB or more off: ' + oddKeys.slice(0, 12).join(', ') + (oddKeys.length > 12 ? '…' : '') + '.' : 'No key is 1.5 dB or more off.');
      document.getElementById('src-profile').checked = true;
      setSource('profile');
    } catch (e) {
      $('cal-error').textContent = e.message || String(e);
      $('cal-status').textContent = '';
    }
    $('cal-learn').disabled = !state.calAudio;
  }

  // ----------------------------------------------------------------- wiring

  function setSource(v) {
    state.source = v;
    $('drop-audio').classList.toggle('hidden', v !== 'render');
    $('profile-box').classList.toggle('hidden', v !== 'profile');
    $('learn').classList.toggle('hidden', v !== 'profile');
    if (v === 'profile' && !state.profiles.length) $('learn').open = true;
    schedule();
  }

  function init() {
    state.profiles = loadProfiles().filter(p => { try { NPVF.checkProfile(p); return true; } catch (e) { return false; } });
    fillProfiles();
    updateCalLength();

    document.querySelectorAll('input[name=source]').forEach(el => el.addEventListener('change', e => setSource(e.target.value)));
    $('midi-choose').addEventListener('click', () => $('midi-input').click());
    $('audio-choose').addEventListener('click', () => $('audio-input').click());
    $('profile-load').addEventListener('click', () => $('profile-input').click());
    $('cal-choose').addEventListener('click', () => $('cal-input').click());
    $('midi-input').addEventListener('change', e => { if (e.target.files[0]) takeMidi(e.target.files[0]); e.target.value = ''; });
    $('audio-input').addEventListener('change', e => { if (e.target.files[0]) takeAudio(e.target.files[0]); e.target.value = ''; });
    $('profile-input').addEventListener('change', e => { if (e.target.files[0]) takeProfileFile(e.target.files[0]); e.target.value = ''; });
    $('cal-input').addEventListener('change', e => { if (e.target.files[0]) takeCalAudio(e.target.files[0]); e.target.value = ''; });
    wireDrop('drop-midi', takeMidi, isMidi);
    wireDrop('drop-audio', takeAudio, isAudio);
    wireDrop('profile-box', takeProfileFile, isJson);
    wireDrop('drop-cal', takeCalAudio, isAudio);
    // dropped anywhere else: sent where it belongs
    document.addEventListener('dragover', e => e.preventDefault());
    document.addEventListener('drop', e => {
      e.preventDefault();
      for (const f of Array.from(e.dataTransfer.files)) {
        if (isMidi(f)) takeMidi(f);
        else if (isJson(f)) takeProfileFile(f);
        else if (state.source === 'profile' && $('learn').open) takeCalAudio(f);
        else takeAudio(f);
      }
    });

    $('profile-select').addEventListener('change', e => {
      state.profile = state.profiles[+e.target.value] || null;
      fillProfiles(); schedule();
    });
    $('profile-save').addEventListener('click', () => {
      if (state.profile) download(JSON.stringify(state.profile, null, 1), state.profile.name.replace(/[\\/:*?"<>|]+/g, '-') + '.json', 'application/json');
    });
    $('profile-delete').addEventListener('click', () => {
      const p = state.profile;
      if (!p || !window.confirm('Delete the profile "' + p.name + '"? Unless you saved it as a file, it can\'t be brought back.')) return;
      state.profiles = state.profiles.filter(q => q !== p);
      state.profile = null;
      storeProfiles(); fillProfiles(); schedule();
    });

    ['cal-low', 'cal-high', 'cal-vels', 'cal-takes', 'cal-ks', 'cal-bpm'].forEach(id => $(id).addEventListener('input', () => { state.calParams = null; updateCalLength(); }));
    $('cal-download').addEventListener('click', () => {
      const c = calParams();
      $('cal-error').textContent = c.error || '';
      if (c.error) return;
      state.calParams = c;
      download(NPVF.calibrationMidi(c), 'Test notes ' + NPVF.noteName(c.low) + '-' + NPVF.noteName(c.high) + '.mid', 'audio/midi');
    });
    $('cal-learn').addEventListener('click', learn);

    // measuring settings re-measure; fixing settings only re-plan
    ['align', 'maxdelay', 'spread', 'offset', 'ksmax', 'method', 'bpm'].forEach(id => $(id).addEventListener('change', schedule));
    ['target', 'tolerance', 'dbvel', 'cc11base', 'dbcc', 'moveends'].forEach(id => $(id).addEventListener('change', replan));
    ['timing', 'volume', 'using'].forEach(n => document.querySelectorAll('input[name=' + n + ']').forEach(el => el.addEventListener('change', replan)));
    $('strength').addEventListener('input', e => { $('strength-out').textContent = e.target.value + '%'; replan(); });

    $('download').addEventListener('click', () => {
      if (!state.plan) return;
      download(NPVF.applyPlan(state.plan), baseName(state.midiName) + ' (fixed).mid', 'audio/midi');
    });

    $('overview').addEventListener('click', e => {
      if (!state.plan) return;
      const rect = e.target.getBoundingClientRect();
      const [t0, t1] = span();
      const t = t0 + (e.clientX - rect.left) / rect.width * (t1 - t0);
      let best = -1, bd = Infinity;
      state.plan.changes.forEach((c, i) => { const d = Math.abs(c.note.t - t); if (d < bd) { bd = d; best = i; } });
      select(best, false);
    });
    const body = $('table').tBodies[0];
    body.addEventListener('click', e => { const tr = e.target.closest('tr'); if (tr) select(+tr.dataset.i, true); });
    body.addEventListener('keydown', e => {
      const n = state.plan ? state.plan.changes.length : 0;
      const step = { ArrowDown: 1, ArrowUp: -1, PageDown: 10, PageUp: -10 }[e.key];
      if (step) { e.preventDefault(); select(Math.max(0, Math.min(n - 1, state.selected + step)), true); }
      else if (e.key === 'Home') { e.preventDefault(); select(0, true); }
      else if (e.key === 'End') { e.preventDefault(); select(n - 1, true); }
    });
    if (window.ResizeObserver) new ResizeObserver(() => drawAll(true)).observe($('overview'));
  }

  init();
})();
