//
//  NoteBodyEditor.swift
//  Evry
//
//  Rich-text body editor for a note — a standard UITextView wrapped for SwiftUI
//  (the system caret and text rendering, so typing stays fast). It owns the
//  Apple Notes-style formatting bar (bold / italic / underline / strikethrough /
//  text styles / alignment / auto-continuing lists).
//
//  The rich body is an `NSAttributedString`; persistence (RTFD) lives in
//  `NoteBodyCodec`. Attribute changes are pushed back through `onEdit`.
//

import SwiftUI
import UIKit

// MARK: - SwiftUI wrapper

struct NoteBodyEditor: View {
    @Binding var text: NSAttributedString
    var placeholder: String = "Start writing…"
    let palette: Palette
    var onEdit: (NSAttributedString) -> Void = { _ in }

    @State private var controller = RichTextController()

    var body: some View {
        // The formatting bar is installed as the text view's inputAccessoryView
        // (see the representable), so it always sits above the keyboard.
        RichTextEditorRepresentable(text: $text, palette: palette,
                                    placeholder: placeholder,
                                    controller: controller, onEdit: onEdit)
    }
}

// MARK: - Formatting bar (hosted above the keyboard as inputAccessoryView)

struct NoteFormattingBar: View {
    var controller: RichTextController
    let palette: Palette

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        // Title = Nunito ExtraBold 28, Heading = Bold 22 (h3), Body = Regular 16.
                        Button { controller.applyTextStyle(size: 28, weight: .heavy) } label: {
                            Label("Title", systemImage: controller.textStyle == .title ? "checkmark" : "textformat.size.larger")
                        }
                        Button { controller.applyTextStyle(size: 22, weight: .bold) } label: {
                            Label("Heading", systemImage: controller.textStyle == .heading ? "checkmark" : "textformat.size")
                        }
                        Button { controller.applyTextStyle(size: 16, weight: .regular) } label: {
                            Label("Body", systemImage: controller.textStyle == .body ? "checkmark" : "textformat")
                        }
                    } label: {
                        iconChip("textformat", active: controller.textStyle != .body)
                    }
                    .accessibilityLabel("Text style")

                    divider

                    formatButton(icon: "bold", label: "Bold", active: controller.isBold) { controller.toggleTrait(.traitBold) }
                    formatButton(icon: "italic", label: "Italic", active: controller.isItalic) { controller.toggleTrait(.traitItalic) }
                    formatButton(icon: "underline", label: "Underline", active: controller.isUnderline) { controller.toggleUnderline() }
                    formatButton(icon: "strikethrough", label: "Strikethrough", active: controller.isStrikethrough) { controller.toggleStrikethrough() }

                    divider

                    formatButton(icon: "text.alignleft", label: "Align left", active: controller.alignment == .left) { controller.setAlignment(.left) }
                    formatButton(icon: "text.aligncenter", label: "Align centre", active: controller.alignment == .center) { controller.setAlignment(.center) }
                    formatButton(icon: "text.alignright", label: "Align right", active: controller.alignment == .right) { controller.setAlignment(.right) }
                    formatButton(icon: "text.justify", label: "Justify", active: controller.alignment == .justified) { controller.setAlignment(.justified) }

                    divider

                    formatButton(icon: "list.bullet", label: "Bulleted list", active: controller.listActive == .bulleted) { controller.startList(.bulleted) }
                    formatButton(icon: "list.number", label: "Numbered list", active: controller.listActive == .numbered) { controller.startList(.numbered) }
                }
                .padding(.horizontal, 12)
            }

            Rectangle().fill(palette.border).frame(width: 1, height: 24)

            Button { controller.dismissKeyboard() } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.nunito(size: 16, weight: .bold))
                    .foregroundStyle(palette.primary)
                    .frame(width: EvrySpace.tap + 4, height: EvrySpace.tap)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide keyboard")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(palette.card)
        .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
    }

    private var divider: some View {
        Rectangle().fill(palette.border).frame(width: 1, height: 22).padding(.horizontal, 2)
    }

    private func iconChip(_ icon: String, active: Bool) -> some View {
        Image(systemName: icon)
            .font(.nunito(size: 15, weight: .bold))
            // Active: a sky tile with a navy glyph (the brand's "on" state);
            // resting: a sky-soft tile with ink glyph.
            .foregroundStyle(active ? Color.evryNavy : palette.text)
            .frame(width: EvrySpace.tap, height: 40)
            .background(active ? Color.evrySky : palette.skySoft,
                        in: RoundedRectangle(cornerRadius: EvryRadius.tile, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: EvryRadius.tile, style: .continuous))
            .animation(EvryMotion.hover, value: active)
    }

    private func formatButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { iconChip(icon, active: active) }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(label)
            .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Representable bridge

