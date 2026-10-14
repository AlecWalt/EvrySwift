//
//  NotesView.swift
//  Evry
//
//  Notes tab — an Apple Notes-style two-level flow that mirrors the Projects
//  tab: a Folders screen (this file's `NotesView`) whose cards navigate into a
//  scoped `NotesListView`. The list groups notes by creation day, surfaces
//  pinned notes, and drops you into the rich editor.
//

import SwiftUI
import SwiftData
import UIKit

// MARK: - Note scope

/// What a `NotesListView` is showing — every note, or a single folder's notes.
enum NoteScope: Hashable {
    case all
    case folder(Folder)

    var title: String {
        switch self {
        case .all:              return "All notes"
        case .folder(let f):    return f.name
        }
    }

    /// The folder new notes should be filed into for this scope (nil for All notes).
    var folder: Folder? {
        if case .folder(let f) = self { return f }
        return nil
    }
}

// MARK: - Navigation state

/// Lets the shared swipe-up handle (in ContentView) know which notes scope is
/// open, mirroring `ProjectNavigationState`. `nil` == the Folders screen.
@Observable
final class NotesNavigationState {
    var activeScope: NoteScope? = nil
}

// MARK: - Folder styling shared between the edit sheet and quick-create

enum FolderStyle {
    // Folder colours are automatic sky/navy shades (see `FolderShade`); only
    // the icon is picked.
    static let icons: [String] = [
        "folder", "tray.full", "briefcase", "book.closed", "star", "heart",
        "flame", "house", "globe", "lightbulb", "pencil", "camera",
        "music.note", "gamecontroller", "car", "airplane", "graduationcap",
        "fork.knife", "leaf", "cart", "gift", "target", "flag", "tag",
    ]
}

/// Glyph ink for an icon sitting on a folder's shade tile: navy on the lighter
/// sky steps, white once the shade leans toward navy (mirrors
/// `Palette.folderColor`'s mix so the glyph always reads).
private func folderInk(shade: Double?, palette: Palette) -> Color {
    let s = min(max(shade ?? 0.5, 0), 1)
    let navyMix = palette.dark ? s * 0.45 : 0.3 + s * 0.55
    return navyMix > 0.5 ? .evryWhite : .evryNavy
}

// MARK: - Folders screen (Notes tab entry)

struct NotesView: View {
    let palette: Palette

