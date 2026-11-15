import AppKit
import AVFoundation
import AudioToolbox
import CoreAudioKit

/// A test event in seconds, from the Lua's test layout.
struct TestEvent {
  var t: Double
  var bytes: [UInt8]
}

enum AUHost {
  /// Every Audio Unit instrument installed (Kontakt, SINE, Spitfire, Engine, Synchron Player, Apple's own...).
  static func instruments() -> [AVAudioUnitComponent] {
    var d = AudioComponentDescription()
    d.componentType = kAudioUnitType_MusicDevice
    return AVAudioUnitComponentManager.shared().components(matching: d)
      .sorted { ($0.manufacturerName + $0.name).localizedCaseInsensitiveCompare($1.manufacturerName + $1.name) == .orderedAscending }
  }

  /// Load an instrument: in the app if it can (fastest), else in a separate process (plug-ins not built for this Mac's chip).
  static func load(_ id: ComponentID) async throws -> AVAudioUnit {
    do {
      return try await AVAudioUnit.instantiate(with: id.description, options: [])
    } catch {
      return try await AVAudioUnit.instantiate(with: id.description, options: [.loadOutOfProcess])
    }
  }

  /// The plug-in's state - the patch loaded in it - as data to keep.
  static func state(of unit: AVAudioUnit) -> Data? {
    guard let s = unit.auAudioUnit.fullState else { return nil }
    return try? PropertyListSerialization.data(fromPropertyList: s, format: .binary, options: 0)
  }

  static func restore(_ data: Data, to unit: AVAudioUnit) throws {
    guard let s = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
      throw BridgeError(message: "The remembered patch couldn't be read.")
    }
    unit.auAudioUnit.fullState = s
  }

  /// Tell the plug-in it is rendering offline, so it loads samples before playing them instead of streaming.
  static func setOffline(_ unit: AVAudioUnit, _ on: Bool) {
    var v: UInt32 = on ? 1 : 0
    AudioUnitSetProperty(unit.audioUnit, kAudioUnitProperty_OfflineRender, kAudioUnitScope_Global, 0, &v,
                         UInt32(MemoryLayout<UInt32>.size))
  }

  /// The test layout's events (from the bridge) as MIDI bytes at times.
  static func events(fromLayout layout: [String: Any]) -> [TestEvent] {
    var out: [TestEvent] = []
    for e in layout["events"] as? [[String: Any]] ?? [] {
      let t = (e["t"] as? NSNumber)?.doubleValue ?? 0
      let ch = UInt8(((e["chan"] as? NSNumber)?.intValue ?? 0) & 15)
      switch e["kind"] as? String {
      case "note":
        let p = UInt8(((e["pitch"] as? NSNumber)?.intValue ?? 60) & 127)
        let v = UInt8(max(1, min(127, (e["vel"] as? NSNumber)?.intValue ?? 100)))
        let len = (e["len"] as? NSNumber)?.doubleValue ?? 0.25
        out.append(TestEvent(t: t, bytes: [0x90 | ch, p, v]))
        out.append(TestEvent(t: t + len, bytes: [0x80 | ch, p, 0]))
      case "cc":
        out.append(TestEvent(t: t, bytes: [0xB0 | ch, UInt8(((e["cc"] as? NSNumber)?.intValue ?? 0) & 127),
                                           UInt8(((e["value"] as? NSNumber)?.intValue ?? 0) & 127)]))
      case "program":
        out.append(TestEvent(t: t, bytes: [0xC0 | ch, UInt8(((e["value"] as? NSNumber)?.intValue ?? 0) & 127)]))
      default: break
      }
    }
    // at the same moment, note-offs first, as a sequencer sends them
    return out.sorted { a, b in a.t != b.t ? a.t < b.t : (a.bytes[0] & 0xF0) == 0x80 && (b.bytes[0] & 0xF0) != 0x80 }
  }

  /// Play `events` into the instrument offline (faster than real time) and return the sound, mixed to mono.
  /// Each event lands on its exact sample. The plug-in's reported latency is taken off the start.
  static func renderOffline(_ unit: AVAudioUnit, events: [TestEvent], seconds: Double,
                            sampleRate: Double = 48000, progress: ((Double) -> Bool)? = nil) throws -> [Float] {
    let engine = AVAudioEngine()
    engine.attach(unit)
    defer {
      engine.stop()
      engine.disconnectNodeOutput(unit)
      engine.detach(unit)
    }
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
      throw BridgeError(message: "Couldn't set up the render format.")
    }
    engine.connect(unit, to: engine.mainMixerNode, format: nil)
    let chunk: AVAudioFrameCount = 512
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
    setOffline(unit, true)
    try engine.start()
    guard let midi = unit.auAudioUnit.scheduleMIDIEventBlock else {
      throw BridgeError(message: "This instrument doesn't take MIDI from a host.")
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else {
      throw BridgeError(message: "Couldn't make a render buffer.")
    }
    let latency = max(0, Int((unit.auAudioUnit.latency * sampleRate).rounded()))
    let total = Int((seconds * sampleRate).rounded()) + latency
    var out = [Float]()
    out.reserveCapacity(total)
    var frame = 0, next = 0, chunks = 0
    let samples = events.map { Int(($0.t * sampleRate).rounded()) }
    while frame < total {
      let n = min(Int(chunk), total - frame)
      // events in this chunk, each at its offset into it
      while next < events.count && samples[next] < frame + n {
        let offset = max(0, samples[next] - frame)
        var bytes = events[next].bytes
        midi(AUEventSampleTimeImmediate + AUEventSampleTime(offset), 0, bytes.count, &bytes)
        next += 1
      }
      let status = try engine.renderOffline(AVAudioFrameCount(n), to: buffer)
      if status == .error { throw BridgeError(message: "The instrument stopped rendering.") }
      let got = Int(buffer.frameLength)
      if let data = buffer.floatChannelData {
        let chans = Int(buffer.format.channelCount)
        for i in 0..<got {
          var s: Float = 0
          for c in 0..<chans { s += data[c][i] }
          out.append(s / Float(chans))
        }
      }
      if got == 0 { out.append(contentsOf: [Float](repeating: 0, count: n)) }
      frame += n
      chunks += 1
      // now and then (every couple of seconds of audio), say how far, and stop if asked
      if chunks % 200 == 0, let progress, progress(Double(frame) / Double(total)) { throw CancellationError() }
    }
    setOffline(unit, false)
    return latency > 0 ? Array(out.dropFirst(latency)) : out
  }
}

