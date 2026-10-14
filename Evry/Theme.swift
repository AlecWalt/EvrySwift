//
//  Theme.swift
//  Evry
//
//  Design tokens from the Evry Design System (EvryDesignSystem/EvryDesignSystem.md
//  + evry-tokens.json). The palette is a strict 60-30-10 of white, sky and navy;
//  every other shade is an opacity step or a documented mix of those three. One
//  typeface (Nunito), soft round shapes, navy-tinted shadows.
//
//  The design system is light-only. The dark palette below is derived from the
//  same three colours (navy surfaces, white text, sky accents — the brand's
//  "on-navy" treatment) so the app's dark mode still reads as Evry.
//

import SwiftUI
import UIKit
import CoreText

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// A colour that resolves per light/dark trait — for the static semantic
    /// tokens, which don't have a `Palette` instance to ask.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

// MARK: - Brand colours (60-30-10)

extension Color {
    /// The 60: page backgrounds, cards, fields; labels on navy fills.
    static let evryWhite = Color(hex: 0xFFFFFF)
    /// The 30: highlights, bullets, check discs, badges, the button on navy.
    /// Never text on white (1.35:1).
    static let evrySky = Color(hex: 0xB0E6FF)
    /// The 10: all text, primary buttons, icons, the focus ring.
    static let evryNavy = Color(hex: 0x162339)

    /// sky 35% + white. Secondary-button hover, eyebrow pills, Evry's bubble.
    static let evrySkySoft = Color(hex: 0xE3F6FF)
    /// sky 18% + white. The faintest tint: the "mist" section tone.
    static let evrySkyMist = Color(hex: 0xF1FBFF)
    /// navy 88% + sky. Primary button pressed/hover only.
    static let evryNavySoft = Color(hex: 0x283A51)

    /// Navy opacity steps. Text never goes lighter than `navy75`.
    static let evryNavy80 = evryNavy.opacity(0.8)   // secondary copy
    static let evryNavy75 = evryNavy.opacity(0.75)  // captions — lightest text allowed
    static let evryNavy60 = evryNavy.opacity(0.6)   // placeholders only
    static let evryNavy40 = evryNavy.opacity(0.4)   // dashed placeholder border
    static let evryNavy28 = evryNavy.opacity(0.28)  // secondary border, pressed
    static let evryNavy20 = evryNavy.opacity(0.2)   // field border at rest
    static let evryNavy16 = evryNavy.opacity(0.16)  // secondary border at rest
    static let evryNavy08 = evryNavy.opacity(0.08)  // card hairline

    /// White opacity steps, for use on navy.
    static let evryWhite85 = Color.white.opacity(0.85)  // body copy on navy
    static let evryWhite80 = Color.white.opacity(0.8)   // muted text on navy
    static let evryWhite60 = Color.white.opacity(0.6)
    static let evryWhite35 = Color.white.opacity(0.35)  // ghost-light border
    static let evryWhite10 = Color.white.opacity(0.1)   // ghost-light fill
}

// MARK: - Shape, spacing, motion tokens

enum EvryRadius {
    static let field: CGFloat = 16   // fields, store buttons, bubbles, inset panels
    static let card: CGFloat = 24    // cards, forms
    static let panel: CGFloat = 32   // plan cards, large panels, sheets
    static let tile: CGFloat = 12    // tool icon tiles
    static let tail: CGFloat = 6     // speech-bubble tail corner
}

enum EvrySpace {
    static let gutter: CGFloat = 16
    static let grid: CGFloat = 24
    static let card: CGFloat = 28
    static let buttonX: CGFloat = 24
    static let buttonY: CGFloat = 12
    static let buttonHeight: CGFloat = 48
    static let tap: CGFloat = 44
    static let storeHeight: CGFloat = 56
}

enum EvryMotion {
    /// The house "settle" curve — cubic-bezier(0.2, 0.8, 0.2, 1): fast out, soft landing.
    static let settle = Animation.spring(response: 0.5, dampingFraction: 0.8)
    /// Playful overshoot, reserved for the mascot and small delights.
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.6)
    static let hover = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2)
    static let card = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.25)
    static let pop = Animation.timingCurve(0.3, 1.4, 0.5, 1, duration: 0.5)
    static let reveal = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.7)
}

// MARK: - Accent (single, fixed)

/// The app used to offer a set of swappable accent colours. The Evry design
/// system has exactly one palette, so this is now a single fixed theme; the type
/// is kept so `Palette(dark:accent:)` call sites stay unchanged.
struct AccentColorTheme: Identifiable, Equatable {
    let key: String
    let label: String

    var id: String { key }

    static let evry = AccentColorTheme(key: "evry", label: "Evry")
    static let all: [AccentColorTheme] = [evry]

    static func byKey(_ key: String) -> AccentColorTheme { evry }
}

// MARK: - Theme mode

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

// MARK: - Appearance (persisted theme selection)

