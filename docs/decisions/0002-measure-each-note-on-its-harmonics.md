# 0002 - Measure each note on its own harmonics

- **Date:** 2026-11-13
- **Status:** Accepted

## Context

On the whole sound, a quiet note after a loud one is buried in the loud
note's tail, and low notes a semitone apart can't be told apart. Three ways
were compared on the test library (median / worst error, ms):

| | whole sound | narrow bands skipping other notes | own harmonics, wide bands |
| --- | --- | --- | --- |
| eighths | 1.1 / 6.7, 2 not found | outliers to 70 | 0.8 / 7.8 |
| low register | 3.4 / 89.9 | outliers to 187 | 3.0 / 18.4 |
| legato | 6.0 / 18.1, 6 not found | 4.4 / 7.7 | 4.4 / 7.7 |

Searching negative lags for the typical delay (to catch audio that starts
early) was also tried: in a regular rhythm the lag one note early lines up
just as well, and it was chosen.

## Decision

- Each note is measured on its harmonics, band-passed forwards and
  backwards (no delay), bandwidth half the fundamental, after subtracting
  the projected tail of what was already sounding.
- A note entering under held notes uses narrow bands that skip the held
  notes' harmonics, and is marked *Check*.
- If harmonics hold under −12 dB of the sound (an unpitched sound) or most
  notes aren't found on them, the whole sound is used.
- The typical delay is searched from −20 ms up. Audio that starts early is
  caught by sound appearing before the first note.

## Consequences

- Fast parts whose notes differ by more than half the gap between them can't
  be untangled from a render; a profile can (0004).
