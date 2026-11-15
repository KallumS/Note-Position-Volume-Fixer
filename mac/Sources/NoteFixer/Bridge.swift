import Foundation
import NPVFBridge

struct BridgeError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// The shared Lua (measuring, map reading, profile files), through mac/Sources/NPVFBridge.
/// JSON goes in and out. One Lua state: call it from one task at a time.
final class Bridge {
  private let handle: OpaquePointer

  init(directory: URL) throws {
    var err = [CChar](repeating: 0, count: 2048)
    guard let h = npvf_open(directory.path, &err, err.count) else {
      throw BridgeError(message: "Couldn't start the measuring code: " + String(cString: err))
    }
    handle = h
  }

  deinit { npvf_close(handle) }

  static func json(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    return String(decoding: data, as: UTF8.self)
  }

  static func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
  }

  private func take(_ out: UnsafeMutablePointer<CChar>?) throws -> Any {
    guard let out else { throw BridgeError(message: "The measuring code gave nothing back.") }
    defer { npvf_free(out) }
    let text = String(cString: out)
    let obj = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    if let d = obj as? [String: Any], let e = d["error"] as? String { throw BridgeError(message: e) }
    return obj
  }

  func call(_ fn: String, _ args: Any) throws -> [String: Any] {
    let out = npvf_call(handle, fn, try Bridge.json(args))
    guard let d = try take(out) as? [String: Any] else { throw BridgeError(message: "\(fn) gave something unexpected.") }
    return d
  }

  private final class ProgressBox {
    let callback: (Int, Int) -> Bool
    init(_ callback: @escaping (Int, Int) -> Bool) { self.callback = callback }
  }

  /// Measure a mono render. `progress(done, total)` returns true to stop (the result is then an error "stopped").
  func measure(mono: [Float], sampleRate: Double, request: [String: Any],
               progress: @escaping (Int, Int) -> Bool) throws -> [String: Any] {
    let box = ProgressBox(progress)
    let context = Unmanaged.passUnretained(box).toOpaque()
    let req = try Bridge.json(request)
    let out: UnsafeMutablePointer<CChar>? = mono.withUnsafeBufferPointer { buf in
      npvf_measure(handle, buf.baseAddress, buf.count, sampleRate, req, { ctx, done, total in
        guard let ctx else { return 0 }
        let b = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
        return b.callback(Int(done), Int(total)) ? 1 : 0
      }, context)
    }
    withExtendedLifetime(box) {}
    guard let d = try take(out) as? [String: Any] else { throw BridgeError(message: "Measuring gave something unexpected.") }
    return d
  }
}
