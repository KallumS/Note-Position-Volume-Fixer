import AppKit
import AVFoundation
import Foundation

/// Stop, readable from the background render and measuring.
final class StopFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
  func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

struct LogLine: Identifiable {
  let id = UUID()
  let text: String
  let warn: Bool
}

/// The window's state, and the measuring run. Everything here runs on the main actor except
/// the render and the measuring, which go to the background and report back.
@MainActor
final class Store: ObservableObject {
  @Published var instruments: [Instrument] = []
  @Published var selected: UUID?
  @Published var settings = TestSettings()
  @Published var log: [LogLine] = []
  @Published var message: LogLine?
  @Published var running = false
  @Published var progress = 0.0
  @Published var status = ""
  @Published var pendingMap: PendingMap?
  /// Instruments loaded now (for their windows), by id.
  var live: [UUID: AVAudioUnit] = [:]
  nonisolated let stopper = StopFlag()
  private var stopRequested: Bool {
    get { stopper.isSet }
    set { stopper.set(newValue) }
  }
  private var task: Task<Void, Never>?
  let bridge: Bridge?

  struct PendingMap {
    var banks: [(name: String, articulations: [Articulation])]
    var chosen: Int
    var source: String
    var library: String?
  }

  init() {
    var b: Bridge?
    var problem: String?
    if let dir = Places.lua {
      do { b = try Bridge(directory: dir) } catch { problem = error.localizedDescription }
    } else { problem = "The app's measuring code is missing. Download the app again." }
    bridge = b
    load()
    if let problem { message = LogLine(text: problem, warn: true) }
  }

  // MARK: Saving

  private func load() {
    let dec = JSONDecoder()
    if let d = try? Data(contentsOf: Places.instruments), let list = try? dec.decode([Instrument].self, from: d) { instruments = list }
    if let d = try? Data(contentsOf: Places.settings), let s = try? dec.decode(TestSettings.self, from: d) { settings = s }
    selected = instruments.first?.id
  }

  func save() {
    do {
      try FileManager.default.createDirectory(at: Places.support, withIntermediateDirectories: true)
      let enc = JSONEncoder()
      enc.outputFormatting = [.prettyPrinted, .sortedKeys]
      try enc.encode(instruments).write(to: Places.instruments, options: .atomic)
      try enc.encode(settings).write(to: Places.settings, options: .atomic)
    } catch {
      say("Couldn't save the instrument list: \(error.localizedDescription)", warn: true)
    }
  }

  var profilesFolder: URL {
    if let p = settings.profilesFolder { return URL(fileURLWithPath: p, isDirectory: true) }
    return Places.defaultProfiles
  }

  func say(_ text: String, warn: Bool = false) { message = LogLine(text: text, warn: warn) }
  func note(_ text: String, warn: Bool = false) { log.append(LogLine(text: text, warn: warn)) }

  func index(of id: UUID?) -> Int? { instruments.firstIndex { $0.id == id } }

  // MARK: Instruments

  func add(_ component: AVAudioUnitComponent) async {
    let inst = Instrument(name: component.name, plugin: "\(component.name) (\(component.manufacturerName))",
                          component: ComponentID(component.audioComponentDescription))
    instruments.append(inst)
    selected = inst.id
    save()
    say("Added \(inst.name). Load the patch in its window, then press Remember This Patch.")
    await openWindow(inst.id)
  }

  func openWindow(_ id: UUID) async {
    guard let i = index(of: id) else { return }
    let inst = instruments[i]
    do {
      let unit: AVAudioUnit
      if let u = live[id] { unit = u } else {
        unit = try await AUHost.load(inst.component)
        if let s = inst.state { try AUHost.restore(s, to: unit) }
        live[id] = unit
      }
      await PluginWindows.shared.show(unit, id: id, title: inst.name)
    } catch {
      say("Couldn't load \(inst.plugin): \(error.localizedDescription). Is it still installed?", warn: true)
    }
  }

