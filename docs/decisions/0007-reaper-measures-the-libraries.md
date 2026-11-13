# 0007 - REAPER measures the libraries, a new track for each

- **Date:** 2026-11-13
- **Status:** Accepted

## Context

Rendering a test file by hand for every patch and articulation doesn't
scale to a whole set of libraries. The user asked for a program that plays
through their installed libraries (SINE, Kontakt, Spitfire, Engine,
Synchron), changing articulations and instruments, and chose REAPER for it.
They would rather start a new track for each test than rely on a template.

## Decision

- Two ReaScripts with ReaImGui windows, in the shape of the family's other
  REAPER scripts (Good Idea): plain-Lua modules that never touch REAPER,
  one module that does, and the windows.
- An instrument is **captured once from a track**: its whole FX chain, which
  holds the loaded patch. Each test puts that chain on a **new track** (new
  FX IDs), switches off effects after the instrument, waits for samples to
  load, writes the test into an item, renders it with *Apply track/take FX
  to items as new take* (offline), reads it with a take audio accessor,
  measures it, and deletes the item, the rendered file and the track.
- A test that comes back with fewer than 80% of its notes is taken as
  samples still loading: it waits again and tries once more.
- The measuring is a **Lua port** of the engine's, not a call out to it: a
  REAPER script can't be relied on to find Node. `tests/lua_parity.js`
  measures the same renders with both: delays agree within 0.5 ms,
  loudness within 0.3 dB.
- Profiles are the page's format plus where they came from (instrument,
  articulation, plug-in, switch, dynamics), one file per articulation, so
  the page and the Fix script read the same files.

## Consequences

- Unattended: a library's worth runs overnight. The Lua measures about
  300 notes in 26 s here.
- Nothing has been run inside REAPER from where this was written. The mock
  (`tests/lua/reaper_mock.lua`) follows the documented signatures, plays two
  unknowns pessimistically (MIDI_SetItemExtents keeping PPQ; accessor time
  from the item start) and renders real audio, but the real REAPER and real
  players are the test that matters. Unverified: whether *Apply FX* waits
  for samples a player is still streaming, whether every player restores
  its patch from a copied FX chain, and offline rendering speed.