    @Environment(\.modelContext) private var context
    @Environment(Appearance.self) private var appearance
    @Environment(\.evryAway) private var evryAway
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]
    /// Trash is filtered in the store, not in Swift on every render.
    @Query(filter: #Predicate<Note> { $0.deletedAt == nil },
           sort: \Note.modifiedAt, order: .reverse) private var allNotes: [Note]

    @State private var navPath = NavigationPath()
    /// True while a notes list is on top, and for the length of the pop
    /// transition after it leaves — so this screen's Evry only returns once the
    /// list's Evry has gone (never two at once).
    @State private var listOnTop = false
    @State private var editingFolder: Folder?

    private var liveNotes: [Note] { allNotes }

    /// Per-folder note counts in a single pass (avoids O(folders × notes) work
    /// when rendering the folder list).
    private var countsByFolder: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for note in liveNotes {
            if let id = note.folder?.uid { counts[id, default: 0] += 1 }
        }
        return counts
    }

    var body: some View {
        let counts = countsByFolder
        let total = liveNotes.count
        return NavigationStack(path: $navPath) {
            ScrollView {
                VStack(spacing: 12) {
                    HStack(alignment: .center, spacing: 14) {
                        PageTitle(
                            title: "Notes",
                            subtitle: "\(total) note\(total == 1 ? "" : "s")",
                            palette: palette
                        )
                        Spacer()
                    }
                    .padding(.horizontal, EvrySpace.gutter)
                    .padding(.top, 24)
                    .padding(.bottom, 8)

                    VStack(spacing: 8) {
                        // "All notes" smart folder — always present, catches notes
                        // that don't belong to any folder.
                        folderCard(title: "All notes", icon: "tray.full",
                                   tile: Color.evrySky, ink: Color.evryNavy, count: total) {
                            navPath.append(NoteScope.all)
                        }

                        ForEach(folders) { folder in
                            folderCard(title: folder.name, icon: folder.icon,
                                       tile: folder.tint(palette),
                                       ink: folderInk(shade: folder.shade, palette: palette),
                                       count: counts[folder.uid] ?? 0) {
                                navPath.append(NoteScope.folder(folder))
                            }
                            .contextMenu {
                                Button { editingFolder = folder } label: {
                                    Label("Edit folder", systemImage: "pencil")
                                }
                                Button(role: .destructive) { deleteFolder(folder) } label: {
                                    Label("Delete folder", systemImage: "trash")
                                }
                            }
                        }

                        if folders.isEmpty {
                            EmptyStateView(
                                icon: "folder",
                                title: "No folders yet",
                                text: "Folders keep related notes together. Swipe up on the handle below to make your first one.",
                                palette: palette
                            )
                            .padding(.top, 28)
                        }
                    }
                    .padding(.horizontal, EvrySpace.gutter)
                }
                .padding(.bottom, 130)
                // Evry is never in two places at once: while a notes list is
                // pushed on top (it may show its own empty-state Evry, and both
                // screens are on-screen mid-transition), this screen's Evry
                // steps away.
                .environment(\.evryAway, evryAway || listOnTop)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(palette.bg)
            .onChange(of: navPath.isEmpty) { _, isEmpty in
                if !isEmpty {
                    listOnTop = true
                } else {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        if navPath.isEmpty { listOnTop = false }
                    }
                }
            }
            .navigationDestination(for: NoteScope.self) { scope in
                NotesListView(scope: scope, palette: palette)
            }
        }
        .sheet(item: $editingFolder) { folder in
            EditFolderSheet(folder: folder).environment(appearance)
        }
        .onAppear { NoteActions.purgeExpiredTrash(context: context) }
    }

    // MARK: Folder card

    private func folderCard(title: String, icon: String, tile: Color, ink: Color,
                            count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Mirrors the Inbox's task-folder header: 38pt shade tile, label
            // title, 13pt count, flat white card + hairline (no shadow).
            HStack(spacing: 12) {
                // The folder's shade fills an icon tile (shades differ by
                // strength, never hue); the glyph ink flips to stay readable.
                Image(systemName: icon)
                    .font(.nunito(size: 18))
                    .foregroundStyle(ink)
                    .frame(width: 38, height: 38)
                    .background(tile, in: RoundedRectangle(cornerRadius: EvryRadius.tile, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.evryLabel)
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text("\(count) note\(count == 1 ? "" : "s")")
                        .font(.nunito(size: 13))
                        .foregroundStyle(palette.textSec)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.nunito(size: 12, weight: .bold))
                    .foregroundStyle(palette.textSec)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, EvrySpace.gutter)
            .padding(.vertical, 12)
            .evryField(palette)
            .contentShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
    }

    private func deleteFolder(_ folder: Folder) {
        // Notes inside are detached (nullify rule), not deleted — they remain
        // reachable under All Notes.
        withAnimation { context.delete(folder) }
        try? context.save()
    }
}

// MARK: - Scoped notes list

struct NotesListView: View {
    let scope: NoteScope
    let palette: Palette

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(Appearance.self) private var appearance
    @Environment(NotesNavigationState.self) private var notesNav
    @Environment(\.evryAway) private var evryAway
    /// Trash is filtered in the store, not in Swift on every render.
    @Query(filter: #Predicate<Note> { $0.deletedAt == nil },
           sort: \Note.modifiedAt, order: .reverse) private var allNotes: [Note]

    @State private var searchText = ""
    @State private var searchActive = false
    @FocusState private var searchFocused: Bool
    @State private var sheet: NotesSheet?
    // Brain Dump is presented full-screen (not as a card sheet), so it lives in
    // its own cover rather than the editor item-sheet.
    @State private var showBrainDump = false

    private enum NotesSheet: Identifiable {
        case editor(Note)
        var id: String {
            switch self {
            case .editor(let n): return "editor-\(n.uid.uuidString)"
            }
        }
    }

    // MARK: Derived collections

    /// Notes within this scope (trash is already excluded by the query).
    private var notes: [Note] {
        switch scope {
        case .all:              return allNotes
        case .folder(let f):    return allNotes.filter { $0.folder?.uid == f.uid }
        }
    }

