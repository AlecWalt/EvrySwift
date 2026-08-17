//
//  MembershipView.swift
//  Evry
//

import SwiftUI
import UIKit

// MARK: - Animated feature promo

struct MembershipPromoView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @State private var currentPage = 0
    @State private var showPlans = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Logo + pro badge header
                VStack(spacing: 8) {
                    Image("TextLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 32)

                    Text("Included with Pro")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(palette.primaryLight, in: Capsule())
                }
                .padding(.top, 24)
                .padding(.bottom, 4)

                // Pages — each page owns its animation + title + description,
                // so swiping anywhere on a page (including the text) advances cards.
                TabView(selection: $currentPage) {
                    PromoCloudPage(palette: palette).tag(0)
                    PromoCalendarPage(palette: palette).tag(1)
                    PromoVoicePage(palette: palette).tag(2)
                    PromoAIPage(palette: palette).tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)

                // Pill-style page dots
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule()
                            .fill(i == currentPage ? palette.primary : palette.border)
                            .frame(width: i == currentPage ? 24 : 8, height: 8)
                            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: currentPage)
                    }
                }
                .padding(.bottom, 24)

                // CTA
                VStack(spacing: 12) {
                    Button {
                        if currentPage < 3 {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                                currentPage += 1
                            }
                        } else {
                            showPlans = true
                        }
                    } label: {
                        Text(currentPage < 3 ? "Next" : "Unlock Pro")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(palette.onPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(palette.primary, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                    .buttonStyle(PressScaleStyle())

                    Button("Maybe later") { dismiss() }
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textSec)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
            }

            // Close button
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textSec)
                    .frame(width: 30, height: 30)
                    .background(palette.hover, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        // task(id:) cancels and restarts whenever currentPage changes,
        // so a manual swipe always resets the auto-advance timer.
        .task(id: currentPage) {
            guard currentPage < 3 else { return }
            do {
                try await Task.sleep(for: .seconds(6.0))
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    currentPage += 1
                }
            } catch {}
        }
        .fullScreenCover(isPresented: $showPlans) { MembershipPlansView() }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
    }
}

// MARK: - Page 1: Cloud Sync

private struct PromoCloudPage: View {
    let palette: Palette
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(palette.primary.opacity(0.11 - Double(i) * 0.03), lineWidth: 1.5)
                        .frame(width: 90 + CGFloat(i) * 50)
                        .scaleEffect(pulsing ? 1.12 + CGFloat(i) * 0.04 : 1.0)
                        .animation(
                            .easeInOut(duration: 2.0 + Double(i) * 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.5),
                            value: pulsing
                        )
                }
                Image(systemName: "icloud.fill")
                    .font(.system(size: 70))
                    .foregroundStyle(palette.primary)
                    .scaleEffect(pulsing ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: pulsing)
                    .offset(y: -50)
                HStack(spacing: 26) {
                    PromoPacket(delay: 0.0, icon: "doc.fill",    palette: palette)
                    PromoPacket(delay: 0.9, icon: "list.bullet", palette: palette)
                    PromoPacket(delay: 1.8, icon: "folder.fill", palette: palette)
                }
                HStack(spacing: 22) {
                    Image(systemName: "iphone").font(.system(size: 25))
                    Image(systemName: "ipad.landscape").font(.system(size: 28))
                    Image(systemName: "laptopcomputer").font(.system(size: 25))
                }
                .foregroundStyle(palette.textSec.opacity(0.55))
                .offset(y: 90)
            }
            .frame(height: 220)

            promoText(
                title: "Cloud Syncing",
                desc: "Tasks and projects sync instantly across all your Apple devices. Start on iPhone, finish on iPad.",
                palette: palette
            )
        }
        .onAppear { pulsing = true }
    }
}

