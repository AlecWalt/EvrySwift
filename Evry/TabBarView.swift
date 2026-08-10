//
//  TabBarView.swift
//  Evry
//
//  Floating liquid-glass tab bar + accent swipe handle, ported from the
//  webapp's renderTabBar/renderSwipeHandle. The webapp faked liquid glass
//  with backdrop-filter CSS; here it's the real thing via glassEffect.
//

import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case inbox, focus, projects, calendar, profile

    var id: String { rawValue }
}

/// The accent-colored pull-up pill that opens quick add — tap or swipe up.
struct SwipeHandle: View {
    let palette: Palette
    let action: () -> Void

    @State private var pull: CGFloat = 0

    var body: some View {
        Capsule()
            .fill(palette.primary)
            .frame(width: 48, height: 4)
            .opacity(0.4 + min(pull / 40, 1) * 0.5)
            .shadow(color: palette.primary.opacity(0.4), radius: 5)
            .scaleEffect(y: 1 + pull / 40, anchor: .bottom)
            .offset(y: -pull)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let raw = -value.translation.height
                        guard raw > 0 else {
                            pull = 0
                            return
                        }
                        // Damped past 30pt, capped at 40 — same feel as the webapp.
                        let damped = raw < 30 ? raw : 30 + (raw - 30) * 0.32
                        pull = min(damped, 40)
                    }
                    .onEnded { value in
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                            pull = 0
                        }
                        if -value.translation.height > 12 {
                            action()
                        }
                    }
            )
            .accessibilityLabel("Add task")
            .accessibilityAddTraits(.isButton)
    }
}
