# 0008 - Articulations by their switch; dynamics by velocity or CC1

- **Date:** 2026-11-13
- **Status:** Accepted

## Context

A part on one track usually changes articulation with keyswitches (or
Spitfire's UACC CC32, program changes, MIDI channels), and each articulation
is late by its own amounts. Long notes in Spitfire, SINE and Synchron
patches get their dynamics from the mod wheel, where velocity changes little
or nothing.

## Decision

- Each articulation's profile records its switch. When fixing, the notes and
  switches are read in time order; each note takes the profile whose switch
  is in force (the last keyswitch, the last value of that CC on its channel,
  the last program, or its channel). A note no switch chose takes the
  profile with no switch, else the one chosen under *When no switch says*,
  else it is left alone and counted.
- An articulation measured with **Dynamics: CC1** steps CC1 instead of
  velocity (velocity held at 100). Its profile is looked up by each note's
  CC1, and loudness is evened out with one CC11 a note, a tick before it,
  where notes don't overlap.

## Consequences

- Keyswitches named by the profiles are never moved on their own; they move
  with the note they introduce if within a 16th note before it.
- CC1 profiles don't follow velocity at all. A patch where both matter
  (velocity for the attack, CC1 for the level) is measured on CC1.