private struct PromoPacket: View {
    let delay: Double
    let icon: String
    let palette: Palette
    @State private var yOffset: CGFloat = 55
    @State private var opacity: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(palette.primaryLight)
            .frame(width: 36, height: 36)
            .overlay(Image(systemName: icon).font(.system(size: 14)).foregroundStyle(palette.primary))
            .shadow(color: palette.primary.opacity(0.18), radius: 5, y: 2)
            .offset(y: yOffset)
            .opacity(opacity)
            .task {
                do {
                    while true {
                        try await Task.sleep(for: .seconds(delay))
                        yOffset = 55
                        try await Task.sleep(for: .milliseconds(16))
                        withAnimation(.easeIn(duration: 0.22)) { opacity = 1 }
                        withAnimation(.easeInOut(duration: 2.0)) { yOffset = -55 }
                        try await Task.sleep(for: .seconds(1.65))
                        withAnimation(.easeOut(duration: 0.35)) { opacity = 0 }
                        try await Task.sleep(for: .seconds(0.75))
                    }
                } catch {}
            }
    }
}

// MARK: - Page 2: Calendar Integration

private struct PromoCalendarPage: View {
    let palette: Palette
    @State private var visibleDots: [Int: Color] = [:]

    private let events: [(Int, Color)] = [
        (2,  Color(hex: 0x4285F4)),
        (5,  Color(hex: 0x34C759)),
        (8,  Color(hex: 0xFF3B30)),
        (11, Color(hex: 0x6366F1)),
        (14, Color(hex: 0x4285F4)),
        (17, Color(hex: 0xFF9500)),
        (20, Color(hex: 0x34C759)),
        (24, Color(hex: 0xEC4899)),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("July 2026")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(palette.text)
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(
                            [Color(hex: 0x4285F4), Color(hex: 0xFF3B30), Color(hex: 0x34C759)],
                            id: \.self
                        ) { c in Circle().fill(c).frame(width: 8, height: 8) }
                    }
                }
                HStack(spacing: 0) {
                    ForEach(["S","M","T","W","T","F","S"], id: \.self) { d in
                        Text(d)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(palette.textSec)
                            .frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7),
                    spacing: 4
                ) {
                    ForEach(0..<28, id: \.self) { i in
                        let isToday = (i == 13)
                        let dotColor = visibleDots[i]
                        ZStack(alignment: .bottom) {
                            ZStack {
                                if isToday { Circle().fill(palette.primary).frame(width: 24, height: 24) }
                                Text("\(i + 1)")
                                    .font(.system(size: 10, weight: isToday ? .bold : .regular))
                                    .foregroundStyle(isToday ? palette.onPrimary : palette.text)
                            }
                            .frame(height: 26)
                            Circle()
                                .fill(dotColor ?? .clear)
                                .frame(width: 4, height: 4)
                                .scaleEffect(dotColor != nil ? 1 : 0)
                                .opacity(dotColor != nil ? 1 : 0)
                                .animation(.spring(response: 0.28, dampingFraction: 0.55), value: dotColor != nil)
                                .offset(y: 2)
                        }
                        .frame(height: 30)
                    }
                }
            }
            .padding(14)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
            .padding(.horizontal, 28)
            .frame(height: 220, alignment: .center)

            promoText(
                title: "Calendar Integration",
                desc: "Apple, Google, and Outlook events appear right alongside your Evry tasks — no app switching.",
                palette: palette
            )
        }
        .task {
            do {
                while true {
                    visibleDots = [:]
                    try await Task.sleep(for: .milliseconds(500))
                    for (cell, color) in events {
                        try await Task.sleep(for: .milliseconds(260))
                        visibleDots[cell] = color
                    }
                    try await Task.sleep(for: .seconds(2.0))
                }
            } catch {}
        }
    }
}

// MARK: - Page 3: Voice Dictation

private struct PromoVoicePage: View {
    let palette: Palette
    @State private var pulsing = false
    @State private var textLines = 0