private struct RichTextEditorRepresentable: UIViewRepresentable {
    @Binding var text: NSAttributedString
    let palette: Palette
    let placeholder: String
    let controller: RichTextController
    let onEdit: (NSAttributedString) -> Void

    func makeUIView(context: Context) -> NoteTextView {
        let tv = NoteTextView()
        tv.font = tv.bodyFont   // one-time default; never reset afterwards
        tv.delegate = controller
        controller.textView = tv
        controller.textBinding = $text
        controller.onEdit = onEdit
        tv.configure(palette: palette)
        tv.setAttributedTextPreservingSelection(text.length > 0 ? text : NSAttributedString(string: "", attributes: tv.bodyTypingAttributes))
        tv.typingAttributes = tv.bodyTypingAttributes
        tv.placeholderText = placeholder
        tv.refreshPlaceholder()
        installAccessory(on: tv)
        return tv
    }

    func updateUIView(_ tv: NoteTextView, context: Context) {
        controller.textBinding = $text
        controller.onEdit = onEdit
        tv.configure(palette: palette)
        // Reflect external content changes (initial load, brain dump append).
        // Compare plain strings so attribute-only differences don't reload.
        if (tv.attributedText?.string ?? "") != text.string {
            tv.setAttributedTextPreservingSelection(text)
        }
        tv.placeholderText = placeholder
        tv.refreshPlaceholder()
        // Keep the hosted bar's palette in sync (e.g. light/dark change).
        if let host = controller.accessoryHost as? UIHostingController<NoteFormattingBar> {
            host.rootView = NoteFormattingBar(controller: controller, palette: palette)
        }
    }

    /// Hosts the SwiftUI formatting bar as the text view's inputAccessoryView so
    /// it always rides above the keyboard and keeps the field focused when tapped.
    private func installAccessory(on tv: NoteTextView) {
        let host = UIHostingController(rootView: NoteFormattingBar(controller: controller, palette: palette))
        host.view.backgroundColor = .clear
        // The text view's own screen (not the deprecated UIScreen.main); the
        // flexible width then follows the keyboard's.
        let width = tv.window?.windowScene?.screen.bounds.width ?? tv.bounds.width
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 52)
        host.view.autoresizingMask = [.flexibleWidth]
        controller.accessoryHost = host
        tv.inputAccessoryView = host.view
    }
}

// MARK: - Controller (delegate + toolbar state/actions)

enum NoteListKind: Equatable { case bulleted, numbered }
enum NoteTextStyle: Equatable { case title, heading, body }

@Observable
final class RichTextController: NSObject, UITextViewDelegate {
    @ObservationIgnored weak var textView: NoteTextView?
    @ObservationIgnored var textBinding: Binding<NSAttributedString>?
    @ObservationIgnored var onEdit: ((NSAttributedString) -> Void)?
    /// Retains the hosting controller for the inputAccessoryView formatting bar.
    @ObservationIgnored var accessoryHost: UIViewController?

    var isBold = false
    var isItalic = false
    var isUnderline = false
    var isStrikethrough = false
    var listActive: NoteListKind? = nil
    var textStyle: NoteTextStyle = .body
    var alignment: NSTextAlignment = .left

    // List markers use a trailing tab so text hangs at a fixed indent and wrapped
    // / continuation lines align under it (via the list paragraph style below).
    private let listIndent: CGFloat = 26
    private var bulletMarker: String { "•\t" }
    private func numberMarker(_ n: Int) -> String { "\(n).\t" }

