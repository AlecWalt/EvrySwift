//
//  Theme.swift
//  Evry
//
//  Design tokens ported from the EvryJS webapp (css/index.css :root +
//  js/utils/accentColors.js). Everything that isn't the accent (backgrounds,
//  body text, borders) is a true greyscale neutral; --primary is the app's
//  one accent color and defaults to brand amber. The add-task submit button
//  is the one exception — it always stays gold via the fixed amber tokens,
//  no matter which accent is active.
//

import SwiftUI

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
}

// MARK: - Accent colors (accentColors.js)

struct AccentColorTheme: Identifiable, Equatable {
    let key: String
    let label: String
    let primary: Color
    let hover: Color
    let light: Color      // tint surface in light mode
    let lightDark: Color  // tint surface in dark mode
    let onPrimary: Color  // text/icon color on a primary-filled surface

    var id: String { key }

    static let all: [AccentColorTheme] = [
        AccentColorTheme(key: "default", label: "Amber",  primary: Color(hex: 0xEBC580), hover: Color(hex: 0xDFB567), light: Color(hex: 0xF7ECD6), lightDark: Color(hex: 0x4A3F2A), onPrimary: Color(hex: 0x3E3E3E)),
        AccentColorTheme(key: "ink",     label: "Ink",    primary: Color(hex: 0x3E3E3E), hover: Color(hex: 0x2B2B2B), light: Color(hex: 0xE2E2E2), lightDark: Color(hex: 0x3A3A3A), onPrimary: .white),
        AccentColorTheme(key: "indigo",  label: "Indigo", primary: Color(hex: 0x6366F1), hover: Color(hex: 0x4F46E5), light: Color(hex: 0xE0E7FF), lightDark: Color(hex: 0x312E81), onPrimary: .white),
        AccentColorTheme(key: "violet",  label: "Violet", primary: Color(hex: 0x8B5CF6), hover: Color(hex: 0x7C3AED), light: Color(hex: 0xEDE9FE), lightDark: Color(hex: 0x3B1E73), onPrimary: .white),
        AccentColorTheme(key: "pink",    label: "Pink",   primary: Color(hex: 0xEC4899), hover: Color(hex: 0xDB2777), light: Color(hex: 0xFCE7F3), lightDark: Color(hex: 0x5C1039), onPrimary: .white),
        AccentColorTheme(key: "red",     label: "Red",    primary: Color(hex: 0xEF4444), hover: Color(hex: 0xDC2626), light: Color(hex: 0xFEE2E2), lightDark: Color(hex: 0x450A0A), onPrimary: .white),
        AccentColorTheme(key: "orange",  label: "Orange", primary: Color(hex: 0xF97316), hover: Color(hex: 0xEA580C), light: Color(hex: 0xFFEDD5), lightDark: Color(hex: 0x431407), onPrimary: .white),
        AccentColorTheme(key: "green",   label: "Green",  primary: Color(hex: 0x22C55E), hover: Color(hex: 0x16A34A), light: Color(hex: 0xDCFCE7), lightDark: Color(hex: 0x14532D), onPrimary: .white),
        AccentColorTheme(key: "teal",    label: "Teal",   primary: Color(hex: 0x14B8A6), hover: Color(hex: 0x0D9488), light: Color(hex: 0xCCFBF1), lightDark: Color(hex: 0x134E4A), onPrimary: .white),
        AccentColorTheme(key: "blue",    label: "Blue",   primary: Color(hex: 0x0EA5E9), hover: Color(hex: 0x0284C7), light: Color(hex: 0xE0F2FE), lightDark: Color(hex: 0x0C3A52), onPrimary: .white),
    ]

    static func byKey(_ key: String) -> AccentColorTheme {
        all.first { $0.key == key } ?? all[0]
    }
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

// MARK: - Appearance (persisted theme + accent selection)

@Observable
final class Appearance {
    var themeMode: ThemeMode {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: "theme") }
    }
    var accentKey: String {
        didSet { UserDefaults.standard.set(accentKey, forKey: "accent_color") }
    }

    init() {
        themeMode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .system
        accentKey = UserDefaults.standard.string(forKey: "accent_color") ?? "default"
    }

    var accent: AccentColorTheme { .byKey(accentKey) }

    var preferredColorScheme: ColorScheme? {
        switch themeMode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - Palette (light/dark neutral tokens + accent-derived colors)

struct Palette {
    let dark: Bool
    let accent: AccentColorTheme

    init(dark: Bool, accent: AccentColorTheme) {
        self.dark = dark
        self.accent = accent
    }

    // Neutral greyscale
    var bg: Color      { dark ? Color(hex: 0x1E1E1E) : Color(hex: 0xF7F7F7) }
    var card: Color    { dark ? Color(hex: 0x262626) : .white }
    var hover: Color   { dark ? Color(hex: 0x333333) : Color(hex: 0xEEEEEE) }
    var border: Color  { dark ? Color(hex: 0x404040) : Color(hex: 0xE2E2E2) }
    var text: Color    { dark ? Color(hex: 0xF0F0F0) : Color(hex: 0x3E3E3E) }
    var textSec: Color { dark ? Color(hex: 0xADADAD) : Color(hex: 0x6D6D6D) }
    var textPh: Color  { dark ? Color(hex: 0x7D7D7D) : Color(hex: 0x9C9C9C) }

    // Accent
    var primary: Color      { accent.primary }
    var primaryHover: Color { accent.hover }
    var primaryLight: Color { dark ? accent.lightDark : accent.light }
    var onPrimary: Color    { accent.onPrimary }

    // Fixed brand amber — the add-task submit button never changes with accent.
    static let amber = Color(hex: 0xEBC580)
    static let amberHover = Color(hex: 0xDFB567)
    static let onAmber = Color(hex: 0x3E3E3E)

    // Functional colors (usability signals, separate from accent)
    static let success = Color(hex: 0x22C55E)
    static let danger = Color(hex: 0xEF4444)
    static let warning = Color(hex: 0xF97316)

    var successLight: Color { dark ? Color(hex: 0x14532D) : Color(hex: 0xDCFCE7) }
    var dangerLight: Color  { dark ? Color(hex: 0x450A0A) : Color(hex: 0xFEE2E2) }
    var warningLight: Color { dark ? Color(hex: 0x431407) : Color(hex: 0xFFEDD5) }

    /// Date-chip color coding — overdue rose, today green, tomorrow sand,
    /// this week sky blue, next week violet, later muted grey.
    func dateColor(_ category: DateCategory) -> Color {
        switch category {
        case .overdue:  dark ? Color(hex: 0xE8A0B5) : Color(hex: 0xB04A65)
        case .today:    dark ? Color(hex: 0x6FCFA0) : Color(hex: 0x1A7A55)
        case .tomorrow: dark ? Color(hex: 0xD4AA6E) : Color(hex: 0x8A6230)
        case .week:     dark ? Color(hex: 0x93C5FD) : Color(hex: 0x3A6DB0)
        case .nextweek: dark ? Color(hex: 0xC4B5FD) : Color(hex: 0x6040B8)
        case .later:    textSec
        }
    }
}
