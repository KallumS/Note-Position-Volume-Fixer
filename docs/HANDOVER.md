# Handover

Where things stood on 20 November 2026, when the first chat was cleared.
Read this, then `CLAUDE.md`, before changing anything. The whole first
conversation is in [`chat/2026-11-13-chat.md`](chat/2026-11-13-chat.md).

## Who it's for

A composer, not a developer, working with older orchestral sample libraries
whose notes speak late (the sample starts before the attack) and unevenly,
key by key and dynamic by dynamic, and some of whose notes are louder or
quieter than their neighbours. Main DAW Ableton Live; Cubase and REAPER too;
measuring in REAPER or on the Mac. Libraries: SINE, Kontakt, Spitfire,
Engine, Synchron Player. Has BabylonWaves Art Conductor maps. Wants
everything measured kept, for scripts to come. Follows Apple's HIG and the
house colours of their other repositories (Good Idea's `docs/COLOUR.md`).
Explain in plain words; show pictures.

## What exists

| Part | State | Tested by |
| --- | --- | --- |
| The page (`Note-Position-Volume-Fixer.html`): fix a MIDI file from its render or from a profile | Done | 35 engine tests, the page in Chromium |
| *Note Fixer - Measure Libraries* (REAPER): captures an instrument, imports its articulations from a map, plays every key on a new track offline, saves profiles | Done, 1.1 | Lua tests, Lua against the page's engine, both windows in a mock REAPER |
| *Note Fixer - Fix Selected Items* (REAPER): each note fixed by its own articulation's profile | Done, 1.1 | as above |
| Map import: Cubase expression maps, Logic articulation sets (Art Conductor), Reaticulate banks | Done | Fixtures, and 242 real maps from public repositories (not committed) |
| *Note Fixer for Mac*: hosts Audio Unit instruments, measures offline, same Lua via a C bridge | Done, 1.0 | The bridge here; on GitHub's macos-15: build, a self-test with Apple's DLS synth, the app starts |
| Profile format version 2 and `Library.json` | Done | `docs/profile-format.md` |

All work is on the branch `claude/kind-cray-otnrrc`. Nothing has been merged
into `main`, so the ReaPack link in the README won't work until it is.

## Never tried for real

Everything above was tested against a made-up library (`tests/synth.js`),
a mock REAPER, and, for the Mac app, Apple's own synth. **Nobody has yet run
any of it with a real player or a real DAW.** The first real tries should
be small (one patch, two articulations, a short key range). The open
questions:

- REAPER: whether *Apply FX as new take* waits for samples a player is
  still streaming; whether each player restores its patch from a copied FX
  chain; render speed; a take audio accessor's time origin.
- Mac: whether each player's window shows (`requestViewController`, else
  the Cocoa view), whether *Remember This Patch* (`fullState`) brings the
  patch back, and whether players load samples before an offline render.
- Both: real libraries' reverb, noisy attacks and legato transitions
  (measured as first notes only).
- Logic sets using program changes or channels (no example seen).

## Next, if the user wants it

- The first real test, and fixing what it shows.
- A Max for Live device that applies a profile to a clip in place (the
  research's option C), so Ableton needs no export.
- A ReaPack version 1.2 (it must add `npvf_library.lua`), and merging the
  branch so the ReaPack link works.
- Studio One, Dorico, Digital Performer, Cakewalk maps.
- A text size choice in the REAPER windows.
- Notarising the Mac app (needs the user's Apple Developer account).
- The user's ScaleView workflow still asks for `macos-14`, which GitHub no
  longer offers (found here on 15 November).

## How to work here

- `sh tools/test.sh` runs everything that runs here (Lua: `apt-get update &&
  apt-get install -y lua5.4` in a fresh container).
- Swift is built only on GitHub: push, then read the *Mac app* run's log.
- A measuring change goes into `src/engine.js` and `reaper/npvf_measure.lua`
  both; the parity and bridge tests hold them together.
- A profile field is a promise: add, never rename or drop.
- Prove a new test bites by breaking the code in a scratch copy.
