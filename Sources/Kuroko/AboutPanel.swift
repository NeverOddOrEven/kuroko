import AppKit

@MainActor
enum AboutPanel {
    private static let tagline = "Visible to you, not your audience"
    private static let wikipediaURL = URL(string: "https://en.wikipedia.org/wiki/Kuroko")!
    private static let repositoryURL = URL(string: "https://github.com/NeverOddOrEven/kuroko")!

    static func show() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ]
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let iconSize = font.pointSize + 2
        /// Icon plus title, both clickable.
        func link(_ title: String, _ url: URL, icon: NSImage?) -> NSAttributedString {
            var attributes = base
            attributes[.link] = url
            let result = NSMutableAttributedString()
            if let icon {
                let attachment = NSTextAttachment()
                attachment.image = icon
                // Center the icon on the text's cap height instead of sitting on the baseline.
                attachment.bounds = CGRect(x: 0, y: (font.capHeight - iconSize) / 2, width: iconSize, height: iconSize)
                let iconString = NSMutableAttributedString(attachment: attachment)
                iconString.addAttributes(attributes, range: NSRange(location: 0, length: iconString.length))
                result.append(iconString)
                result.append(NSAttributedString(string: " ", attributes: attributes))
            }
            result.append(NSAttributedString(string: title, attributes: attributes))
            return result
        }
        let credits = NSMutableAttributedString(string: Self.tagline + "\n\n", attributes: base)
        credits.append(link("What is a kuroko?", Self.wikipediaURL, icon: AboutIcons.wikipedia(size: iconSize)))
        credits.append(NSAttributedString(string: "\n", attributes: base))
        credits.append(link("github.com/NeverOddOrEven/kuroko", Self.repositoryURL, icon: AboutIcons.github(size: iconSize)))
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Kuroko",
            .credits: credits,
        ]
        if let icon = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Kuroko")?
            .withSymbolConfiguration(.init(pointSize: 64, weight: .regular)) {
            options[.applicationIcon] = icon
        }
        // Accessory apps aren't frontmost, so the panel would open behind other windows.
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