    private func listParagraphStyle() -> NSParagraphStyle {
        let s = NSMutableParagraphStyle()
        s.tabStops = [NSTextTab(textAlignment: .left, location: listIndent)]
        s.defaultTabInterval = listIndent
        s.headIndent = listIndent          // wrapped lines indent to the text
        s.firstLineHeadIndent = 0
        return s
    }
    private var defaultParagraphStyle: NSParagraphStyle { NSMutableParagraphStyle() }

    /// The list kind of a line, detected from its leading marker (stateless, so
    /// it survives closing and reopening the note).
    private func markerKind(ofLine line: String) -> NoteListKind? {
        if line.hasPrefix(bulletMarker) { return .bulleted }
        if let tab = line.firstIndex(of: "\t") {
            let head = line[line.startIndex..<tab]
            let digits = head.dropLast()
            if head.hasSuffix("."), !digits.isEmpty, digits.allSatisfy(\.isNumber) { return .numbered }
        }
        return nil
    }

    private func number(ofLine line: String) -> Int? {
        guard let tab = line.firstIndex(of: "\t") else { return nil }
        let head = line[line.startIndex..<tab]
        guard head.hasSuffix(".") else { return nil }
        return Int(head.dropLast())
    }

    private func isEmptyMarkerLine(_ line: String) -> Bool {
        if line == bulletMarker { return true }
        if line.hasSuffix(".\t") {
            let digits = line.dropLast(2)
            return !digits.isEmpty && digits.allSatisfy(\.isNumber)
        }
        return false
    }

    private var bodyFont: UIFont { textView?.bodyFont ?? .nunito(size: 16) }

    // MARK: Delegate

    func textViewDidChange(_ tv: UITextView) {
        pushText()
    }

    func textViewDidChangeSelection(_ tv: UITextView) {
        refreshState()
    }

