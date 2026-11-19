import AppKit
import CoreText
import SwiftUI

/// SocialForge's design system, taken from design/SocialForge v2.dc.html.
/// Dark values are the design's; light values keep the same hierarchy.
/// Views use these tokens, never raw colors.
enum DS {
    // MARK: Surfaces
    static let window = Color(light: 0xEFEBE7, dark: 0x0B0B10)
    static let sidebar = Color(light: 0xEDE7E2, dark: 0x221E21)
    static let main = Color(light: 0xF8F7F5, dark: 0x19191C)
    static let panel = Color(light: 0xFDFCFB, dark: 0x1E1E22)
    static let canvas = Color(light: 0xE9E6E2, dark: 0x141417)
    /// Card and row fills: white at 4–7 % on dark, ink at 3–6 % on light.
    static let fill = Color(nsColor: .sfDynamic(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 1, alpha: 0.045)))
    static let fillStrong = Color(nsColor: .sfDynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.07)))
    static let fillSelected = Color(nsColor: .sfDynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.10)))
    static let stroke = Color(nsColor: .sfDynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.07)))
    static let strokeStrong = Color(nsColor: .sfDynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.12)))

    // MARK: Text
    static let text = Color(light: 0x1C1B1F, dark: 0xECECEF)
    static let textBody = Color(light: 0x34333A, dark: 0xD6D6DC)
    static let text2 = Color(light: 0x6B6A72, dark: 0x9C9CA6)
    static let text3 = Color(light: 0x8E8D95, dark: 0x6F6F78)

    // MARK: Accent and status
    static let accent = Color(light: 0xE8662F, dark: 0xFF8A5C)
    static let accentFill = Color(hex: 0xFF7A45)
    static let onAccent = Color(hex: 0x1D0D05)
    static let accentSoft = Color(nsColor: .sfDynamic(light: NSColor(srgbRed: 1, green: 0.48, blue: 0.27, alpha: 0.12),
                                                       dark: NSColor(srgbRed: 1, green: 0.48, blue: 0.27, alpha: 0.15)))
    static let green = Color(light: 0x1F9D57, dark: 0x3DDC84)
    static let amber = Color(light: 0xB7791F, dark: 0xF5B544)
    static let red = Color(light: 0xD93A3A, dark: 0xFF6B6B)

    // MARK: Shape
    static let radiusControl: CGFloat = 8
    static let radiusCard: CGFloat = 12
    static let sidebarWidth: CGFloat = 228
    static let inspectorWidth: CGFloat = 340
    static let topBarHeight: CGFloat = 56

    // MARK: Type
    /// Instrument Serif (bundled), else the system serif.
    static func display(_ size: CGFloat) -> Font {
        FontRegistry.hasInstrumentSerif ? .custom("Instrument Serif", size: size) : .system(size: size, design: .serif)
    }
    static let sectionLabel = Font.system(size: 11, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let small = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let mono = Font.system(size: 12, design: .monospaced)
}

extension NSColor {
    static func sfDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}

/// Registers the bundled fonts once at launch (process scope; nothing is installed system-wide).
enum FontRegistry {
    nonisolated(unsafe) private(set) static var hasInstrumentSerif = false

    static func registerBundledFonts() {
        let dirs = [Bundle.main.resourceURL?.appending(path: "Fonts"),
                    // Running from the build folder (tests, swift run): use the repo copy.
                    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fonts")].compactMap { $0 }
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "ttf" {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
            break
        }
        let font = CTFontCreateWithName("InstrumentSerif-Regular" as CFString, 12, nil)
        hasInstrumentSerif = (CTFontCopyPostScriptName(font) as String) == "InstrumentSerif-Regular"
    }
}

// MARK: - Components

/// "POST TO", "CADENCE": the design's small uppercase section labels.
struct SectionLabel: View {
    let text: String
    var trailing: AnyView?

    init(_ text: String, trailing: AnyView? = nil) { self.text = text; self.trailing = trailing }

    var body: some View {
        HStack {
            Text(text.uppercased()).font(DS.sectionLabel).tracking(0.6).foregroundStyle(DS.text3)
            Spacer()
            trailing
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// The header row of a panel: "Pipeline · 60 posts".
struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
            Spacer()
            trailing.font(DS.small).foregroundStyle(DS.text2)
        }
        .frame(height: DS.topBarHeight)
        .padding(.horizontal, Space.xl)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String) { self.title = title; self.trailing = EmptyView() }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = Space.lg
    var selected = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(selected ? DS.accentFill : DS.stroke, lineWidth: selected ? 2 : 1))
    }
}

