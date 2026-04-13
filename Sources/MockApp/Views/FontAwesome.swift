import AppKit
import CoreText

enum FontAwesome {

    static let bluetoothB = "\u{f294}"

    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true

        guard let url = Bundle.module.url(forResource: "fa-brands-400", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func brandImage(_ glyph: String, size: CGFloat, active: Bool = false) -> NSImage {
        register()
        let font = NSFont(name: "Font Awesome 6 Brands", size: size)
            ?? NSFont.systemFont(ofSize: size)

        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let attrStr = NSAttributedString(string: glyph, attributes: attributes)
        let textSize = attrStr.size()

        let inset: CGFloat = 3
        let cornerRadius: CGFloat = 3
        let canvasSize = NSSize(width: textSize.width + inset * 2, height: textSize.height + inset * 2)

        let image = NSImage(size: canvasSize)
        image.lockFocus()
        if active {
            let bgRect = NSRect(origin: .zero, size: canvasSize)
            let path = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.setFill()
            path.fill()
            let invertedAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let invertedStr = NSAttributedString(string: glyph, attributes: invertedAttributes)
            invertedStr.draw(at: NSPoint(x: inset, y: inset))
        } else {
            attrStr.draw(at: NSPoint(x: inset, y: inset))
        }
        image.unlockFocus()
        image.isTemplate = !active
        return image
    }
}
