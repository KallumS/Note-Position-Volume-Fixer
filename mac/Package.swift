// swift-tools-version:5.9
// Note Fixer for Mac: measures sample libraries by hosting their Audio Unit
// instruments, with the same Lua as the REAPER scripts (via NPVFBridge).
import PackageDescription

let package = Package(
  name: "NoteFixer",
  platforms: [.macOS(.v13)],
  targets: [
    // Lua 5.4.6, unchanged (LICENSE-Lua.txt).
    .target(
      name: "CLua",
      path: "Sources/CLua",
      exclude: ["LICENSE-Lua.txt"],
      cSettings: [.define("LUA_USE_MACOSX")]
    ),
    // C: starts Lua, loads npvf_app.lua, passes audio in and JSON out.
    .target(name: "NPVFBridge", dependencies: ["CLua"], path: "Sources/NPVFBridge"),
    .executableTarget(
      name: "NoteFixer",
      dependencies: ["NPVFBridge"],
      path: "Sources/NoteFixer",
      linkerSettings: [
        .linkedFramework("AVFoundation"), .linkedFramework("AudioToolbox"),
        .linkedFramework("CoreAudioKit"), .linkedFramework("AppKit"),
      ]
    ),
  ]
)
