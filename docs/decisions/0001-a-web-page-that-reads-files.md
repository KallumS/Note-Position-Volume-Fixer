# 0001 - A web page that reads files, not a plugin

- **Date:** 2026-11-13
- **Status:** Accepted

## Context

The user wants notes moved by however late each one sounds, in Ableton first
and Cubase and REAPER if possible. The samples can't be edited. A tool needs
to hear the library, which means audio from the DAW. The options are in
`docs/research.md` section 4.

## Decision

A single HTML file that runs in any browser, offline: MIDI and a render go
in, a corrected MIDI file comes out. The measuring is plain JavaScript with
no DOM, so the same code is tested under Node.

## Consequences

- Works in every DAW, on Mac and Windows, with nothing installed.
- The user has to export and import files. A learned profile (0004) halves
  that; a Max for Live device that applies a profile in place would remove
  it for Ableton, and is the suggested next step.
- A real-time plugin hosting the library with lookahead would keep the MIDI
  on the grid, but adds latency to the project and has to host Kontakt and
  the rest reliably. Left for later.
