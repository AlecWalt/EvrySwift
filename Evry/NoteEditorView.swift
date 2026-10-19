//
//  NoteEditorView.swift
//  Evry
//
//  Note editor — title + rich body with auto-save (no save button), matching the
//  app's low-friction flow. Blank notes are discarded on dismiss. From the Notes
//  tab it's a full page pushed onto the Notes stack; from the chat, a card
//  sheet. The rich body lives in the swappable `NoteBodyEditor`; this screen
//  owns the title, auto-save, and discard-empty behavior.
//

import SwiftUI
import SwiftData

struct NoteEditorView: View {
    @Bindable var note: Note
    /// How the editor is shown: its own page pushed onto the Notes stack, or a
    /// card sheet (opened from the chat).
    var style: Style = .sheet

    enum Style { case page, sheet }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]

    @State private var bodyText = NSAttributedString()
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @FocusState private var titleFocused: Bool
    @State private var showBgColorPicker = false
    /// Debounces body saves (see `NoteBodySaver`).
    @State private var saver = NoteBodySaver()
    @Environment(\.scenePhase) private var scenePhase
    /// The note was blank when opened (a fresh one, not an old one emptied).
    @State private var openedEmpty = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        chrome
            .tint(palette.primary)
            .sheet(isPresented: $showBgColorPicker) {
                NoteBackgroundPicker(
                    selectedHex: note.backgroundColorHex,
                    palette: palette
                ) { hex in
                    note.backgroundColorHex = hex
                    note.modifiedAt = Date()
                }
                .environment(appearance)
            }
            .onAppear {
                // Coming back to a page whose blank note was already discarded
                // (it disappeared when another tab took over) — leave it.
                if note.isDeleted || note.modelContext == nil {
                    dismiss()
                    return
                }
                openedEmpty = note.isEmpty
                bodyText = note.body
                // A freshly created note opens ready to type its title.
                if note.title.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { titleFocused = true }
                }
            }
            .onChange(of: note.title) { _, _ in
                note.modifiedAt = Date()
            }
            // Leaving the app mid-pause still writes the last edit.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { saver.flush(note) }
            }
            .onDisappear {
                guard !note.isDeleted, note.modelContext != nil else { return }
                // Write any edit still waiting on the debounce first.
                saver.flush(note)
                // A brand-new note left blank is discarded. An existing note that's
                // been emptied goes to Recently Deleted (with its 30-day undo)
                // instead of vanishing for good.
                if note.isEmpty {
                    if openedEmpty { context.delete(note) } else { NoteActions.softDelete(note) }
                }
                try? context.save()
                // A brand-new note that was actually written can earn a little XP.
                if openedEmpty && !note.isEmpty { EvryXP.rollBonus(.noteCreated) }
                // Only with note-extraction consent; only structured facts are kept.
                CoreHooks.noteSaved(note)
            }
    }

    // MARK: Chrome

    /// A page in the Notes stack gets a back button (and the tab bar steps
    /// away); the chat's card sheet keeps its own stack and a Done button.
    @ViewBuilder
    private var chrome: some View {
        switch style {
        case .page:
            editor
                .navigationBarBackButtonHidden(true)
                // The notes list hides the bar for its custom header; this page
                // brings it back for the back / folder / background buttons.
                .toolbar(.visible, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.nunito(size: 18, weight: .bold))
                                .foregroundStyle(palette.primary)
                                .frame(minWidth: EvrySpace.tap, minHeight: EvrySpace.tap)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Back to notes")
                    }
                    ToolbarItem(placement: .principal) { folderMenu }
                    ToolbarItem(placement: .topBarTrailing) { backgroundButton }
                }
                // Swipe from the left edge to go back — hiding the system back
                // button turns off its pop gesture (same catcher as the list).
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
        case .sheet:
            NavigationStack {
                editor
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { folderMenu }
                        ToolbarItem(placement: .topBarTrailing) { backgroundButton }
                        ToolbarItem(placement: .confirmationAction) {
                            Button { dismiss() } label: {
                                Text("Done")
                                    .font(.evryLabel)
                                    .foregroundStyle(palette.primary)
                            }
                        }
                    }
            }
            .presentationCornerRadius(EvryRadius.panel)
            .preferredColorScheme(appearance.preferredColorScheme)
        }
    }

    /// Title + rich body on the note's surface.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $note.title)
                // The note's h3-sized heading (matches the body editor's
                // "Title" style: Nunito 28 extra-bold).
                .font(.nunito(size: 28, weight: .heavy))
                .foregroundStyle(palette.text)
                .tint(palette.primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .focused($titleFocused)
                .submitLabel(.next)
                .padding(.horizontal, EvrySpace.gutter)
                .padding(.top, 16)
                .padding(.bottom, 8)

            NoteBodyEditor(text: $bodyText, palette: palette, onEdit: { newBody in
                saver.edited(newBody, note: note)
            })
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .background(editorBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var backgroundButton: some View {
        Button { showBgColorPicker = true } label: {
            Image(systemName: "paintpalette")
                .font(.nunito(size: 17, weight: .semibold))
                .foregroundStyle(palette.primary)
                .frame(minWidth: EvrySpace.tap, minHeight: EvrySpace.tap)
        }
        .accessibilityLabel("Change background")
    }

    // MARK: Background

    /// The editor surface — the app background, with the note's chosen sky
    /// step laid over it (a soft wash in dark mode).
    private var editorBackground: some View {
        ZStack {
            palette.bg
            if let surface = note.backgroundSurface(palette) {
                surface
            }
        }
        // Bleed under the (transparent) navigation bar so the header with the
        // feature buttons matches the body and the chosen color.
        .ignoresSafeArea()
    }

    // MARK: Folder assignment

    private var folderMenu: some View {
        Menu {
            ForEach(folders) { folder in
                Button {
                    note.folder = folder
                    note.modifiedAt = Date()
                } label: {
                    Label(folder.name, systemImage: note.folder?.uid == folder.uid ? "checkmark" : "folder")
                }
            }
            Divider()
            // Folderless notes live under the "All notes" smart folder.
            Button {
                note.folder = nil
                note.modifiedAt = Date()
            } label: {
                Label("All notes", systemImage: note.folder == nil ? "checkmark" : "tray.full")
            }
            Button { showNewFolder = true } label: {
                Label("New folder…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: note.folder == nil ? "tray.full" : "folder")
                Text(note.folder?.name ?? "All notes")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.nunito(size: 11, weight: .bold))
            }
            .font(.evrySmall)
            .foregroundStyle(palette.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(palette.skySoft, in: Capsule())
            .frame(minHeight: EvrySpace.tap)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Folder: \(note.folder?.name ?? "All notes")")
        // Attached here (not the root) so it doesn't collide with the
        // "Added to Tasks" alert — stacked alerts on one view drop all but one.
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create folder") { createFolder() }
        } message: {
            Text("Give it a short name. You can change it any time.")
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        newFolderName = ""
        guard !name.isEmpty else { return }
        let folder = Folder(name: name)
        // The next sky/navy shade, like folders made from the Notes screen.
        folder.shade = FolderShade.next(FolderShade.noteFoldersKey)
        folder.sortOrder = folders.count
        context.insert(folder)
        note.folder = folder
        note.modifiedAt = Date()
        try? context.save()
    }
}

// MARK: - Note background color picker

/// A small sheet of sky background steps for the note (mist to deep sky), plus
/// a "Default" option that clears the custom tint.
private struct NoteBackgroundPicker: View {
    let selectedHex: Int?
    let palette: Palette
    var onSelect: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Appearance.self) private var appearance

    /// Brand steps only — notes differ by strength of sky, never by hue.
    private let colors: [UInt32] = NoteTint.options
    private let columns = Array(repeating: GridItem(.flexible()), count: 6)
    private let stepNames = ["Mist", "Soft sky", "Light sky", "Sky", "Deep sky"]

    /// Which brand step a stored (possibly legacy) value shows as.
    private var selectedBrandHex: UInt32? {
        selectedHex.map { NoteTint.brandHex(forStoredHex: $0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    // Default (no custom color).
                    Button { onSelect(nil); dismiss() } label: {
                        ZStack {
                            Circle().fill(palette.card)
                            Circle().strokeBorder(palette.border, lineWidth: 1.5)
                            Image(systemName: "slash.circle")
                                .font(.nunito(size: 15, weight: .semibold))
                                .foregroundStyle(palette.textMuted)
                            if selectedHex == nil {
                                Circle().strokeBorder(palette.primary, lineWidth: 2.5)
                            }
                        }
                        .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel("Default background")
                    .accessibilityAddTraits(selectedHex == nil ? .isSelected : [])

                    ForEach(Array(colors.enumerated()), id: \.element) { index, hex in
                        let isSel = selectedBrandHex == hex
                        Button { onSelect(Int(hex)); dismiss() } label: {
                            ZStack {
                                Circle().fill(Color(hex: hex))
                                Circle().strokeBorder(isSel ? palette.primary : palette.border,
                                                      lineWidth: isSel ? 2.5 : 1.5)
                                if isSel {
                                    Image(systemName: "checkmark")
                                        .font(.nunito(size: 13, weight: .heavy))
                                        .foregroundStyle(Color.evryNavy)
                                }
                            }
                            .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                        }
                        .buttonStyle(PressScaleStyle())
                        .accessibilityLabel(stepNames[index])
                        .accessibilityAddTraits(isSel ? .isSelected : [])
                    }
                }
                .padding(EvrySpace.grid)
            }
            .background(palette.bg)
            .navigationTitle("Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.evryLabel)
                }
            }
        }
        .presentationDetents([.height(220), .medium])
        .presentationCornerRadius(EvryRadius.panel)
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
    }
}

// MARK: - Body saving

/// Writes the note body a moment after typing pauses, instead of on every
/// keystroke — each write re-archives the whole document (RTFD) and wakes the
/// notes list behind the editor. A plain class (not observed), so recording
/// an edit doesn't re-render the editor either.
@MainActor
final class NoteBodySaver {
    private var pending: NSAttributedString?
    private var task: Task<Void, Never>?

    func edited(_ body: NSAttributedString, note: Note) {
        pending = body
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flush(note)
        }
    }

    /// Writes the waiting edit now (on pause, or when the editor closes).
    func flush(_ note: Note) {
        task?.cancel()
        task = nil
        guard let body = pending else { return }
        pending = nil
        note.body = body            // writes bodyData + plainText
        note.modifiedAt = Date()
    }
}
