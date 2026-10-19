//
//  CoreView.swift
//  Evry
//
//  The Core, visible and editable: the crystal (the user-facing visualizer on
//  the Profile page, behind the photo), a progress card, and the Core sheet —
//  consent switches, the person's own preferences, everything learned in plain
//  words with rename / confirm / delete on each entry, and a full reset.
//

import SwiftUI

// MARK: - Crystal

/// A faceted crystal that builds itself as the Core fills: an empty outline at
/// 0%, one more fragment for every twelfth of progress, from the base up,
/// complete at 100%.
struct CoreCrystal: View {
    let fraction: Double
    let palette: Palette
    /// All bright sky — no navy anywhere (the flying XP crystals).
    var bright = false

    /// Unit-square points of the crystal: a point, three front faces, a point.
    private static let top = CGPoint(x: 0.5, y: 0)
    private static let bottom = CGPoint(x: 0.5, y: 1)
    private static let shoulders = [CGPoint(x: 0.14, y: 0.30), CGPoint(x: 0.36, y: 0.25),
                                    CGPoint(x: 0.64, y: 0.25), CGPoint(x: 0.86, y: 0.30)]
    private static let waist = [CGPoint(x: 0.14, y: 0.52), CGPoint(x: 0.36, y: 0.50),
                                CGPoint(x: 0.64, y: 0.50), CGPoint(x: 0.86, y: 0.52)]
    private static let hips = [CGPoint(x: 0.14, y: 0.72), CGPoint(x: 0.36, y: 0.76),
                               CGPoint(x: 0.64, y: 0.76), CGPoint(x: 0.86, y: 0.72)]

    struct Fragment: Identifiable {
        let id: Int
        let points: [CGPoint]
        /// 0 left face, 1 centre, 2 right.
        let column: Int
        /// 0 base point … 3 top point.
        let row: Int
    }

    /// In build order: each row centre-first, rows from the base up.
    static let fragments: [Fragment] = {
        var out: [Fragment] = []
        for row in 0..<4 {
            for column in [1, 0, 2] {
                let a = column, b = column + 1
                let points: [CGPoint]
                switch row {
                case 0: points = [bottom, hips[a], hips[b]]
                case 1: points = [waist[a], waist[b], hips[b], hips[a]]
                case 2: points = [shoulders[a], shoulders[b], waist[b], waist[a]]
                default: points = [top, shoulders[a], shoulders[b]]
                }
                out.append(Fragment(id: out.count, points: points, column: column, row: row))
            }
        }
        return out
    }()

    private static let silhouette = [top, shoulders[3], hips[3], bottom, hips[0], shoulders[0]]

    /// Fragments built so far.
    static func built(_ fraction: Double) -> Int {
        min(fragments.count, max(0, Int((fraction * Double(fragments.count) + 0.0001).rounded(.down))))
    }

    var body: some View {
        let built = Self.built(fraction)
        ZStack {
            // The empty crystal: every facet edge, faint.
            if !bright {
                ForEach(Self.fragments) { f in
                    CrystalFacet(points: f.points)
                        .stroke(palette.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                }
            }
            ForEach(Self.fragments.prefix(built)) { f in
                CrystalFacet(points: f.points)
                    .fill(shade(f))
                    .overlay(CrystalFacet(points: f.points)
                        .stroke(Color.evryWhite.opacity(bright ? 0.85 : 0.65),
                                style: StrokeStyle(lineWidth: 0.75, lineJoin: .round)))
                    .transition(.scale(scale: 0.4, anchor: centroid(f)).combined(with: .opacity))
            }
            CrystalFacet(points: Self.silhouette)
                .stroke(bright ? Color.evrySky : palette.primary.opacity(built == Self.fragments.count ? 0.9 : 0.55),
                        style: StrokeStyle(lineWidth: 1.75, lineJoin: .round))
        }
        .aspectRatio(0.64, contentMode: .fit)
        .animation(EvryMotion.pop, value: built)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Core crystal")
        .accessibilityValue("\(built) of \(Self.fragments.count) pieces")
    }

    /// Sky and navy only: left faces deepest, centre brightest, the top caps
    /// lifted toward white so the crystal reads as lit from above.
    private func shade(_ f: Fragment) -> Color {
        if bright {
            // Sky throughout, lifted toward white on the right faces and top.
            let lift = [0.0, 0.08, 0.2][f.column] + [0, 0, 0.06, 0.25][f.row]
            return Color.evrySky.mix(with: .evryWhite, by: min(0.45, lift))
        }
        let base = [0.5, 0.05, 0.3][f.column]
        let lift = [0.1, 0, -0.08, -0.2][f.row]
        let v = base + lift
        return v >= 0 ? Color.evrySky.mix(with: .evryNavy, by: v) : Color.evrySky.mix(with: .evryWhite, by: min(0.7, -v * 2))
    }

    private func centroid(_ f: Fragment) -> UnitPoint {
        let n = Double(f.points.count)
        return UnitPoint(x: f.points.reduce(0) { $0 + $1.x } / n, y: f.points.reduce(0) { $0 + $1.y } / n)
    }
}

private struct CrystalFacet: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        func p(_ u: CGPoint) -> CGPoint { CGPoint(x: rect.minX + u.x * rect.width, y: rect.minY + u.y * rect.height) }
        path.move(to: p(first))
        for u in points.dropFirst() { path.addLine(to: p(u)) }
        path.closeSubpath()
        return path
    }
}

