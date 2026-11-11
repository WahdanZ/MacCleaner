import AppKit
import SwiftUI

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

enum Palette {
    /// Main text / ink colour (near-black in light, white in dark). Also used with opacity for fills.
    static let fg = Color.adaptive(light: 0x1D1D1F, dark: 0xFFFFFF)
    static let dim = Color.adaptive(light: 0x1D1D1F, dark: 0xFFFFFF, lightAlpha: 0.62, darkAlpha: 0.62)
    static let faint = Color.adaptive(light: 0x1D1D1F, dark: 0xFFFFFF, lightAlpha: 0.42, darkAlpha: 0.4)

    static let windowTop = Color.adaptive(light: 0xF3F6FB, dark: 0x1B1D21)
    static let windowBottom = Color.adaptive(light: 0xE8EEF8, dark: 0x141518)
    static let bgBottom = Color.adaptive(light: 0xF3F6FB, dark: 0x1B1D21)
    static let sidebar = Color.adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.45, darkAlpha: 0.035)
    /// Card surface.
    static let panel = Color.adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.78, darkAlpha: 0.055)
    static let stroke = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09)
    static let selection = Color.adaptive(light: 0x0A84FF, dark: 0x0A84FF, lightAlpha: 0.16, darkAlpha: 0.28)

    static let accent = Color.adaptive(light: 0x0A6CFF, dark: 0x3B9BFF)
    static let accent2 = Color.adaptive(light: 0x3E9BFF, dark: 0x64B5FF)
    static let success = Color.adaptive(light: 0x22A54A, dark: 0x34C759)
    static let warn = Color.adaptive(light: 0xE07A12, dark: 0xFF9F0A)
    static let danger = Color.adaptive(light: 0xE5383B, dark: 0xFF5A6E)

    // Storage colours (donut)
    static let apps = Color(hex: 0x1A7CFF)
    static let documents = Color(hex: 0xA25BF0)
    static let library = Color(hex: 0xF0559C)
    static let other = Color(hex: 0xF7B731)
    static let available = Color.adaptive(light: 0xD5DAE3, dark: 0x3A3D44)
}

extension CacheCategory {
    var color: Color {
        switch self {
        case .xcode: return Color(hex: 0x3A8DFF)
        case .android: return Color(hex: 0x7DC42F)
        case .packages: return Color(hex: 0xF5A623)
        case .editors: return Color(hex: 0xEC4899)
        case .devCache: return Color(hex: 0x8B5CF6)
        case .appCaches: return Color(hex: 0x14B8C8)
        case .webCaches: return Color(hex: 0xF43F5E)
        case .logs: return Color(hex: 0x8A94A6)
        case .trash: return Color(hex: 0xF97316)
        }
    }
}

extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Surfaces

struct AppBackground: View {
    var body: some View {
        LinearGradient(colors: [Palette.windowTop, Palette.windowBottom], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// Kept for older call sites.
typealias GridBackground = AppBackground

extension View {
    /// Card: soft surface, hairline border, light shadow.
    func panel(radius: CGFloat = 18) -> some View {
        self
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.stroke))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
    }
}

// MARK: - Buttons

struct AccentButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 16 : 13, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : Palette.faint)
            .padding(.horizontal, large ? 26 : 16)
            .padding(.vertical, large ? 13 : 8)
            .background {
                Capsule().fill(isEnabled
                               ? AnyShapeStyle(LinearGradient(colors: [Palette.accent2, Palette.accent],
                                                              startPoint: .top, endPoint: .bottom))
                               : AnyShapeStyle(Palette.fg.opacity(0.08)))
            }
            .shadow(color: isEnabled ? Palette.accent.opacity(configuration.isPressed ? 0.15 : 0.3) : .clear,
                    radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Wide primary action ("Clean 12.4 GB").
struct WideAccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : Palette.faint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isEnabled
                          ? AnyShapeStyle(LinearGradient(colors: [Palette.accent2, Palette.accent],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Palette.fg.opacity(0.08)))
            }
            .shadow(color: isEnabled ? Palette.accent.opacity(0.28) : .clear, radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEnabled ? Palette.fg : Palette.faint)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Palette.fg.opacity(configuration.isPressed ? 0.12 : 0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.stroke))
    }
}

struct CircleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Palette.fg)
            .frame(width: 40, height: 40)
            .background(Palette.panel, in: Circle())
            .overlay(Circle().strokeBorder(Palette.stroke))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}

// MARK: - Small parts

struct CheckSquare: View {
    let on: Bool
    let color: Color
    var mixed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(on ? color : mixed ? color.opacity(0.35) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(on || mixed ? color : Palette.fg.opacity(0.28), lineWidth: 1.5))
            .overlay {
                if on || mixed {
                    Image(systemName: on ? "checkmark" : "minus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 18, height: 18)
            .animation(.easeOut(duration: 0.12), value: on)
    }
}

struct ReviewTag: View {
    var body: some View {
        Text("REVIEW")
            .font(.mono(8.5, .bold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Palette.warn.opacity(0.16), in: Capsule())
            .foregroundStyle(Palette.warn)
    }
}

/// Rounded tinted icon tile, as in the Overview mockup.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.opacity(0.13))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(color))
            .frame(width: size, height: size)
    }
}

/// Page title + subtitle used at the top of every section.
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 34, weight: .bold))
            Text(subtitle).font(.system(size: 15)).foregroundStyle(Palette.dim)
        }
    }
}
