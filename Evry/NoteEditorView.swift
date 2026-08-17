//
//  NoteEditorView.swift
//  Evry
//
//  Note editor — title + rich body with auto-save (no save button), matching the
//  app's low-friction flow. Blank notes are discarded on dismiss. The rich body
//  lives in the swappable `NoteBodyEditor`; this screen owns the title,
//  auto-save, and discard-empty behavior.
//

import SwiftUI
import SwiftData
import UIKit

struct NoteEditorView: View {
    @Bindable var note: Note

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]

    @State private var bodyText = NSAttributedString()
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @FocusState private var titleFocused: Bool
    // Stickers
    @State private var stickers: [NoteSticker] = []
    @State private var selectedStickerID: UUID?
    @State private var showStickerPicker = false
    @State private var pendingEmoji: String?
    // The body's scroll offset lives in its own observable so updating it (on
    // every scroll tick / bounce) only re-renders the sticker layer, not the
    // text-view representable — which otherwise fed back and caused jitter.
    @State private var scrollModel = StickerScrollModel()

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Title", text: $note.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .focused($titleFocused)
                    .submitLabel(.next)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                ZStack {
                    NoteBodyEditor(text: $bodyText, palette: palette, onEdit: { newBody in
                        note.body = newBody           // writes bodyData + plainText
                        note.modifiedAt = Date()
                    }, onScroll: { scrollModel.offset = $0 })
                    .padding(.horizontal, 12)
                    .padding(.top, 4)

                    // Emoji stickers float over the body; drag to move, pinch to
                    // scale, twist to rotate, long-press to delete. They track the
                    // body's scroll offset so they move with the content.
                    StickerLayer(
                        stickers: $stickers,
                        selectedID: $selectedStickerID,
                        pendingEmoji: $pendingEmoji,
                        scrollModel: scrollModel,
                        palette: palette,
                        onChange: saveStickers
                    )
                }
                // Clip stickers to the body area so, like the text, they scroll
                // under the title header instead of floating over it.
                .clipped()
            }
            .background(palette.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { folderMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showStickerPicker = true } label: {
                        Image(systemName: "face.smiling")
                            .foregroundStyle(palette.primary)
                    }
                    .accessibilityLabel("Add sticker")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Done")
                            .fontWeight(.semibold)
                            .foregroundStyle(palette.primary)
                    }
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .sheet(isPresented: $showStickerPicker) {
            EmojiPickerSheet(palette: palette) { pendingEmoji = $0 }
                .environment(appearance)
        }
        .onAppear {
            bodyText = note.body
            stickers = note.stickers
            // A freshly created note opens ready to type its title.
            if note.title.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { titleFocused = true }
            }
        }
        .onChange(of: note.title) { _, _ in
            note.modifiedAt = Date()
        }
        .onDisappear {
            // Discard a note left blank, otherwise flush edits so the list row
            // (preview / modified order) reflects them right away.
            if note.isEmpty { context.delete(note) }
            try? context.save()
        }
    }

    // MARK: Stickers

    private func saveStickers() {
        note.stickers = stickers
        note.modifiedAt = Date()
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
            Button {
                note.folder = nil
                note.modifiedAt = Date()
            } label: {
                Label("No Folder", systemImage: note.folder == nil ? "checkmark" : "tray")
            }
            Button { showNewFolder = true } label: {
                Label("New Folder…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(note.folder?.name ?? "No Folder")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(palette.textSec)
        }
        // Attached here (not the root) so it doesn't collide with the
        // "Added to Tasks" alert — stacked alerts on one view drop all but one.
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") { createFolder() }
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        newFolderName = ""
        guard !name.isEmpty else { return }
        let folder = Folder(name: name)
        folder.sortOrder = folders.count
        context.insert(folder)
        note.folder = folder
        note.modifiedAt = Date()
        try? context.save()
    }
}

// MARK: - Sticker layer

/// Holds the note body's scroll offset, isolated so scroll updates only
/// re-render the sticker layer (not the text-view representable).
@Observable final class StickerScrollModel {
    var offset: CGFloat = 0
}