/// The crystal in the same medallion as the profile photo — a white disc
/// ringed by a progress track — so the two can trade places on the carousel.
struct CoreCrystalBadge: View {
    let palette: Palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var core: EvryCore { .shared }

    var body: some View {
        let fraction = core.progress.overall
        let complete = core.progress.isComplete
        ZStack {
            Circle()
                .fill(palette.card)
                .frame(width: 148, height: 148)
                .overlay(Circle().strokeBorder(Color.evryWhite, lineWidth: 6))
            CoreCrystal(fraction: fraction, palette: palette)
                .frame(height: 96)
            Circle()
                .stroke(Color.evryWhite, lineWidth: 12)
                .frame(width: 162, height: 162)
                .shadow(color: Color.evryNavy.opacity(palette.dark ? 0.35 : 0.14), radius: 5, y: 2)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(Color.evrySky, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 162, height: 162)
                .animation(EvryMotion.settle, value: fraction)
            if complete {
                Image(systemName: "sparkle")
                    .font(.nunito(size: 18, weight: .bold))
                    .foregroundStyle(Color.evrySky)
                    .offset(x: 34, y: -40)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 174, height: 174)
        .overlay(alignment: .bottom) {
            Text("Core · \(Int((fraction * 100).rounded()))%")
                .font(.nunito(size: 14, weight: .heavy))
                .foregroundStyle(Color.evryNavy)
                .monospacedDigit()
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.evrySky, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.evryWhite, lineWidth: 2))
                .offset(y: 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your Core")
        .accessibilityValue(complete ? "Complete" : "\(Int((fraction * 100).rounded())) percent built")
    }
}

// MARK: - Progress card (developer view)

/// Overall progress as a ring, and one bar per module. Tap to open the Core.
struct CoreProgressCard: View {
    let palette: Palette
    /// Nil inside the Core sheet itself, where the card is just a summary.
    var onOpen: (() -> Void)?

    private var core: EvryCore { .shared }

