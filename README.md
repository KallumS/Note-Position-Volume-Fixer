# Note Position & Volume Fixer

Older orchestral sample libraries sound late: the sample starts with the bow
or breath before the note, so the attack is heard 30-150 ms after the MIDI
note - and by a different amount on every key and velocity. Some notes also
come out louder or quieter than their neighbours because of how they were
recorded.

This tool listens to a render of your part, finds where each note is really
heard and how loud it is, and gives you back the MIDI with every note moved
so its sound lands where you wrote it, and velocities (or CC11) changed where
a note was too loud or too quiet. It works with any library and any DAW:
Ableton Live, Cubase, REAPER, Logic, Studio One.

It is one web page that runs on your own computer. Nothing is installed and
no file is uploaded anywhere.

![Results for a staccato line](docs/screenshot.png)

## Use

Open **`Note-Position-Volume-Fixer.html`** in Chrome, Edge, Safari or Firefox
(download it, then double-click it).

### Fix a part from its render

1. In your DAW, export the part as a MIDI file, and render the same part to
   WAV or AIFF from the same starting point. Turn off reverb sends so each
   note is clear. (The page's *How to get the files out of your DAW* section
   has the steps for Live, Cubase and REAPER.)
2. Drop both files on the page. It measures every note.
3. Choose what to fix, look over the results, and press
   **Download Fixed MIDI**. Drag the file back into your DAW where the part
   was.

If you changed velocities, render the fixed part and drop it in again: a new
velocity can play a different sample with its own delay, so a second pass
tidies up what's left.

### Fix any part from a learned profile

Better for chords, legato, fast passages and libraries with round robins.
You do this once per patch:

1. Choose **Measure from: A learned profile**, then open
   **Learn a new profile**. Choose the keys and velocities, type your
   project's tempo, and press **Download Test MIDI**.
2. Put the test MIDI on the instrument, render it from its first bar, and
   drop the render on the page. Name the profile after the patch
   ("Berlin Strings Violins 1 Staccato") and press **Learn Profile**.

After that, any part played on that patch only needs its MIDI file: drop it
in, choose the profile, download the fix. Profiles are kept in the browser;
**Save Profile File…** keeps a copy you can open on another computer.

### In REAPER: measure your libraries automatically

Two scripts do the profile work for you, for any number of instruments and
articulations, while you're away:

- **Note Fixer - Measure Libraries** plays every key at several dynamics,
  articulation by articulation, and saves a profile for each.
- **Note Fixer - Fix Selected Items** fixes MIDI items from those profiles,
  each note by the articulation its keyswitch (or CC, program change or
  channel) chose.

**Install.** They need ReaImGui (ReaPack › ReaTeam Extensions). Then add this
repository in **Extensions › ReaPack › Import repositories…** with
`https://raw.githubusercontent.com/KallumS/Note-Position-Volume-Fixer/main/index.xml`
and install *Note Fixer*. (Until this work is merged into `main`, copy the
`reaper` folder into REAPER's `Scripts` folder instead and load both scripts
with **Actions › Load ReaScript…**.)

**Measure.**

1. Put the instrument on any track and load the patch - a SINE instrument,
   a Kontakt patch, a Spitfire, Engine or Synchron preset. Select the track
   and press **Add Instrument From Selected Track**. Name it after the patch.
2. Give it a **Library** name (such as *Spitfire BBC Symphony Orchestra*),
   then press **Import Articulations…** and open the articulation map you
   already have for that patch:
   - a **BabylonWaves Art Conductor** map for Cubase (`.expressionmap`) or
     Logic (`.plist`), or any other Cubase expression map or Logic
     articulation set;
   - a **Reaticulate** bank (`.reabank`). A file with several instruments
     asks which one.

   Every articulation comes in with what chooses it - keyswitches (several
   at once, as VSL's Synchron maps use), CCs such as Spitfire's UACC,
   program changes, MIDI channels - and a guess at its dynamics: **CC1** for
   long notes played on the mod wheel, **Velocity** for short notes. Check
   the guesses, and untick articulations you don't need (**Tick All** and
   **Untick All** help with big maps). Keys used as keyswitches are never
   played as test notes.

   Without a map, **Add Articulation** for each one and say how it's chosen:
   *Keyswitch* (a note name, such as C-1), *CC* (a number and value),
   *Program change* or *MIDI channel*.
3. Choose the keys, the levels (velocities or CC1 values) and the takes, and
   press **Measure All**. Each instrument is put on a **new track**, waits for
   its samples to load, plays each articulation's test, renders it offline,
   measures it and is removed. Profiles go to REAPER's resource folder under
   `Data/Note Fixer/Profiles`, one per articulation; **Skip ones already
   measured** lets a stopped run carry on.

   Each profile keeps everything the test found: for every key and level,
   when the sound starts, when the attack is heard and when it's done, each
   take (how much round robins differ) and how loud it is; and for the
   patch, the keys it plays, the keys that are too loud or too quiet, and
   how delays change with dynamics. `Library.json` lists every profile.
   [`docs/profile-format.md`](docs/profile-format.md) describes it all, for
   scripts to come.

**Fix.** Select MIDI items, open *Fix Selected Items*, check each track's
instrument (it's guessed from the track's name) and press **Fix Selected
Items**. Each note uses the articulation its keyswitches, CC, program change
or channel chose - or, in a part using Reaticulate, its articulation number.
Undo puts it back. The page above opens the same profiles.

**For each player:**