    func textViewDidBeginEditing(_ tv: UITextView) {
        refreshState()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let tv = textView as? NoteTextView else { return true }

        // Auto-continue lists on Return — the current line's marker is read from
        // the text itself, so continuation works after reopening the note.
        guard text == "\n" else { return true }

        let storageString = tv.textStorage.string as NSString
        var lineStart = range.location
        while lineStart > 0 && storageString.character(at: lineStart - 1) != 10 { lineStart -= 1 }
        let lineContent = storageString.substring(with: NSRange(location: lineStart, length: range.location - lineStart))

        guard let kind = markerKind(ofLine: lineContent) else { return true }

        if isEmptyMarkerLine(lineContent) {
            // Return on an empty item → strip the marker and leave the list.
            var attrs = tv.typingAttributes
            attrs[.paragraphStyle] = defaultParagraphStyle
            tv.textStorage.replaceCharacters(
                in: NSRange(location: lineStart, length: range.location - lineStart),
                with: NSAttributedString(string: "", attributes: attrs)
            )
            tv.selectedRange = NSRange(location: lineStart, length: 0)
            tv.typingAttributes = attrs
            listActive = nil
            pushText(); refreshState()
            return false
        } else {
            let marker: String
            switch kind {
            case .bulleted: marker = bulletMarker
            case .numbered: marker = numberMarker((number(ofLine: lineContent) ?? 0) + 1)
            }
            let insertion = "\n" + marker
            var attrs = tv.typingAttributes
            attrs[.paragraphStyle] = listParagraphStyle()
            tv.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: insertion, attributes: attrs))
            let caret = range.location + (insertion as NSString).length
            tv.selectedRange = NSRange(location: caret, length: 0)
            tv.typingAttributes = attrs
            listActive = kind
            pushText(); refreshState()
            return false
        }
    }

    // MARK: List helpers

    func startList(_ mode: NoteListKind) {
        guard let tv = textView else { return }
        listActive = mode
        let marker = mode == .bulleted ? bulletMarker : numberMarker(1)
        let range = tv.selectedRange
        var attrs = tv.typingAttributes
        attrs[.paragraphStyle] = listParagraphStyle()
        tv.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: marker, attributes: attrs))
        tv.selectedRange = NSRange(location: range.location + (marker as NSString).length, length: 0)
        tv.typingAttributes = attrs
        // Apply the hanging-indent paragraph style across the whole current line.
        let paraRange = (tv.textStorage.string as NSString).paragraphRange(for: tv.selectedRange)
        tv.textStorage.addAttribute(.paragraphStyle, value: listParagraphStyle(), range: paraRange)
        pushText(); refreshState()
        tv.becomeFirstResponder()
    }

    // MARK: Character-style actions

    func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        mutateFont { font in
            let isOn = font.fontDescriptor.symbolicTraits.contains(trait)
            return font.withTrait(trait, on: !isOn)
        }
    }

    func applyTextStyle(size: CGFloat, weight: UIFont.Weight) {
        mutateFont { _ in .nunito(size: size, weight: weight) }
    }

    func toggleUnderline() { toggleLineStyle(.underlineStyle) }
    func toggleStrikethrough() { toggleLineStyle(.strikethroughStyle) }

    // MARK: Paragraph alignment

    /// Alignment is a paragraph attribute, so it applies to the whole paragraph(s)
    /// the selection touches (and to typing attributes for what's typed next).
    func setAlignment(_ newAlignment: NSTextAlignment) {
        guard let tv = textView else { return }
        let ns = tv.textStorage.string as NSString
        let paraRange = ns.paragraphRange(for: tv.selectedRange)
        if paraRange.length > 0 {
            tv.textStorage.enumerateAttribute(.paragraphStyle, in: paraRange, options: []) { value, sub, _ in
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.alignment = newAlignment
                tv.textStorage.addAttribute(.paragraphStyle, value: style, range: sub)
            }
        }
        let typingStyle = (tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        typingStyle.alignment = newAlignment
        tv.typingAttributes[.paragraphStyle] = typingStyle
        alignment = newAlignment
        pushText(); refreshState()
    }

    private func toggleLineStyle(_ key: NSAttributedString.Key) {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        let currentlyOn = (activeAttributes()[key] as? Int ?? 0) != 0
        let newValue = currentlyOn ? 0 : NSUnderlineStyle.single.rawValue
        if range.length > 0 {
            tv.textStorage.addAttribute(key, value: newValue, range: range)
        }
        tv.typingAttributes[key] = newValue
        pushText(); refreshState()
    }

    private func mutateFont(_ transform: (UIFont) -> UIFont) {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        if range.length > 0 {
            // Collect first (don't mutate mid-enumeration), then apply.
            var updates: [(NSRange, UIFont)] = []
            tv.textStorage.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
                let font = (value as? UIFont) ?? bodyFont
                updates.append((sub, transform(font)))
            }
            for (sub, font) in updates {
                tv.textStorage.addAttribute(.font, value: font, range: sub)
            }
        }
        let typingFont = (tv.typingAttributes[.font] as? UIFont) ?? bodyFont
        tv.typingAttributes[.font] = transform(typingFont)
        pushText(); refreshState()
    }

    func dismissKeyboard() { textView?.resignFirstResponder() }

    // MARK: State reflection

    private func activeAttributes() -> [NSAttributedString.Key: Any] {
        guard let tv = textView else { return [:] }
        if tv.selectedRange.length > 0, tv.selectedRange.location < tv.textStorage.length {
            return tv.textStorage.attributes(at: tv.selectedRange.location, effectiveRange: nil)
        }
        return tv.typingAttributes
    }

    private func refreshState() {
        let attrs = activeAttributes()
        let font = (attrs[.font] as? UIFont) ?? bodyFont
        isBold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
        isItalic = font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        isUnderline = (attrs[.underlineStyle] as? Int ?? 0) != 0
        isStrikethrough = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
        textStyle = font.pointSize >= 24 ? .title : (font.pointSize >= 18 ? .heading : .body)
        alignment = (attrs[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .left

        // Reflect the current line's list marker so the toolbar highlights the
        // right button (also keeps state correct after reopening the note).
        if let tv = textView {
            let ns = tv.textStorage.string as NSString
            let loc = min(tv.selectedRange.location, ns.length)
            var start = loc
            while start > 0 && ns.character(at: start - 1) != 10 { start -= 1 }
            let line = ns.substring(with: NSRange(location: start, length: max(0, loc - start)))
            listActive = markerKind(ofLine: line)
        }
    }

    private func pushText() {
        guard let tv = textView else { return }
        let snapshot = NSAttributedString(attributedString: tv.attributedText ?? NSAttributedString())
        textBinding?.wrappedValue = snapshot
        onEdit?(snapshot)
        tv.refreshPlaceholder()
    }
}

// MARK: - Font trait helper

private extension UIFont {
    /// Toggles bold/italic by rebuilding the matching Nunito face directly
    /// (`withSymbolicTraits` is unreliable across fonts and can silently return
    /// the original).
    func withTrait(_ trait: UIFontDescriptor.SymbolicTraits, on: Bool) -> UIFont {
        var traits = fontDescriptor.symbolicTraits
        if on { traits.insert(trait) } else { traits.remove(trait) }
        return .nunito(size: pointSize,
                       weight: traits.contains(.traitBold) ? Self.boldWeight(forSize: pointSize) : .regular,
                       italic: traits.contains(.traitItalic))
    }

    /// Headlines are heavy: title-sized text bolds to ExtraBold, the rest to Bold.
    static func boldWeight(forSize size: CGFloat) -> UIFont.Weight {
        size >= 24 ? .heavy : .bold
    }

    /// The Nunito equivalent of this font (same size, bold and italic) — used to
    /// bring notes saved in the system font into the app typeface.
    var asNunito: UIFont {
        guard !familyName.localizedCaseInsensitiveContains("Nunito") else { return self }
        let traits = fontDescriptor.symbolicTraits
        return .nunito(size: pointSize,
                       weight: traits.contains(.traitBold) ? Self.boldWeight(forSize: pointSize) : .regular,
                       italic: traits.contains(.traitItalic))
    }
}

extension UIFont {
    /// The app typeface (Nunito) as a UIFont for UIKit text views — e.g.
    /// "Nunito-Regular", "Nunito-Bold", "Nunito-ExtraBold" — falling back to the
    /// system font if the bundled face isn't available.
    static func nunito(size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        let base: String
        switch weight {
        case .medium: base = "Medium"
        case .semibold: base = "SemiBold"
        case .bold: base = "Bold"
        case .heavy: base = "ExtraBold"
        case .black: base = "Black"
        default: base = "Regular"
        }
        let name = italic ? (base == "Regular" ? "Nunito-Italic" : "Nunito-\(base)Italic") : "Nunito-\(base)"
        if let font = UIFont(name: name, size: size) { return font }
        let system = UIFont.systemFont(ofSize: size, weight: weight)
        guard italic, let d = system.fontDescriptor.withSymbolicTraits(.traitItalic) else { return system }
        return UIFont(descriptor: d, size: size)
    }
}

// MARK: - Text view

/// The note's text view: a standard UITextView (system caret and rendering)
/// with the app's theming and a placeholder.
final class NoteTextView: UITextView {
    let bodyFont = UIFont.nunito(size: 16)
    var placeholderText = ""

    private let placeholderLabel = UILabel()

    var bodyTypingAttributes: [NSAttributedString.Key: Any] {
        let ink = textColor ?? .label
        // Line decorations get the ink colour explicitly so strikethroughs and
        // underlines always match the text.
        return [.font: bodyFont, .foregroundColor: ink, .strikethroughColor: ink, .underlineColor: ink]
    }

    /// Recolours a whole document with the current theme's ink. Notes store
    /// their colours in the archived body, so one saved in the other theme (or
    /// before explicit decoration colours) would otherwise open with white text
    /// or white strikethroughs until something re-rendered it.
    func themed(_ text: NSAttributedString) -> NSAttributedString {
        guard text.length > 0 else { return text }
        let ink = textColor ?? .label
        let out = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: out.length)
        out.addAttributes([.foregroundColor: ink, .strikethroughColor: ink, .underlineColor: ink], range: full)
        // Notes saved before the editor used Nunito carry system-font runs —
        // bring them into the app typeface (keeping size, bold and italic).
        var fontUpdates: [(NSRange, UIFont)] = []
        out.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            let font = (value as? UIFont) ?? bodyFont
            let nunito = font.asNunito
            if nunito != font || value == nil { fontUpdates.append((range, nunito)) }
        }
        for (range, font) in fontUpdates { out.addAttribute(.font, value: font, range: range) }
        styleLinks(in: out)
        return out
    }

    /// The design system's TextLink: bold, current ink, with a soft navy-30
    /// underline (white-35 on navy). Applied to any `.link` runs in the body.
    private var linkUnderlineColor: UIColor {
        traitCollection.userInterfaceStyle == .dark ? UIColor(Color.evryWhite35) : UIColor(Color.evryNavy.opacity(0.3))
    }

    private func styleLinks(in storage: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: storage.length)
        var updates: [(NSRange, UIFont)] = []
        storage.enumerateAttribute(.link, in: full, options: []) { value, range, _ in
            guard value != nil else { return }
            storage.enumerateAttribute(.font, in: range, options: []) { f, sub, _ in
                let font = (f as? UIFont) ?? bodyFont
                let italic = font.fontDescriptor.symbolicTraits.contains(.traitItalic)
                updates.append((sub, .nunito(size: font.pointSize,
                                             weight: UIFont.boldWeight(forSize: font.pointSize),
                                             italic: italic)))
            }
            storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue,
                                   .underlineColor: linkUnderlineColor], range: range)
        }
        for (range, font) in updates { storage.addAttribute(.font, value: font, range: range) }
    }

    /// Applies the current ink to the live document in place (theme switch).
    private func rethemeStorage() {
        guard textStorage.length > 0 else { return }
        let ink = textColor ?? .label
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.addAttributes([.foregroundColor: ink, .strikethroughColor: ink, .underlineColor: ink], range: full)
        styleLinks(in: textStorage)
        typingAttributes[.foregroundColor] = ink
        typingAttributes[.strikethroughColor] = ink
        typingAttributes[.underlineColor] = ink
    }

    // MARK: Setup

    func configure(palette: Palette) {
        backgroundColor = .clear
        // NOTE: never assign `self.font` here — setting a UITextView's font
        // re-applies it to the whole document, wiping per-run bold/italic/size.
        // `textColor` only affects color (safe, and keeps text theme-correct).
        let ink = UIColor(palette.text)
        let inkChanged = textColor != ink
        textColor = ink
        if inkChanged { rethemeStorage() }
        tintColor = UIColor(palette.primary)
        // Links read as ink with the soft TextLink underline (bold is applied
        // per-run in `styleLinks`, since linkTextAttributes can't set a font).
        linkTextAttributes = [
            .foregroundColor: ink,
            .underlineStyle: NSUnderlineStyle.thick.rawValue,
            .underlineColor: linkUnderlineColor,
        ]
        autocorrectionType = .default
        autocapitalizationType = .sentences
        textContainerInset = UIEdgeInsets(top: 8, left: 5, bottom: 8, right: 5)

        if placeholderLabel.superview == nil {
            placeholderLabel.numberOfLines = 0
            placeholderLabel.isUserInteractionEnabled = false
            addSubview(placeholderLabel)
        }
        placeholderLabel.font = bodyFont
        placeholderLabel.textColor = UIColor(palette.textPh)
    }

    /// Replaces content while keeping the caret where it was when possible.
    func setAttributedTextPreservingSelection(_ new: NSAttributedString) {
        let sel = selectedRange
        attributedText = themed(new)
        let loc = min(sel.location, (new.string as NSString).length)
        selectedRange = NSRange(location: loc, length: 0)
        refreshPlaceholder()
    }

    // MARK: Placeholder

    func refreshPlaceholder() {
        placeholderLabel.text = placeholderText
        placeholderLabel.isHidden = !(text ?? "").isEmpty ? true : false
        let width = bounds.width - textContainerInset.left - textContainerInset.right - 2 * textContainer.lineFragmentPadding
        placeholderLabel.frame = CGRect(
            x: textContainerInset.left + textContainer.lineFragmentPadding,
            y: textContainerInset.top,
            width: max(0, width),
            height: placeholderLabel.sizeThatFits(CGSize(width: max(0, width), height: CGFloat.greatestFiniteMagnitude)).height
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshPlaceholder()
    }
}