    /// Scope notes narrowed by the search query (case-insensitive, without
    /// lowercasing a copy of every note's text on each pass).
    private var filtered: [Note] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return notes }
        return notes.filter {
            $0.title.range(of: q, options: .caseInsensitive) != nil
                || $0.plainText.range(of: q, options: .caseInsensitive) != nil
        }
    }

    /// In All Notes the folder chip is useful context; inside a folder it's noise.
    private var showsFolderChip: Bool {
        if case .all = scope { return true }
        return false
    }

    private struct DateGroup: Identifiable {
        let id: Date          // start of the creation day
        let title: String
        let notes: [Note]
    }

    /// Unpinned notes bucketed by the day they were created, newest day first.
    private func dateGroups(_ unpinned: [Note]) -> [DateGroup] {
        let cal = Calendar.current
        let buckets = Dictionary(grouping: unpinned) { cal.startOfDay(for: $0.createdAt) }
        return buckets.keys.sorted(by: >).map { day in
            let items = (buckets[day] ?? []).sorted { $0.createdAt > $1.createdAt }
            return DateGroup(id: day, title: Self.dateHeader(day), notes: items)
        }
    }

    private static func dateHeader(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.month(.wide).day().year())
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, EvrySpace.gutter)
                .padding(.top, 24)
                .padding(.bottom, 8)

            if searchActive {
                searchBar
                    .padding(.horizontal, EvrySpace.gutter)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollView {
                // Filtered once per render, then split.
                let shown = filtered
                let pinned = shown.filter(\.pinned)
                // Lazy, so long note lists only build the rows on screen.
                LazyVStack(spacing: 0) {
                    if shown.isEmpty {
                        emptyState
                            // Lines up with the Inbox's empty state.
                            .padding(.top, 36)
                    } else {
                        if !pinned.isEmpty {
                            SectionLabel(text: "Pinned", palette: palette)
                                .padding(.horizontal, EvrySpace.gutter)
                            noteRows(pinned)
                        }
                        // Unpinned notes grouped by creation day, newest first,
                        // with a date header between groups (Apple Notes style).
                        ForEach(dateGroups(shown.filter { !$0.pinned })) { group in
                            SectionLabel(text: group.title, palette: palette)
                                .padding(.horizontal, EvrySpace.gutter)
                            noteRows(group.notes)
                        }
                    }
                }
                .padding(.bottom, 120)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg)
        // Apple-style swipe-from-the-left-edge to pop back to Folders. The nav
        // bar is hidden (custom header), which disables the system pop gesture,
        // so a thin leading catcher restores it without clashing with row swipes.
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 18)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if value.translation.width > 70 && abs(value.translation.height) < 60 {
                                dismiss()
                            }
                        }
                )
        }
        // Brain Dump opens with its own Evry; the list's empty-state Evry steps
        // away while it's up (applied before the cover so the cover keeps its own).
        .environment(\.evryAway, evryAway || showBrainDump)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $sheet) { which in
            switch which {
            case .editor(let note):
                NoteEditorView(note: note).environment(appearance)
            }
        }
        .fullScreenCover(isPresented: $showBrainDump) {
            BrainDumpSheet(context: .note(save: { text in brainDumpToNewNote(text) }))
                .environment(appearance)
        }
        .onAppear { notesNav.activeScope = scope }
        .onDisappear { if notesNav.activeScope == scope { notesNav.activeScope = nil } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.nunito(size: 18, weight: .bold))
                    .foregroundStyle(palette.primary)
                    .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to folders")

            // Tapping the title goes back too, matching the chevron.
            PageTitle(
                title: scope.title,
                subtitle: "\(notes.count) note\(notes.count == 1 ? "" : "s")",
                palette: palette
            )
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }

            Spacer(minLength: 4)

            HeaderIconButton(systemName: searchActive ? "xmark" : "magnifyingglass", palette: palette) {
                withAnimation(EvryMotion.settle) { searchActive.toggle() }
                if searchActive {
                    searchFocused = true
                } else {
                    searchText = ""
                    searchFocused = false
                }
            }
            .accessibilityLabel(searchActive ? "Close search" : "Search notes")

            HeaderIconButton(systemName: "lightbulb", palette: palette) {
                // Suppress the cover's slide-up so Brain Dump fades in.
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { showBrainDump = true }
            }
                .accessibilityLabel("Brain dump")
        }
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.nunito(size: 15, weight: .bold))
                .foregroundStyle(palette.textMuted)
                .accessibilityHidden(true)
            TextField("Search notes", text: $searchText)
                .font(.evryBody)
                .foregroundStyle(palette.text)
                .tint(palette.primary)
                .autocorrectionDisabled()
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.nunito(size: 16))
                        .foregroundStyle(palette.textMuted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: EvrySpace.buttonHeight)
        .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous)
            .strokeBorder(searchFocused ? palette.text : (palette.dark ? Color.evryWhite35 : .evryNavy20),
                          lineWidth: 1.5))
    }

    // MARK: Rows

    private func noteRows(_ items: [Note]) -> some View {
        VStack(spacing: 8) {
            ForEach(items, id: \.uid) { note in
                SwipeActionRow(
                    leadingAction: SwipeActionRow.Action(
                        label: note.pinned ? "Unpin" : "Pin",
                        icon: note.pinned ? "bookmark.slash.fill" : "bookmark.fill",
                        color: palette.primary,
                        action: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { NoteActions.togglePin(note) } }
                    ),
                    trailingAction: SwipeActionRow.Action(
                        label: "Delete", icon: "trash.fill", color: Palette.danger,
                        action: { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { NoteActions.softDelete(note) } }
                    )
                ) {
                    NoteRowView(note: note, palette: palette, showFolder: showsFolderChip)
                        .contentShape(Rectangle())
                        .onTapGesture { sheet = .editor(note) }
                        .contextMenu {
                            Button {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    NoteActions.togglePin(note)
                                }
                            } label: {
                                Label(note.pinned ? "Unpin" : "Pin",
                                      systemImage: note.pinned ? "bookmark.slash" : "bookmark")
                            }
                            Divider()
                            Button(role: .destructive) {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { NoteActions.softDelete(note) }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .padding(.horizontal, EvrySpace.gutter)
        .animation(EvryMotion.settle, value: items.count)
    }

    // MARK: Empty state

    private var emptyState: some View {
        EmptyStateView(
            icon: searchText.isEmpty ? "note.text" : "magnifyingglass",
            title: searchText.isEmpty ? "No notes yet" : "Nothing matches that",
            text: searchText.isEmpty
                ? "Jot down whatever’s on your mind. Swipe up on the handle below to start a note."
                : "Try a different word, or clear the search to see every note.",
            palette: palette
        )
    }

    // MARK: Actions

    /// Brain Dump from the list → a brand-new note in this scope, opened for review.
    private func brainDumpToNewNote(_ text: String) {
        let note = Note(body: NSAttributedString(string: text), folder: scope.folder)
        note.modifiedAt = Date()
        context.insert(note)
        try? context.save()
        sheet = .editor(note)
    }
}

// MARK: - Note row

struct NoteRowView: View {
    let note: Note
    let palette: Palette
    var showFolder: Bool = true

    var body: some View {
        // Mirrors `TaskRowView`'s card: 17pt title, 13pt secondary text,
        // 12pt vertical / gutter horizontal padding, flat white + hairline.
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if note.pinned {
                        Image(systemName: "bookmark.fill")
                            .font(.nunito(size: 12, weight: .semibold))
                            .foregroundStyle(palette.primary)
                            .accessibilityLabel("Pinned")
                    }
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(.nunito(size: 17))
                        .foregroundStyle(note.title.isEmpty ? palette.textSec : palette.text)
                        .lineLimit(1)
                }

                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.nunito(size: 13))
                        .foregroundStyle(palette.textSec)
                        .lineLimit(1)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 8)

            // Folder chip sits on the trailing edge (not below the text) so the
            // row stays as compact as a task card.
            if showFolder, let folder = note.folder {
                // Folder chip: the folder's shade as a small dot (never as text
                // colour — the lighter shades aren't readable), name in ink.
                // Sized like the task row's meta chips (13pt medium, 2×8).
                HStack(spacing: 5) {
                    Circle().fill(folder.tint(palette)).frame(width: 8, height: 8)
                    Text(folder.name)
                        .font(.nunito(size: 13, weight: .medium))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(palette.skySoft, in: Capsule())
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, EvrySpace.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Flat at rest like the task rows: white fill + hairline, no shadow.
        // Tint the card with the note's chosen background (matching the
        // editor), falling back to the normal card when unset.
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous).fill(palette.card)
                if let surface = note.backgroundSurface(palette) {
                    RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous).fill(surface)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous)
            .strokeBorder(palette.hairline, lineWidth: 1))
    }
}

