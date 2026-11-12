import AppKit
import SwiftUI

// MARK: - Design tokens ("Quiet Utility")
//
// System semantic colours, system text styles and native controls first. Custom values live here only,
// so screens never hard-code colours, sizes or animation curves.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    /// A color that follows the window's light/dark appearance.
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let h = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                           blue: CGFloat(h & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

/// Semantic colours. Everything maps to macOS system colours, so the app follows the user's accent colour,
/// light/dark mode and Increase Contrast automatically.
enum Palette {
    static let fg = Color.primary
    static let dim = Color.secondary
    static let faint = Color(nsColor: .tertiaryLabelColor)

    static let windowTop = Color(nsColor: .windowBackgroundColor)
    static let windowBottom = Color(nsColor: .windowBackgroundColor)
    static let bgBottom = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color.clear
    /// Content card surface: white on the light window, a lifted grey on the dark one (like System Settings groups).
    static let panel = Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.065)
            : NSColor.controlBackgroundColor
    })
    /// Inner tile / well inside a card.
    static let tile = Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.black.withAlphaComponent(0.04)
    })
    static let stroke = Color(nsColor: .separatorColor)
    static let selection = Color.accentColor.opacity(0.16)

    static let accent = Color.accentColor
    static let accent2 = Color.accentColor
    static let success = Color(nsColor: .systemGreen)
    static let warn = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)

    // Data colours (storage bar, categories). System colours keep them legible in both appearances.
    static let apps = Color(nsColor: .systemBlue)
    static let documents = Color(nsColor: .systemPurple)
    static let library = Color(nsColor: .systemPink)
    static let other = Color(nsColor: .systemYellow)
    static let available = Color(nsColor: .quaternaryLabelColor)
}

/// Spacing scale (points).
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
}

/// Corner radii. Nested shapes are concentric: inner radius = outer radius − the padding between them.
enum Radius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 10
    static let large: CGFloat = 12
    /// Dashboard and content cards.
    static let card: CGFloat = 22
    /// Padding inside a card.
    static let cardPadding: CGFloat = 16
    /// Tiles and wells placed inside a card's padding.
    static let inner: CGFloat = card - cardPadding + 4
}

/// Text roles built on system text styles (they scale with the system text size).
extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Big number on a summary (free space, total selected).
    static let figure = Font.system(.largeTitle, design: .rounded).weight(.semibold)
    static let sectionTitle = Font.headline
    static let rowTitle = Font.body.weight(.medium)
    static let rowDetail = Font.callout
    static let meta = Font.caption
}

/// Animation roles. Every one returns nil under Reduce Motion.
enum Motion {
    static func standard(_ reduce: Bool) -> Animation? { reduce ? nil : .snappy(duration: 0.25) }
    static func quick(_ reduce: Bool) -> Animation? { reduce ? nil : .easeOut(duration: 0.15) }
}

extension CacheCategory {
    var color: Color {
        switch self {
        case .xcode: return Color(nsColor: .systemBlue)
        case .android: return Color(nsColor: .systemGreen)
        case .packages: return Color(nsColor: .systemOrange)
        case .editors: return Color(nsColor: .systemPink)
        case .devCache: return Color(nsColor: .systemPurple)
        case .appCaches: return Color(nsColor: .systemTeal)
        case .webCaches: return Color(nsColor: .systemRed)
        case .logs: return Color(nsColor: .systemGray)
        case .trash: return Color(nsColor: .systemBrown)
        }
    }
}

// MARK: - Surfaces

/// Window background (plain system colour, no gradient).
struct AppBackground: View {
    var body: some View { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() }
}

/// Kept for older call sites.
typealias GridBackground = AppBackground

extension View {
    /// Content card: readable solid surface, continuous corners, hairline edge. No shadow.
    func panel(radius: CGFloat = Radius.card) -> some View {
        let r = min(max(radius, Radius.large), Radius.card)
        return self
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: r, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
    }

    /// Floating control surface: Liquid Glass on macOS 26, a regular material before that.
    /// Used only for controls that float over content (action bars), never for content cards.
    @ViewBuilder func floatingBar(radius: CGFloat = Radius.large) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 0.5))
        }
        #else
        self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 0.5))
        #endif
    }
}

// MARK: - Small parts

/// Checkbox drawn like the system one. It reports its state to VoiceOver, so a button that contains it
/// reads as "Selected, <item>, <size>".
struct CheckSquare: View {
    let on: Bool
    let color: Color
    var mixed = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(on || mixed ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(on || mixed ? Color.clear : Color(nsColor: .tertiaryLabelColor), lineWidth: 1))
            .overlay {
                if on || mixed {
                    Image(systemName: on ? "checkmark" : "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 14, height: 14)
            .opacity(enabled ? 1 : 0.45)
            .accessibilityElement()
            .accessibilityLabel(on ? "Selected" : mixed ? "Partly selected" : "Not selected")
    }
}

struct ReviewTag: View {
    var body: some View {
        Text("REVIEW")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Palette.warn.opacity(0.15), in: Capsule())
            .foregroundStyle(Palette.warn)
            .accessibilityLabel("Needs review")
    }
}

/// Symbol on a softly tinted rounded square.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.opacity(0.14))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium)).foregroundStyle(color))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Title + subtitle (used by sheets; pages use the window toolbar title instead).
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.title.bold())
            Text(subtitle).font(.callout).foregroundStyle(Palette.dim)
        }
    }
}
