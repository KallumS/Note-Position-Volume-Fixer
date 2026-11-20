# Research: fixing sample-library timing and volume inside the DAW

November 2026. The question: what is the best way to find how late (and how
loud) each note of a sample library really sounds, and correct the MIDI so
the sound lands where the note was written - per note, for any library, in
Ableton Live first and ideally Cubase and REAPER too.

**Short answer.** Nothing available measures per note (each key at each
velocity) and nothing corrects volume at all. The most accurate approach that
works in every DAW today is to measure a render: either the part itself, or
once per patch from a test render of every key, which then fixes any part on
that patch without rendering it again. That is what this repository builds.
A Max for Live device that applies a learned profile in place is the natural
next step for Ableton.

## 1. Why notes are late, and by different amounts

- A sample starts with the noise before the note: the bow settling, breath,
  the hammer. Older libraries left that in so the attack sounds natural,
  which pushes the audible attack 30-150 ms after the MIDI note.
- The delay differs by **articulation** (shorts are tighter than sustains and
  legato), by **dynamic or velocity** (soft notes speak slower: Cinematic
  Studio Strings' legato delay depends on velocity), by **key** (each sample
  was edited separately), and by **round robin**.
- Reported values are examples, not rules: Berlin Woodwinds Revive flute
  about −60 ms sustains, −80 ms legato, −40 ms staccato; Audio Imperia
  recommends −125 ms with its Sample Start control. A community spreadsheet
  (the Negative Track Delay Database, started by David Kudell on VI-Control)
  collects values per library and articulation, but one user who wrote a
  compensation script found "virtually none" of the Berlin values accurate
  enough, and contributors asked for per-dynamic columns.
- Volume: the same velocity on neighbouring keys can come out several dB
  apart, because each sample was recorded and trimmed separately. Peak
  normalising doesn't fix perceived loudness.

## 2. What exists

| Approach | Per what | Measures it? | Volume | Ableton | Cubase | REAPER |
| --- | --- | --- | --- | --- | --- | --- |
| Negative track delay (every DAW) | track | no | no | yes | yes | yes |
| One track per articulation, each with its own delay | articulation | no | no | yes | yes | yes |
| Cubase 15 *Attack Compensation* in expression maps | articulation | no | no | – | yes (forum reports: only positive values, legato bugs) | – |
| Dorico 5 expression maps | articulation | no | no | – | – | – |
| Logic Scripter scripts, Studio One Scoring Tools | articulation | no | no | – | – | – |
| **NTD Engine** (OwnLife Audio, VST3/AU, about $39) | articulation and dynamic, switched by keyswitch or CC | yes: *NTD Capture* measures in the DAW | not mentioned | a VST3 MIDI effect can't be used in Live, which has no VST MIDI effects (not confirmed with the maker) | yes | yes |
| Foresight (open source, XML config) | articulation | no | no | ? | ? | ? (monophonic only) |
| REAPER JSFX with keyswitches and delay (VI-Control) | articulation | no | no | – | – | yes |
| Kontakt multi-scripts (e.g. a variable delay compensator for CSS) | articulation / velocity | no | no | yes | yes | yes |
| Libraries with lookahead (CSS low-latency mode, newer Spitfire/OT/VSL, NotePerformer) | built in | – | – | yes | yes | yes |
| **This repository** | **each note, or each key × velocity** | **yes, from a render** | **yes: velocity or CC11** | yes (file round trip) | yes | yes |

The gap: every existing tool works per articulation with numbers typed in or
captured once, and none touches volume. Per-key and per-velocity differences
inside one articulation, which the user describes, are left alone.

## 3. How to measure

- **Physical onset or heard attack.** Research separates the first rise from
  silence (physical onset) from the *perceptual attack time* (Gordon 1987:
  when the attack is heard, which depends mainly on rise time and level).
  For a slow string attack these can be 20-40 ms apart. Musicians line up
  what they hear, so the default here is **the attack: 12 dB below the
  note's first peak**, with **the start of any sound** as the alternative.
