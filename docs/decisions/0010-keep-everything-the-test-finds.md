# 0010 - Keep everything the test finds

- **Date:** 2026-11-15
- **Status:** Accepted

## Context

The user wants what Measure Libraries detects saved, so that future scripts
can correct notes from it. A version 1 profile kept only the delay to
correct by, the loudness and its deviation, per key and level.

## Decision

Profile version 2 (`docs/profile-format.md`):

- per key and level: `startMs` (30 dB below the peak), `attackMs` (12 dB),
  `peakMs` (within 1 dB - the attack's end; the loudest moment itself
  wanders along a flat top, so it isn't used), and every take's delay;
- per patch: the keys that sounded (`range`, `silentKeys`), the test's
  settings, where the switching came from, and a `summary` (median and
  extremes, the round robins' spread, delay by level, keys off level);
- `Library.json`, an index of every profile, rebuilt on each save;
- file names with the library: `<Library> - <Instrument> - <Articulation>`.

Start, attack and end are found in one pass from the same curve, in both
the Lua and engine.js, and the parity test holds them to each other (start
and attack within 0.6 ms; the end within 3 ms, a median of 0.03).

A test where few notes are heard is no longer refused for that alone:
keys outside a patch's range are silent. A mostly silent first render is
tried again once, keeping the better; a profile is saved from six notes up.

## Consequences

- Profiles are larger (each take's delay).
- A script can choose start or attack after the fact, without measuring
  again.
