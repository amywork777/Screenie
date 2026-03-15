import AppKit

/// Generates Screenie's app icon and menu bar icon programmatically
/// Design: minimal dark icon with a stylized screen/monitor + red recording dot
struct AppIconGenerator {

    /// Generate the main app icon at the given size
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Background — deep charcoal gradient
            let bgPath = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
            let gradient = NSGradient(
                starting: NSColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1),
                ending: NSColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1)
            )
            gradient?.draw(in: bgPath, angle: -45)

            let cx = size / 2
            let cy = size / 2

            // Screen/monitor shape — rounded rectangle
            let screenW = size * 0.52
            let screenH = size * 0.36
            let screenRect = NSRect(
                x: cx - screenW / 2,
                y: cy - screenH / 2 + size * 0.04,
                width: screenW,
                height: screenH
            )
            let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: size * 0.04, yRadius: size * 0.04)

            // Screen border — soft white
            NSColor(white: 0.85, alpha: 0.9).setStroke()
            screenPath.lineWidth = size * 0.02
            screenPath.stroke()

            // Screen fill — subtle dark gradient
            let screenGradient = NSGradient(
                starting: NSColor(white: 0.18, alpha: 1),
                ending: NSColor(white: 0.12, alpha: 1)
            )
            screenGradient?.draw(in: screenPath, angle: -90)

            // Stand/base — small line below screen
            let standPath = NSBezierPath()
            standPath.move(to: NSPoint(x: cx, y: screenRect.minY))
            standPath.line(to: NSPoint(x: cx, y: screenRect.minY - size * 0.06))
            NSColor(white: 0.7, alpha: 0.7).setStroke()
            standPath.lineWidth = size * 0.018
            standPath.stroke()

            // Base
            let baseW = size * 0.14
            let baseY = screenRect.minY - size * 0.07
            let basePath = NSBezierPath()
            basePath.move(to: NSPoint(x: cx - baseW / 2, y: baseY))
            basePath.line(to: NSPoint(x: cx + baseW / 2, y: baseY))
            basePath.lineWidth = size * 0.02
            basePath.lineCapStyle = .round
            basePath.stroke()

            // Red recording dot — top right of screen
            let dotR = size * 0.055
            let dotX = screenRect.maxX - size * 0.07
            let dotY = screenRect.maxY - size * 0.07
            let dotRect = NSRect(x: dotX - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2)
            let redGradient = NSGradient(
                starting: NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1),
                ending: NSColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
            )
            let dotPath = NSBezierPath(ovalIn: dotRect)
            redGradient?.draw(in: dotPath, angle: -45)

            // Glow around dot
            let glowRect = dotRect.insetBy(dx: -size * 0.02, dy: -size * 0.02)
            NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.2).setStroke()
            NSBezierPath(ovalIn: glowRect).stroke()

            return true
        }
    }

    /// Small monochrome menu bar icon (template image)
    static func menuBarIcon() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let cx = size / 2
            let cy = size / 2

            // Small screen shape
            let screenW: CGFloat = 14
            let screenH: CGFloat = 10
            let screenRect = NSRect(x: cx - screenW / 2, y: cy - screenH / 2 + 1, width: screenW, height: screenH)
            let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 2, yRadius: 2)
            NSColor.black.setStroke()
            screenPath.lineWidth = 1.2
            screenPath.stroke()

            // Stand
            let standPath = NSBezierPath()
            standPath.move(to: NSPoint(x: cx, y: screenRect.minY))
            standPath.line(to: NSPoint(x: cx, y: screenRect.minY - 2))
            standPath.lineWidth = 1.0
            standPath.stroke()

            // Base
            NSBezierPath.strokeLine(
                from: NSPoint(x: cx - 3, y: screenRect.minY - 2.5),
                to: NSPoint(x: cx + 3, y: screenRect.minY - 2.5)
            )

            // Recording dot
            let dotR: CGFloat = 1.8
            let dotRect = NSRect(x: screenRect.maxX - 4, y: screenRect.maxY - 4, width: dotR * 2, height: dotR * 2)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        image.isTemplate = true
        return image
    }

    /// Set the app icon at runtime
    static func setAppIcon() {
        NSApp.applicationIconImage = appIcon(size: 512)
    }
}