- **Soft onsets are the hard case.** String onsets remain a challenge for
  the best detectors (Tomczak et al. 2022, the ARME Virtuoso Strings set).
  Two things help here that a general detector doesn't have: the tool knows
  when each note was played and which pitch it is.
- **Separating notes.** Each note is measured on its own harmonics,
  band-passed out of the mix without delay (filtered forwards and
  backwards), after taking away the decaying tail of whatever was already
  sounding. That keeps the last note's tail and other pitches out. Notes
  that start together (chords) are measured as one attack on the whole
  sound and moved together; unpitched sounds fall back to the whole sound.
- **Finding the right onset.** First the part's typical delay is found by
  lining up all the note starts with rises in the sound; then each note is
  searched for only near that delay and between its neighbours, so in fast
  passages a note can't be matched to the next one's sound.
- **Loudness.** The loudest 50 ms after the attack, K-weighted (ITU-R
  BS.1770, the curve loudness meters use). What each note *should* measure
  is fitted from its velocity, CC1, CC11 and pitch, with a fit that a few
  faulty notes can't drag (Huber weights). What's left over is the
  unintended difference, turned into a velocity (dB per velocity step from
  the same fit) or a CC11 value.

## 4. Ways to deliver it

| | Accuracy | Effort for the user | Works in | Notes |
| --- | --- | --- | --- | --- |
| **A. Measure the part's own render** (built) | each note as it played, including which round robin | export MIDI, render, drop both, import the fix | any DAW | velocity changes can pick different samples: render and check again |
| **B. Learned profile** (built) | each key at each velocity, averaged over takes; best for chords, legato and fast parts | once per patch: render a test file; then only export and import MIDI | any DAW | can't know which round robin will play; uses the typical one |
| C. Max for Live device | as B | none: fixes the clip in place | Ableton only | Live's notes API (`get_notes_extended`, `apply_note_modifications`) can move notes and change velocity in place. Needs Max to build and test, which isn't available here |
| D. Real-time plugin that hosts the library with lookahead | as B | load the library inside it | any DAW, Ableton included (as an instrument) | non-destructive and the MIDI stays on the grid, but adds latency to the whole project and has to host Kontakt and others reliably |
| E. ReaScript | as A and B | none | REAPER only | REAPER can render and edit items from a script |

**Recommendation:** A and B now, as one tool that runs in the browser with no
installation (decision 0001). For Ableton, C next: a Max for Live MIDI Tool
that reads a profile saved by this tool and fixes the selected clip in place.
D is the long-term ideal but a much larger project.

**What was built since** (November 2026):

| | Built as | Decision |
| --- | --- | --- |
| A, B | The page | 0001-0004 |
| E | *Note Fixer* for REAPER: Measure Libraries plays every key of each instrument, articulation by articulation, on a new track, offline; Fix Selected Items fixes items, each note by its own articulation | 0007-0010 |
| D, in part | *Note Fixer for Mac*: hosts the Audio Unit instruments itself and plays the tests offline, faster than real time - for measuring, not real-time fixing | 0011 |
| C | Not yet | |

Both measuring tools read the articulations from BabylonWaves Art Conductor
maps for Cubase and Logic, and Reaticulate banks (0009), and save
everything they find (0010, `docs/profile-format.md`).

## 5. How accurate it is

On the made-up library in `tests/synth.js` (delays 45-125 ms that vary by key
and velocity, attacks 12-42 ms, three keys recorded 3.5-5 dB off), measured
against the library's own numbers:

| Part | Found | Error after fixing (median / worst) |
| --- | --- | --- |
| Staccato eighths | 19-20 of 20 | 2 ms / 10 ms |
| Low and high registers | 19-20 of 20 | 3 ms / 17 ms |
| Legato, overlapping | 20 of 20 | 6 ms / 12 ms |
| Sixteenths at 140 BPM, each sound starting after the next note | 32 of 40 | 3 ms / 14 ms |
| Chords (moved as one attack) | all | first attack within 10 ms |
| **Any of these from a learned profile** | all | **under 1 ms / 2 ms** |

Loudness: faulty keys are found within 1.5 dB from a part and 0.5 dB from a
profile; after the velocity fix the unintended spread drops from about 3 dB
to under 0.5 dB.