/// The plug-in's own window, where you load the patch.
@MainActor
final class PluginWindows {
  static let shared = PluginWindows()
  private var windows: [UUID: NSWindow] = [:]

  func show(_ unit: AVAudioUnit, id: UUID, title: String) async {
    if let w = windows[id] { w.makeKeyAndOrderFront(nil); return }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    if let vc = await viewController(unit) {
      window.contentViewController = vc
      let size = vc.preferredContentSize
      if size.width > 50 && size.height > 50 { window.setContentSize(size) }
    } else if let view = cocoaView(unit) {
      window.contentView = view
      window.setContentSize(view.frame.size)
    } else {
      let text = NSTextField(labelWithString: "This instrument has no window of its own.")
      window.contentView = text
    }
    window.center()
    window.makeKeyAndOrderFront(nil)
    windows[id] = window
  }

  func close(_ id: UUID) {
    windows[id]?.close()
    windows[id] = nil
  }

  private func viewController(_ unit: AVAudioUnit) async -> NSViewController? {
    await withCheckedContinuation { cont in
      unit.auAudioUnit.requestViewController { vc in cont.resume(returning: vc) }
    }
  }

  /// A version 2 Audio Unit's Cocoa view (how Kontakt and most players show theirs).
  private func cocoaView(_ unit: AVAudioUnit) -> NSView? {
    let au = unit.audioUnit
    var size: UInt32 = 0
    var writable: DarwinBoolean = false
    guard AudioUnitGetPropertyInfo(au, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) == noErr,
          size >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size) else { return nil }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
    defer { raw.deallocate() }
    guard AudioUnitGetProperty(au, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &size) == noErr else { return nil }
    let info = raw.load(as: AudioUnitCocoaViewInfo.self)
    let url = info.mCocoaAUViewBundleLocation.takeUnretainedValue() as URL
    let className = info.mCocoaAUViewClass.takeUnretainedValue() as String
    guard let bundle = Bundle(url: url), let cls = bundle.classNamed(className) as? NSObject.Type else { return nil }
    let object = cls.init()
    // The view factory answers AUCocoaUIBase's uiViewForAudioUnit:withSize:, called here through the runtime
    // (Swift doesn't see that protocol from CoreAudioKit).
    guard object.responds(to: #selector(CocoaViewFactory.uiView(forAudioUnit:with:))) else { return nil }
    let factory = unsafeBitCast(object, to: CocoaViewFactory.self)
    return factory.uiView(forAudioUnit: au, with: NSSize(width: 800, height: 560))
  }
}

/// AUCocoaUIBase's one method, as a version 2 Audio Unit's view factory has it.
@objc private protocol CocoaViewFactory {
  @objc(uiViewForAudioUnit:withSize:)
  func uiView(forAudioUnit unit: AudioUnit, with size: NSSize) -> NSView?
}
