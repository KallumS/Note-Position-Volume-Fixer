# 0009 - Import articulation maps; articulations are combinations of outputs

- **Date:** 2026-11-15
- **Status:** Accepted. Widens 0008.

## Context

The user asked to import BabylonWaves expression maps so the measuring
window knows the keyswitches. Art Conductor makes maps for Cubase, Logic,
Studio One, Dorico, Digital Performer and Cakewalk - not REAPER. REAPER's own
articulation system is Reaticulate. Real maps (52 Cubase expression maps,
4 Logic sets and 185 Reaticulate bank files from public repositories) showed
what one keyswitch per articulation can't hold:

- VSL's Synchron maps choose an articulation with two to four keyswitches
  at once, one per dimension of the patch, some of them inside the playing
  range (F6);
- Spitfire's UACC KS uses one key whose velocity chooses;
- articulations combine notes, CCs and program changes, and some move the
  notes to another channel.

## Decision

- `reaper/npvf_maps.lua` reads Cubase expression maps, Logic articulation
  sets and Reaticulate banks into one form: each articulation has `send`, a
  list of outputs (note with velocity, CC, program), a `channel`, and for
  Reaticulate its `program` number. Only the outputs are read: Cubase's
  note changer channel, remote triggers and Reaticulate's routing to buses
  are not.
- Its dynamics are guessed from the name's main articulation (before any
  "+" options) or Reaticulate's colour category: long, legato, tremolo and
  trill on CC1, the rest on velocity. A guess, shown for checking.
- Reaticulate articulations outside group 1 (con sordino on/off and the
  like) change another articulation, so they come in unticked.
- The test sends every output, 10 ms apart, then plays on the
  articulation's channel, and **never plays a key the instrument uses as a
  keyswitch** as a test note.
- When fixing, keyswitches latch into a set of keys held on; a new key turns
  off only the keys no articulation combines it with. A key whose velocity
  differs between articulations is told apart by velocity. The most
  specific articulation whose conditions all hold wins; at a draw, the one
  chosen last. A Reaticulate part's program change chooses its articulation
  directly.

## Consequences

- Every real map tried reads (32,171 articulations). Logic's program change
  output and channel keys weren't in any file seen and are read by guess.
- Profiles written before 1.1 still work (their single `switch` is read as
  one output), and 1.1 still writes `switch` where one output says it all.
- Studio One, Dorico, Digital Performer and Cakewalk maps aren't read yet.