  func rememberPatch(_ id: UUID) {
    guard let i = index(of: id) else { return }
    guard let unit = live[id], let data = AUHost.state(of: unit) else {
      say("Open the instrument's window and load the patch first.", warn: true)
      return
    }
    instruments[i].state = data
    instruments[i].stateSaved = Date()
    save()
    say("Remembered \(instruments[i].name)'s patch. Each test loads it fresh.")
  }

  func remove(_ id: UUID) {
    PluginWindows.shared.close(id)
    live[id] = nil
    instruments.removeAll { $0.id == id }
    if selected == id { selected = instruments.first?.id }
    save()
  }

  // MARK: Maps

  func importMap(from url: URL, into id: UUID) {
    guard let bridge else { return }
    do {
      let text = try String(contentsOf: url, encoding: .utf8)
      let name = instruments[index(of: id) ?? 0].name
      let map = try bridge.call("parseMap", ["text": text, "filename": url.lastPathComponent, "name": name])
      let format = map["format"] as? String ?? ""
      let banks = (map["banks"] as? [[String: Any]] ?? []).map { b -> (name: String, articulations: [Articulation]) in
        let arts = (b["articulations"] as? [[String: Any]] ?? []).compactMap { a -> Articulation? in
          guard let d = try? JSONSerialization.data(withJSONObject: a) else { return nil }
          return try? JSONDecoder().decode(Articulation.self, from: d)
        }
        return (b["name"] as? String ?? "", arts)
      }
      let group = (map["banks"] as? [[String: Any]])?.first?["group"] as? String
      let kind = ["cubase": "Cubase expression map", "logic": "Logic articulation set", "reaticulate": "Reaticulate bank"][format] ?? "Map"
      let pending = PendingMap(banks: banks, chosen: max(0, ((map["best"] as? NSNumber)?.intValue ?? 1) - 1),
                               source: "\(kind): \(url.lastPathComponent)", library: group?.components(separatedBy: "/").first)
      if banks.count == 1 { importBank(pending, into: id) } else { pendingMap = pending }
    } catch {
      say(error.localizedDescription, warn: true)
    }
  }

  func importBank(_ p: PendingMap, into id: UUID) {
    guard let i = index(of: id), p.banks.indices.contains(p.chosen) else { return }
    let bank = p.banks[p.chosen]
    if !instruments[i].articulations.isEmpty {
      let alert = NSAlert()
      alert.messageText = "Replace \(instruments[i].name)'s \(instruments[i].articulations.count) articulations?"
      alert.informativeText = "With the \(bank.articulations.count) in \(bank.name.isEmpty ? "this map" : bank.name)."
      alert.addButton(withTitle: "Replace")
      alert.addButton(withTitle: "Cancel")
      if alert.runModal() != .alertFirstButtonReturn { return }
    }
    let source = p.banks.count > 1 ? "\(p.source) (\(bank.name))" : p.source
    instruments[i].articulations = bank.articulations.map { var a = $0; a.source = source; return a }
    if instruments[i].library.isEmpty, let lib = p.library { instruments[i].library = lib }
    pendingMap = nil
    save()
    let on = instruments[i].articulations.filter(\.include).count
    say("Imported \(bank.articulations.count) articulations; \(on) ticked to measure. Check each one's dynamics: velocity for short notes, CC1 for long notes on the mod wheel.")
  }

  func describe(_ a: Articulation) -> String {
    if let d = a.describe { return d }
    guard let bridge, let obj = try? Bridge.object(a), let r = try? bridge.call("describe", obj) else { return "" }
    return r["text"] as? String ?? ""
  }

  // MARK: The test

  struct TestOptions { var low: Int; var high: Int; var levels: [Int]; var takes: Int }

