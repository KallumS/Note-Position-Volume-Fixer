# What Note Fixer saves, for scripts to come

Everything *Note Fixer - Measure Libraries* finds is kept in REAPER's
resource folder (Options › Show REAPER resource path), under
`Data/Note Fixer/`:

| File | What it is |
| --- | --- |
| `Profiles/<Library> - <Instrument> - <Articulation>.json` | One per articulation measured: every key at every level, as described below. The library part is left out when none is set. |
| `Library.json` | An index: one line per profile with its headline numbers, rebuilt after every save. Read this first to find a patch. |
| `Instruments.json` | The measuring window's list: each instrument's captured FX chain (the plug-in with its patch loaded) and its articulations. |

The page (`Note-Position-Volume-Fixer.html`) opens the same profiles.

All are JSON. Times are milliseconds after the MIDI note-on; levels are dB
(K-weighted, the curve loudness meters use; only differences between notes
mean anything). Keys are MIDI note numbers (60 is middle C, which Note Fixer
calls C3). Fields can be missing - a script should check, and should ignore
fields it doesn't know.

## A profile

`kind` is always `"note-position-volume-fixer/profile"`. `version` is `2`
from Note Fixer 1.1; version 1 (from the page, or 1.0) has only `name`,
`created`, `alignTo`, `dbPerVelocity`, `notFound`, `entries` (without the
version 2 entry fields) and, from REAPER, `instrument`, `articulation`,
`plugin`, `switch`, `dynamics`, `measuredIn`.

### What was measured

| Field | Example | Meaning |
| --- | --- | --- |
| `name` | `"Spitfire BBCSO - Violins 1 - Spiccato"` | Library, instrument and articulation. |
| `library` | `"Spitfire BBCSO"` | As typed in the window, or from a Reaticulate bank's group. |
| `instrument` | `"Violins 1"` | As named in the window. |
| `articulation` | `"Spiccato"` | As named in the window or the imported map. |
| `plugin` | `"Spitfire Audio (Spitfire Audio)"` | The instrument plug-in, as REAPER names it. |
| `category` | `"short"` | Reaticulate's colour category, if imported from a bank. |
| `source` | `"Cubase expression map: BBCSO Violins 1.expressionmap"` | Where the articulation's switching came from. |
| `created`, `measuredIn`, `measuredBy` | | When, in what, by which script and version. |
| `sampleRate` | `48000` | Of the test render. |

### How the articulation is chosen

| Field | Example | Meaning |
| --- | --- | --- |
| `send` | `[{"kind":"note","pitch":24,"vel":127},{"kind":"note","pitch":89,"vel":127}]` | Everything sent, in order, to choose it: `note` (`pitch`, `vel` - the velocity matters for one-key-many-velocities schemes such as Spitfire's UACC KS), `cc` (`cc`, `value`), `program` (`value`). Several notes at once are combinations, as in VSL's Synchron dimension trees. |
| `channel` | `3` | The articulation is played on this MIDI channel (1-16). |
| `program` | `42` | The Reaticulate articulation number: a REAPER part using Reaticulate chooses it with this program change. |
| `switch` | `{"type":"keyswitch","value":24}` | The version 1 form, still written when one output says it all. |

*Fix Selected Items* works out which articulation each note plays from these
(`reaper/npvf_fix.lua`, `F.plan`): keys held on latch, and a key only turns
off the keys no articulation combines it with.

### How it was tested

| Field | Meaning |
| --- | --- |
| `dynamics` | `"velocity"`: levels are velocities. `"cc1"`: levels are CC1 values, velocity held at `test.velocity` - for long notes on the mod wheel. |
| `test` | The test part: `low`, `high` (keys), `levels`, `takes`, `spacing` (s between notes), `noteLength` (s), `lead` (s before the first note), `velocity`, `cc1`, `keyswitchKeysSkipped` (the instrument's keyswitch keys, never played as test notes). |
| `alignTo`, `attackDb`, `startDb` | What `delayMs` lines up: `"attack"`, the point `attackDb` (12) dB below the note's peak, or `"start"`, `startDb` (30) dB below it. |

### What was found

| Field | Meaning |
| --- | --- |
| `range` | `{ "low": 55, "high": 103 }`: the lowest and highest keys that sounded at any level. |
| `silentKeys` | Keys played that never sounded: outside the patch's range, or silent there. |
| `notFound` | Each `{ pitch, vel }` (vel = the level) not heard. |
| `dbPerVelocity` | How much louder one velocity step makes a note, fitted over the whole test. Missing for CC1 profiles. |
| `summary.medianMs`, `minMs`, `maxMs` | The delay over every key and level. |
| `summary.roundRobinSpreadMs` | The median spread between takes of the same note: how much round robins differ. |
| `summary.byLevel` | `[{ "level": 30, "delayMs": 112.5 }, …]`: soft notes usually speak later. |
| `summary.offKeys` | Keys 1.5 dB or more louder or quieter than their neighbours would predict. |

### `entries`: every key at every level

Sorted by `pitch`, then `vel`.

| Field | Meaning |
| --- | --- |
| `pitch`, `vel` | The key, and the level (velocity, or CC1 value for CC1 profiles). |
| `delayMs` | The one to correct by: `attackMs` or `startMs`, as `alignTo` says. The median of the takes. |
| `startMs` | When the sound starts: 30 dB below its peak (and never under what was already sounding). Close to where the sample begins. |
| `attackMs` | When the attack is heard: 12 dB below its peak. |
| `peakMs` | When the attack is done: within 1 dB of its peak. Less exact than the others (±3 ms) where the top of the attack ripples. `peakMs - startMs` is the attack's length. |
| `takesMs` | Each take's `delayMs`, in the order played. Their spread is the round robins'. |
| `takes`, `spreadMs` | How many takes were heard, and the gap between the earliest and latest. |
| `loudDb` | The loudest 50 ms from the attack (K-weighted dB). |
| `deviationDb` | How much louder (+) or quieter (−) than expected from its level and key - what the fix evens out. |

Between measured levels and keys, *Fix Selected Items* and the page
interpolate the delay (`profileAt`). A key's `deviationDb` belongs to that key
only.

## `Library.json`

```json
{
  "kind": "note-position-volume-fixer/library", "version": 1, "updated": "2026-11-15T20:00:00Z",
  "profiles": [
    { "file": "Profiles/Spitfire BBCSO - Violins 1 - Spiccato.json", "name": "…", "library": "…",
      "instrument": "…", "articulation": "…", "plugin": "…", "dynamics": "velocity",
      "send": [ … ], "channel": null, "program": 42, "created": "…", "version": 2,
      "range": { "low": 55, "high": 103 }, "medianMs": 61.2, "minMs": 38.5, "maxMs": 94.0,
      "roundRobinSpreadMs": 4.1, "offKeys": [ 64, 71 ] }
  ]
}
```

`file` is relative to `Data/Note Fixer/`.

## `Instruments.json`

A list of `{ name, library, plugin, chain, include, articulations }`.
`chain` is REAPER's `<FXCHAIN …>` block, the patch's whole state, which is
why the file can be large. Each articulation is `{ name, include, dynamics
(1 velocity, 2 CC1), send, channel, program, category, source, imported }`
when imported from a map, or `{ name, include, dynamics, switch (1 none,
2 keyswitch, 3 CC, 4 program change, 5 MIDI channel), value, cc }` when made
by hand.