extension View {
    func card(padding: CGFloat = Space.lg, selected: Bool = false) -> some View {
        modifier(CardModifier(padding: padding, selected: selected))
    }

    /// The design's text-field look: soft fill, hairline border, 8 pt radius.
    func fieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).strokeBorder(DS.stroke))
    }
}

/// Orange primary button with dark text, as "New Post" and "Schedule 60 posts".
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize(horizontal: !fullWidth, vertical: false)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.onAccent)
            .padding(.horizontal, Space.lg)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 32)
            .background(DS.accentFill.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// Neutral filled button: "Save draft", "Review", "Variations".
struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = false
    var tint: Color?
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize(horizontal: !fullWidth, vertical: false)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint ?? DS.text)
            .padding(.horizontal, Space.md)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 32)
            .background((tint.map { $0.opacity(0.14) } ?? DS.fillStrong).opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Text-only action in the accent color: "Open calendar", "Use title".
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(DS.bodyMedium).foregroundStyle(DS.accent.opacity(configuration.isPressed ? 0.6 : 1)).contentShape(Rectangle())
    }
}

/// Square icon button for tool bars and headers.
struct IconButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(selected ? DS.accent : DS.text2)
            .frame(width: 32, height: 32)
            .background(selected ? DS.accentSoft : (configuration.isPressed ? DS.fillStrong : .clear),
                        in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// The design's green switch.
struct SFToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { configuration.isOn.toggle() }
        } label: {
            HStack {
                configuration.label
                Spacer(minLength: Space.sm)
                Capsule()
                    .fill(configuration.isOn ? DS.green : DS.fillSelected)
                    .frame(width: 36, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 16, height: 16).padding(2).shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// A row of pill choices: "hours | days | weeks", "Month | Week | Queue".
struct PillPicker<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Button { withAnimation(.snappy(duration: 0.15)) { selection = o } } label: {
                    Text(label(o)).lineLimit(1).fixedSize()
                }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: selection == o ? .semibold : .regular))
                    .foregroundStyle(selection == o ? DS.text : DS.text2)
                    .padding(.horizontal, Space.md)
                    .frame(height: 28)
                    .background(selection == o ? DS.fillSelected : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(2)
        .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
    }
}

/// A selectable chip: "9:00 AM" in the time row, "Pinterest Pin" in previews.
struct Chip: View {
    let text: String
    var selected = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? DS.accent : DS.textBody)
                .padding(.horizontal, Space.md)
                .frame(height: 28)
                .background(selected ? DS.accentSoft : DS.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? DS.accentFill.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// "● Connected", "● Needs approval".
struct StatusDot: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(DS.small).foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Label on the left, value on the right: "Board · Winter Home Edit".
struct KeyValueRow<Value: View>: View {
    let key: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(DS.body).foregroundStyle(DS.text2)
            Spacer(minLength: Space.md)
            value.font(DS.body).foregroundStyle(DS.text).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, Space.sm)
    }
}

extension KeyValueRow where Value == Text {
    init(_ key: String, _ value: String) { self.key = key; self.value = Text(value) }
}

/// Initials in a rounded square: workspace, provider, and person badges.
struct InitialBadge: View {
    let text: String
    var color: Color = DS.fillStrong
    var foreground: Color = DS.textBody
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Text(text).font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(foreground))
            .accessibilityHidden(true)
    }
}

/// Thin progress bar: approvals, ComfyUI memory, sampling steps.
struct ThinProgress: View {
    let segments: [(Double, Color)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    Capsule().fill(s.1).frame(width: max(0, geo.size.width * s.0 - 2))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 4)
        .background(DS.fillStrong, in: Capsule())
    }
}

/// A scrolling inspector column with the design's spacing.
struct InspectorScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) { content }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

/// Empty state in the design's voice: icon in a soft square, title, one line, one action.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(DS.accent)
                .frame(width: 44, height: 44).background(DS.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
            Text(message).font(DS.body).foregroundStyle(DS.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack(spacing: Space.sm) { actions }.padding(.top, Space.xs)
        }
        .padding(Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.symbol = symbol; self.title = title; self.message = message; self.actions = EmptyView()
    }
}
