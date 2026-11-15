import AVFoundation
import AudioToolbox
import Foundation

/// What GitHub Actions checks on its Mac, with no third-party plug-ins: Apple's own DLS synth, loaded,
/// its state kept and restored, a test rendered offline and measured through the shared Lua.
///   NoteFixer --self-test <tests/fixtures>     (NPVF_LUA=<staged Lua> outside the app bundle)
@MainActor
enum SelfTest {
  static func run(fixtures: String?) async -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
      print((ok ? "  ok   " : "  FAIL ") + what)
      if !ok { failures += 1 }
    }
    func number(_ any: Any?) -> Double { (any as? NSNumber)?.doubleValue ?? .nan }

    guard let lua = Places.lua, let bridge = try? Bridge(directory: lua) else {
      print("  FAIL can't start the measuring code (Resources/lua, or NPVF_LUA)")
      return 1
    }
    print("Maps")
    if let fixtures {
      for (file, count) in [("Test Strings.expressionmap", 3), ("Test Strings.plist", 3), ("Test Strings.reabank", 4)] {
        let text = (try? String(contentsOfFile: fixtures + "/" + file, encoding: .utf8)) ?? ""
        let banks = (try? bridge.call("parseMap", ["text": text, "filename": file]))?["banks"] as? [[String: Any]]
        let arts = (banks?.first?["articulations"] as? [Any])?.count ?? -1
        check(arts == count, "reads \(file): \(arts) articulations")
      }
    }

    print("Apple's DLS synth")
    let dls = ComponentID(AudioComponentDescription(componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    let listed = AUHost.instruments()
    check(listed.contains { ComponentID($0.audioComponentDescription) == dls }, "listed among \(listed.count) instruments")
    do {
      let unit = try await AUHost.load(dls)
      let state = AUHost.state(of: unit)
      check(state != nil, "its state is kept (\(state?.count ?? 0) bytes)")
      let fresh = try await AUHost.load(dls)
      if let state { try AUHost.restore(state, to: fresh) }
      check(true, "and restored into a fresh copy")

      // C3-B3 at two velocities, C#3 being a keyswitch, after a keyswitch at C-1
      let layout = try bridge.call("layout", ["low": 60, "high": 71, "levels": [60, 110], "takes": 1, "skipKeys": [61],
                                              "send": [["kind": "note", "pitch": 12, "vel": 127]]])
      let events = AUHost.events(fromLayout: layout)
      let seconds = number(layout["length"])
      let started = Date()
      let mono = try AUHost.renderOffline(unit, events: events, seconds: seconds)
      let took = Date().timeIntervalSince(started)
      check(abs(Double(mono.count) - seconds * 48000) < 2, "renders the whole test: \(mono.count) samples")
      check(took < seconds, String(format: "faster than real time: %.1f s of audio in %.1f s", seconds, took))
      let peak = mono.map(abs).max() ?? 0
      check(peak > 0.01, "makes sound (peak \(peak))")

      let request: [String: Any] = ["layout": layout, "measure": [String: Any](),
                                    "meta": ["instrument": "DLS", "library": "Apple", "articulation": "Piano", "measuredBy": "self-test"]]
      let result = try bridge.measure(mono: mono, sampleRate: 48000, request: request) { _, _ in false }
      let stats = result["stats"] as? [String: Any] ?? [:]
      check(number(stats["found"]) == 22 && number(stats["notes"]) == 22, "every test note found: \(stats["found"] ?? "?") of \(stats["notes"] ?? "?") (C#3 skipped)")
      let profile = result["profile"] as? [String: Any] ?? [:]
      let summary = profile["summary"] as? [String: Any] ?? [:]
      let median = number(summary["medianMs"]), lo = number(summary["minMs"]), hi = number(summary["maxMs"])
      print(String(format: "       heard %.1f to %.1f ms late, median %.1f", lo, hi, median))
      check(median > -2 && median < 60 && hi - lo < 25, "a synth with no sample start: soon after the note, and much the same on every key")
      check(result["file"] as? String == "Apple - DLS - Piano.json", "named \(result["file"] ?? "?")")

      let again = try AUHost.renderOffline(fresh, events: events, seconds: seconds)
      let result2 = try bridge.measure(mono: again, sampleRate: 48000, request: request) { _, _ in false }
      let median2 = number(((result2["profile"] as? [String: Any])?["summary"] as? [String: Any])?["medianMs"])
      check(abs(median - median2) < 0.5, String(format: "the restored copy gives the same: %.2f and %.2f ms", median, median2))

      // events on exact samples: the same test a tenth of a millisecond later is heard a tenth later
      let shifted = events.map { TestEvent(t: $0.t + 0.0001, bytes: $0.bytes) }
      let late = try AUHost.renderOffline(fresh, events: shifted, seconds: seconds)
      let r3 = try bridge.measure(mono: late, sampleRate: 48000, request: request) { _, _ in false }
      let median3 = number(((r3["profile"] as? [String: Any])?["summary"] as? [String: Any])?["medianMs"])
      check(abs((median3 - median2) - 0.1) < 0.06, String(format: "each event lands on its sample: %.3f ms later", median3 - median2))

      var calls = 0
      do {
        _ = try bridge.measure(mono: mono, sampleRate: 48000, request: request) { _, _ in calls += 1; return calls >= 3 }
        check(false, "Stop stops measuring")
      } catch {
        check(error.localizedDescription == "stopped" && calls == 3, "Stop stops measuring (\(error.localizedDescription))")
      }

      let index = try bridge.call("index", ["files": [["file": "Apple - DLS - Piano.json", "profile": profile]]])
      check((index["profiles"] as? [Any])?.count == 1, "Library.json from it")
    } catch {
      check(false, "the DLS synth: \(error.localizedDescription)")
    }
    print(failures == 0 ? "all passed" : "\(failures) failed")
    return failures == 0 ? 0 : 1
  }
}