Real libraries are messier than the test library (reverb in the samples,
noisy attacks, legato transitions), so these numbers are the best case. The
table on the page marks notes worth checking by ear.

## Sources

Network access to vi-control.net and ownlifeaudio.com was blocked from where
this was written, so those pages are known from search results, not read in
full.

- [Negative Track Delay Database / Spreadsheet (VI-Control)](https://vi-control.net/community/threads/negative-track-delay-database-spreadsheet.105332/)
- [A guide to sample delay/latency, offset/negative track delay & look ahead (VI-Control)](https://vi-control.net/community/threads/a-guide-to-sample-delay-latency-offset-negative-track-delay-look-ahead-smart-delay.161372/)
- [I've been working with orchestral libraries without compensating for latency (VI-Control)](https://vi-control.net/community/threads/ive-been-working-with-orchestral-libraries-without-compensating-for-latency-how-big-of-a-mistake-was-this.161940/page-2)
- [Apply delay compensation to every articulation separately? (VI-Control)](https://vi-control.net/community/threads/apply-delay-compensation-to-every-articulation-separately.159485/)
- [NTD Engine 1.0.3 release (VI-Control)](https://vi-control.net/community/threads/release-ntd-engine-1-0-3-dynamic-negative-track-delay-for-orchestral-libraries-vst3-au-win-mac.176349/), [KVR product page](https://www.kvraudio.com/product/ntd-engine-by-ownlife-audio), [OwnLife Audio](https://ownlifeaudio.com/products/ntd-engine)
- [JSFX plugin with automatic keyswitches and delay compensation (VI-Control)](https://vi-control.net/community/threads/jsfx-plugin-with-automatic-keyswitches-and-delay-compensation.174733/)
- [Foresight (GitHub)](https://github.com/capnspacehook/Foresight)
- [Cubase 15 Expression Maps - Attack compensation problem (Steinberg forum)](https://forums.steinberg.net/t/cubase-15-expression-maps-attack-compensation-problem/1013737), [Attack Compensation: Now +, Before -?](https://forums.steinberg.net/t/attack-compensation-now-before/1016099), [Negative delay compensation in expression maps](https://forums.steinberg.net/t/negative-delay-compensation-in-expression-maps/799145)
- [Feature request: Articulation latency correction (Steinberg forum)](https://forums.steinberg.net/t/feature-request-articulation-latency-correction/705760)
- [Audio Imperia: The Sample Start Methodology](https://help.audioimperia.com/?p=7934)
- [Spitfire Audio: What is a MIDI offset](https://support.spitfireaudio.com/en/articles/11816103-what-is-a-midi-offset-and-how-can-i-use-it)
- [Tokyo Scoring Strings patch notes on Kontakt's reported latency (VI-Control)](https://vi-control.net/community/threads/tokyo-scoring-strings-patch-1-0-7-available-fixed-short-notes.108670/page-18)
- [Logic: negative delay per articulation? (VI-Control)](https://vi-control.net/community/threads/logic-negative-delay-per-articulation.158659/)
- [Cycling '74: What's new in Live 11, part 2 (the notes API)](https://cycling74.com/articles/what's-new-in-live-11-part-2), [Adam Murray: MIDI Tools in Max for Live](https://adammurray.link/max-for-live/v8-in-live/midi-tools/)
- [Ableton: How latency works](https://help.ableton.com/hc/en-us/articles/360010545559)
- [Tomczak et al., Annotation of soft onsets in string ensemble recordings (arXiv 2211.08848)](https://arxiv.org/abs/2211.08848v1)
- [Bechtold & Senn, perceptual attack time in saxophone tones (Frontiers in Psychology, 2018)](https://frontiersin.org/articles/10.3389/fpsyg.2018.01692/pdf) (cites Gordon 1987 on perceptual attack time)
- [Do you think volume normalization can be a good strategy for piano sample libraries? (VI-Control)](https://vi-control.net/community/threads/do-you-think-volume-normalization-can-be-a-good-strategy-for-piano-sample-libraries.126024/)
- ITU-R BS.1770, the K-weighting curve.
