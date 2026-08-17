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
        case .all:              return "All Notes"
        case .folder(let f):    return f.name
        }
    }

    /// The folder new notes should be filed into for this scope (nil for All Notes).
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
    static let colors: [UInt32] = [
        0x3B82F6, 0x8B5CF6, 0xEC4899, 0xEF4444, 0xF97316,
        0xF59E0B, 0x22C55E, 0x14B8A6, 0x64748B,
    ]
    static let icons: [String] = [
        "folder", "tray.full", "briefcase", "book.closed", "star", "heart",
        "flame", "house", "globe", "lightbulb", "pencil", "camera",
        "music.note", "gamecontroller", "car", "airplane", "graduationcap",
        "fork.knife", "leaf", "cart", "gift", "target", "flag", "tag",
    ]
}

// MARK: - Folders screen (Notes tab entry)

struct NotesView: View {
    let palette: Palette

    @Environment(\.modelContext) private var context
    @Environment(Appearance.self) private var appearance
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]
    @Query(sort: \Note.modifiedAt, order: .reverse) private var allNotes: [Note]

    @State private var navPath = NavigationPath()
    @State private var editingFolder: Folder?

    private var liveNotes: [Note] { allNotes.filter { !$0.isTrashed } }

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
                    HStack {
                        Text("Folders")
                            .font(.system(size: 34, weight: .heavy))
                            .tracking(-0.5)
                            .foregroundStyle(palette.text)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                    VStack(spacing: 10) {
                        // "All Notes" smart folder — always present, catches notes
                        // that don't belong to any folder.
                        folderCard(title: "All Notes", icon: "tray.full",
                                   color: palette.primary, count: total) {
                            navPath.append(NoteScope.all)
                        }

                        ForEach(folders) { folder in
                            folderCard(title: folder.name, icon: folder.icon,
                                       color: folder.color ?? palette.primary,
                                       count: counts[folder.uid] ?? 0) {
                                navPath.append(NoteScope.folder(folder))
                            }
                            .contextMenu {
                                Button { editingFolder = folder } label: {
                                    Label("Edit Folder", systemImage: "pencil")
                                }
                                Button(role: .destructive) { deleteFolder(folder) } label: {
                                    Label("Delete Folder", systemImage: "trash")
                                }
                            }
                        }

                        if folders.isEmpty {
                            EmptyStateView(
                                title: "No folders yet",
                                text: "Pull up the handle below to create your first folder.",
                                palette: palette
                            )
                            .padding(.top, 30)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 130)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(palette.bg)
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

    private func folderCard(title: String, icon: String, color: Color,
                            count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text("\(count) note\(count == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSec)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPh)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
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
    @Query(sort: \Note.modifiedAt, order: .reverse) private var allNotes: [Note]

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

    /// Non-trashed notes within this scope.
    private var notes: [Note] {
        allNotes.filter { note in
            guard !note.isTrashed else { return false }
            switch scope {
            case .all:              return true
            case .folder(let f):    return note.folder?.uid == f.uid
            }
        }
    }

    /// Scope notes narrowed by the search query.
    private var filtered: [Note] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return notes }
        return notes.filter {
            $0.title.lowercased().contains(q) || $0.plainText.lowercased().contains(q)
        }
    }

    private var pinned: [Note] { filtered.filter(\.pinned) }
    private var unpinned: [Note] { filtered.filter { !$0.pinned } }

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
    private var dateGroups: [DateGroup] {
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
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)

            if searchActive {
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollView {
                VStack(spacing: 0) {
                    if filtered.isEmpty {
                        emptyState
                            .padding(.top, 40)
                    } else {
                        if !pinned.isEmpty {
                            SectionLabel(text: "Pinned", palette: palette)
                                .padding(.horizontal, 20)
                            noteRows(pinned)
                        }
                        // Unpinned notes grouped by creation day, newest first,
                        // with a date header between groups (Apple Notes style).
                        ForEach(dateGroups) { group in
                            SectionLabel(text: group.title, palette: palette)
                                .padding(.horizontal, 20)
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
        HStack(alignment: .center, spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .frame(width: 32, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to folders")

            Text(scope.title)
                .font(.system(size: 28, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(palette.text)
                .lineLimit(1)

            Spacer(minLength: 4)

            RoundIconButton(systemName: searchActive ? "xmark" : "magnifyingglass", palette: palette) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { searchActive.toggle() }
                if searchActive {
                    searchFocused = true
                } else {
                    searchText = ""
                    searchFocused = false
                }
            }
            .accessibilityLabel(searchActive ? "Close search" : "Search notes")

            RoundIconButton(systemName: "lightbulb", palette: palette) {
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
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textSec)
            TextField("Search notes", text: $searchText)
                .font(.system(size: 15))
                .foregroundStyle(palette.text)
                .autocorrectionDisabled()
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textPh)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(palette.hover, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
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
                            Button { NoteActions.togglePin(note) } label: {
                                Label(note.pinned ? "Unpin" : "Pin",
                                      systemImage: note.pinned ? "bookmark.slash" : "bookmark")
                            }
                            Button { convertToTask(note) } label: {
                                Label("Turn into Task", systemImage: "checklist")
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
        .padding(.horizontal, 12)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: items.count)
    }

    // MARK: Empty state

    private var emptyState: some View {
        EmptyStateView(
            title: searchText.isEmpty ? "No notes yet" : "No matching notes",
            text: searchText.isEmpty
                ? "Pull up the handle below to start a note."
                : "Try a different search.",
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

    private func convertToTask(_ note: Note) {
        NoteActions.makeTask(from: note, context: context)
        try? context.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Note row

struct NoteRowView: View {
    let note: Note
    let palette: Palette
    var showFolder: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if note.pinned {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.primary)
                    }
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(note.title.isEmpty ? palette.textSec : palette.text)
                        .lineLimit(1)
                }

                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSec)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if showFolder, let folder = note.folder {
                    ChipView(text: folder.name,
                             foreground: folder.color ?? palette.textSec,
                             background: palette.hover)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

// MARK: - New folder sheet (pick icon + color before creating)

struct NewFolderSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    @State private var name = ""
    @State private var icon = "folder"
    @State private var colorHex: UInt32 = FolderStyle.colors[0]
    @FocusState private var nameFocused: Bool

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var tint: Color { Color(hex: colorHex) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Folder name", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { create() }
                }

                Section("Icon") {
                    FolderIconGrid(selected: icon, tint: tint) { icon = $0 }
                }

                Section("Color") {
                    FolderColorGrid(selectedHex: colorHex) { colorHex = $0 }
                }
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .onAppear { nameFocused = true }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let count = (try? context.fetch(FetchDescriptor<Folder>()))?.count ?? 0
        let folder = Folder(name: trimmed, icon: icon, colorHex: Int(colorHex))
        folder.sortOrder = count
        context.insert(folder)
        try? context.save()
        dismiss()
    }
}

// MARK: - Shared folder pickers

private struct FolderIconGrid: View {
    let selected: String
    let tint: Color
    let onSelect: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
            ForEach(FolderStyle.icons, id: \.self) { icon in
                Button { onSelect(icon) } label: {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundStyle(selected == icon ? .white : tint)
                        .frame(width: 40, height: 40)
                        .background(
                            selected == icon ? tint : tint.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FolderColorGrid: View {
    let selectedHex: UInt32
    let onSelect: (UInt32) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
            ForEach(FolderStyle.colors, id: \.self) { hex in
                Button { onSelect(hex) } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 34, height: 34)
                        .overlay {
                            if selectedHex == hex {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Edit folder sheet

private struct EditFolderSheet: View {
    @Bindable var folder: Folder

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var tint: Color { folder.color ?? palette.primary }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Folder name", text: $folder.name)
                }

                Section("Icon") {
                    FolderIconGrid(selected: folder.icon, tint: tint) { folder.icon = $0 }
                }

                Section("Color") {
                    FolderColorGrid(selectedHex: folder.colorHex.map { UInt32(truncatingIfNeeded: $0) } ?? 0) {
                        folder.colorHex = Int($0)
                    }
                }
            }
            .navigationTitle("Edit Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
    }
}
