//
//  InboxDrawer.swift
//  Evry
//
//  The Inbox's swipe layout menu: swiping right on Schedule slides the main
//  screen aside as a Liquid Glass card and reveals this menu behind it on the
//  left (like the Claude app's home). It holds the day's two views, the other
//  spaces, the chat with Evry and the profile.
//
//  The wordmark here is text only — the main card (with Evry's mark) is still
//  on screen beside it, and Evry is never in two places at once.
//

import SwiftUI

struct InboxDrawerMenu: View {
    let palette: Palette
    let mode: InboxMode
    var onSelectMode: (InboxMode) -> Void
    var onSelectTab: (AppTab) -> Void
    var onOpenChat: () -> Void

    @AppStorage("user_name") private var userName = ""

    static let width: CGFloat = 288

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Evry")
                .font(.evryWordmark)
                .tracking(EvryTracking.wordmark)
                .foregroundStyle(palette.text)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 24)

            section("Today")
            row("Schedule", icon: "calendar", selected: mode == .schedule) { onSelectMode(.schedule) }
            row("Tasks", icon: "checkmark.square", selected: mode == .tasks) { onSelectMode(.tasks) }

            section("Spaces")
            row("Habits", icon: "arrow.triangle.2.circlepath") { onSelectTab(.habits) }
            row("Notes", icon: "note.text") { onSelectTab(.notes) }

            section("Assistant")
            row("Chat with Evry", icon: "bubble.left.and.text.bubble.right") { onOpenChat() }

            Spacer(minLength: 0)

            Button { onSelectTab(.profile) } label: {
                HStack(spacing: 12) {
                    Text(initials)
                        .font(.nunito(size: 15, weight: .heavy))
                        .foregroundStyle(Color.evryNavy)
                        .frame(width: 38, height: 38)
                        .background(Color.evrySky, in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text(userName.isEmpty ? "Your profile" : userName)
                            .font(.evryLabel)
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                        Text("Profile and settings")
                            .font(.nunito(size: 13))
                            .foregroundStyle(palette.textMuted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .frame(minHeight: EvrySpace.storeHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle(scale: 0.98))
            .padding(.bottom, 12)
        }
        .frame(width: Self.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var initials: String {
        let words = userName.split(separator: " ")
        guard !words.isEmpty else { return "?" }
        return words.prefix(2).compactMap { $0.first.map(String.init)?.uppercased() }.joined()
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.evrySmall)
            .foregroundStyle(palette.textMuted)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func row(_ title: String, icon: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.nunito(size: 16, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.nunito(size: 16, weight: selected ? .bold : .semibold))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: EvrySpace.tap + 4)
            .background(selected ? palette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The main screen as a solid card that slides aside for the menu — sideways
/// only, never shrinking or reshaping. Its corners are fixed to (about) the
/// display's own radius, with a Liquid Glass rim and a soft navy shadow; at
/// rest those all sit just beyond the screen's edges, so nothing changes as it
/// moves — it simply slides.
struct GlassCardModifier: ViewModifier {
    let progress: CGFloat
    let palette: Palette

    /// Fixed, close to the display's corner radius.
    private let radius: CGFloat = 56

    func body(content: Content) -> some View {
        content
            // Full height, edge to edge: the card's white runs under the status
            // bar and the home indicator, so nothing else shows there.
            .background(palette.bg.ignoresSafeArea())
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background {
                // The glass rim, just outside the card's edge.
                RoundedRectangle(cornerRadius: radius + 6, style: .continuous)
                    .fill(Color.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius + 6, style: .continuous))
                    .padding(-6)
            }
            .shadow(color: Color.evryNavy.opacity(0.16), radius: 24, x: -6, y: 8)
    }
}

/// How far the Inbox's menu is open (0 closed … 1 open). Shared so things on
/// the main screen that live outside the Inbox view — the add handle — can
/// ride along with the card, without the whole app re-rendering every frame.
@Observable
final class InboxDrawerState {
    var progress: CGFloat = 0
}

/// Moves a main-screen element with the Inbox card as it slides aside.
struct DrawerFollower: ViewModifier {
    var active: Bool
    @Environment(InboxDrawerState.self) private var drawer

    func body(content: Content) -> some View {
        content.offset(x: active ? InboxDrawerMenu.width * drawer.progress : 0)
    }
}

// MARK: - Tab bar fade

/// Fades the app's tab bar (the system one behind SwiftUI's TabView) in step
/// with the menu, instead of hiding it — hiding slides it away and reflows the
/// screen. Returns false if no tab bar was found (callers then fall back).
@MainActor
enum TabBarFader {
    @discardableResult
    static func set(alpha: CGFloat, animated: Bool, duration: TimeInterval = 0.3) -> Bool {
        guard let bar = findTabBar() else { return false }
        bar.isUserInteractionEnabled = alpha > 0.99
        if animated {
            UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .curveLinear]) {
                bar.alpha = alpha
            }
        } else {
            bar.alpha = alpha
        }
        return true
    }

    private static func findTabBar() -> UITabBar? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            if let bar = tabBar(in: window.rootViewController) { return bar }
        }
        return nil
    }

    private static func tabBar(in vc: UIViewController?) -> UITabBar? {
        guard let vc else { return nil }
        if let tbc = vc as? UITabBarController { return tbc.tabBar }
        for child in vc.children {
            if let bar = tabBar(in: child) { return bar }
        }
        return nil
    }
}

// MARK: - Date wheel (the menu)

/// The menu behind the Inbox card: a wheel of days to jump to, like setting an
/// alarm in the Clock app — the system wheel, with its clicks and momentum.
/// The card's day follows the wheel as it turns. (The earlier list-style menu,
/// `InboxDrawerMenu`, is kept above in case it's wanted back.)
struct InboxDateWheel: View {
    @Binding var dayOffset: Int
    let palette: Palette

    /// A year either way.
    private static let range = -365...365
    private let cal = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Go to a day")
                    .font(.evryH3)
                    .foregroundStyle(palette.text)
                Spacer()
                if dayOffset != 0 {
                    Button("Today") {
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(EvryMotion.settle) { dayOffset = 0 }
                    }
                    .font(.nunito(size: 15, weight: .bold))
                    .foregroundStyle(palette.onPrimary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(palette.primary, in: Capsule())
                    .frame(minHeight: EvrySpace.tap)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            // Fixed height, so the Today button coming and going never shifts
            // the title or the wheel.
            .frame(height: EvrySpace.tap)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .animation(EvryMotion.settle, value: dayOffset == 0)

            Spacer(minLength: 0)

            Picker("Day", selection: $dayOffset) {
                ForEach(Self.range, id: \.self) { offset in
                    Text(label(for: offset))
                        .font(.nunito(size: 19, weight: offset == 0 ? .heavy : .semibold))
                        .foregroundStyle(palette.text)
                        .tag(offset)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 260)
            .padding(.horizontal, 8)

            Spacer(minLength: 0)
        }
        .frame(width: InboxDrawerMenu.width, alignment: .leading)
        .frame(maxHeight: .infinity)
    }

    private func label(for offset: Int) -> String {
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date())) ?? Date()
            let sameYear = cal.isDate(day, equalTo: Date(), toGranularity: .year)
            return sameYear
                ? day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        }
    }
}