// MARK: - New folder card (swipe-up)

/// Folder quick-add, opened from the shared swipe-up handle on the Notes
/// screen. Built on `QuickAddCard` — the reference design every creation card
/// (task, habit, folder) shares.
struct NewFolderSheet: View {
    @Binding var isPresented: Bool

    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @State private var name = ""
    @State private var icon = "folder"
    @FocusState private var nameFocused: Bool

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    /// Colour is automatic — the next sky/navy shade, previewed here.
    private var shade: Double { FolderShade.peek(FolderShade.noteFoldersKey) }
    private var tint: Color { palette.folderColor(shade: shade) }
    private var ink: Color { folderInk(shade: shade, palette: palette) }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        QuickAddCard(palette: palette, actionTitle: "Add folder", actionEnabled: !trimmed.isEmpty,
                     onAction: create, onClose: close) {
            TextField("Name your folder", text: $name)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit(create)
                .evryTextField(palette, focused: nameFocused)

            VStack(alignment: .leading, spacing: 10) {
                QuickAddLabel(text: "Icon", icon: "square.grid.2x2", palette: palette)
                QuickAddIconRow(icons: FolderStyle.icons, selection: $icon, tint: tint, ink: ink, palette: palette)
            }
        }
        .task {
            // Focus once the overlay is in the window (an early request is dropped).
            try? await Task.sleep(for: .milliseconds(120))
            nameFocused = true
            try? await Task.sleep(for: .milliseconds(300))
            if !nameFocused { nameFocused = true }
        }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        let count = (try? context.fetch(FetchDescriptor<Folder>()))?.count ?? 0
        let folder = Folder(name: trimmed, icon: icon)
        folder.shade = FolderShade.next(FolderShade.noteFoldersKey)
        folder.sortOrder = count
        context.insert(folder)
        try? context.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        close()
    }

    private func close() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isPresented = false
    }
}

