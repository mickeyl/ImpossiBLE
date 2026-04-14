import AppKit
import CoreText

enum FontAwesome {

    static let bluetoothB = "\u{f294}"

    enum MenuBarMode {
        case off
        case mock
        case passthrough
    }

    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true

        guard let url = Bundle.main.url(forResource: "fa-brands-400", withExtension: "ttf")
            ?? Bundle.module.url(forResource: "fa-brands-400", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func brandImage(_ glyph: String, size: CGFloat, active: Bool = false, mode: MenuBarMode = .off) -> NSImage {
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

        let foreground: NSColor
        if active {
            let bgRect = NSRect(origin: .zero, size: canvasSize)
            let path = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.setFill()
            path.fill()
            foreground = .white
        } else {
            foreground = .black
        }

        let drawAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        NSAttributedString(string: glyph, attributes: drawAttributes)
            .draw(at: NSPoint(x: inset, y: inset))

        switch mode {
            case .off:
                // Diagonal strikethrough
                let strike = NSBezierPath()
                strike.move(to: NSPoint(x: inset * 0.5, y: inset + textSize.height * 0.15))
                strike.line(to: NSPoint(x: canvasSize.width - inset * 0.5, y: inset + textSize.height * 0.85))
                strike.lineWidth = max(1.5, size * 0.1)
                foreground.setStroke()
                strike.stroke()

            case .mock:
                // Small dot badge in lower-right corner
                let dotSize = max(4, size * 0.28)
                foreground.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: canvasSize.width - dotSize - 0.5,
                    y: 0.5,
                    width: dotSize,
                    height: dotSize
                )).fill()

            case .passthrough:
                break
        }

        image.unlockFocus()
        image.isTemplate = !active
        return image
    }
}