/// Floats the note's emoji stickers over the body editor. When nothing is
/// selected the layer is transparent to touches (so the editor works normally);
/// selecting a sticker enables a tap-to-deselect catcher.
private struct StickerLayer: View {
    @Binding var stickers: [NoteSticker]
    @Binding var selectedID: UUID?
    @Binding var pendingEmoji: String?
    let scrollModel: StickerScrollModel
    let palette: Palette
    var onChange: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selectedID = nil }
                    .allowsHitTesting(selectedID != nil)

                ForEach($stickers) { $sticker in
                    StickerView(
                        sticker: $sticker,
                        canvasSize: geo.size,
                        scrollOffset: scrollModel.offset,
                        selected: selectedID == sticker.id,
                        palette: palette,
                        onSelect: { selectedID = sticker.id },
                        onDelete: {
                            let id = sticker.id
                            stickers.removeAll { $0.id == id }
                            selectedID = nil
                            onChange()
                        },
                        onCommit: onChange
                    )
                }
            }
            // Drop a newly-picked emoji at the visible center (in content space so
            // it stays put as the note scrolls), then select it.
            .onChange(of: pendingEmoji) { _, emoji in
                guard let emoji, geo.size.width > 0 else { return }
                // Place at the current visible center (top-anchored, width-unit).
                let y = Double((geo.size.height * 0.5 + scrollModel.offset) / geo.size.width)
                let sticker = NoteSticker(emoji: emoji, x: 0.5, y: y)
                stickers.append(sticker)
                selectedID = sticker.id
                onChange()
                pendingEmoji = nil
            }
        }
    }
}

private struct StickerView: View {
    @Binding var sticker: NoteSticker
    let canvasSize: CGSize
    let scrollOffset: CGFloat
    let selected: Bool
    let palette: Palette
    var onSelect: () -> Void
    var onDelete: () -> Void
    var onCommit: () -> Void

    private let baseSize: CGFloat = 44

    @GestureState private var pinch: CGFloat = 1
    @GestureState private var twist: Angle = .zero
    @State private var dragBase: CGPoint?
    @State private var confirmDelete = false

    /// Extra margin around the sticker for the pinch/rotate area (only while
    /// selected). Tap/drag use a tight area on the sticker itself.
    private var pinchPad: CGFloat { selected ? 80 : 0 }

    var body: some View {
        Text(sticker.emoji)
            // Committed scale via font size so the sticker's layout bounds (and
            // thus its tap/drag hit area) match its visual size; live pinch uses
            // scaleEffect on top.
            .font(.system(size: baseSize * sticker.scale))
            .padding(6)
            .background(
                selected ? palette.primary.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(palette.primary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .scaleEffect(pinch)
            .rotationEffect(Angle(radians: sticker.rotation) + twist)
            // Tap + drag: a tight area on the sticker itself.
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .gesture(dragGesture)
            // Long-press → a delete confirmation dialog (no context-menu preview
            // box that clipped the sticker).
            .onLongPressGesture(minimumDuration: 0.5) { confirmDelete = true }
            .confirmationDialog("Delete this sticker?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Sticker", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) {}
            }
            // Pinch + rotate: a larger surrounding area, easy to grab.
            .padding(pinchPad)
            .contentShape(Rectangle())
            .gesture(pinchRotateGesture)
            // Positioned from the top using the width as the (keyboard-stable)
            // unit for both axes, so opening/closing the keyboard — which only
            // shrinks the bottom of the editor — doesn't shift stickers.
            .offset(x: (sticker.x - 0.5) * canvasSize.width,
                    y: sticker.y * canvasSize.width - scrollOffset - canvasSize.height / 2)
    }

    private var dragGesture: some Gesture {
        // Global space so the sticker's own `.offset` (which moves as we drag)
        // doesn't feed back into the translation and cause oscillation.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                // Only move once selected — prevents accidental drags.
                guard selected, canvasSize.width > 0 else { return }
                // Ignore drag while a pinch/rotate is happening.
                guard pinch == 1, twist == .zero else { return }
                if dragBase == nil { dragBase = CGPoint(x: sticker.x, y: sticker.y) }
                let base = dragBase ?? CGPoint(x: sticker.x, y: sticker.y)
                sticker.x = min(1, max(0, base.x + Double(value.translation.width / canvasSize.width)))
                sticker.y = base.y + Double(value.translation.height / canvasSize.width)
            }
            .onEnded { _ in
                if dragBase != nil { onCommit() }
                dragBase = nil
            }
    }

