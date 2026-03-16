import AppKit

/// Generates Screenie's app icon and menu bar icon programmatically
/// Design: cute kawaii-style screen with rosy cheeks and a happy expression
struct AppIconGenerator {

    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let cx = size / 2
            let cy = size / 2

            // Background — soft pastel gradient (lavender → pink)
            let bgPath = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
            let bgGradient = NSGradient(colors: [
                NSColor(red: 0.58, green: 0.48, blue: 0.95, alpha: 1),  // soft purple
                NSColor(red: 0.85, green: 0.55, blue: 0.85, alpha: 1),  // pink-purple
                NSColor(red: 0.95, green: 0.65, blue: 0.75, alpha: 1),  // soft pink
            ], atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)
            bgGradient?.draw(in: bgPath, angle: -45)

            // Screen body — white rounded rectangle (the "face")
            let screenW = size * 0.56
            let screenH = size * 0.40
            let screenRect = NSRect(
                x: cx - screenW / 2,
                y: cy - screenH / 2 + size * 0.05,
                width: screenW,
                height: screenH
            )
            let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: size * 0.06, yRadius: size * 0.06)
            NSColor.white.setFill()
            screenPath.fill()

            // Subtle shadow on screen
            NSColor(white: 0.0, alpha: 0.08).setStroke()
            screenPath.lineWidth = size * 0.01
            screenPath.stroke()

            // Stand
            let standPath = NSBezierPath()
            standPath.move(to: NSPoint(x: cx, y: screenRect.minY))
            standPath.line(to: NSPoint(x: cx, y: screenRect.minY - size * 0.05))
            NSColor(white: 0.85, alpha: 1).setStroke()
            standPath.lineWidth = size * 0.025
            standPath.stroke()

            // Base — cute rounded
            let baseW = size * 0.16
            let baseY = screenRect.minY - size * 0.06
            let baseRect = NSRect(x: cx - baseW / 2, y: baseY - size * 0.015, width: baseW, height: size * 0.025)
            let basePath = NSBezierPath(roundedRect: baseRect, xRadius: size * 0.01, yRadius: size * 0.01)
            NSColor(white: 0.85, alpha: 1).setFill()
            basePath.fill()

            // --- Cute face on the screen ---
            let faceY = screenRect.midY

            // Eyes — two happy dots
            let eyeSpacing = size * 0.09
            let eyeR = size * 0.032
            let eyeY = faceY + size * 0.02

            // Left eye
            NSColor(red: 0.25, green: 0.25, blue: 0.35, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: cx - eyeSpacing - eyeR, y: eyeY - eyeR,
                width: eyeR * 2, height: eyeR * 2
            )).fill()

            // Right eye
            NSBezierPath(ovalIn: NSRect(
                x: cx + eyeSpacing - eyeR, y: eyeY - eyeR,
                width: eyeR * 2, height: eyeR * 2
            )).fill()

            // Eye highlights — tiny white dots
            let hlR = size * 0.012
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: cx - eyeSpacing - hlR + size * 0.01, y: eyeY + size * 0.01,
                width: hlR * 2, height: hlR * 2
            )).fill()
            NSBezierPath(ovalIn: NSRect(
                x: cx + eyeSpacing - hlR + size * 0.01, y: eyeY + size * 0.01,
                width: hlR * 2, height: hlR * 2
            )).fill()

            // Rosy cheeks — soft pink circles
            let cheekR = size * 0.035
            let cheekY = faceY - size * 0.02
            NSColor(red: 1.0, green: 0.6, blue: 0.65, alpha: 0.5).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: cx - eyeSpacing * 1.5 - cheekR, y: cheekY - cheekR,
                width: cheekR * 2, height: cheekR * 2
            )).fill()
            NSBezierPath(ovalIn: NSRect(
                x: cx + eyeSpacing * 1.5 - cheekR, y: cheekY - cheekR,
                width: cheekR * 2, height: cheekR * 2
            )).fill()

            // Smile — small curved line
            let smilePath = NSBezierPath()
            let smileY = faceY - size * 0.04
            let smileW = size * 0.06
            smilePath.move(to: NSPoint(x: cx - smileW, y: smileY))
            smilePath.curve(
                to: NSPoint(x: cx + smileW, y: smileY),
                controlPoint1: NSPoint(x: cx - smileW * 0.3, y: smileY - size * 0.04),
                controlPoint2: NSPoint(x: cx + smileW * 0.3, y: smileY - size * 0.04)
            )
            NSColor(red: 0.25, green: 0.25, blue: 0.35, alpha: 1).setStroke()
            smilePath.lineWidth = size * 0.018
            smilePath.lineCapStyle = .round
            smilePath.stroke()

            // Recording dot — red circle, top-right corner of screen
            let dotR = size * 0.04
            let dotX = screenRect.maxX - size * 0.06
            let dotY = screenRect.maxY - size * 0.06
            let dotRect = NSRect(x: dotX - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2)
            NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1).setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            // Dot glow
            NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 0.25).setFill()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -size * 0.015, dy: -size * 0.015)).fill()

            return true
        }
    }

    /// Small monochrome menu bar icon
    static func menuBarIcon() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let cx = size / 2
            let cy = size / 2

            // Screen
            let screenW: CGFloat = 14
            let screenH: CGFloat = 10
            let screenRect = NSRect(x: cx - screenW / 2, y: cy - screenH / 2 + 1, width: screenW, height: screenH)
            NSBezierPath(roundedRect: screenRect, xRadius: 2, yRadius: 2).stroke()

            // Stand + base
            NSBezierPath.strokeLine(from: NSPoint(x: cx, y: screenRect.minY), to: NSPoint(x: cx, y: screenRect.minY - 2))
            NSBezierPath.strokeLine(from: NSPoint(x: cx - 3, y: screenRect.minY - 2.5), to: NSPoint(x: cx + 3, y: screenRect.minY - 2.5))

            // Cute eyes (two dots)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - 3.5, y: cy + 1, width: 2.5, height: 2.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: cx + 1, y: cy + 1, width: 2.5, height: 2.5)).fill()

            // Smile
            let smile = NSBezierPath()
            smile.move(to: NSPoint(x: cx - 2, y: cy - 1))
            smile.curve(to: NSPoint(x: cx + 2, y: cy - 1),
                        controlPoint1: NSPoint(x: cx - 0.5, y: cy - 3),
                        controlPoint2: NSPoint(x: cx + 0.5, y: cy - 3))
            smile.lineWidth = 0.8
            smile.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    static func setAppIcon() {
        NSApp.applicationIconImage = appIcon(size: 512)
    }
}