    var body: some View {
        let label = "Your Core, \(Int((core.progress.overall * 100).rounded())) percent"
        if let onOpen {
            Button(action: onOpen) { content }
                .buttonStyle(PressScaleStyle(scale: 0.99))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityHint("Shows what Evry has learned and lets you change it")
        } else {
            // A plain summary (inside the Core sheet) — not a dimmed button.
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }

    private var content: some View {
        let progress = core.progress
        return VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    CoreProgressRing(fraction: progress.overall, palette: palette)
                        .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progress.isComplete ? "Fully tuned to you" : "Still learning your patterns")
                            .font(.nunito(size: 15, weight: .bold))
                            .foregroundStyle(palette.text)
                        Text(progress.isComplete
                             ? "Evry has enough to fit suggestions to how you work."
                             : "Evry fits itself to you as you use the app. Only summaries are kept, on this device.")
                            .font(.nunito(size: 13))
                            .foregroundStyle(palette.textSec)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if onOpen != nil {
                        Image(systemName: "chevron.right")
                            .font(.nunito(size: 12, weight: .bold))
                            .foregroundStyle(palette.textMuted)
                            .accessibilityHidden(true)
                    }
                }
                VStack(spacing: 10) {
                    ForEach(progress.modules) { module in
                        CoreModuleBar(module: module, palette: palette)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

struct CoreProgressRing: View {
    let fraction: Double
    let palette: Palette

    var body: some View {
        ZStack {
            Circle().stroke(palette.skySoft, lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(palette.primary, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.nunito(size: 14, weight: .heavy))
                .foregroundStyle(palette.text)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .animation(EvryMotion.settle, value: fraction)
    }
}

private struct CoreModuleBar: View {
    let module: CoreProgress.Module
    let palette: Palette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: module.kind.icon)
                .font(.nunito(size: 13, weight: .bold))
                .foregroundStyle(module.isActive ? palette.primary : palette.textPh)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(module.kind.label)
                .font(.nunito(size: 14, weight: .bold))
                .foregroundStyle(module.isActive ? palette.text : palette.textMuted)
                .frame(width: 64, alignment: .leading)
            if module.isActive {
                ProgressBarView(fraction: module.fraction, palette: palette)
                    .frame(height: 6)
                Text("\(Int((module.fraction * 100).rounded()))%")
                    .font(.nunito(size: 13, weight: .heavy))
                    .foregroundStyle(palette.text)
                    .monospacedDigit()
                    .frame(minWidth: 38, alignment: .trailing)
            } else {
                Text(module.hint)
                    .font(.nunito(size: 13))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(module.kind.label)
        .accessibilityValue(module.isActive ? "\(Int((module.fraction * 100).rounded())) percent" : module.hint)
    }
}

// MARK: - Core sheet

struct CoreSheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @State private var askDeletePlaces = false
    @State private var askDeleteFacts = false
    @State private var askReset = false
    @State private var renaming: CoreReadout.Item?
    @State private var renameText = ""
    @State private var newGoal = ""
    @State private var newSuppressed = ""
    @State private var addingQuiet = false
    @State private var quietStart = CoreSheet.time(22)
    @State private var quietEnd = CoreSheet.time(7)

    private var core: EvryCore { .shared }
    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        let profile = core.profile
        let view = core.getView()
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    summary
                    consentSection(profile)
                    preferencesSection(profile.declared)
                    ForEach(view.sections) { section in
                        readoutSection(section, profile: profile)
                    }
                    resetButton
                    Text("Your Core stays on this device. Only short summaries are kept — never your note text or a trail of where you've been.")
                        .font(.nunito(size: 13))
                        .foregroundStyle(palette.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, EvrySpace.gutter)
                .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(palette.bg)
            .navigationTitle("Your Core")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .evryConfirm(isPresented: $askDeletePlaces, title: "Delete learned places?",
                     message: "Places stop being learned now. You can also forget the ones already learned.",
                     confirmTitle: "Delete places", cancelTitle: "Keep them") {
            core.clearLocationData()
        }
        .evryConfirm(isPresented: $askDeleteFacts, title: "Delete note details?",
                     message: "Notes stop being read now. You can also forget the details already found.",
                     confirmTitle: "Delete details", cancelTitle: "Keep them") {
            core.setNoteConsent(false, deleteData: true)
        }
        .evryConfirm(isPresented: $askReset, title: "Reset your Core?",
                     message: "Evry forgets everything it has learned and your preferences here, and starts fresh.",
                     confirmTitle: "Reset") {
            core.reset()
        }
        .alert("Rename place", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if case .place(let id) = renaming?.ref { core.renamePlace(id, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave it empty to let Evry name it.")
        }
    }

    // MARK: Summary

    private var summary: some View {
        CoreProgressCard(palette: palette, onOpen: nil)
            .evryField(palette, cornerRadius: EvryRadius.field)
    }

    // MARK: Consent

    private func consentSection(_ p: CoreProfile) -> some View {
        VStack(spacing: 12) {
            sectionLabel("What Evry learns from")
            toggleRow("Places", icon: "mappin.and.ellipse",
                      subtitle: locationSubtitle(p.meta.consent.location),
                      isOn: Binding(get: { p.meta.consent.location }, set: { on in
                          core.setLocationConsent(on)
                          if !on && !core.profile.places.isEmpty { askDeletePlaces = true }
                      }))
            toggleRow("Note details", icon: "note.text",
                      subtitle: "Picks out appointments, projects and people — never keeps the text",
                      isOn: Binding(get: { p.meta.consent.noteExtraction }, set: { on in
                          if on || core.profile.facts.isEmpty { core.setNoteConsent(on) }
                          else { core.setNoteConsent(false); askDeleteFacts = true }
                      }))
        }
    }

    private func locationSubtitle(_ on: Bool) -> String {
        guard on else { return "Learns your usual places from a rough location, only when you open Evry or finish a task" }
        switch core.locationAccess {
        case .granted: return "On. A rough location (about 100 m), never a route"
        case .notAsked: return "Waiting for location access"
        case .denied: return "Location access is off in Settings, so nothing is collected"
        }
    }

    // MARK: Preferences

    private func preferencesSection(_ d: CoreDeclared) -> some View {
        VStack(spacing: 12) {
            sectionLabel("Your preferences")

            // Nudge level
            VStack(alignment: .leading, spacing: 10) {
                Text("How much Evry suggests")
                    .font(.evryBody)
                    .foregroundStyle(palette.text)
                HStack(spacing: 8) {
                    ForEach(CoreDeclared.NudgeLevel.allCases) { level in
                        let selected = d.nudgeLevel == level
                        Button {
                            core.updateDeclared { $0.nudgeLevel = level }
                        } label: {
                            Text(level.label)
                                .font(.nunito(size: 14, weight: .bold))
                                .foregroundStyle(selected ? palette.onPrimary : palette.text)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(selected ? palette.primary : palette.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(selected ? Color.clear : palette.border, lineWidth: 1))
                        }
                        .buttonStyle(PressScaleStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .evryField(palette)

            // Quiet hours
            listCard(title: "Quiet hours", empty: "No quiet hours",
                     items: d.quietHours.map { ($0.id, "\($0.start) – \($0.end)", CoreEntryRef.quietHours($0.id)) }) {
                if addingQuiet {
                    HStack {
                        DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute).labelsHidden()
                        Text("to").font(.nunito(size: 14)).foregroundStyle(palette.textSec)
                        DatePicker("To", selection: $quietEnd, displayedComponents: .hourAndMinute).labelsHidden()
                        Spacer()
                        Button("Add") {
                            let q = CoreDeclared.QuietHours(start: Self.hhmm(quietStart), end: Self.hhmm(quietEnd))
                            core.updateDeclared { $0.quietHours.append(q) }
                            addingQuiet = false
                        }
                        .font(.nunito(size: 15, weight: .bold))
                    }
                } else {
                    Button { addingQuiet = true } label: {
                        Label("Add quiet hours", systemImage: "plus").font(.nunito(size: 15, weight: .bold))
                    }
                }
            }

            listCard(title: "Goals", empty: "No goals yet",
                     items: d.goals.map { ($0, $0, CoreEntryRef.goal($0)) }) {
                addField("Add a goal", text: $newGoal) { goal in core.updateDeclared { $0.goals.append(goal) } }
            }

            listCard(title: "Don’t suggest", empty: "Nothing held back",
                     items: d.suppressed.map { ($0, $0, CoreEntryRef.suppressed($0)) }) {
                addField("A topic, task type or place", text: $newSuppressed) { term in
                    core.updateDeclared { $0.suppressed.append(term) }
                }
            }
        }
    }

    private func listCard<Footer: View>(title: String, empty: String, items: [(id: String, text: String, ref: CoreEntryRef)],
                                        @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.evryBody)
                .foregroundStyle(palette.text)
            if items.isEmpty {
                Text(empty)
                    .font(.nunito(size: 14))
                    .foregroundStyle(palette.textMuted)
            }
            ForEach(items, id: \.id) { item in
                HStack {
                    Text(item.text)
                        .font(.nunito(size: 15))
                        .foregroundStyle(palette.text)
                    Spacer()
                    Button { core.deleteEntry(item.ref) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.nunito(size: 16))
                            .foregroundStyle(palette.textPh)
                            .frame(width: EvrySpace.tap, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(item.text)")
                }
            }
            footer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .evryField(palette)
    }

    private func addField(_ prompt: String, text: Binding<String>, add: @escaping (String) -> Void) -> some View {
        HStack {
            TextField(prompt, text: text)
                .font(.nunito(size: 15))
                .submitLabel(.done)
                .onSubmit { commit(text, add) }
            Button("Add") { commit(text, add) }
                .font(.nunito(size: 15, weight: .bold))
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func commit(_ text: Binding<String>, _ add: (String) -> Void) {
        let value = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        add(value)
        text.wrappedValue = ""
    }

    // MARK: Learned sections

    private func readoutSection(_ section: CoreReadout.Section, profile: CoreProfile) -> some View {
        VStack(spacing: 12) {
            sectionLabel(section.title)
            VStack(spacing: 0) {
                if section.items.isEmpty {
                    Text(section.empty)
                        .font(.nunito(size: 14))
                        .foregroundStyle(palette.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle().fill(palette.border).frame(height: 1).padding(.leading, 16)
                    }
                    itemRow(item, profile: profile)
                }
            }
            .evryField(palette)
        }
    }

    private func itemRow(_ item: CoreReadout.Item, profile: CoreProfile) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.nunito(size: 15, weight: .bold))
                    .foregroundStyle(palette.text)
                Text(item.detail)
                    .font(.nunito(size: 13))
                    .foregroundStyle(palette.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let ref = item.ref {
                Menu {
                    if item.canConfirm, case .fact(let id) = ref {
                        Button { core.confirmFact(id) } label: { Label("That’s right", systemImage: "checkmark") }
                    }
                    if item.canRename, case .place(let id) = ref {
                        Button {
                            renameText = profile.declared.placeLabels[id] ?? item.title
                            renaming = item
                        } label: { Label("Rename", systemImage: "pencil") }
                        Menu {
                            ForEach(CorePlace.Category.allCases) { category in
                                Button(category.label) { core.setPlaceCategory(id, to: category) }
                            }
                            if profile.declared.placeCategories[id] != nil {
                                Button("Let Evry decide") { core.setPlaceCategory(id, to: nil) }
                            }
                        } label: { Label("Kind of place", systemImage: "tag") }
                    }
                    Button { core.deleteEntry(ref) } label: { Label("Forget this", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.nunito(size: 16, weight: .bold))
                        .foregroundStyle(palette.textSec)
                        .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Options for \(item.title)")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .frame(minHeight: EvrySpace.storeHeight)
    }

    // MARK: Reset

    private var resetButton: some View {
        Button { askReset = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.nunito(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.danger)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text("Reset my Core")
                    .font(.evryBody)
                    .foregroundStyle(Palette.danger)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: EvrySpace.storeHeight)
            .contentShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .evryField(palette)
        .padding(.top, 12)
    }

    // MARK: Helpers

    private func toggleRow(_ name: String, icon: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.nunito(size: 18, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? palette.primary : palette.textSec)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.evryBody)
                    .foregroundStyle(palette.text)
                Text(subtitle)
                    .font(.nunito(size: 14))
                    .foregroundStyle(palette.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(palette.primary)
                .accessibilityLabel(name)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: EvrySpace.storeHeight)
        .evryField(palette)
    }

    private func sectionLabel(_ text: String) -> some View {
        SectionLabel(text: text, palette: palette)
            .padding(.horizontal, 4)
    }

    private static func time(_ hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private static func hhmm(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

#Preview("Crystal stages") {
    let palette = Palette(dark: false, accent: .evry)
    HStack(spacing: 18) {
        ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { f in
            VStack(spacing: 6) {
                CoreCrystal(fraction: f, palette: palette).frame(height: 96)
                Text("\(Int(f * 100))%").font(.nunito(size: 12, weight: .bold))
            }
        }
    }
    .padding()
}

#Preview("Crystal badge") {
    CoreCrystalBadge(palette: Palette(dark: false, accent: .evry))
        .padding(40)
}

#Preview("XP crystal") {
    HStack(spacing: 30) {
        CoreCrystal(fraction: 1, palette: Palette(dark: false, accent: .evry)).frame(height: 48)
        CoreCrystal(fraction: 1, palette: Palette(dark: false, accent: .evry), bright: true)
            .frame(height: 48)
            .shadow(color: Color.evrySky.opacity(0.9), radius: 6)
    }
    .padding(40)
}
