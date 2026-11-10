import AppKit

/// Offers a new version with its release notes in a scrolling view, so long notes stay readable.
final class UpdateWindow: NSObject, NSWindowDelegate {
    enum Choice { case install, later, skip }

    private static let width: CGFloat = 480
    private static let notesHeight: CGFloat = 260
    private static let margin: CGFloat = 20
    private static let iconSize: CGFloat = 64
    private static let bulletIndent: CGFloat = 14

    private let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
    private let onChoice: (Choice) -> Void
    private var hasChosen = false
    private let installButton = NSButton(title: "Install and Relaunch", target: nil, action: nil)
    private let laterButton = NSButton(title: "Later", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip This Version", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    init(version: String, current: String, notes: String, onChoice: @escaping (Choice) -> Void) {
        self.onChoice = onChoice
        super.init()
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: Self.iconSize).isActive = true
        icon.heightAnchor.constraint(equalToConstant: Self.iconSize).isActive = true
        let title = NSTextField(labelWithString: "peekaboo \(version) is available")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        let subtitle = NSTextField(labelWithString: "You have \(current).")
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2
        let header = NSStackView(views: [icon, heading])
        header.spacing = 12

        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .lineBorder
        scroll.heightAnchor.constraint(equalToConstant: Self.notesHeight).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.textStorage?.setAttributedString(Self.render(notes))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        installButton.keyEquivalent = "\r"
        for (button, action) in [(installButton, #selector(install)), (laterButton, #selector(later)), (skipButton, #selector(skip))] {
            button.target = self
            button.action = action
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [skipButton, spacer, spinner, laterButton, installButton])
        buttons.widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        let page = NSStackView(views: [header, scroll, buttons])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 16
        page.edgeInsets = NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: Self.margin, right: Self.margin)
        window.contentView = page
        window.setContentSize(page.fittingSize)
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window.close()
    }

    @objc private func install() {
        [installButton, laterButton, skipButton].forEach { $0.isEnabled = false }
        spinner.startAnimation(nil)
        choose(.install)
    }

    @objc private func later() {
        choose(.later)
        window.close()
    }

    @objc private func skip() {
        choose(.skip)
        window.close()
    }

    private func choose(_ choice: Choice) {
        guard !hasChosen else { return }
        hasChosen = true
        onChoice(choice)
    }

    /// Closing the window means later.
    func windowWillClose(_ notification: Notification) {
        choose(.later)
    }

    /// Release notes are short Markdown: headings, bullets, and inline bold, italics, code and links.
    private static func render(_ markdown: String) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString()
        // Blank lines are dropped, with spacing around headings standing in for them.
        for line in markdown.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            var text = line
            var font = body
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 4
            if let marker = text.range(of: "^#+ ", options: .regularExpression) {
                text.removeSubrange(marker)
                font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
                paragraph.paragraphSpacingBefore = result.length > 0 ? 10 : 0
            } else if let marker = text.range(of: "^[-*] ", options: .regularExpression) {
                text.replaceSubrange(marker, with: "•\t")
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: bulletIndent)]
                paragraph.headIndent = bulletIndent
            }
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let rendered = (try? NSMutableAttributedString(markdown: text, options: options)) ?? NSMutableAttributedString(string: text)
            let whole = NSRange(location: 0, length: rendered.length)
            rendered.addAttributes([.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: whole)
            rendered.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
                guard let raw = value as? UInt else { return }
                let intent = InlinePresentationIntent(rawValue: raw)
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if intent.contains(.code) { traits.insert(.monoSpace) }
                let styled = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
                rendered.addAttribute(.font, value: styled, range: range)
            }
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(rendered)
        }
        return result
    }
}