| Player | Choosing articulations | Worth knowing |
| --- | --- | --- |
| SINE (Orchestral Tools) | Set in the instrument's settings: keyswitch, CC, program change or MIDI channel | Match the switch type here to SINE's setting. |
| Kontakt | Mostly keyswitches; some libraries use a CC or channels | Big patches take a while to load: raise *Seconds to load samples* if a test comes back with notes missing (it tries again once by itself). |
| Spitfire | UACC on CC32 (values in the manual) or keyswitches | Long patches follow CC1 for dynamics. The *Tightness* control changes how late notes are: measure with the setting you play with. |
| Engine (Best Service) | Keyswitches or program changes | |
| Synchron Player (VSL) | Keyswitches or CCs, as the preset's Dimension Tree is set up | Turn off humanising of timing while measuring, or each take is late by a different random amount. |

In every player, a profile is only true for the settings it was measured
with: a different release, attack or "tightness" setting needs measuring
again. Effects after the instrument (reverb) are switched off on the test
track while measuring.

### On a Mac: measure without REAPER

**Note Fixer for Mac** does what *Measure Libraries* does, on its own: it
loads your instruments' Audio Unit plug-ins itself (Kontakt, SINE, Spitfire,
Engine and the Synchron Player all come as Audio Units), plays each test
faster than real time and saves the same profiles - into REAPER's profiles
folder when REAPER is installed, so *Fix Selected Items* finds them.

**Get it.** Each build is on the repository's **Actions** tab, under *Mac
app*: open the latest run with a green tick and download
**NoteFixer-macOS** at the bottom. Unzip it and drag *Note Fixer.app* into
Applications. The first time, right-click it and choose **Open** (it isn't
signed with an Apple Developer ID, so macOS asks once). `INSTALL-MAC.txt`
inside the zip has the details. Needs macOS 13 or later on Apple Silicon.

**Use it.**

1. **Add Instrument…** and choose it from the list of instruments on your
   Mac. Its own window opens: load the patch, then press **Remember This
   Patch**. (Each test loads that patch fresh.)
2. Set the **Library**, **Import Articulations…** from your Art Conductor
   (or other) map, and check each articulation's dynamics - as in REAPER.
3. Choose the keys, levels and takes and press **Measure All**.

**Open the Fixer Page** opens the page above, to fix a MIDI file from a
profile.

### What the settings do

| Setting | What it does |
| --- | --- |
| **Move: Each note / Each key / Whole part / Don't move** | Each note uses its own measurement. Each key uses one typical value per key and velocity - steadier when the library cycles round robins. Whole part is the same as one negative track delay. |
| **Line up: The attack / The start of any sound** | Where "the sound" is: when the attack is heard (12 dB below the note's first peak), or the very first sound. |
| **Strength** | How much of the measured difference to correct. |
| **Land after the grid** | Put the sound this many ms after the written note instead of on it. |
| **Even out: Each note / Each key / Off** | Correct loudness differences per note, or one value per key. |
| **Using: Velocity / CC11** | Velocity works for most patches. CC11 suits patches where velocity changes the attack but not the level; it writes one CC11 value per note, so overlapping notes keep using velocity. |
| **Leave alone within** | Differences smaller than this aren't corrected. |
| **dB per velocity step** | How much louder one velocity step makes a note. Left empty, it's worked out from the part. |
| **Played at … BPM** | Live and Cubase play an imported MIDI file at the project's tempo. If yours differs from the file's, type it here. |
| More settings | How late a sound can be, how far notes can differ, audio that starts late, keyswitch range, how to measure, CC11 values, whether note ends move too. |

Keyswitches, program changes and CCs written exactly on a note's start move
with the note, so the articulation still arrives first. A part whose notes
now start before the clip did is moved later by whole bars; the page tells
you how far to move it back.

### What to check

The table marks notes worth a listen (**Check**): measured under other
notes, at the edge of where they could be, or far from other notes on the
same key. Notes it can't find are left alone. Chords are measured as one
attack and moved together.

## What else exists

[`docs/research.md`](docs/research.md) compares this with negative track
delay, Cubase's attack compensation, NTD Engine, Kontakt scripts and the
community delay database, explains how notes are measured, and suggests a
Max for Live device as the next step for Ableton.

## For developers

```sh
npm test            # the engine: 35 checks against a made-up library with known delays
npm run build       # writes Note-Position-Volume-Fixer.html from src/
npm run test:ui     # builds, then drives the page in Chromium (needs Playwright)
npm run test:lua    # the REAPER scripts: Lua tests, Lua against the engine, the windows in a mock REAPER (needs lua5.4)
npm run test:all    # everything
```

`mac/` is the Mac app: Swift for the window and the plug-ins, and Lua
(built in, through `mac/Sources/NPVFBridge`) for the measuring - the very
files the REAPER scripts use. `node tests/bridge_test.js` tests the bridge
anywhere; GitHub Actions builds the app (`.github/workflows/mac-app.yml`) and
runs `NoteFixer --self-test`, which measures Apple's built-in DLS synth.

`src/engine.js` does all the measuring and MIDI writing and runs in Node and
the browser alike; `src/app.html` and `src/app.js` are the page. `reaper/`
holds the REAPER scripts; their measuring is a Lua port of the engine's, kept
in step by `tests/lua_parity.js`. See
[`CLAUDE.md`](CLAUDE.md) and [`docs/decisions/`](docs/decisions/README.md).

## Licence

MIT.