  func testOptions() -> Result<TestOptions, BridgeError> {
    guard let low = Notes.parse(settings.low), let high = Notes.parse(settings.high), high >= low else {
      return .failure(BridgeError(message: "Write the keys as note names, such as C0 and C6, lowest first."))
    }
    var levels = Set<Int>()
    for part in settings.levels.split(whereSeparator: { !$0.isNumber }) { if let n = Int(part), (1...127).contains(n) { levels.insert(n) } }
    if levels.isEmpty { return .failure(BridgeError(message: "Write at least one level between 1 and 127.")) }
    return .success(TestOptions(low: low, high: high, levels: levels.sorted(), takes: max(1, min(8, settings.takes))))
  }

  func keyswitchKeys(_ inst: Instrument) -> [Int] {
    Array(Set(inst.articulations.flatMap { $0.send.compactMap { $0.kind == "note" ? $0.pitch : nil } })).sorted()
  }

  func profileURL(_ inst: Instrument, _ art: Articulation?) -> URL? {
    guard let bridge, let r = try? bridge.call("profileFileName", ["instrument": inst.name, "articulation": art?.name ?? "", "library": inst.library]),
          let f = r["file"] as? String else { return nil }
    return profilesFolder.appendingPathComponent(f)
  }

  /// What a run would measure: ticked instruments' ticked articulations, less those already measured if asked.
  func jobs() -> [(Instrument, [Articulation?])] {
    instruments.filter(\.include).compactMap { inst in
      let arts: [Articulation?] = inst.articulations.isEmpty ? [nil] : inst.articulations.filter(\.include).map { $0 }
      let todo = arts.filter { a in
        !(settings.skipMeasured && (profileURL(inst, a).map { FileManager.default.fileExists(atPath: $0.path) } ?? false))
      }
      return todo.isEmpty ? nil : (inst, todo)
    }
  }

  func estimate() -> String {
    guard case .success(let o) = testOptions(), let bridge else { return "" }
    let count = jobs().reduce(0) { $0 + $1.1.count }
    let per = (try? bridge.call("testSeconds", ["low": o.low, "high": o.high, "levels": o.levels, "takes": o.takes]))?["seconds"] as? Double ?? 0
    let notes = (o.high - o.low + 1) * o.levels.count * o.takes
    let total = per * Double(count)
    return String(format: "Each articulation plays %d notes, %d:%02d of audio. %d to measure: %d h %02d min of audio, played faster than real time.",
                  notes, Int(per) / 60, Int(per) % 60, count, Int(total) / 3600, Int(total) % 3600 / 60)
  }

  // MARK: Measuring

  func stop() { stopRequested = true }

  func measureAll() {
    guard let bridge else { return }
    let opts: TestOptions
    switch testOptions() {
    case .failure(let e): say(e.message, warn: true); return
    case .success(let o): opts = o
    }
    let list = jobs()
    let total = list.reduce(0) { $0 + $1.1.count }
    if total == 0 { say("Nothing to measure: every articulation already has a profile. Untick Skip Ones Already Measured to measure them again."); return }
    if let missing = list.first(where: { $0.0.state == nil })?.0 {
      say("\(missing.name) has no patch remembered yet: open its window, load the patch and press Remember This Patch.", warn: true)
      return
    }
    log = []
    message = nil
    running = true
    stopRequested = false
    progress = 0
    task = Task { await run(list, opts, total, bridge) }
  }