    private let taskLines = [
        "Schedule team standup for 9am",
        "Review product mockups today",
        "Send client proposal by Friday",
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                // Mic with glow rings
                ZStack {
                    ForEach(0..<2, id: \.self) { i in
                        Circle()
                            .fill(palette.primary.opacity(pulsing ? 0.08 - Double(i) * 0.03 : 0))
                            .frame(width: 58 + CGFloat(i) * 30)
                            .animation(
                                .easeInOut(duration: 1.2 + Double(i) * 0.35)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.3),
                                value: pulsing
                            )
                    }
                    Circle()
                        .fill(palette.primary)
                        .frame(width: 58, height: 58)
                        .overlay(
                            Image(systemName: "mic.fill")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(palette.onPrimary)
                        )
                        .scaleEffect(pulsing ? 1.06 : 1.0)
                        .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulsing)
                }
                .frame(height: 96)

                // Waveform bars
                HStack(spacing: 3) {
                    ForEach(0..<13, id: \.self) { i in
                        PromoWaveBar(index: i, palette: palette)
                    }
                }
                .frame(height: 38)

                // Transcription lines
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(taskLines.prefix(textLines).enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.success)
                            Text(line)
                                .font(.system(size: 12))
                                .foregroundStyle(palette.text)
                                .lineLimit(1)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 68)
                .padding(.horizontal, 20)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: textLines)
            }
            .frame(height: 220, alignment: .top)

            promoText(
                title: "Voice Dictation",
                desc: "Brain dump at full speed. Speak and Evry captures every task instantly — no typing required.",
                palette: palette
            )
        }
        .onAppear { pulsing = true }
        .task {
            do {
                while true {
                    withAnimation { textLines = 0 }
                    try await Task.sleep(for: .milliseconds(500))
                    for i in 1...3 {
                        try await Task.sleep(for: .seconds(1.1))
                        withAnimation { textLines = i }
                    }
                    try await Task.sleep(for: .seconds(1.2))
                }
            } catch {}
        }
    }
}

private struct PromoWaveBar: View {
    let index: Int
    let palette: Palette
    @State private var barHeight: CGFloat = 6
    private var duration: Double { 0.18 + Double(index % 5) * 0.04 }

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(palette.primary.opacity(0.45 + 0.35 * Double(index % 2)))
            .frame(width: 3.5, height: barHeight)
            .animation(.easeInOut(duration: duration), value: barHeight)
            .task {
                do {
                    try await Task.sleep(for: .milliseconds(index * 35))
                    while true {
                        barHeight = CGFloat.random(in: 4...38)
                        try await Task.sleep(for: .milliseconds(Int(duration * 1000) + Int.random(in: 60...140)))
                    }
                } catch {}
            }
    }
}

// MARK: - Page 4: AI Project Planning

private struct PromoAIPage: View {
    let palette: Palette
    @State private var pulsing = false
    @State private var cardOpacities = Array(repeating: 0.0, count: 3)
    @State private var cardOffsets   = Array(repeating: CGFloat(-32), count: 3)
    @State private var cardScales    = Array(repeating: CGFloat(0.88), count: 3)

