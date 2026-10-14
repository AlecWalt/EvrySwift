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

/// The main screen as a solid card that slides aside for the menu — sideways
/// only, never shrinking or reshaping. Its corners are fixed to (about) the
/// display's own radius, with a Liquid Glass rim and a soft navy shadow; at
/// rest those all sit just beyond the screen's edges, so nothing changes as it
/// moves — it simply slides.
struct GlassCardModifier: ViewModifier {
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
    /// How far the card slides aside — the width of the menu behind it.
    static let menuWidth: CGFloat = 288
}

// The pieces of the Inbox that follow the menu frame by frame each read
// `InboxDrawerState` themselves, so a drag re-renders only them — never the
// whole Inbox (both pages, both lists, the date wheel).

/// The menu behind the card: fully gone while closed (so VoiceOver never finds
/// it there), and only interactive once the card has slid all the way aside.
struct DrawerMenuVisibility: ViewModifier {
    @Environment(InboxDrawerState.self) private var drawer

    func body(content: Content) -> some View {
        let p = drawer.progress
        content
            .opacity(p <= 0.001 ? 0 : 1)
            .allowsHitTesting(p > 0.98)
            .accessibilityHidden(p < 0.98)
    }
}

/// Slides the main card aside with the menu; while it's open, a tap on the
/// card closes it.
struct DrawerCardSlide: ViewModifier {
    var onClose: () -> Void
    @Environment(InboxDrawerState.self) private var drawer

    func body(content: Content) -> some View {
        content
            .overlay {
                if drawer.progress > 0.02 {
                    Color.white.opacity(0.001)
                        .onTapGesture(perform: onClose)
                        .accessibilityLabel("Close menu")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .offset(x: InboxDrawerState.menuWidth * drawer.progress)
    }
}

/// Fades the tab bar with the menu (easing over a settle, following the finger
/// during a drag) and reports when the menu settles fully open or closed.
struct DrawerTabBarSync: View {
    var settleDuration: Double
    @Binding var settledOpen: Bool
    @Binding var tabBarFades: Bool
    @Environment(InboxDrawerState.self) private var drawer

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: drawer.progress) { old, p in
                // A jump (a settle animation, not a drag frame) eases over.
                let alpha = max(0, 1 - p * 1.4)
                tabBarFades = TabBarFader.set(alpha: alpha, animated: abs(p - old) > 0.08, duration: settleDuration)
                if p >= 0.999 && !settledOpen { settledOpen = true }
                if p <= 0.001 && settledOpen { settledOpen = false }
            }
    }
}

/// The live finger offset while swiping between Schedule and Tasks — in its
/// own observable so drag frames only move the pages, not re-render the Inbox.
@Observable
final class InboxPageDrag {
    var x: CGFloat = 0
}

struct PageDragOffset: ViewModifier {
    let base: CGFloat
    let drag: InboxPageDrag

    func body(content: Content) -> some View {
        content.offset(x: base + drag.x)
    }
}

/// Moves a main-screen element with the Inbox card as it slides aside.
struct DrawerFollower: ViewModifier {
    var active: Bool
    @Environment(InboxDrawerState.self) private var drawer

    func body(content: Content) -> some View {
        content.offset(x: active ? InboxDrawerState.menuWidth * drawer.progress : 0)
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

    /// The bar found last time — looked up once instead of walking every
    /// window's view-controller tree on each drag frame.
    private static weak var cachedBar: UITabBar?

    private static func findTabBar() -> UITabBar? {
        if let bar = cachedBar, bar.window != nil { return bar }
        cachedBar = searchTabBar()
        return cachedBar
    }

    private static func searchTabBar() -> UITabBar? {
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
/// The card's day follows the wheel as it turns.
struct InboxDateWheel: View {
    @Binding var dayOffset: Int
    let palette: Palette

    /// A year either way — widened to reach the current day if a swipe or a
    /// jump to a task has gone further, so the wheel always has its row.
    private var range: ClosedRange<Int> { min(-365, dayOffset)...max(365, dayOffset) }
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
                ForEach(range, id: \.self) { offset in
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
        .frame(width: InboxDrawerState.menuWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
    }

    /// The wheel's 731 row labels, built once per calendar day rather than
    /// formatting every date on each render.
    private static var labelCache: (day: Date, labels: [Int: String])?

    private func label(for offset: Int) -> String {
        let today = cal.startOfDay(for: Date())
        if let cache = Self.labelCache, cache.day == today, let label = cache.labels[offset] { return label }
        if Self.labelCache?.day != today { Self.labelCache = (today, [:]) }
        let label = makeLabel(for: offset)
        Self.labelCache?.labels[offset] = label
        return label
    }

    private func makeLabel(for offset: Int) -> String {
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
