/*
 * Note Position & Volume Fixer - the engine.
 *
 * Reads a MIDI file and a render of it (WAV or AIFF), finds where each note
 * is actually heard and how loud it is, and writes a corrected MIDI file:
 * notes moved so their sound lands where they were written, and velocities
 * (or CC11) changed where a note is louder or quieter than its neighbours
 * would predict.
 *
 * No browser, no DAW: the same file runs in the page and under Node, which
 * is how the tests drive it (tests/run_tests.js).
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.NPVF = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const VERSION = '1.0.0';

  // ------------------------------------------------------------------ bytes

  function toBytes(input) {
    if (input instanceof Uint8Array) return input;
    if (input instanceof ArrayBuffer) return new Uint8Array(input);
    if (ArrayBuffer.isView(input)) return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    throw new Error('Expected bytes.');
  }
  const str4 = (b, p) => String.fromCharCode(b[p], b[p + 1], b[p + 2], b[p + 3]);
  const u16 = (b, p) => (b[p] << 8) | b[p + 1];
  const u32 = (b, p) => ((b[p] << 24) >>> 0) + ((b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]);
  const u16le = (b, p) => b[p] | (b[p + 1] << 8);
  const u32le = (b, p) => (b[p] | (b[p + 1] << 8) | (b[p + 2] << 16)) + ((b[p + 3] << 24) >>> 0);

  // ------------------------------------------------------------------- MIDI

  function readVLQ(b, pos, end) {
    let v = 0, c, n = 0;
    do {
      if (pos.i >= end || n++ > 4) throw new Error('The MIDI file is damaged (a length runs past the end).');
      c = b[pos.i++];
      v = (v * 128) + (c & 0x7f);
    } while (c & 0x80);
    return v;
  }

  /** Parse a Standard MIDI File (format 0 or 1). Every event keeps a unique `order`. */
  function parseMidi(input) {
    const b = toBytes(input);
    if (b.length < 14 || str4(b, 0) !== 'MThd') throw new Error("This isn't a MIDI file.");
    const hlen = u32(b, 4);
    const format = u16(b, 8), division = u16(b, 12);
    if (division & 0x8000) throw new Error('This MIDI file is timed in SMPTE frames. Export it in bars and beats instead.');
    if (division === 0) throw new Error('The MIDI file is damaged (zero ticks per beat).');
    let p = 8 + hlen, order = 0;
    const tracks = [];
    while (p + 8 <= b.length) {
      const id = str4(b, p), len = u32(b, p + 4);
      p += 8;
      const end = Math.min(b.length, p + len);
      if (id === 'MTrk') {
        const events = [];
        const pos = { i: p };
        let tick = 0, running = 0;
        while (pos.i < end) {
          tick += readVLQ(b, pos, end);
          const st = b[pos.i];
          if (st === 0xff) {
            pos.i++;
            const type = b[pos.i++];
            const l = readVLQ(b, pos, end);
            const data = b.slice(pos.i, pos.i + l);
            pos.i += l;
            events.push({ tick, kind: 'meta', type, data, order: order++ });
            if (type === 0x2f) break;
          } else if (st === 0xf0 || st === 0xf7) {
            pos.i++;
            const l = readVLQ(b, pos, end);
            const data = b.slice(pos.i, pos.i + l);
            pos.i += l;
            events.push({ tick, kind: 'sysex', status: st, data, order: order++ });
            running = 0;
          } else {
            if (st & 0x80) { running = st; pos.i++; }
            else if (!running) throw new Error('The MIDI file is damaged (data with no status byte).');
            const hi = running & 0xf0;
            const two = !(hi === 0xc0 || hi === 0xd0);
            const d1 = b[pos.i++] & 0x7f;
            const d2 = two ? b[pos.i++] & 0x7f : 0;
            events.push({ tick, kind: 'ch', status: running, d1, d2, order: order++ });
          }
        }
        const last = events[events.length - 1];
        if (!last || !(last.kind === 'meta' && last.type === 0x2f)) {
          events.push({ tick, kind: 'meta', type: 0x2f, data: new Uint8Array(0), order: order++ });
        }
        tracks.push({ events });
      }
      p = end;
    }
    if (!tracks.length) throw new Error('The MIDI file has no tracks.');
    return { format, division, tracks, nextOrder: order };
  }

  function writeVLQ(out, v) {
    v = Math.max(0, Math.round(v));
    const stack = [v & 0x7f];
    v = Math.floor(v / 128);
    while (v > 0) { stack.push((v & 0x7f) | 0x80); v = Math.floor(v / 128); }
    for (let i = stack.length - 1; i >= 0; i--) out.push(stack[i]);
  }

  const isNoteOn = e => e.kind === 'ch' && (e.status & 0xf0) === 0x90 && e.d2 > 0;
  const isNoteOff = e => e.kind === 'ch' && ((e.status & 0xf0) === 0x80 || ((e.status & 0xf0) === 0x90 && e.d2 === 0));
  const isEOT = e => e.kind === 'meta' && e.type === 0x2f;

  /** Same-tick order: meta and sysex, then note-offs, then everything else in its original order. */
  function eventClass(e) {
    if (e.kind === 'meta' || e.kind === 'sysex') return 0;
    if (isNoteOff(e)) return 1;
    return 2;
  }

  function sortTrack(events) {
    const body = events.filter(e => !isEOT(e));
    body.sort((a, b) => (a.tick - b.tick) || (eventClass(a) - eventClass(b)) || (a.order - b.order));
    const lastTick = body.length ? body[body.length - 1].tick : 0;
    const eot = events.find(isEOT);
    const eotTick = Math.max(lastTick, eot ? eot.tick : 0);
    body.push({ tick: eotTick, kind: 'meta', type: 0x2f, data: new Uint8Array(0), order: eot ? eot.order : 1e12 });
    return body;
  }

  function writeMidi(midi) {
    const out = [];
    const pushStr = s => { for (let i = 0; i < 4; i++) out.push(s.charCodeAt(i)); };
    const push32 = v => out.push((v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255);
    pushStr('MThd'); push32(6);
    const format = midi.tracks.length > 1 ? 1 : midi.format;
    out.push(0, format, (midi.tracks.length >> 8) & 255, midi.tracks.length & 255);
    out.push((midi.division >> 8) & 255, midi.division & 255);
    for (const t of midi.tracks) {
      const evs = sortTrack(t.events.map(e => Object.assign({}, e, { tick: Math.max(0, Math.round(e.tick)) })));
      const body = [];
      let prev = 0;
      for (const e of evs) {
        writeVLQ(body, e.tick - prev);
        prev = e.tick;
        if (e.kind === 'meta') {
          body.push(0xff, e.type);
          writeVLQ(body, e.data.length);
          for (const x of e.data) body.push(x);
        } else if (e.kind === 'sysex') {
          body.push(e.status);
          writeVLQ(body, e.data.length);
          for (const x of e.data) body.push(x);
        } else {
          const hi = e.status & 0xf0;
          body.push(e.status, e.d1 & 0x7f);
          if (!(hi === 0xc0 || hi === 0xd0)) body.push(e.d2 & 0x7f);
        }
      }
      pushStr('MTrk'); push32(body.length);
      for (const x of body) out.push(x);
    }
    return new Uint8Array(out);
  }

  /** Pair note-ons with note-offs (first on, first off). Notes keep references to their two events. */
  function collectNotes(midi) {
    const notes = [];
    midi.tracks.forEach((t, ti) => {
      const open = new Map();
      let lastTick = 0;
      for (const e of t.events) {
        lastTick = Math.max(lastTick, e.tick);
        if (e.kind !== 'ch') continue;
        const ch = e.status & 0x0f;
        const key = ch * 128 + e.d1;
        if (isNoteOn(e)) {
          if (!open.has(key)) open.set(key, []);
          open.get(key).push(e);
        } else if (isNoteOff(e)) {
          const q = open.get(key);
          if (q && q.length) {
            const on = q.shift();
            notes.push({ track: ti, ch, pitch: e.d1, vel: on.d2, startTick: on.tick, endTick: e.tick, on, off: e });
          }
        }
      }
      for (const q of open.values()) {
        for (const on of q) {
          notes.push({ track: ti, ch: on.status & 0x0f, pitch: on.d1, vel: on.d2, startTick: on.tick, endTick: Math.max(lastTick, on.tick + 1), on, off: null });
        }
      }
    });
    notes.sort((a, b) => (a.startTick - b.startTick) || (a.pitch - b.pitch) || (a.on.order - b.on.order));
    notes.forEach((n, i) => { n.index = i; });
    return notes;
  }

  /** Seconds for ticks. `bpm`, if given, replaces the file's tempo (a DAW may play it at its own). */
  function tempoMap(midi, bpm) {
    const ev = [];
    midi.tracks.forEach(t => t.events.forEach(e => {
      if (e.kind === 'meta' && e.type === 0x51 && e.data.length === 3) {
        ev.push({ tick: e.tick, uspq: (e.data[0] << 16) | (e.data[1] << 8) | e.data[2] });
      }
    }));
    ev.sort((a, b) => a.tick - b.tick);
    const ppq = midi.division;
    const segs = [{ tick: 0, sec: 0, uspq: 500000 }];
    if (bpm > 0) { ev.length = 0; segs[0].uspq = 60e6 / bpm; }
    for (const e of ev) {
      if (e.uspq <= 0) continue;
      const last = segs[segs.length - 1];
      if (e.tick === last.tick) { last.uspq = e.uspq; continue; }
      segs.push({ tick: e.tick, sec: last.sec + (e.tick - last.tick) * last.uspq / 1e6 / ppq, uspq: e.uspq });
    }
    function segForTick(tick) { let s = segs[0]; for (const g of segs) { if (g.tick <= tick) s = g; else break; } return s; }
    function segForSec(sec) { let s = segs[0]; for (const g of segs) { if (g.sec <= sec) s = g; else break; } return s; }
    return {
      segs,
      hasTempo: ev.length > 0 || bpm > 0,
      toSec(tick) { const s = segForTick(tick); return s.sec + (tick - s.tick) * s.uspq / 1e6 / ppq; },
      toTick(sec) { const s = segForSec(sec); return s.tick + (sec - s.sec) * 1e6 * ppq / s.uspq; },
      bpmAtStart: 60e6 / segs[0].uspq,
    };
  }

  function timeSignature(midi) {
    let num = 4, den = 4, best = Infinity;
    midi.tracks.forEach(t => t.events.forEach(e => {
      if (e.kind === 'meta' && e.type === 0x58 && e.data.length >= 2 && e.tick < best) {
        best = e.tick; num = e.data[0] || 4; den = Math.pow(2, e.data[1]);
      }
    }));
    return { num, den, barTicks: Math.round(num * midi.division * 4 / den) };
  }

  /** Tracks that hold notes, with their names, for choosing one. */
  function noteTracks(midi) {
    const out = [];
    midi.tracks.forEach((t, i) => {
      const count = t.events.filter(isNoteOn).length;
      if (!count) return;
      const nm = t.events.find(e => e.kind === 'meta' && e.type === 0x03);
      let name = '';
      if (nm) { try { name = new TextDecoder().decode(nm.data); } catch (e) { name = String.fromCharCode.apply(null, nm.data); } }
      out.push({ index: i, name: name.trim(), notes: count });
    });
    return out;
  }

  const NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  /** Middle C (60) is C3, as Ableton Live and Cubase name it. */
  function noteName(p, middleCOctave) {
    const o = middleCOctave === undefined ? 3 : middleCOctave;
    return NAMES[p % 12] + (Math.floor(p / 12) - (5 - o));
  }

  function position(tick, midi, ts) {
    const ppq = midi.division;
    const beatTicks = ppq * 4 / ts.den;
    const bar = Math.floor(tick / ts.barTicks);
    const rem = tick - bar * ts.barTicks;
    const beat = Math.floor(rem / beatTicks);
    const sixteenth = Math.floor((rem - beat * beatTicks) / (ppq / 4));
    return (bar + 1) + '.' + (beat + 1) + '.' + (sixteenth + 1);
  }

  // ------------------------------------------------------------------ audio

  function readSample(b, p, bits, fmt, little) {
    if (fmt === 'float') {
      const dv = new DataView(b.buffer, b.byteOffset + p, bits / 8);
      return bits === 32 ? dv.getFloat32(0, little) : dv.getFloat64(0, little);
    }
    if (bits === 8) return little ? (b[p] - 128) / 128 : ((b[p] << 24) >> 24) / 128; // WAV 8-bit is unsigned, AIFF signed
    if (bits === 16) {
      const v = little ? (b[p] | (b[p + 1] << 8)) : ((b[p] << 8) | b[p + 1]);
      return ((v << 16) >> 16) / 32768;
    }
    if (bits === 24) {
      const v = little ? (b[p] | (b[p + 1] << 8) | (b[p + 2] << 16)) : ((b[p] << 16) | (b[p + 1] << 8) | b[p + 2]);
      return ((v << 8) >> 8) / 8388608;
    }
    if (bits === 32) {
      const v = little ? (b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24)) : ((b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]);
      return v / 2147483648;
    }
    throw new Error('Unsupported bit depth: ' + bits + '.');
  }

  function mixToMono(b, offset, frames, channels, bits, fmt, little) {
    const bytes = bits / 8, stride = bytes * channels;
    const avail = Math.floor((b.length - offset) / stride);
    const n = Math.max(0, Math.min(frames, avail));
    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      let s = 0;
      const base = offset + i * stride;
      for (let c = 0; c < channels; c++) s += readSample(b, base + c * bytes, bits, fmt, little);
      out[i] = s / channels;
    }
    return out;
  }

  function decodeWav(b) {
    let p = 12, fmt = null, data = null;
    while (p + 8 <= b.length) {
      const id = str4(b, p);
      let len = u32le(b, p + 4);
      const body = p + 8;
      if (id === 'fmt ') {
        let tag = u16le(b, body);
        const channels = u16le(b, body + 2), sampleRate = u32le(b, body + 4), bits = u16le(b, body + 14);
        if (tag === 0xfffe && len >= 26) tag = u16le(b, body + 24);
        fmt = { tag, channels, sampleRate, bits };
      } else if (id === 'data') {
        if (len === 0xffffffff || body + len > b.length) len = b.length - body;
        data = { offset: body, len };
      }
      p = body + len + (len & 1);
    }
    if (!fmt || !data) throw new Error('The WAV file has no audio in it.');
    if (fmt.tag !== 1 && fmt.tag !== 3) throw new Error('This WAV is compressed. Render a plain PCM or 32-bit float WAV.');
    const kind = fmt.tag === 3 ? 'float' : 'int';
    const frames = Math.floor(data.len / (fmt.channels * fmt.bits / 8));
    return { sampleRate: fmt.sampleRate, channels: fmt.channels, data: mixToMono(b, data.offset, frames, fmt.channels, fmt.bits, kind, true) };
  }

  function extended80(b, p) {
    const exp = ((b[p] & 0x7f) << 8) | b[p + 1];
    const hi = u32(b, p + 2), lo = u32(b, p + 6);
    if (exp === 0 && hi === 0 && lo === 0) return 0;
    return (hi * 4294967296 + lo) * Math.pow(2, exp - 16383 - 63);
  }

  function decodeAiff(b) {
    const aifc = str4(b, 8) === 'AIFC';
    let p = 12, comm = null, ssnd = null;
    while (p + 8 <= b.length) {
      const id = str4(b, p);
      let len = u32(b, p + 4);
      const body = p + 8;
      if (body + len > b.length) len = b.length - body;
      if (id === 'COMM') {
        comm = { channels: u16(b, body), frames: u32(b, body + 2), bits: u16(b, body + 6), sampleRate: extended80(b, body + 8), comp: aifc ? str4(b, body + 18) : 'NONE' };
      } else if (id === 'SSND') {
        ssnd = { offset: body + 8 + u32(b, body) };
      }
      p = body + len + (len & 1);
    }
    if (!comm || !ssnd) throw new Error('The AIFF file has no audio in it.');
    let kind = 'int', little = false, bits = comm.bits;
    const c = comm.comp;
    if (c === 'sowt') little = true;
    else if (c === 'fl32' || c === 'FL32') { kind = 'float'; bits = 32; }
    else if (c === 'fl64' || c === 'FL64') { kind = 'float'; bits = 64; }
    else if (c !== 'NONE' && c !== 'twos') throw new Error('This AIFF is compressed (' + c + '). Render an uncompressed AIFF or WAV.');
    bits = Math.ceil(bits / 8) * 8;
    return { sampleRate: comm.sampleRate, channels: comm.channels, data: mixToMono(b, ssnd.offset, comm.frames, comm.channels, bits, kind, little) };
  }

  /** WAV or AIFF to mono. Anything else is left to the browser (see the page). */
  function decodeAudio(input) {
    const b = toBytes(input);
    if (b.length >= 12 && str4(b, 0) === 'RIFF' && str4(b, 8) === 'WAVE') return decodeWav(b);
    if (b.length >= 12 && str4(b, 0) === 'FORM' && (str4(b, 8) === 'AIFF' || str4(b, 8) === 'AIFC')) return decodeAiff(b);
    throw new Error('Not a WAV or AIFF file.');
  }

  // -------------------------------------------------------------------- DSP

  function biquadRun(x, c, out) {
    const y = out || new Float32Array(x.length);
    let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    const { b0, b1, b2, a1, a2 } = c;
    for (let n = 0; n < x.length; n++) {
      const xn = x[n];
      const yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
      x2 = x1; x1 = xn; y2 = y1; y1 = yn;
      y[n] = yn;
    }
    return y;
  }

  function norm(b0, b1, b2, a0, a1, a2) {
    return { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 };
  }

  /** ITU-R BS.1770 K-weighting, the curve loudness meters use, at any sample rate. */
  function kWeight(x, fs) {
    let w0 = 2 * Math.PI * 1681.974450955533 / fs;
    const A = Math.pow(10, 3.999843853973347 / 40);
    let alpha = Math.sin(w0) / (2 * 0.7071752369554196);
    let cs = Math.cos(w0), sa = 2 * Math.sqrt(A) * alpha;
    const shelf = norm(
      A * ((A + 1) + (A - 1) * cs + sa), -2 * A * ((A - 1) + (A + 1) * cs), A * ((A + 1) + (A - 1) * cs - sa),
      (A + 1) - (A - 1) * cs + sa, 2 * ((A - 1) - (A + 1) * cs), (A + 1) - (A - 1) * cs - sa);
    w0 = 2 * Math.PI * 38.13547087602444 / fs;
    alpha = Math.sin(w0) / (2 * 0.5003270373238773);
    cs = Math.cos(w0);
    const hp = norm((1 + cs) / 2, -(1 + cs), (1 + cs) / 2, 1 + alpha, -2 * cs, 1 - alpha);
    const y = biquadRun(x, shelf);
    return biquadRun(y, hp, y);
  }

  function bandpass(fc, q, fs) {
    const w0 = 2 * Math.PI * fc / fs, alpha = Math.sin(w0) / (2 * q), cs = Math.cos(w0);
    return norm(alpha, 0, -alpha, 1 + alpha, -2 * cs, 1 - alpha);
  }

  /** Forward then backward, so the filter adds no delay of its own. */
  function zeroPhase(x, c) {
    const y = biquadRun(x, c);
    y.reverse();
    biquadRun(y, c, y);
    return y.reverse();
  }

  /**
   * Mean power in a centred window every `hop` seconds over [s0, s1) samples.
   * `squared` says the input is already power. Returns { lin, db, t0, hop }.
   */
  function envelope(sig, fs, hop, win, s0, s1, squared) {
    s0 = Math.max(0, s0 || 0);
    s1 = Math.min(sig.length, s1 === undefined ? sig.length : s1);
    const n = Math.max(0, Math.floor((s1 - s0) / (hop * fs)));
    const half = Math.max(1, Math.round(win * fs / 2));
    const lin = new Float32Array(n), db = new Float32Array(n);
    const sq = squared ? (i => sig[i]) : (i => sig[i] * sig[i]);
    let lo = Math.max(0, s0 - half), hi = lo, sum = 0;
    for (let k = 0; k < n; k++) {
      const c = s0 + Math.round(k * hop * fs);
      const a = Math.max(0, c - half), b = Math.min(sig.length, c + half);
      while (hi < b) sum += sq(hi++);
      while (lo < a) sum -= sq(lo++);
      const v = Math.max(0, sum) / Math.max(1, b - a);
      lin[k] = v;
      db[k] = 10 * Math.log10(v + 1e-12);
    }
    return { lin, db, t0: s0 / fs, hop };
  }

  // ------------------------------------------------------------ statistics

  function median(a) {
    if (!a.length) return NaN;
    const s = Float64Array.from(a).sort();
    const m = s.length >> 1;
    return s.length & 1 ? s[m] : (s[m - 1] + s[m]) / 2;
  }
  function quantile(a, q) {
    if (!a.length) return NaN;
    const s = Float64Array.from(a).sort();
    const i = Math.min(s.length - 1, Math.max(0, (s.length - 1) * q));
    const lo = Math.floor(i), f = i - lo;
    return lo + 1 < s.length ? s[lo] * (1 - f) + s[lo + 1] * f : s[lo];
  }
  function stdev(a) {
    if (a.length < 2) return 0;
    const m = a.reduce((x, y) => x + y, 0) / a.length;
    return Math.sqrt(a.reduce((x, y) => x + (y - m) * (y - m), 0) / (a.length - 1));
  }

  function solve(M, v) {
    const n = v.length;
    const A = M.map((row, i) => row.slice().concat([v[i]]));
    for (let c = 0; c < n; c++) {
      let piv = c;
      for (let r = c + 1; r < n; r++) if (Math.abs(A[r][c]) > Math.abs(A[piv][c])) piv = r;
      [A[c], A[piv]] = [A[piv], A[c]];
      const d = A[c][c];
      if (Math.abs(d) < 1e-12) return null;
      for (let r = 0; r < n; r++) {
        if (r === c) continue;
        const f = A[r][c] / d;
        for (let k = c; k <= n; k++) A[r][k] -= f * A[c][k];
      }
    }
    return A.map((row, i) => row[n] / row[i]);
  }

  /** Least squares that a few loud or quiet notes cannot drag (Huber weights). */
  function robustFit(X, y) {
    const n = y.length, p = X[0].length;
    let w = new Array(n).fill(1), beta = null, scale = 1;
    for (let it = 0; it < 30; it++) {
      const M = Array.from({ length: p }, () => new Array(p).fill(0));
      const v = new Array(p).fill(0);
      for (let i = 0; i < n; i++) {
        for (let a = 0; a < p; a++) {
          v[a] += w[i] * X[i][a] * y[i];
          for (let b = 0; b < p; b++) M[a][b] += w[i] * X[i][a] * X[i][b];
        }
      }
      for (let a = 1; a < p; a++) M[a][a] += 1e-6;
      const nb = solve(M, v);
      if (!nb) break;
      beta = nb;
      const r = y.map((yi, i) => yi - X[i].reduce((s, x, a) => s + x * beta[a], 0));
      scale = Math.max(0.3, 1.4826 * median(r.map(Math.abs)));
      const k = 1.345 * scale;
      w = r.map(ri => (Math.abs(ri) <= k ? 1 : k / Math.abs(ri)));
    }
    return { beta, scale };
  }

  // -------------------------------------------------------------- analysis

  const ANALYSE_DEFAULTS = {
    alignTo: 'attack',   // 'attack': where the attack is heard; 'start': where any sound begins
    attackDb: 12,        // 'attack' is this many dB below the note's first peak
    startDb: 30,         // 'start' is this many dB below it (never closer than 3 dB to the noise)
    maxDelayMs: 400,     // the latest a note's sound can start after its MIDI note
    spreadMs: 120,       // how far one note can differ from the part's typical delay
    audioOffsetMs: 0,    // positive if the audio starts later than the MIDI file's beginning
    keyswitchMax: -1,    // notes at or below this pitch are keyswitches (never measured)
    track: -1,           // only this track's notes (index into midi.tracks); -1 for all
    tempoBpm: 0,         // if set, the tempo the part was played at, instead of the file's
    minRiseDb: 6,        // a sound must rise at least this much to count as found
    method: 'auto',      // 'auto': each note's harmonics, else the whole sound | 'harmonics' | 'whole'
  };

  /**
   * Power in a note's harmonics, each band-passed without delay. Bands that another
   * note sounding at the same time also fills (`others`, in Hz) are left out where
   * the note has bands of its own, so a chord's notes can be told apart.
   */
  function harmonicPower(x, fs, s0, s1, f0, others) {
    const seg = x.subarray(Math.max(0, s0), Math.min(x.length, s1));
    const pow = new Float32Array(seg.length);
    const narrow = others && others.length > 0;
    // Alone, a wide band reacts fastest. Beside other notes, a narrow, steeper band keeps them out.
    const bw = narrow ? Math.max(f0 * 0.12, 8) : Math.max(f0 * 0.5, 20);
    const bands = [];
    for (let h = 1; h <= 16; h++) {
      const fc = h * f0;
      if (fc > Math.min(10000, fs * 0.45)) break;
      let gap = Infinity;
      for (const g of others || []) {
        const k = Math.max(1, Math.round(fc / g));
        gap = Math.min(gap, Math.abs(k * g - fc), Math.abs((k + 1) * g - fc), k > 1 ? Math.abs((k - 1) * g - fc) : Infinity);
      }
      bands.push({ fc, gap });
    }
    let use = narrow ? bands.filter(b => b.gap > 2.5 * bw) : bands;
    if (!use.length) use = bands.slice().sort((a, b) => b.gap - a.gap).slice(0, 1);
    for (const band of use.slice(0, 8)) {
      const c = bandpass(band.fc, band.fc / bw, fs);
      let y = zeroPhase(seg, c);
      if (narrow) y = zeroPhase(y, c);
      for (let i = 0; i < y.length; i++) pow[i] += y[i] * y[i];
    }
    return pow;
  }

  /** Find one note's onset inside [a, b] seconds of an envelope. */
  function findOnset(env, a, b, limit, o) {
    const n = env.db.length;
    if (!n) return null;
    const fr = t => Math.min(n - 1, Math.max(0, Math.round((t - env.t0) / env.hop)));
    const ka = fr(a), kb = fr(b);
    if (kb <= ka) return null;
    const d = Math.max(1, Math.round(0.005 / env.hop));
    const e = env.db;
    let ks = -1, best = -Infinity;
    for (let k = ka; k <= kb; k++) {
      const r = e[Math.min(n - 1, k + d)] - e[Math.max(0, k - d)];
      if (r > best) { best = r; ks = k; }
    }
    if (ks < 0) return null;
    const kLim = Math.min(fr(limit), ks + Math.round(0.15 / env.hop));
    let kp = ks, pv = e[ks];
    for (let k = ks; k <= kLim; k++) {
      if (e[k] > pv) { pv = e[k]; kp = k; } else if (e[k] < pv - 3) break;
    }
    const kb0 = Math.max(0, ks - Math.round(0.06 / env.hop));
    let base = Infinity;
    for (let k = kb0; k <= ks; k++) base = Math.min(base, e[k]);

    // Whatever was sounding before (the last note's tail, reverb, noise) is projected forward
    // as a steady decay and taken away, leaving this note's own sound.
    const p0 = Math.max(0, ks - Math.round(0.06 / env.hop)), p1 = ks - Math.round(0.015 / env.hop);
    let slope = 0, icept = base;
    if (p1 - p0 >= 8) {
      let sx = 0, sy = 0, sxx = 0, sxy = 0, m = 0;
      for (let k = p0; k <= p1; k++) { sx += k; sy += e[k]; sxx += k * k; sxy += k * e[k]; m++; }
      const den = m * sxx - sx * sx;
      slope = den ? (m * sxy - sx * sy) / den : 0;
      icept = (sy - slope * sx) / m;
      if (slope > 0) { slope = 0; icept = sy / m; }
    } else if (p1 >= p0) {
      let sy = 0; for (let k = p0; k <= p1; k++) sy += e[k];
      icept = sy / (p1 - p0 + 1);
    }
    const tail = k => Math.pow(10, (icept + slope * k) / 10);
    const own = new Float64Array(Math.max(kp, kLim) - kb0 + 2);
    let ownPeak = 0, kOwnPeak = kp;
    for (let k = kb0; k <= Math.max(kp, kb0); k++) {
      const v = Math.max(0, env.lin[k] - tail(k));
      own[k - kb0] = v;
      if (k >= ks && v > ownPeak) { ownPeak = v; kOwnPeak = k; }
    }
    if (ownPeak <= 0) return { onset: env.t0 + ks * env.hop, peakDb: pv, baseDb: base, riseDb: 0, maskDb: 0, slope: best, atEdge: true };
    const ownPeakDb = 10 * Math.log10(ownPeak);
    const rise = ownPeakDb - (icept + slope * ks);
    const drop = o.alignTo === 'start' ? o.startDb : o.attackDb;
    // never closer to what was already there than it can be told apart from it
    const thrAt = k => Math.max(ownPeak * Math.pow(10, -drop / 10), 0.5 * tail(k));
    let k = kOwnPeak;
    while (k > kb0 && own[k - 1 - kb0] >= thrAt(k - 1)) k--;
    let t = env.t0 + k * env.hop;
    if (k > kb0) {
      const a0 = own[k - 1 - kb0] - thrAt(k - 1), a1 = own[k - kb0] - thrAt(k);
      if (a1 > a0) t = env.t0 + (k - 1 + (-a0) / (a1 - a0)) * env.hop;
    }
    const maskDb = 10 * Math.log10(tail(Math.max(kb0, Math.round((t - env.t0) / env.hop))) / ownPeak);
    return { onset: t, peakDb: ownPeakDb, baseDb: base, riseDb: Math.max(rise, ownPeakDb - base), maskDb, slope: best, peakTime: env.t0 + kOwnPeak * env.hop, atEdge: ks === ka || ks === kb };
  }

  /** Loudest 50 ms of [t0, t1], in dB. */
  function loudness(env, t0, t1) {
    const n = env.lin.length;
    const k0 = Math.max(0, Math.round((t0 - env.t0) / env.hop));
    const k1 = Math.min(n, Math.round((t1 - env.t0) / env.hop));
    if (k1 - k0 < 1) return -Infinity;
    const L = Math.min(k1 - k0, Math.max(1, Math.round(0.05 / env.hop)));
    let sum = 0;
    for (let k = k0; k < k0 + L; k++) sum += env.lin[k];
    let best = sum;
    for (let k = k0 + L; k < k1; k++) { sum += env.lin[k] - env.lin[k - L]; if (sum > best) best = sum; }
    return 10 * Math.log10(best / L + 1e-12);
  }

  function ccValueAt(midi, track, ch, cc, tick) {
    let v = null, t = -1;
    for (const e of midi.tracks[track].events) {
      if (e.kind === 'ch' && (e.status & 0xf0) === 0xb0 && (e.status & 0x0f) === ch && e.d1 === cc && e.tick <= tick && e.tick >= t) { v = e.d2; t = e.tick; }
    }
    return v;
  }

  function analyse(midi, audio, options) {
    const o = Object.assign({}, ANALYSE_DEFAULTS, options || {});
    const tm = tempoMap(midi, o.tempoBpm);
    const ts = timeSignature(midi);
    const fs = audio.sampleRate, x = audio.data;
    const off = o.audioOffsetMs / 1000;
    const maxDelay = o.maxDelayMs / 1000, spread = o.spreadMs / 1000;
    const all = collectNotes(midi).filter(n => o.track < 0 || n.track === o.track).map(n => Object.assign(n, {
      t: tm.toSec(n.startTick) + off,
      tEnd: tm.toSec(n.endTick) + off,
      keyswitch: n.pitch <= o.keyswitchMax,
    }));
    const notes = all.filter(n => !n.keyswitch);
    const warnings = [];
    if (!notes.length) throw new Error('The MIDI file has no notes to measure.');
    const duration = x.length / fs;
    if (notes[notes.length - 1].t > duration) warnings.push('The audio is shorter than the MIDI part: notes after ' + duration.toFixed(1) + ' s were not measured. Render the whole part.');

    // Notes that sound together with another note are measured on their own harmonics.
    const byStart = notes.slice().sort((a, b) => a.t - b.t);
    for (const n of notes) n.overlapped = false;
    for (let i = 0; i < byStart.length; i++) {
      const a = byStart[i];
      for (let j = i + 1; j < byStart.length; j++) {
        const b = byStart[j];
        if (b.t - a.t >= 0.03 && b.t >= a.tEnd - 0.005) break;
        if (b.t - a.t < 0.03 || b.t < a.tEnd - 0.005) { a.overlapped = true; b.overlapped = true; }
      }
    }
    const polyphonic = notes.some(n => n.overlapped);

    const kw = kWeight(x, fs);
    const benv = envelope(kw, fs, 0.0005, 0.003);

    // The part's typical delay: the lag at which the note starts best line up with rises in the sound.
    const d = Math.round(0.005 / benv.hop);
    const nE = benv.db.length;
    const rise = new Float32Array(nE);
    for (let k = 0; k < nE; k++) rise[k] = Math.max(0, benv.db[Math.min(nE - 1, k + d)] - benv.db[Math.max(0, k - d)]);
    let typical = 0, bestScore = -1;
    for (let L = -0.02; L <= maxDelay; L += benv.hop) {
      let s = 0;
      for (const n of notes) {
        const k = Math.round((n.t + L - benv.t0) / benv.hop);
        if (k >= 1 && k < nE - 1) s += Math.max(rise[k - 1], rise[k], rise[k + 1]);
      }
      if (s > bestScore) { bestScore = s; typical = L; }
    }

    // A note's own harmonics, band-passed out of the mix: other pitches and the last note's tail mostly fall away.
    const harm = new Map();
    // `apart`: keep out the harmonics of notes sounding with it (chords, held notes, the last note's tail).
    const harmonicEnv = (n, apart) => {
      const key = n.index + (apart ? ':apart' : '');
      if (harm.has(key)) return harm.get(key);
      const f0 = 440 * Math.pow(2, (n.pitch - 69) / 12);
      const s0 = Math.max(0, Math.floor((n.window[0] - 0.12) * fs));
      const s1 = Math.min(x.length, Math.ceil((Math.max(n.limit, n.window[1]) + 0.45) * fs) + 1);
      const pad = Math.round(0.1 * fs);
      const base = Math.max(0, s0 - pad);
      const others = apart ? notes.filter(m => m !== n && m.pitch !== n.pitch && m.t < n.window[1] && m.tEnd + 0.4 > n.window[0])
        .map(m => 440 * Math.pow(2, (m.pitch - 69) / 12)) : [];
      const pow = harmonicPower(x, fs, base, s1 + pad, f0, others);
      const env = envelope(pow, fs, 0.0005, Math.max(0.003, 0.5 / f0), s0 - base, Math.min(pow.length, s1 - base), true);
      env.t0 += base / fs;
      harm.set(key, env);
      return env;
    };
    const ok = r => r && r.riseDb >= o.minRiseDb && r.slope >= 1;

    // Notes starting within 30 ms of each other are a chord: heard as one attack, so measured on the
    // whole sound and moved together. A note entering under held notes is measured apart from them.
    let chordId = 0;
    for (let i = 0; i < byStart.length;) {
      let j = i + 1;
      while (j < byStart.length && byStart[j].t - byStart[i].t < 0.03) j++;
      for (let k = i; k < j; k++) byStart[k].chord = j - i > 1 ? chordId : -1;
      chordId++;
      i = j;
    }
    for (const n of notes) n.under = n.overlapped && n.chord < 0;

    for (const n of notes) {
      // Neighbours bound the search: every other note for the whole sound, the same key for a note under held notes.
      const pool = notes.filter(m => m !== n && (n.chord < 0 || m.chord !== n.chord) && (!n.under || m.pitch === n.pitch));
      let prev = null, next = null;
      for (const m of pool) {
        if (m.t <= n.t && (!prev || m.t > prev.t)) prev = m;
        if (m.t > n.t && (!next || m.t < next.t)) next = m;
      }
      if (prev && n.t - prev.t < 0.03) prev = null;
      let a = Math.max(n.t + typical - spread, n.t + Math.min(0, typical) - 0.01);
      let b = Math.min(n.t + typical + spread, n.t + maxDelay);
      if (prev) a = Math.max(a, (prev.t + n.t) / 2 + typical);
      if (next) b = Math.min(b, (n.t + next.t) / 2 + typical);
      n.limit = next ? next.t + typical - 0.005 : n.t + maxDelay + 0.3;
      n.window = [a, b];
      n.next = next;
    }

    const chordResult = new Map();
    const measure = (n, method) => {
      const [a, b] = n.window;
      if (n.t >= duration || b - a < 0.004) return { r: null, on: 'whole sound' };
      if (n.chord >= 0) {
        if (!chordResult.has(n.chord)) chordResult.set(n.chord, findOnset(benv, a, b, n.limit, o));
        return { r: chordResult.get(n.chord), on: 'chord' };
      }
      if (method === 'whole') return { r: findOnset(benv, a, b, n.limit, o), on: 'whole sound' };
      // Each note on its own harmonics: the last note's tail and other pitches mostly fall away.
      return { r: findOnset(harmonicEnv(n, n.under), a, b, n.limit, o), on: 'harmonics' };
    };
    const keep = (n, m) => {
      n.measuredOn = m.on;
      n.found = ok(m.r);
      if (!n.found) return;
      n.onset = m.r.onset;
      n.delay = m.r.onset - n.t;
      n.riseDb = m.r.riseDb;
      n.atEdge = m.r.atEdge;
      if (m.on === 'harmonics') {
        // how much of the sound at its peak is in the note's harmonics
        const k = Math.min(benv.db.length - 1, Math.max(0, Math.round((m.r.peakTime - benv.t0) / benv.hop)));
        n.harmonicShareDb = m.r.peakDb - benv.db[k];
      }
    };
    const first = o.method === 'whole' ? 'whole' : 'harmonics';
    for (const n of notes) keep(n, measure(n, first));
    if (o.method === 'auto') {
      // Mostly not found on harmonics: an unpitched sound, or pitches the MIDI doesn't match. Use the whole sound.
      const single = notes.filter(n => n.chord < 0);
      const onHarm = single.filter(n => n.found).length;
      const share = median(single.filter(n => n.found).map(n => n.harmonicShareDb));
      if (single.length && (onHarm < single.length / 2 || share < -12)) {
        const tries = single.map(n => measure(n, 'whole'));
        if (share < -12 || tries.filter(m => ok(m.r)).length > onHarm) single.forEach((n, i) => keep(n, tries[i]));
      }
    }

    // Loudness: from the note's own onset to its end, the next note's onset, or 400 ms, whichever is first.
    // Every note is measured the same way: on its harmonics unless everything was measured on the whole sound.
    const metric = notes.every(n => !n.found || n.measuredOn === 'whole sound') ? 'whole sound' : 'harmonics';
    for (const n of notes) {
      if (!n.found) continue;
      let end = n.onset + Math.min(0.4, Math.max(0.05, n.tEnd - n.t));
      if (n.next && n.next.found) end = Math.min(end, n.next.onset);
      else if (n.next) end = Math.min(end, n.next.t + typical);
      end = Math.max(end, n.onset + 0.01);
      n.loudDb = loudness(metric === 'harmonics' ? harmonicEnv(n, false) : benv, n.onset, end);
    }
    harm.clear();

    // Worth a look: under held notes, at the edge of where it could be, or far from other notes on the same key.
    for (const n of notes) {
      if (!n.found) continue;
      const same = notes.filter(m => m.found && m.pitch === n.pitch && m !== n).map(m => m.delay);
      const far = same.length >= 2 && Math.abs(n.delay - median(same)) > 0.015;
      n.check = !!(n.under || n.atEdge || far);
    }

    // What each note's loudness should be, given its velocity, its pitch and the dynamics CCs.
    const found = notes.filter(n => n.found && isFinite(n.loudDb));
    for (const n of found) {
      n.cc1 = ccValueAt(midi, n.track, n.ch, 1, n.startTick);
      n.cc11 = ccValueAt(midi, n.track, n.ch, 11, n.startTick);
    }
    const model = { terms: [], dbPerVelocity: null, fitted: false };
    if (found.length >= 6) {
      const vary = f => { const v = found.map(f).filter(z => z !== null); return v.length === found.length && stdev(v) > 2; };
      const pitches = found.map(n => n.pitch);
      const span = Math.max.apply(null, pitches) - Math.min.apply(null, pitches);
      const terms = [{ name: 'level', f: () => 1 }];
      if (vary(n => n.vel)) terms.push({ name: 'velocity', f: n => n.vel });
      if (vary(n => n.cc1)) terms.push({ name: 'CC1', f: n => n.cc1 });
      if (vary(n => n.cc11)) terms.push({ name: 'CC11', f: n => n.cc11 });
      if (span >= 3) terms.push({ name: 'pitch', f: n => (n.pitch - 60) / 12 });
      if (span >= 12 && found.length >= 12) terms.push({ name: 'pitch²', f: n => Math.pow((n.pitch - 60) / 12, 2) });
      const X = found.map(n => terms.map(t => t.f(n)));
      const fit = robustFit(X, found.map(n => n.loudDb));
      if (fit.beta) {
        model.fitted = true;
        model.terms = terms.map((t, i) => ({ name: t.name, coef: fit.beta[i] }));
        model.scaleDb = fit.scale;
        const vi = terms.findIndex(t => t.name === 'velocity');
        if (vi >= 0 && fit.beta[vi] >= 0.05 && fit.beta[vi] <= 1.5) model.dbPerVelocity = fit.beta[vi];
        found.forEach((n, i) => {
          n.expectedDb = X[i].reduce((s, xv, a) => s + xv * fit.beta[a], 0);
          n.deviationDb = n.loudDb - n.expectedDb;
        });
      }
    } else {
      warnings.push('Fewer than six notes were found, too few to judge which are too loud or too quiet.');
    }

    const delays = found.map(n => n.delay);
    const notFound = notes.filter(n => !n.found).length;
    if (notFound) warnings.push(notFound + (notFound === 1 ? ' note was' : ' notes were') + " not found in the audio and won't be changed.");
    // Sound well before the first note means the audio and the MIDI don't start together.
    let loudest = -Infinity;
    for (let k = 0; k < benv.db.length; k++) loudest = Math.max(loudest, benv.db[k]);
    let firstSound = -1;
    for (let k = 0; k < benv.db.length; k++) if (benv.db[k] > loudest - 30) { firstSound = benv.t0 + k * benv.hop; break; }
    const firstNote = Math.min.apply(null, notes.map(n => n.t));
    if (firstSound >= 0 && firstSound < firstNote - 0.02) {
      warnings.unshift('There is sound ' + Math.round((firstNote - firstSound) * 1000) + ' ms before the first note, so the audio probably starts earlier than the MIDI. ' +
        'Render from the start of the clip, or set Audio starts late by to a negative number.');
    } else if (delays.length && quantile(delays, 0.5) < -0.002) {
      warnings.unshift('Most notes sound before their MIDI note. Check that the audio and the MIDI start at the same moment.');
    }

    return {
      version: VERSION,
      options: o,
      midi, tempo: tm, timeSig: ts,
      notes: all,
      measured: notes,
      typicalDelay: typical,
      polyphonic, metric,
      chords: chordId > 0 ? new Set(notes.filter(n => n.chord >= 0).map(n => n.chord)).size : 0,
      model,
      warnings,
      sampleRate: fs,
      duration,
      envelope: benv,
      stats: {
        notes: notes.length,
        found: found.length,
        medianMs: median(delays) * 1000,
        minMs: Math.min.apply(null, delays.concat([Infinity])) * 1000,
        maxMs: Math.max.apply(null, delays.concat([-Infinity])) * 1000,
        spreadMs: (quantile(delays, 0.95) - quantile(delays, 0.05)) * 1000,
        sdMs: stdev(delays) * 1000,
        loudSdDb: stdev(found.filter(n => isFinite(n.deviationDb)).map(n => n.deviationDb)),
      },
    };
  }

  // ------------------------------------------------------------ correction

  const PLAN_DEFAULTS = {
    timingMode: 'note',     // 'note' | 'pitch' | 'part' | 'off'
    timingStrength: 1,
    targetMs: 0,            // where the sound should land relative to the written note
    moveEnds: true,         // move note ends by the same amount (keeps lengths)
    volumeMode: 'note',     // 'note' | 'pitch' | 'off'
    volumeStrength: 1,
    toleranceDb: 1,         // leave notes within this many dB of expected alone
    volumeTarget: 'velocity', // 'velocity' | 'cc11'
    dbPerVelocity: null,    // null: use the fitted value, or 0.25 if none
    dbPerCC: 0.3,
    cc11Base: 100,
    controlLookbackBeats: 0.25, // keyswitches up to this far before a note move with it
  };

  function plan(result, options) {
    const o = Object.assign({}, PLAN_DEFAULTS, options || {});
    const { midi, tempo: tm } = result;
    const notes = result.measured;
    const found = notes.filter(n => n.found);
    const dbPerVel = o.dbPerVelocity || result.model.dbPerVelocity || 0.25;

    const groupMedian = (n, key, sel) => {
      const g = found.filter(m => sel(m) && isFinite(m[key]));
      return g.length ? median(g.map(m => m[key])) : n[key];
    };
    const partDelay = median(found.map(m => m.delay));

    const changes = [];
    for (const n of notes) {
      const c = { note: n, newStartTick: n.startTick, newEndTick: n.endTick, newVel: n.vel, shiftMs: 0, velChange: 0, cc11: null };
      changes.push(c);
      if (!n.found) continue;
      // Volume first: a new velocity can pick a different sample, and a profile knows that sample's delay.
      if (o.volumeMode !== 'off' && isFinite(n.deviationDb)) {
        let dev = n.deviationDb;
        if (o.volumeMode === 'pitch') dev = groupMedian(n, 'deviationDb', m => m.pitch === n.pitch);
        c.deviationUsed = dev;
        if (Math.abs(dev) >= o.toleranceDb) {
          if (o.volumeTarget === 'cc11' && !n.overlapped) {
            c.cc11 = Math.max(0, Math.min(127, Math.round(o.cc11Base - dev * o.volumeStrength / o.dbPerCC)));
          } else {
            c.newVel = Math.max(1, Math.min(127, Math.round(n.vel - dev * o.volumeStrength / dbPerVel)));
            c.velChange = c.newVel - n.vel;
          }
        }
        if (o.volumeTarget === 'cc11' && !n.overlapped && c.cc11 === null) c.cc11 = o.cc11Base;
        const fix = c.cc11 !== null ? (c.cc11 - o.cc11Base) * o.dbPerCC : c.velChange * dbPerVel;
        c.predictedDeviationDb = n.deviationDb + fix;
      }
      // Timing
      let delay = n.delayAt ? n.delayAt(c.newVel) : n.delay;
      if (o.timingMode === 'pitch') {
        delay = groupMedian(n, 'delay', m => m.pitch === n.pitch && Math.abs(m.vel - n.vel) <= 16);
      } else if (o.timingMode === 'part') delay = partDelay;
      if (o.timingMode !== 'off') {
        const shift = -(delay - o.targetMs / 1000) * o.timingStrength;
        if (Math.abs(shift) >= 0.0005) {
          const s = tm.toSec(n.startTick) + shift;
          c.newStartTick = Math.round(tm.toTick(s));
          if (o.moveEnds) c.newEndTick = Math.round(tm.toTick(tm.toSec(n.endTick) + shift));
          if (c.newEndTick <= c.newStartTick) c.newEndTick = c.newStartTick + 1;
          c.shiftMs = (tm.toSec(c.newStartTick) - tm.toSec(n.startTick)) * 1000;
        }
      }
      c.predictedDelayMs = delay * 1000 + c.shiftMs;
    }

    // A note moved under the end of the same key's previous note would be cut off: end the earlier note there.
    const lanes = new Map();
    for (const c of changes) {
      const k = c.note.track + ':' + c.note.ch + ':' + c.note.pitch;
      if (!lanes.has(k)) lanes.set(k, []);
      lanes.get(k).push(c);
    }
    for (const lane of lanes.values()) {
      lane.sort((a, b) => a.newStartTick - b.newStartTick);
      for (let i = 0; i + 1 < lane.length; i++) {
        if (lane[i].newEndTick > lane[i + 1].newStartTick) {
          lane[i].newEndTick = Math.max(lane[i].newStartTick + 1, lane[i + 1].newStartTick);
          lane[i].trimmed = true;
        }
      }
    }

    // Keyswitches and articulation messages travel with the notes they introduce.
    const moves = new Map(); // event order -> new tick
    const groups = new Map(); // track:ch:tick -> earliest shift (ticks, <= 0)
    for (const c of changes) {
      const k = c.note.track + ':' + c.note.ch + ':' + c.note.startTick;
      const dt = c.newStartTick - c.note.startTick;
      groups.set(k, Math.min(groups.has(k) ? groups.get(k) : 0, dt));
    }
    const lookback = Math.round(o.controlLookbackBeats * midi.division);
    const ksMax = result.options.keyswitchMax;
    const ksNotes = result.notes.filter(n => n.keyswitch);
    const ksByOn = new Map(ksNotes.map(n => [n.on.order, n]));
    let controlsMoved = 0;
    midi.tracks.forEach((t, ti) => {
      const starts = new Map(); // ch -> sorted list of group start ticks with shifts
      for (const [k, dt] of groups) {
        const [tr, ch, tick] = k.split(':').map(Number);
        if (tr !== ti || dt >= 0) continue;
        if (!starts.has(ch)) starts.set(ch, []);
        starts.get(ch).push({ tick, dt });
      }
      for (const list of starts.values()) list.sort((a, b) => a.tick - b.tick);
      for (const e of t.events) {
        if (e.kind !== 'ch') continue;
        const ch = e.status & 0x0f, hi = e.status & 0xf0;
        const list = starts.get(ch);
        if (!list) continue;
        const ks = isNoteOn(e) && e.d1 <= ksMax ? ksByOn.get(e.order) : null;
        const isControl = ks || hi === 0xc0 || hi === 0xb0;
        if (!isControl) continue;
        // the first moved group at or after this event
        const g = list.find(s => s.tick >= e.tick);
        if (!g) continue;
        const reach = ks || hi === 0xc0 ? lookback : 0; // CCs only when they sit exactly on the note
        if (g.tick - e.tick > reach) continue;
        moves.set(e.order, e.tick + g.dt);
        if (ks && ks.off) moves.set(ks.off.order, ks.off.tick + g.dt);
        controlsMoved++;
      }
    });

    // Anything earlier than the start of the file: the whole part moves later by whole bars.
    let minTick = 0;
    for (const c of changes) minTick = Math.min(minTick, c.newStartTick);
    for (const tk of moves.values()) minTick = Math.min(minTick, tk);
    const barsAdded = minTick < 0 ? Math.ceil(-minTick / result.timeSig.barTicks) : 0;

    const timed = changes.filter(c => c.note.found);
    const before = timed.map(c => c.note.delay * 1000);
    const after = timed.map(c => c.predictedDelayMs);
    const devBefore = timed.filter(c => isFinite(c.note.deviationDb)).map(c => c.note.deviationDb);
    const devAfter = timed.filter(c => isFinite(c.predictedDeviationDb)).map(c => c.predictedDeviationDb);
    return {
      options: o, result, changes, moves, barsAdded, controlsMoved,
      dbPerVelocity: dbPerVel,
      summary: {
        moved: changes.filter(c => c.shiftMs !== 0).length,
        velocityChanged: changes.filter(c => c.velChange !== 0).length,
        cc11Written: changes.filter(c => c.cc11 !== null).length,
        timingSpreadBeforeMs: before.length ? quantile(before, 0.95) - quantile(before, 0.05) : 0,
        timingSpreadAfterMs: after.length ? quantile(after, 0.95) - quantile(after, 0.05) : 0,
        timingOffBeforeMs: before.length ? median(before.map(Math.abs)) : 0,
        timingOffAfterMs: after.length ? median(after.map(v => Math.abs(v - o.targetMs))) : 0,
        loudSdBeforeDb: stdev(devBefore),
        loudSdAfterDb: stdev(devAfter),
      },
    };
  }

  /** Write the plan into a copy of the MIDI file. */
  function applyPlan(p) {
    const midi = p.result.midi;
    const byOrder = new Map();
    for (const c of p.changes) {
      byOrder.set(c.note.on.order, { tick: c.newStartTick, vel: c.newVel });
      if (c.note.off) byOrder.set(c.note.off.order, { tick: c.newEndTick });
    }
    for (const [ord, tk] of p.moves) if (!byOrder.has(ord)) byOrder.set(ord, { tick: tk });
    const shift = p.barsAdded * p.result.timeSig.barTicks;
    const keepAtZero = e => e.kind === 'meta' && e.tick === 0 && [0x51, 0x58, 0x59, 0x03, 0x02, 0x01, 0x00, 0x04, 0x21, 0x20].includes(e.type);
    const tracks = midi.tracks.map((t, ti) => {
      const events = [];
      for (const e of t.events) {
        const ne = Object.assign({}, e);
        const m = byOrder.get(e.order);
        if (m) {
          ne.tick = m.tick;
          if (m.vel !== undefined && isNoteOn(e)) ne.d2 = m.vel;
        }
        if (!keepAtZero(e) && !isEOT(e)) ne.tick += shift;
        if (isEOT(e)) ne.tick += shift;
        events.push(ne);
      }
      for (const c of p.changes) {
        if (c.cc11 === null || c.note.track !== ti) continue;
        events.push({ tick: c.newStartTick + shift, kind: 'ch', status: 0xb0 | c.note.ch, d1: 11, d2: c.cc11, order: c.note.on.order - 0.5 });
      }
      return { events };
    });
    return writeMidi({ format: midi.format, division: midi.division, tracks });
  }

  // --------------------------------------------------------------- profiles

  /**
   * A learned profile: from the render of calibrationMidi(), every key at every velocity measured
   * on its own. Saved as JSON; used to fix any part played on the same patch without rendering it.
   */
  function learnProfile(result, name) {
    const groups = new Map();
    for (const n of result.measured) {
      if (!n.found) continue;
      const k = n.pitch + ':' + n.vel;
      if (!groups.has(k)) groups.set(k, []);
      groups.get(k).push(n);
    }
    const entries = [];
    for (const g of groups.values()) {
      entries.push({
        pitch: g[0].pitch, vel: g[0].vel,
        delayMs: +(median(g.map(n => n.delay)) * 1000).toFixed(2),
        loudDb: +median(g.map(n => n.loudDb)).toFixed(2),
        deviationDb: isFinite(median(g.map(n => n.deviationDb))) ? +median(g.map(n => n.deviationDb)).toFixed(2) : 0,
        spreadMs: +((Math.max.apply(null, g.map(n => n.delay)) - Math.min.apply(null, g.map(n => n.delay))) * 1000).toFixed(2),
        takes: g.length,
      });
    }
    entries.sort((a, b) => a.pitch - b.pitch || a.vel - b.vel);
    if (!entries.length) throw new Error('No notes were found in the test render.');
    return {
      kind: 'note-position-volume-fixer/profile', version: 1,
      name: name || 'Untitled', created: new Date().toISOString(),
      alignTo: result.options.alignTo,
      dbPerVelocity: result.model.dbPerVelocity,
      notFound: result.measured.filter(n => !n.found).map(n => ({ pitch: n.pitch, vel: n.vel })),
      entries,
    };
  }

  function checkProfile(p) {
    if (!p || p.kind !== 'note-position-volume-fixer/profile' || !Array.isArray(p.entries) || !p.entries.length) {
      throw new Error("This isn't a profile saved by Note Position & Volume Fixer.");
    }
    return p;
  }

  /** Delay and loudness deviation for any key and velocity, between the ones measured. */
  function profileAt(p, pitch, vel) {
    const pitches = Array.from(new Set(p.entries.map(e => e.pitch))).sort((a, b) => a - b);
    let lo = pitches[0], hi = pitches[pitches.length - 1];
    const outside = pitch < lo || pitch > hi;
    for (const q of pitches) { if (q <= pitch) lo = q; }
    for (let i = pitches.length - 1; i >= 0; i--) { if (pitches[i] >= pitch) hi = pitches[i]; }
    if (pitch < pitches[0]) hi = lo = pitches[0];
    if (pitch > pitches[pitches.length - 1]) hi = lo = pitches[pitches.length - 1];
    const atKey = (q) => {
      const row = p.entries.filter(e => e.pitch === q).sort((a, b) => a.vel - b.vel);
      let a = row[0], b = row[row.length - 1];
      for (const e of row) { if (e.vel <= vel) a = e; }
      for (let i = row.length - 1; i >= 0; i--) { if (row[i].vel >= vel) b = row[i]; }
      if (vel < row[0].vel) b = a = row[0];
      if (vel > row[row.length - 1].vel) a = b = row[row.length - 1];
      const f = b.vel === a.vel ? 0 : (vel - a.vel) / (b.vel - a.vel);
      return { delayMs: a.delayMs + f * (b.delayMs - a.delayMs), deviationDb: a.deviationDb + f * (b.deviationDb - a.deviationDb) };
    };
    const A = atKey(lo), B = atKey(hi);
    const f = hi === lo ? 0 : (pitch - lo) / (hi - lo);
    return {
      delayMs: A.delayMs + f * (B.delayMs - A.delayMs),
      // a key's own fault is its own: between measured keys there is nothing to correct
      deviationDb: lo === pitch ? A.deviationDb : (hi === pitch ? B.deviationDb : 0),
      exact: lo === pitch || hi === pitch,
      outside,
    };
  }

  /** The same shape analyse() returns, filled in from a profile instead of a render. */
  function fromProfile(midi, profile, options) {
    checkProfile(profile);
    const o = Object.assign({}, ANALYSE_DEFAULTS, options || {}, { audioOffsetMs: 0, alignTo: profile.alignTo });
    const tm = tempoMap(midi, o.tempoBpm);
    const all = collectNotes(midi).filter(n => o.track < 0 || n.track === o.track).map(n => Object.assign(n, {
      t: tm.toSec(n.startTick), tEnd: tm.toSec(n.endTick), keyswitch: n.pitch <= o.keyswitchMax,
    }));
    const notes = all.filter(n => !n.keyswitch);
    if (!notes.length) throw new Error('The MIDI file has no notes to fix.');
    // A profile measured on CC1 (long notes on the mod wheel) is looked up by each note's CC1, not its velocity.
    const byCC1 = profile.dynamics === 'cc1';
    for (const n of notes) {
      n.level = byCC1 ? ccValueAt(midi, n.track, n.ch, 1, n.startTick) : n.vel;
      if (n.level === null) n.level = 100;
      const at = profileAt(profile, n.pitch, n.level);
      n.found = true;
      n.delay = at.delayMs / 1000;
      n.deviationDb = at.deviationDb;
      if (!byCC1) n.delayAt = v => profileAt(profile, n.pitch, v).delayMs / 1000;
      n.measuredOn = 'profile';
      n.check = at.outside;
      n.overlapped = false;
    }
    // overlapping notes can't take CC11 one at a time
    const byStart = notes.slice().sort((a, b) => a.t - b.t);
    for (let i = 0; i < byStart.length; i++) {
      for (let j = i + 1; j < byStart.length && byStart[j].t < byStart[i].tEnd - 0.005; j++) { byStart[i].overlapped = byStart[j].overlapped = true; }
    }
    const outside = notes.filter(n => n.check).length;
    const warnings = outside ? [outside + (outside === 1 ? ' note is' : ' notes are') + " outside the profile's range and use its nearest key."] : [];
    const delays = notes.map(n => n.delay);
    return {
      version: VERSION, options: o, midi, tempo: tm, timeSig: timeSignature(midi),
      notes: all, measured: notes, typicalDelay: median(delays), polyphonic: false, metric: 'profile',
      model: { fitted: false, terms: [], dbPerVelocity: profile.dbPerVelocity },
      warnings, profile, preferCC11: byCC1,
      stats: {
        notes: notes.length, found: notes.length,
        medianMs: median(delays) * 1000,
        minMs: Math.min.apply(null, delays) * 1000, maxMs: Math.max.apply(null, delays) * 1000,
        spreadMs: (quantile(delays, 0.95) - quantile(delays, 0.05)) * 1000,
        sdMs: stdev(delays) * 1000,
        loudSdDb: stdev(notes.map(n => n.deviationDb)),
      },
    };
  }

  // ------------------------------------------------------- test helpers

  /** Seconds a calibration part lasts. */
  function calibrationLength(o) {
    o = Object.assign({ low: 48, high: 72, step: 1, velocities: [40, 80, 120], repeats: 1, bpm: 120, noteBeats: 0.5, gapBeats: 1.5 }, o || {});
    const keys = Math.floor((o.high - o.low) / o.step) + 1;
    return (8 + keys * o.velocities.length * o.repeats * (o.noteBeats + o.gapBeats)) * 60 / o.bpm;
  }

  /** A calibration part: every pitch in a range at several velocities, each note on its own. */
  function calibrationMidi(o) {
    o = Object.assign({ low: 48, high: 72, step: 1, velocities: [40, 80, 120], repeats: 1, bpm: 120, noteBeats: 0.5, gapBeats: 1.5, ppq: 480, channel: 0, keyswitch: null }, o || {});
    const events = [];
    let order = 0;
    const uspq = Math.round(60e6 / o.bpm);
    events.push({ tick: 0, kind: 'meta', type: 0x51, data: new Uint8Array([(uspq >> 16) & 255, (uspq >> 8) & 255, uspq & 255]), order: order++ });
    events.push({ tick: 0, kind: 'meta', type: 0x58, data: new Uint8Array([4, 2, 24, 8]), order: order++ });
    events.push({ tick: 0, kind: 'meta', type: 0x03, data: new Uint8Array(Array.from('Test notes', ch => ch.charCodeAt(0))), order: order++ });
    if (o.keyswitch !== null && o.keyswitch !== undefined) {
      // the articulation, chosen during the empty first bar
      events.push({ tick: o.ppq * 2, kind: 'ch', status: 0x90 | o.channel, d1: o.keyswitch, d2: 100, order: order++ });
      events.push({ tick: o.ppq * 2 + o.ppq / 4, kind: 'ch', status: 0x80 | o.channel, d1: o.keyswitch, d2: 64, order: order++ });
    }
    let tick = o.ppq * 4; // one empty bar first
    for (const v of o.velocities) {
      for (let p = o.low; p <= o.high; p += o.step) {
        for (let r = 0; r < o.repeats; r++) {
          events.push({ tick, kind: 'ch', status: 0x90 | o.channel, d1: p, d2: v, order: order++ });
          events.push({ tick: tick + Math.round(o.noteBeats * o.ppq), kind: 'ch', status: 0x80 | o.channel, d1: p, d2: 64, order: order++ });
          tick += Math.round((o.noteBeats + o.gapBeats) * o.ppq);
        }
      }
    }
    events.push({ tick: tick + o.ppq * 4, kind: 'meta', type: 0x2f, data: new Uint8Array(0), order: order++ });
    return writeMidi({ format: 0, division: o.ppq, tracks: [{ events }] });
  }

  function encodeWav(data, fs) {
    const n = data.length;
    const b = new Uint8Array(44 + n * 4);
    const dv = new DataView(b.buffer);
    const s = (p, t) => { for (let i = 0; i < 4; i++) b[p + i] = t.charCodeAt(i); };
    s(0, 'RIFF'); dv.setUint32(4, 36 + n * 4, true); s(8, 'WAVE');
    s(12, 'fmt '); dv.setUint32(16, 16, true); dv.setUint16(20, 3, true); dv.setUint16(22, 1, true);
    dv.setUint32(24, fs, true); dv.setUint32(28, fs * 4, true); dv.setUint16(32, 4, true); dv.setUint16(34, 32, true);
    s(36, 'data'); dv.setUint32(40, n * 4, true);
    for (let i = 0; i < n; i++) dv.setFloat32(44 + i * 4, data[i], true);
    return b;
  }

  return {
    VERSION,
    parseMidi, writeMidi, collectNotes, noteTracks, tempoMap, timeSignature, noteName, position,
    decodeAudio, kWeight, envelope,
    analyse, plan, applyPlan,
    learnProfile, checkProfile, profileAt, fromProfile,
    calibrationMidi, calibrationLength, encodeWav,
    ANALYSE_DEFAULTS, PLAN_DEFAULTS,
    _internal: { median, quantile, stdev, robustFit, findOnset, harmonicPower, loudness },
  };
});