    private let accents: [Color] = [
        Color(hex: 0x4285F4),
        Color(hex: 0x34C759),
        Color(hex: 0xFF9500),
    ]
    // (primary line width, secondary line width) for skeleton text bars
    private let lineWidths: [(CGFloat, CGFloat)] = [(118, 72), (88, 132), (142, 60)]

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Cards slide down from the sparkle one by one
                VStack(spacing: 9) {
                    Spacer().frame(height: 76)
                    ForEach(0..<3, id: \.self) { i in
                        HStack(spacing: 0) {
                            // Colored left accent bar
                            Rectangle()
                                .fill(accents[i])
                                .frame(width: 4)
                            // Skeleton placeholder text lines
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(palette.textPh.opacity(0.55))
                                    .frame(width: lineWidths[i].0, height: 8)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(palette.textPh.opacity(0.3))
                                    .frame(width: lineWidths[i].1, height: 6)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            Spacer()
                            // Status dot
                            Circle()
                                .fill(accents[i])
                                .frame(width: 8, height: 8)
                                .padding(.trailing, 14)
                        }
                        .background(palette.card)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(accents[i].opacity(0.28), lineWidth: 1.5)
                        )
                        .shadow(color: accents[i].opacity(0.14), radius: 6, y: 2)
                        .opacity(cardOpacities[i])
                        .offset(y: cardOffsets[i])
                        .scaleEffect(cardScales[i])
                    }
                }
                .padding(.horizontal, 22)

                // Sparkle — anchored at top
                ZStack {
                    ForEach(0..<2, id: \.self) { i in
                        Circle()
                            .fill(palette.primary.opacity(pulsing ? (0.09 - Double(i) * 0.035) : 0))
                            .frame(width: 50 + CGFloat(i) * 26)
                            .animation(
                                .easeInOut(duration: 1.6 + Double(i) * 0.4)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.4),
                                value: pulsing
                            )
                    }
                    Image(systemName: "sparkles")
                        .font(.system(size: 28))
                        .foregroundStyle(palette.primary)
                        .scaleEffect(pulsing ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulsing)
                }
                .frame(height: 76)
            }
            .frame(height: 220)

            promoText(
                title: "AI Project Planning",
                desc: "Describe your goal in one sentence. AI builds the full, actionable project plan automatically.",
                palette: palette
            )
        }
        .onAppear { pulsing = true }
        .task {
            do {
                while true {
                    cardOpacities = Array(repeating: 0.0, count: 3)
                    cardOffsets   = Array(repeating: CGFloat(-32), count: 3)
                    cardScales    = Array(repeating: CGFloat(0.88), count: 3)
                    try await Task.sleep(for: .milliseconds(700))

                    for i in 0..<3 {
                        try await Task.sleep(for: .milliseconds(480))
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.76)) {
                            cardOpacities[i] = 1
                            cardOffsets[i]   = 0
                            cardScales[i]    = 1
                        }
                    }

                    try await Task.sleep(for: .seconds(2.5))
                    withAnimation(.easeOut(duration: 0.35)) {
                        cardOpacities = Array(repeating: 0.0, count: 3)
                        cardScales    = Array(repeating: CGFloat(0.94), count: 3)
                    }
                    try await Task.sleep(for: .milliseconds(550))
                }
            } catch {}
        }
    }
}

// MARK: - Shared page text block

private func promoText(title: String, desc: String, palette: Palette) -> some View {
    VStack(spacing: 8) {
        Text(title)
            .font(.system(size: 23, weight: .bold))
            .foregroundStyle(palette.text)
            .multilineTextAlignment(.center)
        Text(desc)
            .font(.system(size: 15))
            .foregroundStyle(palette.textSec)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 28)
    .padding(.top, 36)
    .padding(.bottom, 8)
}

// MARK: - Full plans sheet