@Observable
final class Appearance {
    var themeMode: ThemeMode {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: "theme") }
    }

    init() {
        // Default to light mode (the brand's native look) until the user
        // explicitly picks a theme.
        themeMode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .light
    }

    var accent: AccentColorTheme { .evry }

    var preferredColorScheme: ColorScheme? {
        switch themeMode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - Palette (semantic tokens for light and the derived dark mode)

struct Palette {
    let dark: Bool
    let accent: AccentColorTheme

    init(dark: Bool, accent: AccentColorTheme = .evry) {
        self.dark = dark
        self.accent = accent
    }

    // Dark-mode surfaces: navy, stepped toward sky (the same mix the brand uses
    // for navy-soft) so cards lift off the page without introducing a new hue.
    private static let navyCard = Color.evryNavy.mix(with: .evrySky, by: 0.07)
    private static let navyRaised = Color.evryNavySoft

    // Surfaces
    /// Page background: white (light) / navy (dark).
    var bg: Color      { dark ? .evryNavy : .evryWhite }
    /// Cards, fields, sheets.
    var card: Color    { dark ? Self.navyCard : .evryWhite }
    /// Pressed / hover / selected fill.
    var hover: Color   { dark ? Self.navyRaised : .evrySkySoft }
    /// Dividers, control outlines, inactive tracks.
    var border: Color  { dark ? .evryWhite.opacity(0.14) : .evryNavy16 }
    /// The faint 1pt hairline around cards.
    var hairline: Color { dark ? .evryWhite.opacity(0.08) : .evryNavy08 }

    // Text
    var text: Color      { dark ? .evryWhite : .evryNavy }
    /// Secondary copy (navy-80 / white-85).
    var textSec: Color   { dark ? .evryWhite85 : .evryNavy80 }
    /// Captions — the lightest *text* allowed (navy-75 / white-80).
    var textMuted: Color { dark ? .evryWhite80 : .evryNavy75 }
    /// Placeholders and disabled glyphs only — never for readable text.
    var textPh: Color    { dark ? .evryWhite60 : .evryNavy60 }

    // Brand roles
    /// The strong action/ink colour: navy on light surfaces, sky on navy.
    /// Text-safe on `card` and `bg` in both modes.
    var primary: Color      { dark ? .evrySky : .evryNavy }
    /// Soft tinted surface: sky-soft (light) / sky over navy (dark).
    var primaryLight: Color { dark ? Color.evryNavy.mix(with: .evrySky, by: 0.18) : .evrySkySoft }
    /// Label/icon colour on a `primary` fill.
    var onPrimary: Color    { dark ? .evryNavy : .evryWhite }
    /// Pressed state of a `primary` fill.
    var primaryPressed: Color { dark ? .evryWhite : .evryNavySoft }

    /// The sky highlight (the "30"): fills, discs, badges, progress. Never text on light.
    var sky: Color     { .evrySky }
    var skySoft: Color { dark ? Color.evryNavy.mix(with: .evrySky, by: 0.18) : .evrySkySoft }
    var skyMist: Color { dark ? Self.navyCard : .evrySkyMist }
    /// Ink to place on a `sky` fill — always navy (11.7:1).
    var onSky: Color   { .evryNavy }

    // Functional signals. The brand has no red, green or orange: state is carried
    // by icons and words, so these resolve to the strong ink. Use them for
    // meaning (so call sites stay self-documenting) and pair them with a symbol.
    static let success = Color(light: .evryNavy, dark: .evrySky)
    static let danger  = Color(light: .evryNavy, dark: .evrySky)
    static let warning = Color(light: .evryNavy, dark: .evrySky)
    /// Label/icon colour on a `success`/`danger`/`warning` fill.
    static let onSignal = Color(light: .evryWhite, dark: .evryNavy)
    /// Completed / done fill: the sky "check disc", with navy ink on top.
    static let doneFill = Color.evrySky

    /// Date-chip ink. Urgency is carried by weight and the alert glyph (see
    /// `DateChip`), not hue: overdue and today use full ink, then soften.
    func dateColor(_ category: DateCategory) -> Color {
        switch category {
        case .overdue, .today:          text
        case .tomorrow, .week:          textSec
        case .nextweek, .later:         textMuted
        }
    }
}

// MARK: - Shadows (always navy-tinted, never black)

extension View {
    /// shadow-soft: a resting card.
    func evryShadowSoft(_ palette: Palette) -> some View {
        let ink = palette.dark ? Color.black : Color.evryNavy
        return shadow(color: ink.opacity(palette.dark ? 0.25 : 0.05), radius: 1, y: 1)
            .shadow(color: ink.opacity(palette.dark ? 0.35 : 0.12), radius: 12, y: 8)
    }

    /// shadow-lift: a raised card, open item, popover or floating bar.
    func evryShadowLift(_ palette: Palette) -> some View {
        let ink = palette.dark ? Color.black : Color.evryNavy
        return shadow(color: ink.opacity(palette.dark ? 0.3 : 0.06), radius: 2, y: 2)
            .shadow(color: ink.opacity(palette.dark ? 0.45 : 0.2), radius: 20, y: 18)
    }

    /// shadow-btn: a primary (navy) button at rest.
    func evryShadowButton(_ palette: Palette) -> some View {
        shadow(color: (palette.dark ? Color.black : Color.evryNavy).opacity(palette.dark ? 0.4 : 0.35),
               radius: 8, y: 6)
    }
}

// MARK: - Folder shades

extension Palette {
    /// A folder colour: `shade` 0…1 steps from sky toward navy. The tones are
    /// mixes of the two brand colours, so folders differ by strength, never hue.
    func folderColor(shade: Double) -> Color {
        let s = min(max(shade, 0), 1)
        return dark
            ? Color.evrySky.mix(with: .evryNavy, by: s * 0.45)
            : Color.evrySky.mix(with: .evryNavy, by: 0.3 + s * 0.55)
    }
}

/// Assigns folder colours automatically. Each new folder takes the midpoint of
/// the largest remaining gap between sky and navy — 1/2, then 1/4 and 3/4, then
/// 1/8, 5/8, 3/8, 7/8… — so consecutive folders are always distinct, related shades.
enum FolderShade {
    static let taskGroupsKey = "folder_shade_counter_task_groups"
    static let noteFoldersKey = "folder_shade_counter_note_folders"

    /// The shade the next folder will get (without claiming it).
    static func peek(_ key: String) -> Double {
        vanDerCorput(UserDefaults.standard.integer(forKey: key) + 1)
    }

    /// Claims and returns the next shade in the sequence.
    static func next(_ key: String) -> Double {
        let n = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(n, forKey: key)
        return vanDerCorput(n)
    }

    /// Base-2 van der Corput sequence: 0.5, 0.25, 0.75, 0.125, 0.625, …
    private static func vanDerCorput(_ index: Int) -> Double {
        var n = index, value = 0.0, bit = 0.5
        while n > 0 {
            if n & 1 == 1 { value += bit }
            n >>= 1
            bit /= 2
        }
        return value
    }
}

// MARK: - App typeface (Nunito)

/// The app's only typeface. Every `.font(.nunito(...))` resolves to Nunito once
/// the font files are bundled (see `AppFonts.register()`); until then
/// `Font.custom` falls back to the system font automatically.
extension Font {
    static func nunito(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Name the exact face. The bundled static files give the upright and
        // italic faces the same family, so `.custom("Nunito").weight(...)` can
        // resolve to the wrong face (or fall back) depending on context.
        .custom(nunitoFaceName(weight), size: size)
    }

    static func nunitoFaceName(_ weight: Font.Weight) -> String {
        switch weight {
        case .black:      "Nunito-Black"
        case .heavy:      "Nunito-ExtraBold"
        case .bold:       "Nunito-Bold"
        case .semibold:   "Nunito-SemiBold"
        case .medium:     "Nunito-Medium"
        case .light:      "Nunito-Light"
        case .ultraLight, .thin: "Nunito-ExtraLight"
        default:          "Nunito-Regular"
        }
    }

    // The Evry type scale (phone sizes of the fluid web styles). Headlines are
    // heavy and tight; body is regular; bold is for labels and buttons.
    /// text-h2: page titles and section headings. Tracking -0.015em.
    static let evryH2      = nunito(size: 32, weight: .heavy)
    /// text-h3: card, sheet and plan titles.
    static let evryH3      = nunito(size: 22, weight: .bold)
    /// text-title: small titles inside cards and tiles.
    static let evryTitle   = nunito(size: 19, weight: .semibold)
    /// text-lead: the paragraph under a heading, in textSec.
    static let evryLead    = nunito(size: 18)
    /// text-body: all running text.
    static let evryBody    = nunito(size: 16)
    /// text-body bold: labels and button text.
    static let evryLabel   = nunito(size: 16, weight: .bold)
    /// text-bubble: Evry's speech bubbles.
    static let evryBubble  = nunito(size: 15)
    /// text-sm: eyebrows, field errors, small labels.
    static let evrySmall   = nunito(size: 14, weight: .bold)
    /// text-xs: badges, tags, sublabels.
    static let evryCaption = nunito(size: 12, weight: .bold)
    /// text-wordmark: "Evry" beside the plain mark. Tracking +0.03em.
    static let evryWordmark = nunito(size: 24, weight: .heavy)
    /// text-price: plan prices. Tracking -0.025em.
    static let evryPrice   = nunito(size: 48, weight: .heavy)
}

/// Letter-spacing for the type scale, in points at the style's base size.
enum EvryTracking {
    static let h2: CGFloat = -0.48       // -0.015em @ 32
    static let wordmark: CGFloat = 0.72  // +0.03em @ 24
    static let price: CGFloat = -1.2     // -0.025em @ 48
}

enum AppFonts {
    /// Registers every bundled Nunito font file at launch (variable font or the
    /// individual static weights) so `.custom("Nunito", …)` can resolve them —
    /// no Info.plist / UIAppFonts entries required. Safe to call when no font
    /// files are present (it simply registers nothing).
    static func register() {
        let exts = ["ttf", "otf"]
        var urls: [URL] = []
        for ext in exts {
            urls += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil)?
                .filter { $0.lastPathComponent.lowercased().hasPrefix("nunito") } ?? []
        }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
