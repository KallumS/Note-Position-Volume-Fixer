import SwiftUI

/// The house scheme (Good Idea's docs/COLOUR.md): always dark, every grey blue-shifted (R < G < B),
/// light grey controls with dark ink, yellow only for what is chosen or on.
enum House {
  static let ground = Color(hex: 0x23272E)
  static let sunken = Color(hex: 0x1A1D23)
  static let menu = Color(hex: 0x2A2F37)
  static let rule = Color(hex: 0x3A404A)
  static let control = Color(hex: 0xA9AFBA)
  static let controlHover = Color(hex: 0xC0C6CF)
  static let controlHeld = Color(hex: 0x8F96A2)
  static let ink = Color(hex: 0x14171C)
  static let text = Color(hex: 0xDDE1E7)
  static let textDim = Color(hex: 0xB0B6C0)
  static let disabled = Color(hex: 0x8A919C)
  static let edge = Color(hex: 0x8A919C)
  static let accent = Color(hex: 0xFFF200)
  static let accentHover = Color(hex: 0xFFF42E)
  static let accentHeld = Color(hex: 0xD1C600)
  static let warnText = Color(hex: 0xFF9E96)
  static let warn = Color(hex: 0xD2483F)
  static let focus = Color(hex: 0xF2F4F7)
}

extension Color {
  init(hex: UInt32) {
    self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255, opacity: 1)
  }
}

/// A grey button with dark ink, 28 points tall; a chosen one is yellow with a bar under its words
/// (so it isn't told by colour alone).
struct HouseButton: ButtonStyle {
  var chosen = false
  func makeBody(configuration: Configuration) -> some View {
    HouseButtonBody(configuration: configuration, chosen: chosen)
  }
}

private struct HouseButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let chosen: Bool
  @Environment(\.isEnabled) private var enabled
  @State private var hover = false

  var body: some View {
    configuration.label
      .font(.system(size: 13))
      .foregroundColor(enabled ? House.ink : House.disabled)
      .padding(.horizontal, 12)
      .frame(minHeight: 28)
      .background(RoundedRectangle(cornerRadius: 6).fill(fill))
      .overlay(alignment: .bottom) {
        if chosen { Rectangle().fill(House.ink).frame(height: 2).padding(.horizontal, 8).padding(.bottom, 4) }
      }
      .contentShape(Rectangle())
      .onHover { hover = $0 }
  }

  private var fill: Color {
    if !enabled { return House.rule }
    if chosen { return configuration.isPressed ? House.accentHeld : (hover ? House.accentHover : House.accent) }
    return configuration.isPressed ? House.controlHeld : (hover ? House.controlHover : House.control)
  }
}

/// A field on the sunken ground with an edge 3:1 against the window.
struct HouseField: ViewModifier {
  var width: CGFloat?
  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      .font(.system(size: 13))
      .foregroundColor(House.text)
      .padding(.horizontal, 8)
      .frame(width: width, height: 28)
      .background(RoundedRectangle(cornerRadius: 6).fill(House.sunken))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(House.edge, lineWidth: 1))
  }
}

extension View {
  func houseField(width: CGFloat? = nil) -> some View { modifier(HouseField(width: width)) }
}

/// One of several choices side by side: the chosen one yellow.
struct Choice<T: Hashable>: View {
  let options: [(T, String)]
  @Binding var value: T
  var body: some View {
    HStack(spacing: 1) {
      ForEach(options.indices, id: \.self) { k in
        Button(options[k].1) { value = options[k].0 }
          .buttonStyle(HouseButton(chosen: value == options[k].0))
          .accessibilityAddTraits(value == options[k].0 ? .isSelected : [])
      }
    }
  }
}

/// A numbered section heading with a rule, as the family's windows have.
struct Heading: View {
  let number: Int
  let title: String
  var body: some View {
    HStack(spacing: 10) {
      Text("\(number)").foregroundColor(Color(hex: 0xBFC5CE))
      Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(House.text)
      Rectangle().fill(House.rule).frame(height: 1)
    }
    .padding(.top, 8)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

struct Dim: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(.system(size: 13)).foregroundColor(House.textDim).fixedSize(horizontal: false, vertical: true)
  }
}

struct Warn: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Rectangle().fill(House.warn).frame(width: 3)
      Text(text).font(.system(size: 13)).foregroundColor(House.warnText).fixedSize(horizontal: false, vertical: true)
    }
  }
}