// MARK: - Shared folder pickers

private struct FolderIconGrid: View {
    let selected: String
    let tint: Color
    let ink: Color
    let palette: Palette
    let onSelect: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
            ForEach(FolderStyle.icons, id: \.self) { icon in
                Button { onSelect(icon) } label: {
                    Image(systemName: icon)
                        .font(.nunito(size: 18, weight: .semibold))
                        .foregroundStyle(selected == icon ? ink : palette.text)
                        .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                        .background(
                            selected == icon ? tint : palette.skySoft,
                            in: RoundedRectangle(cornerRadius: EvryRadius.tile, style: .continuous)
                        )
                        .overlay {
                            if selected == icon {
                                RoundedRectangle(cornerRadius: EvryRadius.tile, style: .continuous)
                                    .strokeBorder(palette.text, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(icon)
                .accessibilityAddTraits(selected == icon ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Edit folder sheet

private struct EditFolderSheet: View {
    @Bindable var folder: Folder

    @Environment(\.dismiss) private var dismiss
    /// The name on open, put back if the field is left empty.
    @State private var originalName = ""
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var tint: Color { folder.tint(palette) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder name", text: $folder.name)
                        .font(.evryBody)
                        .foregroundStyle(palette.text)
                } header: {
                    Text("Name").font(.evrySmall).foregroundStyle(palette.textSec).textCase(nil)
                }
                .listRowBackground(palette.card)

                Section {
                    FolderIconGrid(selected: folder.icon, tint: tint,
                                   ink: folderInk(shade: folder.shade, palette: palette), palette: palette) { folder.icon = $0 }
                } header: {
                    Text("Icon").font(.evrySmall).foregroundStyle(palette.textSec).textCase(nil)
                }
                .listRowBackground(palette.card)
            }
            .scrollContentBackground(.hidden)
            .background(palette.bg)
            .navigationTitle("Edit folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.evryLabel)
                }
            }
        }
        .onAppear { originalName = folder.name }
        // A folder can't be left nameless (creating one requires a name too).
        .onDisappear {
            if folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { folder.name = originalName }
        }
        .tint(palette.primary)
        .presentationCornerRadius(EvryRadius.panel)
        .preferredColorScheme(appearance.preferredColorScheme)
    }
}