struct MembershipPlansView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @AppStorage("membership_plan") private var membershipPlan = ""
    @State private var isYearly = true

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    /// Small sparkles slowly orbiting each corner — premium, playful, and far
    /// less distracting than a big animated gradient.
    private var glowBackground: some View {
        ZStack {
            palette.bg
            // Nudged down so the top corners clear the nav bar and read clearly.
            CornerSparkles(palette: palette)
                .offset(y: 70)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var salePrice: String     { isYearly ? "$5" : "$7" }
    private var regularPrice: String  { isYearly ? "$7" : "$9" }
    private var savingsNote: String   { isYearly ? "Billed $60/yr · Lifetime early adopter price" : "Billed monthly · Lifetime early adopter price" }

    private let proFeatures = [
        "Cloud Syncing",
        "Up to 1,000 Notes",
        "Expanded Color Themes",
        "Intelligent Calendar",
        "Unlimited Brain Dump",
        "Voice Dictation",
        "Task Reminders and Deadlines",
        "Unlimited Pomodoros",
    ]

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 24) {

                    // Header
                    VStack(spacing: 6) {
                        Image("EvryPro")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 76)
                        Text("Everything you need to stay on top of it all.")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textSec)
                            .multilineTextAlignment(.center)
                    }

                    // Billing toggle
                    HStack(spacing: 0) {
                        BillingToggleTab(label: "Monthly", badge: nil,       active: !isYearly, palette: palette) { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isYearly = false } }
                        BillingToggleTab(label: "Yearly",  badge: "20% OFF", active:  isYearly, palette: palette) { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isYearly = true  } }
                    }
                    .padding(4)
                    .background(palette.hover, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // Pro card
                    VStack(alignment: .leading, spacing: 18) {

                        // Price row
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(regularPrice + "/mo")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(palette.textSec)
                                    .strikethrough(true, color: palette.textSec)
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(salePrice)
                                        .font(.system(size: 44, weight: .bold))
                                        .foregroundStyle(palette.primary)
                                        .contentTransition(.numericText())
                                    Text("/mo")
                                        .font(.system(size: 16))
                                        .foregroundStyle(palette.textSec)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("EARLY ADOPTER")
                                    .font(.system(size: 9, weight: .bold))
                                    .tracking(0.5)
                                    .foregroundStyle(palette.primary)
                                Text("LIFETIME PRICE")
                                    .font(.system(size: 9, weight: .bold))
                                    .tracking(0.5)
                                    .foregroundStyle(palette.primary)
                                if isYearly {
                                    Text("$60 / year")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(palette.textSec)
                                }
                            }
                        }

                        Text(savingsNote)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSec)

                        Divider().background(palette.border)

                        // Feature list
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(proFeatures, id: \.self) { feature in
                                HStack(spacing: 10) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(palette.primary)
                                    Text(feature)
                                        .font(.system(size: 14))
                                        .foregroundStyle(palette.text)
                                }
                            }
                        }
                    }
                    .padding(20)
                    .background(palette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(palette.primary, lineWidth: 2)
                    )

                    // CTA
                    Button {
                        membershipPlan = "pro"
                        dismiss()
                    } label: {
                        Text("Get Pro — \(salePrice)/mo")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(palette.onPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(palette.primary, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                    .buttonStyle(PressScaleStyle())

                    Text("Cancel anytime. Pricing in USD.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSec)
                        .padding(.bottom, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .background(glowBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

// MARK: - Corner sparkles

/// A cluster of small sparkles orbiting each of the four screen corners, each
/// corner spinning at its own speed/direction while individual sparkles twinkle.
private struct CornerSparkles: View {
    let palette: Palette

    var body: some View {
        GeometryReader { geo in
            ZStack {
                SparkleCluster(palette: palette, duration: 26, clockwise: true)
                    .position(x: 8, y: 8)
                SparkleCluster(palette: palette, duration: 32, clockwise: false)
                    .position(x: geo.size.width - 8, y: 14)
                SparkleCluster(palette: palette, duration: 30, clockwise: false)
                    .position(x: 10, y: geo.size.height - 10)
                SparkleCluster(palette: palette, duration: 24, clockwise: true)
                    .position(x: geo.size.width - 10, y: geo.size.height - 6)
            }
        }
    }
}

private struct SparkleCluster: View {
    let palette: Palette
    let duration: Double
    let clockwise: Bool

    @State private var spin = false

    // (angle in radians, orbit radius, symbol size, twinkle delay)
    private let sparkles: [(Double, CGFloat, CGFloat, Double)] = [
        (0.3, 46, 13, 0.0),
        (1.5, 74, 9,  0.6),
        (2.6, 40, 16, 1.1),
        (3.7, 88, 8,  0.3),
        (4.6, 58, 11, 0.9),
        (5.6, 96, 10, 0.4),
    ]

    var body: some View {
        ZStack {
            ForEach(Array(sparkles.enumerated()), id: \.offset) { _, s in
                SparkleDot(palette: palette, angle: s.0, radius: s.1, size: s.2, delay: s.3)
            }
        }
        .rotationEffect(.degrees(spin ? (clockwise ? 360 : -360) : 0))
        .animation(.linear(duration: duration).repeatForever(autoreverses: false), value: spin)
        .onAppear { spin = true }
    }
}

private struct SparkleDot: View {
    let palette: Palette
    let angle: Double
    let radius: CGFloat
    let size: CGFloat
    let delay: Double

    @State private var on = false

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size))
            .foregroundStyle(palette.primary)
            .scaleEffect(on ? 1.0 : 0.45)
            .opacity(on ? 0.85 : 0.2)
            .offset(x: CGFloat(cos(angle)) * radius, y: CGFloat(sin(angle)) * radius)
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true).delay(delay), value: on)
            .onAppear { on = true }
    }
}

// MARK: - Billing toggle tab

private struct BillingToggleTab: View {
    let label: String
    let badge: String?
    let active: Bool
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: 0x34C759), in: Capsule())
                }
            }
            .foregroundStyle(active ? palette.onPrimary : palette.textSec)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                active ? palette.primary : Color.clear,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
