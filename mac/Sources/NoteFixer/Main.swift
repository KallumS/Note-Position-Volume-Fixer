import AppKit
import SwiftUI

/// `NoteFixer --self-test <fixtures>` runs the checks GitHub Actions runs (SelfTest.swift); otherwise the app.
@main
enum Main {
  static func main() {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--self-test") {
      let fixtures = args.count > i + 1 ? args[i + 1] : nil
      Task { @MainActor in
        let code = await SelfTest.run(fixtures: fixtures)
        exit(code)
      }
      RunLoop.main.run()
    } else {
      NoteFixerApp.main()
    }
  }
}

struct NoteFixerApp: App {
  @StateObject private var store = Store()

  var body: some Scene {
    WindowGroup("Note Fixer") {
      ContentView()
        .environmentObject(store)
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 640)
    }
    .defaultSize(width: 1040, height: 860)
  }
}
