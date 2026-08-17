//
//  NoteBodyEditor.swift
//  Evry
//
//  Rich-text body editor for a note — a custom UIKit/TextKit-1 editor wrapped for
//  SwiftUI. It adds two touches the native TextEditor can't: a caret that glides
//  smoothly to each new position as you type, and freshly typed characters that
//  fade in. It also owns the Apple Notes-style formatting bar (bold / italic /
//  underline / strikethrough / text styles / auto-continuing lists).
//
//  The rich body is an `NSAttributedString`; persistence (RTFD) lives in
//  `NoteBodyCodec`. Attribute changes are pushed back through `onEdit`.
//

import SwiftUI
import UIKit

// MARK: - Custom attribute

extension NSAttributedString.Key {
    /// Timestamp (CACurrentMediaTime) marking when a run was typed, so the layout
    /// manager can fade it in. Purely transient — RTFD does not persist it.
    static let evryFadeStart = NSAttributedString.Key("EvryFadeStart")
}

private let fadeDuration: CFTimeInterval = 0.09

// MARK: - SwiftUI wrapper

struct NoteBodyEditor: View {
    @Binding var text: NSAttributedString
    var placeholder: String = "Start writing…"
    let palette: Palette
    var onEdit: (NSAttributedString) -> Void = { _ in }
    /// Reports the text view's vertical scroll offset (so overlaid stickers can
    /// track the content as it scrolls).
    var onScroll: (CGFloat) -> Void = { _ in }

    @State private var controller = RichTextController()

    var body: some View {
        // The formatting bar is installed as the text view's inputAccessoryView
        // (see the representable), so it always sits above the keyboard.
        RichTextEditorRepresentable(text: $text, palette: palette,
                                    placeholder: placeholder,
                                    controller: controller, onEdit: onEdit, onScroll: onScroll)
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
                        Button { controller.applyTextStyle(size: 28, weight: .bold) } label: {
                            Label("Title", systemImage: controller.textStyle == .title ? "checkmark" : "textformat.size.larger")
                        }
                        Button { controller.applyTextStyle(size: 20, weight: .semibold) } label: {
                            Label("Heading", systemImage: controller.textStyle == .heading ? "checkmark" : "textformat.size")
                        }
                        Button { controller.applyTextStyle(size: 16, weight: .regular) } label: {
                            Label("Body", systemImage: controller.textStyle == .body ? "checkmark" : "textformat")
                        }
                    } label: {
                        iconChip("textformat", active: controller.textStyle != .body)
                    }

                    divider

                    formatButton(icon: "bold", active: controller.isBold) { controller.toggleTrait(.traitBold) }
                    formatButton(icon: "italic", active: controller.isItalic) { controller.toggleTrait(.traitItalic) }
                    formatButton(icon: "underline", active: controller.isUnderline) { controller.toggleUnderline() }
                    formatButton(icon: "strikethrough", active: controller.isStrikethrough) { controller.toggleStrikethrough() }

                    divider

                    formatButton(icon: "text.alignleft", active: controller.alignment == .left) { controller.setAlignment(.left) }
                    formatButton(icon: "text.aligncenter", active: controller.alignment == .center) { controller.setAlignment(.center) }
                    formatButton(icon: "text.alignright", active: controller.alignment == .right) { controller.setAlignment(.right) }
                    formatButton(icon: "text.justify", active: controller.alignment == .justified) { controller.setAlignment(.justified) }

                    divider

