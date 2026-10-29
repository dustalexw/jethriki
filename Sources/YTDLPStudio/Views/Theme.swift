import SwiftUI
#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

/// Visual language taken from the app icon: deep-space navy, an iridescent
/// pink → violet → cyan ribbon, and a glowing red-orange "play" accent.
enum Theme {
    static let spaceTop = Color.adaptive(light: PlatformColor(red: 0.97, green: 0.95, blue: 1.00, alpha: 1),
                                         dark: PlatformColor(red: 0.07, green: 0.05, blue: 0.17, alpha: 1))
    static let spaceBottom = Color.adaptive(light: PlatformColor(red: 0.93, green: 0.95, blue: 1.00, alpha: 1),
                                            dark: PlatformColor(red: 0.03, green: 0.03, blue: 0.10, alpha: 1))

    static let pink = Color(red: 1.00, green: 0.36, blue: 0.82)
    static let violet = Color(red: 0.55, green: 0.40, blue: 1.00)
    static let blue = Color(red: 0.25, green: 0.52, blue: 1.00)
    static let cyan = Color(red: 0.20, green: 0.86, blue: 0.95)
    static let ember = Color(red: 1.00, green: 0.27, blue: 0.20)
    static let flame = Color(red: 1.00, green: 0.55, blue: 0.22)

    static let accent = violet

    static let ribbon = LinearGradient(colors: [pink, violet, blue, cyan],
                                       startPoint: .leading, endPoint: .trailing)
    static let ribbonDiagonal = LinearGradient(colors: [pink, violet, cyan],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
    static let play = LinearGradient(colors: [ember, flame],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)

    static let panelFill = Color.adaptive(light: PlatformColor.white.withAlphaComponent(0.62), dark: PlatformColor.white.withAlphaComponent(0.045))
    static let fieldFill = Color.adaptive(light: PlatformColor.white.withAlphaComponent(0.85), dark: PlatformColor.white.withAlphaComponent(0.06))
    static let chipFill = Color.adaptive(light: PlatformColor.black.withAlphaComponent(0.04), dark: PlatformColor.white.withAlphaComponent(0.06))
    static let hoverFill = Color.adaptive(light: PlatformColor.black.withAlphaComponent(0.09), dark: PlatformColor.white.withAlphaComponent(0.14))
    static let commandFill = Color.adaptive(light: PlatformColor.white.withAlphaComponent(0.6), dark: PlatformColor.black.withAlphaComponent(0.25))
    static let track = Color.adaptive(light: PlatformColor.black.withAlphaComponent(0.08), dark: PlatformColor.white.withAlphaComponent(0.08))
    static let hairline = Color.adaptive(light: PlatformColor.black.withAlphaComponent(0.08), dark: PlatformColor.white.withAlphaComponent(0.09))

    /// Per-category tile colours, walking around the ribbon.
    static func tile(_ c: OptionCategory) -> [Color] {
        switch c {
        case .format: return [pink, violet]
        case .audio: return [violet, blue]
        case .encode: return [ember, flame]
        case .chapters: return [blue, cyan]
        case .subtitles: return [cyan, blue]
        case .metadata: return [pink, ember]
        case .trim: return [violet, pink]
        case .playlist: return [blue, violet]
        case .network: return [cyan, violet]
        case .output: return [flame, pink]
        case .advanced: return [Color(white: 0.45), Color(white: 0.25)]
        }
    }
}

extension Color {
    /// A colour that follows the window's light/dark appearance.
    static func adaptive(light: PlatformColor, dark: PlatformColor) -> Color {
        #if canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
        #else
        Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
        #endif
    }
}

/// User-selectable window appearance, stored under "appearance".
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }
    /// For SwiftUI's preferredColorScheme.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    #if canImport(AppKit)
    /// Applied to NSApp so every window, sheet and the Settings window follow it.
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    #endif
}

/// Cosmic backdrop: a deep-space gradient (or a pale dawn one in light mode) with soft nebula glows.
struct CosmicBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let k = scheme == .dark ? 1.0 : 0.75
        ZStack {
            LinearGradient(colors: [Theme.spaceTop, Theme.spaceBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.violet.opacity(0.28 * k), .clear], center: .topLeading, startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Theme.cyan.opacity(0.14 * k * 1.2), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Theme.pink.opacity(0.10 * k * 1.3), .clear], center: .topTrailing, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

/// Frosted panel with a faint iridescent rim.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.panelFill))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Theme.pink.opacity(0.35), Theme.hairline, Theme.cyan.opacity(0.30)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func glassPanel(radius: CGFloat = 16) -> some View { modifier(GlassPanel(radius: radius)) }
}

/// Small rounded-square icon tile, like System Settings, filled with a ribbon gradient.
struct IconTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 22
    /// Grows with the system text size on iPhone and iPad (always 1 on the Mac).
    @ScaledMetric private var scale: CGFloat = 1

    var body: some View {
        let size = self.size * min(scale, 2)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: (colors.first ?? .clear).opacity(0.35), radius: 3, y: 1)
    }
}

/// Uniform circular icon button used for inline actions.
struct IconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 26
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, diameter: diameter, prominent: prominent)
    }

    private struct IconButtonBody: View {
        let configuration: Configuration
        let diameter: CGFloat
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: diameter * 0.46, weight: .semibold))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(hovering ? .primary : .secondary))
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(prominent ? AnyShapeStyle(Theme.ribbonDiagonal)
                                            : AnyShapeStyle(hovering ? Theme.hoverFill : Theme.chipFill))
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// The big call-to-action, styled like the icon's glowing play button.
struct GlowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlowBody(configuration: configuration)
    }

    private struct GlowBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                #if os(iOS)
                // Follows the system text size, so it grows with Larger Text like the rest of the app.
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 34)
                #else
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 34)
                #endif
                .background(Capsule().fill(Theme.play))
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: Theme.ember.opacity(isEnabled ? (hovering ? 0.65 : 0.45) : 0), radius: hovering ? 12 : 8, y: 2)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .saturation(isEnabled ? 1 : 0.3)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
                #if os(iOS)
                .contentShape(.hoverEffect, Capsule())
                .hoverEffect(.lift)
                #endif
        }
    }
}

/// Brand mark: the app icon (when bundled) and "Jethriki" in ribbon colours.
struct BrandMark: View {
    #if canImport(AppKit)
    private var appIcon: Image { Image(nsImage: NSApp.applicationIconImage) }
    #else
    private var appIcon: Image { Image("BrandIcon") }
    #endif

    @ScaledMetric(relativeTo: .headline) private var iconSize: CGFloat = 26

    var body: some View {
        HStack(spacing: 8) {
            appIcon
                .resizable()
                .interpolation(.high)
                .frame(width: min(iconSize, 40), height: min(iconSize, 40))
            Text("Jethriki")
                #if os(iOS)
                .font(.system(.headline, design: .rounded).weight(.heavy))
                #else
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                #endif
                .foregroundStyle(Theme.ribbon)
        }
        .fixedSize()
    }
}
