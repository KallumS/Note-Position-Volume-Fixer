import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @EnvironmentObject var store: Store
  @State private var choosing = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Dim("Plays every key of your instruments at several dynamics, articulation by articulation, and notes down how late and how loud each one really sounds. The profiles fix your parts in REAPER (Note Fixer - Fix Selected Items) and on the Note Position & Volume Fixer page.")
        Group {
          instrumentsSection
          articulationsSection
          testSection
        }
        .disabled(store.running)
        measureSection
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(House.ground)
    .foregroundColor(House.text)
    .font(.system(size: 13))
    .tint(House.accent)
    .sheet(isPresented: $choosing) { InstrumentPicker(choosing: $choosing).environmentObject(store) }
  }

  // MARK: 1 Instruments

  private var instrumentsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Heading(number: 1, title: "Instruments")
      Dim("Add an instrument, load the patch in its window, and press Remember This Patch. Each test loads that patch fresh.")
      Button("Add Instrument…") { choosing = true }
        .buttonStyle(HouseButton())
        .help("Add Instrument: choose one of the Audio Unit instruments on this Mac.")
      ForEach($store.instruments) { $inst in
        HStack(spacing: 12) {
          Toggle("Measure", isOn: $inst.include)
            .toggleStyle(.checkbox).labelsHidden()
            .help("Measure: include this instrument when you press Measure All.")
            .onChange(of: inst.include) { _ in store.save() }
          TextField("Name", text: $inst.name, onCommit: { store.save() })
            .houseField(width: 220)
            .help("Name: what its profiles are called. Name it after the patch.")
          VStack(alignment: .leading, spacing: 2) {
            Text(inst.plugin).lineLimit(1)
            Text(inst.state == nil ? "No patch remembered yet" : "Patch remembered\(inst.stateSaved.map { " " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")")
              .foregroundColor(inst.state == nil ? House.warnText : House.textDim)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Button("Show Window") { Task { await store.openWindow(inst.id) } }
            .buttonStyle(HouseButton())
            .help("Show Window: the instrument's own window, to load or change the patch.")
          Button("Remember This Patch") { store.rememberPatch(inst.id) }
            .buttonStyle(HouseButton())
            .help("Remember This Patch: keep the patch loaded in the window now.")
          Button("Edit") { store.selected = inst.id }
            .buttonStyle(HouseButton(chosen: store.selected == inst.id))
            .help("Edit: show this instrument's articulations below.")
          Button("Remove") { confirmRemove(inst) }
            .buttonStyle(HouseButton())
            .help("Remove: forget this instrument. Its profiles stay.")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(House.sunken))
      }
    }
  }

  private func confirmRemove(_ inst: Instrument) {
    let alert = NSAlert()
    alert.messageText = "Remove \(inst.name) from the list?"
    alert.informativeText = "Profiles already measured are kept."
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn { store.remove(inst.id) }
  }

  // MARK: 2 Articulations

  @ViewBuilder private var articulationsSection: some View {
    if let i = store.index(of: store.selected) {
      VStack(alignment: .leading, spacing: 12) {
        Heading(number: 2, title: "Articulations of \(store.instruments[i].name)")
        HStack(spacing: 12) {
          Text("Library")
          TextField("Spitfire BBC Symphony Orchestra", text: $store.instruments[i].library, onCommit: { store.save() })
            .houseField(width: 300)
            .help("Library: the collection it comes from. Profiles are named and filed with it.")
        }
        HStack(spacing: 12) {
          Button("Import Articulations…") { importMap(into: store.instruments[i].id) }
            .buttonStyle(HouseButton())
            .help("Import Articulations: read the keyswitches (and CCs, program changes and channels) from a BabylonWaves Art Conductor map for Cubase or Logic, any Cubase expression map, Logic articulation set or Reaticulate bank.")
          Button("Tick All") { setAll(i, true) }.buttonStyle(HouseButton())
          Button("Untick All") { setAll(i, false) }.buttonStyle(HouseButton())
          Button("Add Articulation") {
            store.instruments[i].articulations.append(Articulation(name: "Articulation \(store.instruments[i].articulations.count + 1)"))
            store.save()
          }
          .buttonStyle(HouseButton())
        }
        if let pending = store.pendingMap { bankChooser(pending, into: store.instruments[i].id) }
        Dim("Keyswitches are note names (middle C is C3). Long notes whose dynamics come from the mod wheel should use CC1. With none listed, the patch is measured as it is. Keys used as keyswitches are never played as test notes.")
        ForEach($store.instruments[i].articulations) { $art in
          ArticulationRow(art: $art, onRemove: {
            store.instruments[i].articulations.removeAll { $0.id == art.id }
            store.save()
          })
        }
      }
    }
  }

  private func setAll(_ i: Int, _ on: Bool) {
    for k in store.instruments[i].articulations.indices { store.instruments[i].articulations[k].include = on }
    store.save()
  }

  private func importMap(into id: UUID) {
    let panel = NSOpenPanel()
    panel.title = "Import articulations"
    panel.message = "Choose a Cubase expression map, a Logic articulation set or a Reaticulate bank."
    panel.allowedContentTypes = ["expressionmap", "plist", "reabank"].compactMap { UTType(filenameExtension: $0) }
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { store.importMap(from: url, into: id) }
  }

  private func bankChooser(_ pending: Store.PendingMap, into id: UUID) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Dim("This file has \(pending.banks.count) instruments. Choose the one for this instrument.")
      HStack(spacing: 12) {
        Picker("Instrument", selection: Binding(get: { store.pendingMap?.chosen ?? 0 }, set: { store.pendingMap?.chosen = $0 })) {
          ForEach(pending.banks.indices, id: \.self) { k in
            Text("\(pending.banks[k].name) (\(pending.banks[k].articulations.count))").tag(k)
          }
        }
        .labelsHidden()
        .frame(width: 360)
        Button("Import This One") { if let p = store.pendingMap { store.importBank(p, into: id) } }.buttonStyle(HouseButton())
        Button("Cancel") { store.pendingMap = nil }.buttonStyle(HouseButton())
      }
    }
  }

  // MARK: 3 The test

  private var testSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Heading(number: 3, title: "The test")
      HStack(spacing: 20) {
        labelled("Lowest key") { TextField("C0", text: $store.settings.low).houseField(width: 70) }
        labelled("Highest key") { TextField("C6", text: $store.settings.high).houseField(width: 70) }
        labelled("Levels") { TextField("30, 60, 90, 120", text: $store.settings.levels).houseField(width: 160) }
        labelled("Takes") {
          Stepper(value: $store.settings.takes, in: 1...8) { Text("\(store.settings.takes)").frame(width: 24) }
            .help("Takes: how many times each note is played. Two or more catch round robins.")
        }
        labelled("Seconds to load samples") {
          Stepper(value: $store.settings.waitSeconds, in: 0...600, step: 5) { Text("\(store.settings.waitSeconds)").frame(width: 32) }
            .help("Seconds to load samples: how long to wait after loading an instrument before playing it. Big patches need longer.")
        }
      }
      HStack(spacing: 12) {
        Text("Line up")
        Choice(options: [(false, "The Attack"), (true, "The Start of Any Sound")], value: $store.settings.alignStart)
        Toggle("Skip ones already measured", isOn: $store.settings.skipMeasured).toggleStyle(.checkbox)
          .help("Skip ones already measured: articulations with a profile already are left out, so a stopped run can carry on.")
      }
      HStack(spacing: 12) {
        Text("Profiles folder")
        Text(store.profilesFolder.path).foregroundColor(House.textDim).lineLimit(1).truncationMode(.middle)
          .help(store.profilesFolder.path)
        Button("Choose…") { chooseFolder() }.buttonStyle(HouseButton())
        Button("Show in Finder") {
          try? FileManager.default.createDirectory(at: store.profilesFolder, withIntermediateDirectories: true)
          NSWorkspace.shared.activateFileViewerSelecting([store.profilesFolder])
        }
        .buttonStyle(HouseButton())
      }
      switch store.testOptions() {
      case .failure(let e): Warn(e.message)
      case .success: Dim(store.estimate())
      }
    }
    .onChange(of: store.settings) { _ in store.save() }
  }

  private func labelled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).foregroundColor(House.textDim)
      content()
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.message = "Choose where profiles are saved. REAPER's Fix Selected Items reads them from REAPER › Data › Note Fixer › Profiles."
    if panel.runModal() == .OK, let url = panel.url {
      store.settings.profilesFolder = url.path
      store.save()
    }
  }

  // MARK: 4 Measure

  private var measureSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Heading(number: 4, title: "Measure")
      HStack(spacing: 12) {
        if store.running {
          Button("Stop") { store.stop() }.buttonStyle(HouseButton())
            .help("Stop: finish the note being measured and stop.")
        } else {
          Button("Measure All") { store.measureAll() }.buttonStyle(HouseButton())
            .help("Measure All: play and measure every ticked instrument's ticked articulations, one after another.")
        }
        Button("Open the Fixer Page") { openPage() }.buttonStyle(HouseButton())
          .help("Open the Fixer Page: the Note Position & Volume Fixer page, to fix a MIDI file from a profile or a render.")
      }
      if store.running {
        ProgressView(value: store.progress).tint(House.control)
        Text(store.status)
      }
      if let m = store.message { if m.warn { Warn(m.text) } else { Text(m.text).fixedSize(horizontal: false, vertical: true) } }
      ForEach(store.log) { l in if l.warn { Warn(l.text) } else { Dim(l.text) } }
    }
  }

  private func openPage() {
    if let url = Bundle.main.url(forResource: "Note-Position-Volume-Fixer", withExtension: "html") { NSWorkspace.shared.open(url) }
  }
}

