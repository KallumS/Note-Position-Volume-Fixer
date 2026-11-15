import AudioToolbox
import Foundation

/// One thing sent to choose an articulation: a note (with velocity), a CC, or a program change.
/// The same shape as the Lua's `send` entries (docs/profile-format.md).
struct Output: Codable, Hashable {
  var kind: String
  var pitch: Int?
  var vel: Int?
  var cc: Int?
  var value: Int?
}

struct Articulation: Codable, Identifiable, Hashable {
  var id = UUID()
  var name: String
  var include = true
  /// 1: velocity steps the levels; 2: CC1 does (long notes on the mod wheel).
  var dynamics = 1
  var send: [Output] = []
  var channel: Int?
  var program: Int?
  var category: String?
  var source: String?
  var describe: String?

  enum CodingKeys: String, CodingKey { case id, name, include, dynamics, send, channel, program, category, source, describe }

  init(name: String, send: [Output] = [], dynamics: Int = 1) {
    self.name = name
    self.send = send
    self.dynamics = dynamics
  }

  // Maps from the bridge have no id; ones saved by the app do.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    include = try c.decodeIfPresent(Bool.self, forKey: .include) ?? true
    dynamics = try c.decodeIfPresent(Int.self, forKey: .dynamics) ?? 1
    send = try c.decodeIfPresent([Output].self, forKey: .send) ?? []
    channel = try c.decodeIfPresent(Int.self, forKey: .channel)
    program = try c.decodeIfPresent(Int.self, forKey: .program)
    category = try c.decodeIfPresent(String.self, forKey: .category)
    source = try c.decodeIfPresent(String.self, forKey: .source)
    describe = try c.decodeIfPresent(String.self, forKey: .describe)
  }
}

/// An Audio Unit, by the three codes that find it again.
struct ComponentID: Codable, Hashable {
  var type: UInt32
  var subType: UInt32
  var manufacturer: UInt32

  init(_ d: AudioComponentDescription) {
    type = d.componentType
    subType = d.componentSubType
    manufacturer = d.componentManufacturer
  }

  var description: AudioComponentDescription {
    AudioComponentDescription(componentType: type, componentSubType: subType, componentManufacturer: manufacturer,
                              componentFlags: 0, componentFlagsMask: 0)
  }
}

struct Instrument: Codable, Identifiable {
  var id = UUID()
  var name: String
  var library = ""
  var plugin: String
  var component: ComponentID
  /// The plug-in's whole state (its `fullState`, as a property list): the patch loaded in it.
  var state: Data?
  var stateSaved: Date?
  var include = true
  var articulations: [Articulation] = []
}

struct TestSettings: Codable, Equatable {
  var low = "C0"
  var high = "C6"
  var levels = "30, 60, 90, 120"
  var takes = 2
  var waitSeconds = 15
  var alignStart = false
  var skipMeasured = true
  var profilesFolder: String?
}

/// Note names with middle C (60) as C3, as Ableton Live and Cubase name it.
enum Notes {
  static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
  static func name(_ p: Int) -> String { names[((p % 12) + 12) % 12] + String(Int(floor(Double(p) / 12)) - 2) }
  static func parse(_ s: String) -> Int? {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard let first = t.first, let base = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11][first.lowercased()] else { return nil }
    var rest = t.dropFirst()
    var acc = 0
    if rest.first == "#" { acc = 1; rest = rest.dropFirst() } else if rest.first == "b" { acc = -1; rest = rest.dropFirst() }
    guard let octave = Int(rest.trimmingCharacters(in: .whitespaces)) else { return nil }
    let p = base + acc + (octave + 2) * 12
    return (0...127).contains(p) ? p : nil
  }
}

/// Where things are kept.
enum Places {
  static var support: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Note Fixer", isDirectory: true)
  }
  /// REAPER's own Data/Note Fixer, when REAPER is installed, so its Fix Selected Items reads the same profiles.
  static var defaultProfiles: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let reaper = base.appendingPathComponent("REAPER", isDirectory: true)
    if FileManager.default.fileExists(atPath: reaper.path) {
      return reaper.appendingPathComponent("Data/Note Fixer/Profiles", isDirectory: true)
    }
    return support.appendingPathComponent("Profiles", isDirectory: true)
  }
  static var instruments: URL { support.appendingPathComponent("Instruments.json") }
  static var settings: URL { support.appendingPathComponent("Settings.json") }

  /// The Lua the app runs: in the app's Resources, or NPVF_LUA for a build run from the terminal.
  static var lua: URL? {
    if let env = ProcessInfo.processInfo.environment["NPVF_LUA"] { return URL(fileURLWithPath: env, isDirectory: true) }
    return Bundle.main.resourceURL?.appendingPathComponent("lua", isDirectory: true)
  }
}