    private var pinchRotateGesture: some Gesture {
        let magnify = MagnificationGesture()
            .updating($pinch) { value, state, _ in if selected { state = value } }
            .onEnded { value in
                guard selected else { return }
                sticker.scale = min(6, max(0.3, sticker.scale * value))
                onCommit()
            }
        let rotate = RotationGesture()
            .updating($twist) { value, state, _ in if selected { state = value } }
            .onEnded { value in
                guard selected else { return }
                sticker.rotation += value.radians
                onCommit()
            }
        return magnify.simultaneously(with: rotate)
    }
}

// MARK: - Emoji picker

private struct EmojiPickerSheet: View {
    let palette: Palette
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Appearance.self) private var appearance
    @State private var custom = ""

    private let emojis = [
        // Smileys & people
        "😀","😃","😄","😁","😆","😅","😂","🤣","🙂","🙃","😉","😊","😇",
        "🥰","😍","🤩","😘","😗","😚","😙","😋","😛","😜","🤪","😝","🤗",
        "🤭","🤫","🤔","🤨","😐","😑","😶","😏","😒","🙄","😬","😮‍💨","🤥",
        "😌","😔","😪","🤤","😴","😷","🤒","🤕","🤢","🤮","🥵","🥶","🥴",
        "😵","🤯","🤠","🥳","🥸","😎","🤓","🧐","😕","😟","🙁","😮","😯",
        "😲","😳","🥺","😦","😧","😨","😰","😥","😢","😭","😱","😖","😣",
        "😞","😓","😩","😫","🥱","😤","😡","😠","🤬","😈","👿","💀","👻",
        "👽","🤖","🎃","😺","😸","😹","😻","😼","😽","🙀","😿","😾",
        // Hands & body
        "👍","👎","👏","🙌","🙏","🫶","🤝","👊","✊","🤛","🤜","🤞","✌️",
        "🤟","🤘","👌","🤌","🤏","👈","👉","👆","👇","☝️","✋","🖐️","🖖",
        "👋","🤙","💪","🦾","🧠","👀","👁️","👣","🫰",
        // Hearts & symbols
        "❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","🩷","🩵","💖","💗",
        "💓","💞","💕","💘","💝","💔","❣️","💯","💢","💬","💭","🔥","✨",
        "⭐️","🌟","💫","⚡️","☀️","🌙","🌈","☁️","❄️","💧","🌊","🍀","🌸",
        "🌼","🌻","🌵","🌴","🍃","🌱",
        // Objects & activities
        "✅","❌","⚠️","📌","📍","📎","🔗","✏️","🖊️","📝","📖","📚","💡",
        "🎯","🚀","🎉","🎊","🎁","🏆","🥇","🎖️","👑","💎","⏰","⏳","📅",
        "🗓️","📈","📊","💰","💸","🛒","🔑","🔒","🔔","📣","🧩","🎨","🎵",
        "🎧","🎬","📷","💻","🖥️","📱","⌚️","🎮","🕹️","☕️","🍵","🍺","🥂",
        // Food
        "🍎","🍏","🍊","🍋","🍓","🫐","🍇","🍉","🍑","🥭","🍍","🥥","🥑",
        "🍔","🍟","🍕","🌮","🌯","🍜","🍣","🍩","🍪","🎂","🍰","🧁","🍫",
        // Travel & animals
        "🚗","🚕","🚌","🚲","🏍️","✈️","🚂","🚁","🛴","🏠","🏢","🗺️",
        "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🦁","🐯","🐸","🐵",
        "🦄","🐣","🐧","🐦","🦋","🐝","🐢","🐬","🐳","🦕","🌍","💤",
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(emojis, id: \.self) { emoji in
                        Button {
                            onPick(emoji)
                            dismiss()
                        } label: {
                            Text(emoji)
                                .font(.system(size: 30))
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                HStack(spacing: 8) {
                    TextField("Type any emoji…", text: $custom)
                        .font(.system(size: 18))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(palette.hover, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button("Add") {
                        let e = custom.trimmingCharacters(in: .whitespaces)
                        guard !e.isEmpty else { return }
                        onPick(String(e.prefix(4)))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.primary)
                    .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(16)
            }
            .background(palette.bg)
            .navigationTitle("Add Sticker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
    }
}
