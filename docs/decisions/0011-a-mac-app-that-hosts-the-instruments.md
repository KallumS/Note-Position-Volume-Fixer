# 0011 - A Mac app that hosts the instruments, measuring with the same Lua

- **Date:** 2026-11-15
- **Status:** Accepted

## Context

The user asked for Note Fixer as an Apple Silicon app built by GitHub
Actions, and chose the full measuring app over wrapping the page: it loads
the Audio Unit instruments itself, so measuring doesn't need REAPER.

## Decision

- **Swift and SwiftUI** for the window and the plug-ins: `AVAudioUnit` to
  load an instrument (in the app, else out of process), its `fullState` to
  remember the patch, its own view (`requestViewController`, else the
  version 2 Cocoa view), and `AVAudioEngine`'s offline manual rendering to
  play a test faster than real time. MIDI goes through
  `scheduleMIDIEventBlock` at an offset into each 512-frame chunk, so every
  event lands on its exact sample; the plug-in's reported latency is taken
  off the start; `kAudioUnitProperty_OfflineRender` is set so samplers load
  before they play.
- **The measuring is the REAPER scripts' Lua**, not a third copy: Lua 5.4.6
  is built in (`mac/Sources/CLua`, MIT), `mac/Lua/npvf_app.lua` offers a JSON
  API, and `mac/Sources/NPVFBridge` (C) hands audio over one note's worth at
  a time and can be stopped. `tools/stage_lua.sh` copies the same files
  into the app and into the tests. `tests/bridge_test.js` builds the bridge
  with any C compiler and holds it to the REAPER scripts' output.
- Profiles and `Library.json` are the same format and names
  (`npvf_library.lua`), saved by default to REAPER's `Data/Note Fixer/Profiles`
  when REAPER is installed.
- **Swift Package Manager**, not an Xcode project: a plain text
  `Package.swift`, and `mac/build-app.sh` makes the `.app` around it.
- **GitHub Actions** (`macos-15`, Apple Silicon - `macos-14` is no longer
  offered) runs the bridge test, builds, signs ad hoc, runs
  `NoteFixer --self-test` and checks the app starts, then uploads the zip.
  The self-test needs no third-party plug-in: Apple's DLS synth is on every
  Mac. It checks the instrument is listed, its state survives, a test
  renders faster than real time and in full, every note is found, a
  restored copy measures the same, events land on their sample (a test
  0.1 ms later is heard 0.1 ms later), Stop works, and the index builds.

## Consequences

- No Apple Developer ID: the app is signed ad hoc and the first launch
  needs right-click › Open (`mac/INSTALL-MAC.txt`). Notarising would need
  the user's developer account and secrets in the repository's settings.
- Swift can't be built here. Everything Swift is checked only on GitHub's
  Mac, and nothing with the real players. Unverified: how each player's
  window, saved state and offline loading behave in this host, and whether
  `requestViewController` or the Cocoa view is what they offer.
- Audio Units only: VST3-only instruments can't be measured by the app
  (REAPER can).
