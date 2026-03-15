import AppKit

/// Generates Blink's app icon and menu bar icon programmatically
/// Design: minimal dark icon with a stylized blinking eye + red recording pupil
struct AppIconGenerator {

    /// Generate the main app icon at the given size
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Background — deep charcoal with subtle gradient
            let bgPath = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
            let gradient = NSGradient(
                starting: NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1),
                ending: NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
            )
            gradient?.draw(in: bgPath, angle: -45)

            // Subtle inner glow
            let insetRect = rect.insetBy(dx: size * 0.02, dy: size * 0.02)
            let innerPath = NSBezierPath(roundedRect: insetRect, xRadius: size * 0.20, yRadius: size * 0.20)
            NSColor(white: 1.0, alpha: 0.03).setStroke()
            innerPath.lineWidth = size * 0.01
            innerPath.stroke()

            let cx = size / 2
            let cy = size / 2

            // Eye shape — two mirrored curves forming an almond/lens shape
            let eyeW = size * 0.52
            let eyeH = size * 0.22
            let eyePath = NSBezierPath()

            // Top lid curve
            eyePath.move(to: NSPoint(x: cx - eyeW / 2, y: cy))
            eyePath.curve(
                to: NSPoint(x: cx + eyeW / 2, y: cy),
                controlPoint1: NSPoint(x: cx - eyeW * 0.15, y: cy + eyeH),
                controlPoint2: NSPoint(x: cx + eyeW * 0.15, y: cy + eyeH)
            )
            // Bottom lid curve
            eyePath.curve(
                to: NSPoint(x: cx - eyeW / 2, y: cy),
                controlPoint1: NSPoint(x: cx + eyeW * 0.15, y: cy - eyeH),
                controlPoint2: NSPoint(x: cx - eyeW * 0.15, y: cy - eyeH)
            )

            // Eye outline — soft white
            NSColor(white: 0.92, alpha: 0.9).setStroke()
            eyePath.lineWidth = size * 0.025
            eyePath.lineCapStyle = .round
            eyePath.stroke()

            // Pupil — recording red dot
            let pupilR = size * 0.085
            let pupilRect = NSRect(x: cx - pupilR, y: cy - pupilR, width: pupilR * 2, height: pupilR * 2)
            let pupilPath = NSBezierPath(ovalIn: pupilRect)

            // Red gradient for depth
            let redGradient = NSGradient(
                starting: NSColor(red: 1.0, green: 0.25, blue: 0.25, alpha: 1),
                ending: NSColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
            )
            redGradient?.draw(in: pupilPath, angle: -45)

            // Pupil highlight — tiny white dot
            let highlightR = size * 0.025
            let highlightRect = NSRect(
                x: cx - pupilR * 0.3 - highlightR / 2,
                y: cy + pupilR * 0.25 - highlightR / 2,
                width: highlightR,
                height: highlightR
            )
            NSColor(white: 1.0, alpha: 0.85).setFill()
            NSBezierPath(ovalIn: highlightRect).fill()

            // Subtle glow around pupil
            let glowRect = pupilRect.insetBy(dx: -size * 0.03, dy: -size * 0.03)
            let glowPath = NSBezierPath(ovalIn: glowRect)
            NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.15).setStroke()
            glowPath.lineWidth = size * 0.02
            glowPath.stroke()

            return true
        }
    }

    /// Small monochrome menu bar icon (template image)
    static func menuBarIcon() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let cx = size / 2
            let cy = size / 2

            // Small eye shape
            let eyeW = size * 0.75
            let eyeH = size * 0.30
            let eyePath = NSBezierPath()

            eyePath.move(to: NSPoint(x: cx - eyeW / 2, y: cy))
            eyePath.curve(
                to: NSPoint(x: cx + eyeW / 2, y: cy),
                controlPoint1: NSPoint(x: cx - eyeW * 0.15, y: cy + eyeH),
                controlPoint2: NSPoint(x: cx + eyeW * 0.15, y: cy + eyeH)
            )
            eyePath.curve(
                to: NSPoint(x: cx - eyeW / 2, y: cy),
                controlPoint1: NSPoint(x: cx + eyeW * 0.15, y: cy - eyeH),
                controlPoint2: NSPoint(x: cx - eyeW * 0.15, y: cy - eyeH)
            )

            NSColor.black.setStroke()
            eyePath.lineWidth = 1.5
            eyePath.stroke()

            // Pupil dot
            let dotR: CGFloat = 2.5
            let dotRect = NSRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        image.isTemplate = true // Makes it adapt to light/dark menu bar
        return image
    }

    /// Set the app icon at runtime
    static func setAppIcon() {
        NSApp.applicationIconImage = appIcon(size: 512)
    }
}