                    formatButton(icon: "list.bullet", active: controller.listActive == .bulleted) { controller.startList(.bulleted) }
                    formatButton(icon: "list.number", active: controller.listActive == .numbered) { controller.startList(.numbered) }
                }
                .padding(.horizontal, 12)
            }

            Rectangle().fill(palette.border).frame(width: 1, height: 24)

            Button { controller.dismissKeyboard() } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .frame(width: 46, height: 34)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(palette.card)
        .overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private var divider: some View {
        Rectangle().fill(palette.border).frame(width: 1, height: 22).padding(.horizontal, 2)
    }

    private func iconChip(_ icon: String, active: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(active ? palette.onPrimary : palette.text)
            .frame(width: 38, height: 32)
            .background(active ? palette.primary : palette.hover,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func formatButton(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { iconChip(icon, active: active) }
            .buttonStyle(.plain)
    }
}

// MARK: - Representable bridge

private struct RichTextEditorRepresentable: UIViewRepresentable {
    @Binding var text: NSAttributedString
    let palette: Palette
    let placeholder: String
    let controller: RichTextController
    let onEdit: (NSAttributedString) -> Void
    let onScroll: (CGFloat) -> Void

    func makeUIView(context: Context) -> FadingCaretTextView {
        let tv = FadingCaretTextView.make()
        tv.delegate = controller
        controller.textView = tv
        controller.textBinding = $text
        controller.onEdit = onEdit
        controller.onScroll = onScroll
        tv.configure(palette: palette)
        tv.setAttributedTextPreservingSelection(text.length > 0 ? text : NSAttributedString(string: "", attributes: tv.bodyTypingAttributes))
        tv.typingAttributes = tv.bodyTypingAttributes
        tv.placeholderText = placeholder
        tv.refreshPlaceholder()
        installAccessory(on: tv)
        return tv
    }

    func updateUIView(_ tv: FadingCaretTextView, context: Context) {
        controller.textBinding = $text
        controller.onEdit = onEdit
        controller.onScroll = onScroll
        tv.configure(palette: palette)
        // Reflect external content changes (initial load, brain dump append).
        // Compare plain strings so transient fade attributes don't trigger reloads.
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
    private func installAccessory(on tv: FadingCaretTextView) {
        let host = UIHostingController(rootView: NoteFormattingBar(controller: controller, palette: palette))
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 50)
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
    @ObservationIgnored weak var textView: FadingCaretTextView?
    @ObservationIgnored var textBinding: Binding<NSAttributedString>?
    @ObservationIgnored var onEdit: ((NSAttributedString) -> Void)?
    @ObservationIgnored var onScroll: ((CGFloat) -> Void)?
    /// Retains the hosting controller for the inputAccessoryView formatting bar.
    @ObservationIgnored var accessoryHost: UIViewController?

    var isFocused = false
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

    private var bodyFont: UIFont { textView?.bodyFont ?? .systemFont(ofSize: 16) }

    // MARK: Delegate

    func textViewDidChange(_ tv: UITextView) {
        (tv as? FadingCaretTextView)?.commitPendingFade()
        pushText()
    }

    // UITextViewDelegate refines UIScrollViewDelegate, so this is called as the
    // text view scrolls — used to keep overlaid stickers tracking the content.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScroll?(scrollView.contentOffset.y)
    }

    func textViewDidChangeSelection(_ tv: UITextView) {
        (tv as? FadingCaretTextView)?.moveCaret(animated: true)
        refreshState()
    }

    func textViewDidBeginEditing(_ tv: UITextView) {
        isFocused = true
        (tv as? FadingCaretTextView)?.moveCaret(animated: false)
        refreshState()
    }

    func textViewDidEndEditing(_ tv: UITextView) {
        isFocused = false
        (tv as? FadingCaretTextView)?.hideCaret()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let tv = textView as? FadingCaretTextView else { return true }

        // Fade in only genuine single-character typing. Autocorrect / predictive
        // replacements (multi-character, or replacing an existing range) and pastes
        // insert without a fade so a corrected word doesn't re-animate.
        let isTyping = range.length == 0 && text.count == 1
        tv.pendingFade = isTyping ? NSRange(location: range.location, length: (text as NSString).length) : nil

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
            tv.pendingFade = nil
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
            // Fade the freshly inserted marker (the part after the newline).
            tv.pendingFade = NSRange(location: range.location + 1, length: (marker as NSString).length)
            tv.commitPendingFade()
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
        tv.pendingFade = NSRange(location: range.location, length: (marker as NSString).length)
        tv.commitPendingFade()
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
        mutateFont { _ in .systemFont(ofSize: size, weight: weight) }
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
            // Collect first (don't mutate mid-enumeration), then apply directly —
            // matching the working underline/strikethrough path. Wrapping these in
            // beginEditing/endEditing with the custom layout manager was preventing
            // the font change from taking visual effect.
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
    /// Toggles bold/italic reliably for the system font. Rebuilding from a fresh
    /// system font (bold via weight, italic via descriptor) avoids the case where
    /// `withSymbolicTraits` refuses to apply to the system font's descriptor and
    /// silently returns the original font.
    func withTrait(_ trait: UIFontDescriptor.SymbolicTraits, on: Bool) -> UIFont {
        var traits = fontDescriptor.symbolicTraits
        if on { traits.insert(trait) } else { traits.remove(trait) }
        let wantsBold = traits.contains(.traitBold)
        let wantsItalic = traits.contains(.traitItalic)

        let base = UIFont.systemFont(ofSize: pointSize, weight: wantsBold ? .bold : .regular)
        guard wantsItalic else { return base }
        let italicTraits = base.fontDescriptor.symbolicTraits.union(.traitItalic)
        if let descriptor = base.fontDescriptor.withSymbolicTraits(italicTraits) {
            return UIFont(descriptor: descriptor, size: pointSize)
        }
        return base
    }
}

// MARK: - Text view (custom caret + glyph fade-in)

final class FadingCaretTextView: UITextView {
    let bodyFont = UIFont.systemFont(ofSize: 16)
    var placeholderText = ""
    /// Range awaiting a fade-in, captured in `shouldChangeText` and applied once
    /// the characters actually exist.
    var pendingFade: NSRange?

    private let caretView = UIView()
    private let placeholderLabel = UILabel()
    private var displayLink: CADisplayLink?
    private var caretColor: UIColor = .tintColor

    /// Builds the TextKit-1 stack so our custom layout manager is used.
    static func make() -> FadingCaretTextView {
        let storage = NSTextStorage()
        let layout = FadingLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let tv = FadingCaretTextView(frame: .zero, textContainer: container)
        tv.font = tv.bodyFont   // one-time default; never reset afterwards
        return tv
    }

    var bodyTypingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: textColor ?? .label]
    }

    // MARK: Setup

    func configure(palette: Palette) {
        backgroundColor = .clear
        // NOTE: never assign `self.font` here — setting a UITextView's font
        // re-applies it to the whole document, wiping per-run bold/italic/size.
        // `textColor` only affects color (safe, and keeps text theme-correct).
        textColor = UIColor(palette.text)
        tintColor = UIColor(palette.primary)
        caretColor = UIColor(palette.primary)
        caretView.backgroundColor = caretColor
        autocorrectionType = .default
        autocapitalizationType = .sentences
        textContainerInset = UIEdgeInsets(top: 8, left: 5, bottom: 8, right: 5)

        if caretView.superview == nil {
            caretView.layer.cornerRadius = 1
            caretView.isHidden = true
            addSubview(caretView)
        }
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
        attributedText = new
        let loc = min(sel.location, (new.string as NSString).length)
        selectedRange = NSRange(location: loc, length: 0)
        moveCaret(animated: false)
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
        moveCaret(animated: false)
    }

    // MARK: Custom caret

    // Fully hide the system caret (zero size) but keep its origin so auto-scroll
    // to the caret still works. Selection handles/highlight are unaffected.
    private var revealTrueCaret = false
    override func caretRect(for position: UITextPosition) -> CGRect {
        if revealTrueCaret { return super.caretRect(for: position) }
        // Fully suppress the system caret; our custom caretView draws it instead.
        return .zero
    }

    private func trueCaretRect(for position: UITextPosition) -> CGRect {
        revealTrueCaret = true
        defer { revealTrueCaret = false }
        return caretRect(for: position)
    }

    func moveCaret(animated: Bool) {
        guard isFirstResponder, let range = selectedTextRange, range.isEmpty else {
            caretView.isHidden = true
            return
        }
        // Ensure layout is current before reading the caret rect — right after a
        // Return, a stale layout can briefly report the previous line's position,
        // which is what made the caret jump to the top line and back.
        layoutManager.ensureLayout(for: textContainer)
        caretView.isHidden = false
        let rect = trueCaretRect(for: range.start)
        // Keep the caret a constant height (the current typing font's line height),
        // centered on the caret rect, so it doesn't jump with the adjacent glyph.
        let font = (typingAttributes[.font] as? UIFont) ?? bodyFont
        let height = font.lineHeight
        let target = CGRect(x: rect.minX, y: rect.midY - height / 2, width: 2, height: height)
        // Glide only within a line; snap when the line (vertical position) changes
        // so the caret never animates through an intermediate/stale line.
        let sameLine = !caretView.frame.isEmpty && abs(target.midY - caretView.frame.midY) < height * 0.75
        if animated && sameLine {
            UIView.animate(withDuration: 0.09, delay: 0,
                           options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
                self.caretView.frame = target
            }
        } else {
            caretView.frame = target
        }
        restartBlink()
    }

    func hideCaret() {
        caretView.isHidden = true
        caretView.layer.removeAnimation(forKey: "blink")
    }

    private func restartBlink() {
        caretView.layer.removeAnimation(forKey: "blink")
        caretView.layer.opacity = 1
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0
        blink.duration = 0.5
        blink.autoreverses = true
        blink.repeatCount = .infinity
        // Stay solid briefly after the caret moves, so fast typing reads clearly.
        blink.beginTime = CACurrentMediaTime() + 0.5
        caretView.layer.add(blink, forKey: "blink")
    }

    // MARK: Fade-in

    func commitPendingFade() {
        guard let range = pendingFade,
              range.location >= 0,
              range.location + range.length <= textStorage.length else {
            pendingFade = nil
            return
        }
        pendingFade = nil
        textStorage.addAttribute(.evryFadeStart, value: CACurrentMediaTime(), range: range)
        startFadeLoop()
    }

    private func startFadeLoop() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(stepFade))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func stepFade() {
        let now = CACurrentMediaTime()
        var active = false
        var expired: [NSRange] = []
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.evryFadeStart, in: full, options: []) { value, range, _ in
            guard let start = value as? CFTimeInterval else { return }
            if now - start >= fadeDuration {
                expired.append(range)
            } else {
                active = true
                layoutManager.invalidateDisplay(forCharacterRange: range)
            }
        }
        for range in expired {
            textStorage.removeAttribute(.evryFadeStart, range: range)
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
        if !active {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    deinit {
        displayLink?.invalidate()
    }
}

// MARK: - Layout manager that fades freshly typed glyphs

final class FadingLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let storage = textStorage else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let now = CACurrentMediaTime()

        storage.enumerateAttribute(.evryFadeStart, in: charRange, options: []) { value, subCharRange, _ in
            let subGlyphRange = glyphRange(forCharacterRange: subCharRange, actualCharacterRange: nil)
            if let start = value as? CFTimeInterval {
                let alpha = max(0, min(1, CGFloat((now - start) / fadeDuration)))
                if let ctx = UIGraphicsGetCurrentContext() {
                    ctx.saveGState()
                    ctx.setAlpha(alpha)
                    super.drawGlyphs(forGlyphRange: subGlyphRange, at: origin)
                    ctx.restoreGState()
                } else {
                    super.drawGlyphs(forGlyphRange: subGlyphRange, at: origin)
                }
            } else {
                super.drawGlyphs(forGlyphRange: subGlyphRange, at: origin)
            }
        }
    }
}
