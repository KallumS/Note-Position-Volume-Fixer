# Note Position & Volume Fixer

A one-file web page (`Note-Position-Volume-Fixer.html`, built from `src/`)
that measures a render of a MIDI part - where each note is heard and how loud
it is - and writes the MIDI back with notes moved and velocities (or CC11)
changed. Or learns a profile per patch from a test render and fixes any part
from it. Works with any DAW through MIDI and audio files.

The user is not a developer. Explain in plain words, show pictures of what
changed, and keep the README's "Use" section true: it is how they learn it.
Their main DAW is Ableton Live; Cubase and REAPER matter too.

## Where the reasons are

- [`docs/research.md`](docs/research.md) - what exists, how to measure, the
  options for delivering it, accuracy, sources. Read before changing how
  notes are measured.
- [`docs/decisions/`](docs/decisions/README.md) - one record per choice that
  could reasonably go the other way, referred to by number.
- [`docs/apple-hig-review.md`](docs/apple-hig-review.md) - the page against
  Apple's HIG Foundations.
- [`docs/sessions/`](docs/sessions/) - one log per working session.

## Shape of it

| File | What it does |
| --- | --- |
| `src/engine.js` | Everything that matters: MIDI read/write, WAV/AIFF decoding, the tempo map, onset and loudness measurement (`analyse`), what to change (`plan`), writing it (`applyPlan`), profiles (`learnProfile`, `fromProfile`, `profileAt`), the test MIDI (`calibrationMidi`). **No DOM** - it runs under Node for the tests. |
| `src/app.html` | The page's markup and CSS (house colours). `<!--ENGINE-->` and `<!--APP-->` are replaced by the build. |
| `src/app.js` | Wiring: files in, settings, drawing, table, downloads, saved profiles (`localStorage` key `npvf.profiles`). |
| `tools/build.js` | Inlines both scripts into `Note-Position-Volume-Fixer.html`. **Run it after any change in `src/` and commit the built file** - it is what the user opens. |
| `tests/synth.js` | A made-up library with known per-key/velocity delays, attacks and three faulty keys (64, 67, 71). |
| `tests/run_tests.js` | Engine tests. Most render, fix, render again and check against the library's own numbers. |
| `tests/ui_test.js` | Drives the built page in Chromium: files, keyboard, download, learning a profile, reload. |

## Working in it

```sh
npm test                      # engine, ~7 s
node tools/build.js           # after any change in src/
NODE_PATH=$(npm root -g) node tests/ui_test.js [shots-dir]   # page; Playwright is global here
```

- **When fixing a bug, have a test fail on the old code first.**
- **Check accuracy against ground truth, not against the tool.** Measuring a
  fixed render with the same detector can agree with itself while both are
  wrong (chords did exactly this). `trueAfter()` in the tests uses
  `S.expectedOnsetMs`.
- **Look at a screenshot after any drawing change.**
- Nothing here can be tried in a real DAW or with a real library. Say so
  whenever a change rests on DAW behaviour (how Live imports MIDI tempo,
  where a render starts).

## How measuring works (the parts that are easy to break)

- `typicalDelay`: the lag (−20 ms to *Latest a sound can start*) at which
  all note starts best line up with rises in the K-weighted sound. Searching
  negative lags was tried and aliases onto the previous note in regular
  rhythms (0002).
- Each note is searched only within *How far notes can differ* of that lag,
  and only up to halfway to its neighbours, so fast passages can't swap.
- `findOnset`: steepest 10 ms rise in the window, forward to the end of the
  attack, then **the decaying tail of what was already sounding is projected
  forward and subtracted** before finding the point *attackDb* (12) below
  the note's own peak. Without the subtraction, quiet notes after loud ones
  read 10-20 ms late.
- Measured on the note's **own harmonics** by default (0002); chords
  (starts within 30 ms) on the whole sound as one attack (0003); a note
  entering under held notes on narrow bands that skip the other notes'
  harmonics (best effort, flagged *Check*). Unpitched sounds fall back to
  the whole sound when the harmonics hold under −12 dB of it.
- Loudness: loudest 50 ms from the onset, all notes on the same measure.
  Expected loudness is a Huber-weighted fit of velocity, CC1, CC11, pitch
  and pitch²; terms that don't vary are left out.
- `plan` does volume **before** timing, because with a profile a new
  velocity has its own delay (`n.delayAt`).

## Rules that are easy to break

- **Keyswitches, program changes and CCs on a note's exact start tick move
  with it**; keyswitch notes (at or below *Keyswitches at or below*) up to a
  16th early move by the same amount. A CC1 curve elsewhere must stay put.
- **Notes moved before tick 0 push the whole part later by whole bars**;
  tempo, time signature and names at tick 0 stay at 0. The page says how far
  to move it back.
- **A note moved under the same key's previous note ends that note** where
  the moved one starts, or samplers cut it off.
- **Same-tick order on writing**: meta, then note-offs, then everything else
  in original order. Keyswitches rely on keeping their order.
- **`tempoBpm`**: Live and Cubase play an imported MIDI file at the
  project's tempo, ignoring the file's. The page's *Played at* field
  overrides the file; the test MIDI is written at the tempo typed in.
- Middle C is **C3** (Live and Cubase). `noteName` and the page's note
  parser agree; REAPER users see C4 for the same key.

## Colour and Apple's HIG

The house scheme (Good Idea's `docs/COLOUR.md`; 0005): ground `#23272E`,
sunken `#1A1D23`, roll `#111419`, controls `#A9AFBA` with ink `#14171C` on
every button, text `#DDE1E7`, secondary `#B0B6C0`, focus ring `#F2F4F7`,
**yellow `#FFF200` only for what is on or chosen** (segmented choices, the
selected note), red `#D2483F` marks and `#FF9E96` letters warnings. Every
grey R < G < B. Always dark.

HIG (0006): text 7:1 (checked: the lowest is secondary text at 7.4:1), shapes
that mean something 3:1, controls 28 px tall, every action reachable from the
keyboard, title-style button names with a verb, messages that say what to do,
nothing time-limited. Never commit Apple's guideline pages: the repository is
public.

## Environment

- `vi-control.net` and `ownlifeaudio.com` are blocked by this environment's
  network policy; search results are all there is of them.
- Playwright and Chromium are installed globally; `NODE_PATH=$(npm root -g)`.
