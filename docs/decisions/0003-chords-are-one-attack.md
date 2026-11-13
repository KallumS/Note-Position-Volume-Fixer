# 0003 - A chord is one attack

- **Date:** 2026-11-13
- **Status:** Accepted

## Context

Chord notes share harmonics (G's second is C's third), so measuring each on
its own picks up whichever note sounded first. On the test chords this was
off by a median 40 ms, and checking the fixed render with the same detector
hid it: it agreed with itself.

## Decision

Notes starting within 30 ms of each other are measured together on the whole
sound, as the moment the chord is heard, and moved together so that moment
lands on the grid.

## Consequences

- The chord's attack is right; differences between its notes stay. A
  profile (0004) lines those up too, since it measures each key alone.
