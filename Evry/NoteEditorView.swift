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
import PhotosUI

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
    @State private var pendingImage: Data?
    @State private var showBgColorPicker = false
    // The body's scroll offset lives in its own observable so updating it (on
    // every scroll tick / bounce) only re-renders the sticker layer, not the
    // text-view representable — which otherwise fed back and caused jitter.
    @State private var scrollModel = StickerScrollModel()

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        NavigationStack {
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
                        pendingImage: $pendingImage,
                        scrollModel: scrollModel,
                        palette: palette,
                        onChange: saveStickers
                    )
                }
                // Clip stickers to the body area so, like the text, they scroll
                // under the title header instead of floating over it.
                .clipped()
            }
            .background(editorBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { folderMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showBgColorPicker = true } label: {
                        Image(systemName: "paintpalette")
                            .font(.nunito(size: 17, weight: .semibold))
                            .foregroundStyle(palette.primary)
                            .frame(minWidth: EvrySpace.tap, minHeight: EvrySpace.tap)
                    }
                    .accessibilityLabel("Change background")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showStickerPicker = true } label: {
                        Image(systemName: "face.smiling")
                            .font(.nunito(size: 17, weight: .semibold))
                            .foregroundStyle(palette.primary)
                            .frame(minWidth: EvrySpace.tap, minHeight: EvrySpace.tap)
                    }
                    .accessibilityLabel("Add sticker")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.evryLabel)
                            .foregroundStyle(palette.primary)
                    }
                }
            }
        }
        .tint(palette.primary)
        .presentationCornerRadius(EvryRadius.panel)
        .preferredColorScheme(appearance.preferredColorScheme)
        .sheet(isPresented: $showStickerPicker) {
            EmojiPickerSheet(
                palette: palette,
                onPick: { pendingEmoji = $0 },
                onPickImage: { pendingImage = $0 }
            )
            .environment(appearance)
        }
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
    @Binding var pendingImage: Data?
    let scrollModel: StickerScrollModel
    let palette: Palette
    var onChange: () -> Void
    /// Sticker awaiting delete confirmation.
    @State private var pendingDeleteID: UUID? = nil

    /// Content-space Y (width-unit) where a newly added sticker lands. Placed in
    /// the upper third of the visible area so it sits clearly above the keyboard
    /// rather than behind it.
    private func dropY(in geo: GeometryProxy) -> Double {
        Double((geo.size.height * 0.32 + scrollModel.offset) / geo.size.width)
    }

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
                        // Ask first — the layer (full canvas) shows the prompt.
                        onDelete: { pendingDeleteID = sticker.id },
                        onCommit: onChange
                    )
                }
            }
            // Drop a newly-picked emoji at the visible center (in content space so
            // it stays put as the note scrolls), then select it.
            .onChange(of: pendingEmoji) { _, emoji in
                guard let emoji, geo.size.width > 0 else { return }
                let sticker = NoteSticker(emoji: emoji, x: 0.5, y: dropY(in: geo))
                stickers.append(sticker)
                selectedID = sticker.id
                onChange()
                pendingEmoji = nil
            }
            // Same drop behavior for an imported image (custom / Apple) sticker.
            // Image stickers start larger than emoji so uploaded art is legible.
            .onChange(of: pendingImage) { _, data in
                guard let data, geo.size.width > 0 else { return }
                let sticker = NoteSticker(emoji: "", x: 0.5, y: dropY(in: geo), scale: 2, imageData: data)
                stickers.append(sticker)
                selectedID = sticker.id
                onChange()
                pendingImage = nil
            }
        }
        .evryConfirm(
            isPresented: Binding(get: { pendingDeleteID != nil }, set: { if !$0 { pendingDeleteID = nil } }),
            title: "Delete this sticker?",
            confirmTitle: "Delete sticker"
        ) {
            guard let id = pendingDeleteID else { return }
            stickers.removeAll { $0.id == id }
            selectedID = nil
            pendingDeleteID = nil
            onChange()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @GestureState private var pinch: CGFloat = 1
    @GestureState private var twist: Angle = .zero
    @State private var dragBase: CGPoint?
    // Transient "pop" when the sticker becomes selected — springs larger, then
    // settles back to its normal size to confirm the selection.
    @State private var pop: CGFloat = 1

    /// Extra margin around the sticker for the pinch/rotate area (only while
    /// selected). Tap/drag use a tight area on the sticker itself.
    private var pinchPad: CGFloat { selected ? 80 : 0 }

    /// Emoji text, or the imported image when this is an image sticker. Committed
    /// scale is baked into the size so the layout bounds match the visual size.
    @ViewBuilder private var stickerVisual: some View {
        if let data = sticker.imageData, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(width: baseSize * sticker.scale, height: baseSize * sticker.scale)
        } else {
            Text(sticker.emoji)
                .font(.nunito(size: baseSize * sticker.scale))
        }
    }

    var body: some View {
        stickerVisual
            .padding(6)
            // The ink × disc is the only selection indicator (no outline or fill).
            .overlay(alignment: .topTrailing) {
                if selected {
                    Button { onDelete() } label: {
                        Image(systemName: "xmark")
                            .font(.nunito(size: 11, weight: .heavy))
                            .foregroundStyle(Palette.onSignal)
                            .frame(width: 24, height: 24)
                            .background(Palette.danger, in: Circle())
                            .overlay(Circle().strokeBorder(palette.card, lineWidth: 2))
                            // Generous hit area around the small disc.
                            .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete sticker")
                    .offset(x: 19, y: -19)
                }
            }
            .scaleEffect(pinch * pop)
            .rotationEffect(Angle(radians: sticker.rotation) + twist)
            .contentShape(Rectangle())
            .onChange(of: selected) { _, isSelected in
                guard isSelected else { return }
                pop = 1
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.16, dampingFraction: 0.5)) { pop = 1.25 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
                    withAnimation(EvryMotion.spring) { pop = 1 }
                }
            }
            // Short-hold to (re)select and edit. A plain tap does nothing, so
            // tapping off the sticker simply places + deselects it without a tap
            // on the sticker immediately grabbing it again.
            .onLongPressGesture(minimumDuration: 0.2) { onSelect() }
            .gesture(dragGesture)
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
    var onPickImage: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Appearance.self) private var appearance
    @State private var custom = ""
    @FocusState private var customFocused: Bool
    @State private var photoItem: PhotosPickerItem?

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
                // Import a custom image sticker (e.g. an Apple sticker saved to
                // Photos, or one lifted from a photo).
                PhotosPicker(selection: $photoItem, matching: .images) {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.badge.plus")
                            .font(.nunito(size: 18, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("Add from Photos")
                            .font(.evryLabel)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.nunito(size: 13, weight: .bold))
                            .foregroundStyle(palette.textMuted)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 16)
                    .frame(minHeight: EvrySpace.storeHeight)
                    .background(palette.skySoft, in: RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous)
                        .strokeBorder(Color.evrySky, lineWidth: 1))
                }
                .buttonStyle(PressScaleStyle(scale: 0.98))
                .padding(.horizontal, 16)
                .padding(.top, 12)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(emojis, id: \.self) { emoji in
                        Button {
                            onPick(emoji)
                            dismiss()
                        } label: {
                            Text(emoji)
                                .font(.nunito(size: 30))
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                HStack(spacing: 8) {
                    TextField("Type any emoji", text: $custom)
                        .focused($customFocused)
                        .evryTextField(palette, focused: customFocused)
                    Button("Add sticker") {
                        let e = custom.trimmingCharacters(in: .whitespaces)
                        guard !e.isEmpty else { return }
                        onPick(String(e.prefix(4)))
                        dismiss()
                    }
                    .buttonStyle(EvrySecondaryButtonStyle(palette: palette))
                    .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(EvrySpace.gutter)
            }
            .background(palette.bg)
            .navigationTitle("Add a sticker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.font(.evryLabel)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(EvryRadius.panel)
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data),
                   let png = stickerImageData(ui) {
                    await MainActor.run {
                        onPickImage(png)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Downscales an imported image and returns PNG data (preserving transparency,
/// so cut-out / Apple stickers keep their alpha) for use as a note sticker.
private func stickerImageData(_ image: UIImage) -> Data? {
    let maxDim: CGFloat = 512
    let size = image.size
    guard size.width > 0, size.height > 0 else { return nil }
    let scale = min(1, maxDim / max(size.width, size.height))
    let target = CGSize(width: size.width * scale, height: size.height * scale)
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: target, format: format)
    return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }.pngData()
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
