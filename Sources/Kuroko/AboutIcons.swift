import AppKit

/// Small monochrome link icons for the About panel. They're drawn at render time in the label
/// color, so they follow light and dark mode like the surrounding text.
enum AboutIcons {
    /// GitHub mark from Primer Octicons (`mark-github-16`). MIT License, Copyright (c) GitHub Inc.
    private static let githubMarkSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M6.766 11.328c-2.063-.25-3.516-1.734-3.516-3.656 0-.781.281-1.625.75-2.188-.203-.515-.172-1.609.063-2.062.625-.078 1.468.25 1.968.703.594-.187 1.219-.281 1.985-.281.765 0 1.39.094 1.953.265.484-.437 1.344-.765 1.969-.687.218.422.25 1.515.046 2.047.5.593.766 1.39.766 2.203 0 1.922-1.453 3.375-3.547 3.64.531.344.89 1.094.89 1.954v1.625c0 .468.391.734.86.547C13.781 14.359 16 11.53 16 8.03 16 3.61 12.406 0 7.984 0 3.563 0 0 3.61 0 8.031a7.88 7.88 0 0 0 5.172 7.422c.422.156.828-.125.828-.547v-1.25c-.219.094-.5.156-.75.156-1.031 0-1.64-.562-2.078-1.609-.172-.422-.36-.672-.719-.719-.187-.015-.25-.093-.25-.187 0-.188.313-.328.625-.328.453 0 .844.281 1.25.86.313.452.64.655 1.031.655s.641-.14 1-.5c.266-.265.47-.5.657-.656"/></svg>
    """

    static func github(size: CGFloat) -> NSImage? {
        guard let mark = NSImage(data: Data(githubMarkSVG.utf8)) else { return nil }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            mark.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// Wikipedia's favicon is a serif capital W; set it in the system serif face instead of
    /// bundling the logo.
    static func wikipedia(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            var font = serifFont(ofSize: rect.height * 1.1)
            let width = ("W" as NSString).size(withAttributes: [.font: font]).width
            if width > rect.width {
                font = serifFont(ofSize: font.pointSize * rect.width / width)
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let glyphWidth = ("W" as NSString).size(withAttributes: attributes).width
            // Center the capital vertically: baseline sits half the leftover height up.
            let baseline = (rect.height - font.capHeight) / 2
            ("W" as NSString).draw(
                at: NSPoint(x: (rect.width - glyphWidth) / 2, y: baseline + font.descender),
                withAttributes: attributes
            )
            return true
        }
    }

    private static func serifFont(ofSize size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: .semibold)
        guard let descriptor = system.fontDescriptor.withDesign(.serif) else { return system }
        return NSFont(descriptor: descriptor, size: size) ?? system
    }
}