/// One articulation: tick, name, what chooses it, dynamics.
struct ArticulationRow: View {
  @EnvironmentObject var store: Store
  @Binding var art: Articulation
  let onRemove: () -> Void
  @State private var keyswitch = ""

  var body: some View {
    HStack(spacing: 12) {
      Toggle("Measure", isOn: $art.include).toggleStyle(.checkbox).labelsHidden()
        .help("Measure: include this articulation when you press Measure All.")
      TextField("Name", text: $art.name, onCommit: { store.save() }).houseField(width: 240)
      if art.source != nil || art.send.count > 1 || art.channel != nil {
        Text(store.describe(art) + (art.program.map { "  (Reaticulate \($0))" } ?? ""))
          .frame(width: 260, alignment: .leading).lineLimit(1)
          .help("What the map sends to choose it\(art.source.map { ", from " + $0 } ?? "").")
      } else {
        TextField("Keyswitch, e.g. C-1", text: $keyswitch, onCommit: setKeyswitch)
          .houseField(width: 160)
          .help("Keyswitch: the note that chooses it, such as C-1. Leave empty for none.")
          .onAppear { keyswitch = art.send.first.flatMap { $0.pitch.map(Notes.name) } ?? "" }
        if !keyswitch.isEmpty && Notes.parse(keyswitch) == nil { Text("?").foregroundColor(House.warnText) }
        Spacer().frame(width: 80)
      }
      Choice(options: [(1, "Velocity"), (2, "CC1")], value: $art.dynamics)
        .help("Dynamics: velocity for short notes, CC1 for long notes played on the mod wheel.")
      Button("Remove", action: onRemove).buttonStyle(HouseButton())
      Spacer()
    }
    .onChange(of: art) { _ in store.save() }
  }

  private func setKeyswitch() {
    if keyswitch.trimmingCharacters(in: .whitespaces).isEmpty { art.send = [] }
    else if let p = Notes.parse(keyswitch) { art.send = [Output(kind: "note", pitch: p, vel: 100)] }
  }
}

/// Every Audio Unit instrument on this Mac, to choose from.
struct InstrumentPicker: View {
  @EnvironmentObject var store: Store
  @Binding var choosing: Bool
  @State private var search = ""
  @State private var all: [AVAudioUnitComponent] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add an instrument").font(.system(size: 15, weight: .semibold))
      TextField("Search", text: $search).houseField()
      List(all.filter { search.isEmpty || ($0.manufacturerName + " " + $0.name).localizedCaseInsensitiveContains(search) }, id: \.self) { c in
        Button {
          choosing = false
          Task { await store.add(c) }
        } label: {
          HStack {
            Text(c.name).foregroundColor(House.text)
            Text(c.manufacturerName).foregroundColor(House.textDim)
            Spacer()
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .frame(minHeight: 320)
      HStack {
        Spacer()
        Button("Cancel") { choosing = false }.buttonStyle(HouseButton()).keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 520, height: 480)
    .background(House.ground)
    .onAppear { all = AUHost.instruments() }
  }
}
