# 0004 - Learned profiles

- **Date:** 2026-11-13
- **Status:** Accepted

## Context

A render of the part only shows what played that time: round robins change,
chords and fast passages are hard to untangle, and every part has to be
rendered.

## Decision

The page writes a test MIDI file - every key in a range at chosen velocities,
each note alone, two beats apart, with an optional keyswitch first, at the
user's project tempo. Its render is measured once and kept as a profile
(JSON, in the browser, and as a file on request). Any part on that patch is
then fixed from the profile, interpolating between measured velocities, with
volume corrected first so the delay of the new velocity is used.

## Consequences

- Within 2 ms on every test part, including chords and legato.
- One profile per patch (articulation). A part that switches articulations
  needs a profile for each, applied to the notes of each; not done yet.
- Legato transitions are measured as first notes, not as transitions.