  private func run(_ list: [(Instrument, [Articulation?])], _ opts: TestOptions, _ total: Int, _ bridge: Bridge) async {
    var done = 0, saved = 0
    defer { running = false; status = "" }
    do {
      try FileManager.default.createDirectory(at: profilesFolder, withIntermediateDirectories: true)
    } catch {
      say("Couldn't make the profiles folder \(profilesFolder.path): \(error.localizedDescription)", warn: true)
      return
    }
    outer: for (inst, arts) in list {
      status = "Loading \(inst.name)"
      let unit: AVAudioUnit
      do {
        unit = try await AUHost.load(inst.component)
        if let s = inst.state { try AUHost.restore(s, to: unit) }
      } catch {
        note("\(inst.name): couldn't load \(inst.plugin) (\(error.localizedDescription)).", warn: true)
        done += arts.count
        continue
      }
      if !(await wait(Double(settings.waitSeconds), "Waiting for \(inst.name) to load its samples")) { break }
      for art in arts {
        if stopRequested { break outer }
        let label = inst.name + (art.map { " - " + $0.name } ?? "")
        let cc1 = (art?.dynamics ?? 1) == 2
        var layoutArgs: [String: Any] = ["low": opts.low, "high": opts.high, "levels": opts.levels, "takes": opts.takes,
                                         "skipKeys": keyswitchKeys(inst), "dynamics": cc1 ? "cc1" : "velocity"]
        if let art {
          layoutArgs["send"] = (try? Bridge.object(art.send)) ?? []
          if let ch = art.channel { layoutArgs["outChannel"] = ch }
        }
        let layout: [String: Any]
        do { layout = try bridge.call("layout", layoutArgs) } catch { note("\(label): \(error.localizedDescription)", warn: true); continue }
        let events = AUHost.events(fromLayout: layout)
        let seconds = (layout["length"] as? NSNumber)?.doubleValue ?? 0
        var best: [String: Any]?
        for attempt in 1...2 {
          status = "Playing \(label)"
          let base = Double(done) / Double(total)
          let rendered: [Float]
          do {
            let stopper = self.stopper
            rendered = try await Task.detached(priority: .userInitiated) { [weak self] in
              try AUHost.renderOffline(unit, events: events, seconds: seconds) { f in
                Task { @MainActor in self?.progress = base + f * 0.4 / Double(total) }
                return stopper.isSet
              }
            }.value
          } catch is CancellationError { break outer } catch {
            note("\(label): \(error.localizedDescription)", warn: true)
            break
          }
          status = "Measuring \(label)"
          let request: [String: Any] = [
            "layout": layout,
            "measure": ["alignTo": settings.alignStart ? "start" : "attack"],
            "meta": metadata(inst, art),
          ]
          let result: [String: Any]
          do {
            let stopper = self.stopper
            result = try await Task.detached(priority: .userInitiated) { [weak self] in
              try bridge.measure(mono: rendered, sampleRate: 48000, request: request) { i, n in
                Task { @MainActor in self?.progress = base + (0.4 + 0.6 * Double(i) / Double(n)) / Double(total) }
                return stopper.isSet
              }
            }.value
          } catch {
            if error.localizedDescription == "stopped" { break outer }
            note("\(label): \(error.localizedDescription)", warn: true)
            break
          }
          let found = ((result["stats"] as? [String: Any])?["found"] as? NSNumber)?.intValue ?? 0
          let notes = ((result["stats"] as? [String: Any])?["notes"] as? NSNumber)?.intValue ?? 1
          let bestFound = ((best?["stats"] as? [String: Any])?["found"] as? NSNumber)?.intValue ?? -1
          if found > bestFound { best = result }
          // Mostly silent the first time: perhaps still loading. Keys outside a patch's range are silent too,
          // so a second try that hears no more is taken as its range.
          if found >= notes * 8 / 10 || attempt == 2 { break }
          note("\(label): only \(found) of \(notes) notes were heard. Waiting longer and trying again.", warn: true)
          if !(await wait(Double(settings.waitSeconds), "Waiting for \(inst.name) to load its samples")) { break outer }
        }
        if let best { if saveResult(best, label: label) { saved += 1 } }
        done += 1
        progress = Double(done) / Double(total)
      }
    }
    writeIndex()
    say((stopRequested ? "Stopped. " : "Done. ") + "\(saved) \(saved == 1 ? "profile" : "profiles") saved to \(profilesFolder.path).")
  }


