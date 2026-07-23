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
    case inbox, focus, projects, profile

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inbox: "Inbox"
        case .focus: "Focus"
        case .projects: "Projects"
        case .profile: "Profile"
        }
    }

    var icon: String {
        switch self {
        case .inbox: "tray"
        case .focus: "safari"
        case .projects: "folder"
        case .profile: "person"
        }
    }
}

struct GlassTabBar: View {
    @Binding var selection: AppTab
    let palette: Palette

    @Namespace private var indicatorNS

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                let active = selection == tab
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 19, weight: .regular))
                            .scaleEffect(active ? 1.08 : 1)
                        Text(tab.label)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.2)
                    }
                    .foregroundStyle(active ? palette.primary : palette.textPh)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .padding(.bottom, 9)
                    .contentShape(Rectangle())
                    .background {
                        if active {
                            // Sliding active-tab indicator pill
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(palette.primary.opacity(palette.dark ? 0.18 : 0.10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .strokeBorder(palette.primary.opacity(palette.dark ? 0.30 : 0.20), lineWidth: 1)
                                )
                                .padding(4)
                                .matchedGeometryEffect(id: "tab-indicator", in: indicatorNS)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 16)
    }
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
