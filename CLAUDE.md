# Note Position & Volume Fixer

Three parts sharing one profile format:

- **The page** - a one-file web page (`Note-Position-Volume-Fixer.html`,
  built from `src/`) that measures a render of a MIDI part - where each note
  is heard and how loud it is - and writes the MIDI back with notes moved and
  velocities (or CC11) changed, or learns a profile from a test render and
  fixes any part from it. Any DAW, through files.
- **Note Fixer for REAPER** (`reaper/`) - *Measure Libraries* plays every
  key of each captured instrument, articulation by articulation, on a new
  track, and saves profiles; *Fix Selected Items* fixes MIDI items from them,
  each note by the articulation its switch chose (0007, 0008). The user
  focuses on REAPER for measuring, with SINE, Kontakt, Spitfire, Engine and
  Synchron Player libraries.
- **Note Fixer for Mac** (`mac/`) - the measuring as an Apple Silicon app
  that hosts the Audio Unit instruments itself (0011), measuring with the
  REAPER scripts' own Lua through a C bridge. Built only on GitHub Actions.

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
- [`docs/HANDOVER.md`](docs/HANDOVER.md) - **start here in a new session**:
  where things stand, what has never been tried for real, what's next.
- [`docs/chat/`](docs/chat/) - the whole first conversation (13-20 November
  2026), exported by `tools/export_chat.py` from the session record before
  the chat was cleared. Every user request is there in their own words.

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
| `reaper/npvf_measure.lua` | Lua port of the engine's measuring, for test notes played one at a time, and `learnProfile`. **No REAPER.** |
| `reaper/npvf_fix.lua` | `profileAt` and the fix plan for several profiles, each note's articulation from its switch. **No REAPER.** |
| `reaper/npvf_maps.lua` | Reads Cubase expression maps, Logic articulation sets and Reaticulate banks into articulations with `send` (outputs), `channel`, `program` (0009). **No REAPER.** |
| `reaper/npvf_json.lua` | JSON. |
| `reaper/npvf_reaper.lua` | Everything that touches REAPER but not the window: capture an FX chain, make the test track, render and read it, clean up, read and write items. |
| `reaper/npvf_ui.lua` | The house theme and the family's widgets for ReaImGui (after Good Idea). |
| `reaper/Note Fixer - *.lua` | The two windows. |
| `tests/lua/test_fix.lua` | Lua unit tests: articulation choice (combinations, UACC KS, Reaticulate programs), CC1 profiles, JSON. |
| `tests/lua/test_maps.lua` | The map readers, on `tests/fixtures/Test Strings.*` (written here in each format's real layout). Give it a folder of real maps to read those too. |
| `docs/profile-format.md` | **What is saved**: profiles (version 2), `Library.json`, `Instruments.json`. Change it with the format. |
| `tests/lua_parity.js` | Lua and the engine measure the same renders (and plan the same fix) and must agree. |
| `tests/lua/test_scripts.lua` | Both windows end to end in `reaper_mock.lua` + `imgui_mock.lua`; the mock's *Apply FX* renders the made-up library via `render_cli.js`. |
| `mac/Sources/NoteFixer/*.swift` | The Mac app: `AUHost` (list, load, state, the plug-in's window, offline render), `Store` (instruments, settings, the run), `ContentView`, `Theme` (house colours), `Bridge` (Swift over the C bridge), `SelfTest`. |
| `mac/Sources/NPVFBridge` | C: one Lua state, `npvf_call` (JSON in and out) and `npvf_measure` (audio in, read note by note, stoppable). |
| `mac/Sources/CLua` | Lua 5.4.6, unchanged (headers in `include/` for SwiftPM). |
| `mac/Lua/npvf_app.lua` | The app's JSON API over the shared Lua. |
| `reaper/npvf_library.lua` | Profile file names and `Library.json`, for REAPER and the app alike. |
| `tools/stage_lua.sh` | Copies the Lua the app runs into one folder: the build and `tests/bridge_test.js` both use it. |
| `tests/bridge_test.js` | Builds the bridge with `cc` and checks it against the REAPER scripts' Lua. |
| `.github/workflows/mac-app.yml` | `macos-15`: bridge test, `mac/build-app.sh`, `NoteFixer --self-test tests/fixtures`, the app starts, upload. |
| `index.xml` | ReaPack index: one package, both scripts, every source pinned to a commit. New version = new `<version>` block with a new hash; never edit an old one. **The next version must add `npvf_library.lua`** (the scripts load it since 1.1 was published). |
| `tools/export_chat.py` | Turns a Claude Code session record (`~/.claude/projects/.../<session>.jsonl`) into `docs/chat/*.md`: messages and replies kept, private reasoning, tool output and email addresses left out. |

## Working in it

```sh
npm test                      # engine, ~7 s
node tools/build.js           # after any change in src/
NODE_PATH=$(npm root -g) node tests/ui_test.js [shots-dir]   # page; Playwright is global here
sh tools/test.sh              # everything, ~1.5 min
```

A fresh container has no Lua: `apt-get update && apt-get install -y lua5.4`.

- **A change to measuring goes into both `src/engine.js` and
  `reaper/npvf_measure.lua`**, then `node tests/lua_parity.js`. Same for
  `profileAt` and the plan in `npvf_fix.lua`.
- **The REAPER mock is written from the API's documented signatures, not
  from the scripts.** A function the scripts need that isn't there gets
  added from its documented signature; anything missing raises. Extension
  functions (SWS) read nil unless `P.sws`.
- **Prove a test bites** by breaking the code in a scratch copy (the session
  log lists the sabotages tried).

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

## REAPER rules that are easy to break

- **A profile's fields are a promise to scripts to come** (0010,
  `docs/profile-format.md`): add fields, don't rename or drop them, and bump
  `M.PROFILE_VERSION` when a meaning changes. Old profiles must keep
  working (`F.conditions` reads the version 1 `switch`).
- **The test never plays a key the instrument uses as a keyswitch**
  (`keyswitchKeys`, `skip` in `testLayout`): VSL maps have them in range.
- **Which articulation a note plays** (`F.plan`, 0009): keys held on are a
  set; a new key turns off only keys no articulation combines it with;
  velocity tells keys apart where articulations differ by it; most specific
  wins, then latest; a Reaticulate program chooses directly.
- **Real maps aren't committed** (they're others' work). Fixtures are
  written by hand in the real layout; `test_maps.lua <folder>` checks a
  folder of real ones (Kabraxist/Expression-2-Reaticulate's sources,
  tpoots/cubase-expression-maps, nobodo/logic-pro-x-articulation-sets and
  jtackaberry/reaticulate's userbanks were the ones tried: all read).

- **A test never uses the user's tracks.** It makes a track, copies the
  captured FX chain onto it with new FXIDs, and deletes the track, the item
  and the rendered file afterwards - also when stopped or on an error
  (`ui.finish` → `cleanup`).
- **Stop is checked inside measuring** (the progress callback raises `STOP`),
  so it doesn't wait for a whole articulation.
- **`writeTake` places every note and CC again from its time** after
  extending an item to the left, so it doesn't matter whether
  `MIDI_SetItemExtents` keeps times or PPQ. Note-ons/offs and CCs are set
  with noSort, then sorted, then CC11s inserted.
- Middle C is C3 in the windows too (`U.noteName`, `U.parseNote`); REAPER
  itself may show C4.

## Mac app rules that are easy to break

- **Swift is only built on GitHub's Mac.** After pushing, check the *Mac
  app* run (`mcp__github__actions_list`, then `get_job_logs`); a failure is
  read from the log and fixed, never skipped. `macos-14` runners are gone;
  use `macos-15` or later.
- **The app runs the REAPER scripts' Lua.** A Lua change is a change to the
  app too: `node tests/bridge_test.js` and the CI self-test cover it. The
  app's own Lua is only `mac/Lua/npvf_app.lua`; anything shared goes in
  `reaper/` and into `tools/stage_lua.sh`.
- **Every MIDI event on its exact sample**: scheduled through
  `scheduleMIDIEventBlock` at `AUEventSampleTimeImmediate + offset` before
  the chunk it falls in is rendered. The self-test proves it with a 0.1 ms
  shift.
- **Stop** is a lock-protected flag (`StopFlag`) read by the render and the
  measuring on their background threads.
- The app is macOS 13+: don't use APIs newer than that without a check.

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
- The family's ReaScripts to copy from: Good Idea (`reascripts/`, its
  `tests/reaper_mock.lua` and `hig_mock.lua`, and `docs/COLOUR.md`), cloned
  read-only from `github.com/KallumS/Good-Idea`.