  private func wait(_ seconds: Double, _ what: String) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if stopRequested { return false }
      status = "\(what) (\(Int(end.timeIntervalSinceNow.rounded(.up))) s)"
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
    return !stopRequested
  }

  private func metadata(_ inst: Instrument, _ art: Articulation?) -> [String: Any] {
    var m: [String: Any] = ["instrument": inst.name, "plugin": inst.plugin, "measuredBy": "Note Fixer for Mac 1.0"]
    if !inst.library.isEmpty { m["library"] = inst.library }
    if let art {
      m["articulation"] = art.name
      m["send"] = (try? Bridge.object(art.send)) ?? []
      if let ch = art.channel { m["outChannel"] = ch }
      if let p = art.program { m["program"] = p }
      if let c = art.category { m["category"] = c }
      if let s = art.source { m["source"] = s }
      // the version 1 form, for older scripts, where one output says it all
      if art.send.count == 1, art.channel == nil, let o = art.send.first {
        switch o.kind {
        case "note": m["switch"] = ["type": "keyswitch", "value": o.pitch ?? 0, "vel": o.vel ?? 127]
        case "cc": m["switch"] = ["type": "cc", "cc": o.cc ?? 0, "value": o.value ?? 0]
        default: m["switch"] = ["type": "program", "value": o.value ?? 0]
        }
      } else if art.send.isEmpty, let ch = art.channel { m["switch"] = ["type": "channel", "value": ch] }
    }
    return m
  }

  private func saveResult(_ result: [String: Any], label: String) -> Bool {
    let stats = result["stats"] as? [String: Any] ?? [:]
    let found = (stats["found"] as? NSNumber)?.intValue ?? 0, notes = (stats["notes"] as? NSNumber)?.intValue ?? 0
    guard let profile = result["profile"] as? [String: Any], let file = result["file"] as? String else {
      note("\(label): only \(found) of \(notes) notes were heard, so no profile was saved. Check the articulation's switch, the key range, and that the patch makes sound on its own.", warn: true)
      return false
    }
    do {
      let data = try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: profilesFolder.appendingPathComponent(file), options: .atomic)
    } catch {
      note("\(label): couldn't save the profile: \(error.localizedDescription)", warn: true)
      return false
    }
    let summary = profile["summary"] as? [String: Any] ?? [:]
    let range = profile["range"] as? [String: Any] ?? [:]
    let off = (summary["offKeys"] as? [NSNumber] ?? []).map { Notes.name($0.intValue) }
    var line = String(format: "%@: %d of %d notes, heard %.0f to %.0f ms late.", label, found, notes,
                      (summary["minMs"] as? NSNumber)?.doubleValue ?? 0, (summary["maxMs"] as? NSNumber)?.doubleValue ?? 0)
    if let lo = (range["low"] as? NSNumber)?.intValue, let hi = (range["high"] as? NSNumber)?.intValue, lo <= hi {
      line += " Plays \(Notes.name(lo)) to \(Notes.name(hi))."
    }
    if !off.isEmpty { line += " Keys 1.5 dB or more off: " + off.prefix(12).joined(separator: ", ") + (off.count > 12 ? "…" : "") + "." }
    note(line)
    return true
  }

  /// Library.json beside the Profiles folder, from every profile in it (the Lua builds it, as REAPER's does).
  func writeIndex() {
    guard let bridge else { return }
    let fm = FileManager.default
    let names = ((try? fm.contentsOfDirectory(atPath: profilesFolder.path)) ?? []).filter { $0.lowercased().hasSuffix(".json") }.sorted()
    var files: [[String: Any]] = []
    for n in names {
      if let d = try? Data(contentsOf: profilesFolder.appendingPathComponent(n)),
         let p = try? JSONSerialization.jsonObject(with: d) { files.append(["file": n, "profile": p]) }
    }
    do {
      let index = try bridge.call("index", ["files": files])
      let data = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: profilesFolder.deletingLastPathComponent().appendingPathComponent("Library.json"), options: .atomic)
    } catch {
      note("Couldn't write Library.json: \(error.localizedDescription)", warn: true)
    }
  }
}
