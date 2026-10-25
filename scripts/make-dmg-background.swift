// Draws the DMG window's background at 1x and 2x: the app on the left, Applications on the right, a lane-colored
// arrow between them, and, for a build Apple hasn't notarized, how to open it the first time.
//
// Usage: swift make-dmg-background.swift <output directory> <notarized: 0 or 1>
// The icons sit where build.sh places them: centered at (170, 190) and (470, 190) in a 640x400 window.
import AppKit

let output = URL(filePath: CommandLine.arguments[1])
let isNotarized = CommandLine.arguments[2] == "1"
let fonts = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../dev-null.sh/resources/fonts")

for name in ["Geist-Regular", "Geist-SemiBold", "GeistMono-Regular"] {
    CTFontManagerRegisterFontsForURL(fonts.appending(path: "\(name).ttf") as CFURL, .process, nil)
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

let shell = NSColor(hex: 0xF6F7F8)
let ink = NSColor(hex: 0x121417)
let muted = NSColor(hex: 0x5B616B)
let hairline = NSColor(hex: 0xE1E4E8)
let lane = NSColor(hex: 0xD9480F)
let size = NSSize(width: 640, height: 400)

func text(_ string: String, font: String, size: CGFloat, color: NSColor, centeredAt y: CGFloat, width: CGFloat = 560) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineSpacing = 3

    let attributed = NSAttributedString(string: string, attributes: [
        .font: NSFont(name: font, size: size)!,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ])
    let bounds = attributed.boundingRect(with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin])

    attributed.draw(with: NSRect(x: (640 - width) / 2, y: y - bounds.height / 2, width: width, height: bounds.height), options: [.usesLineFragmentOrigin])
}

func render(scale: CGFloat) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    // Drawn top-down, like Finder lays the window out.
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)

    shell.setFill()
    NSRect(origin: .zero, size: size).fill()

    text("Drag /dev/null to Applications", font: "Geist-SemiBold", size: 17, color: ink, centeredAt: 58)

    // The arrow is a short stretch of rail in the first lane, from a commit node to an arrowhead.
    lane.setFill()
    lane.setStroke()
    NSBezierPath(ovalIn: NSRect(x: 252, y: 185, width: 10, height: 10)).fill()
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 262, y: 190))
    line.line(to: NSPoint(x: 384, y: 190))
    line.lineWidth = 2
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 377, y: 183))
    head.line(to: NSPoint(x: 386, y: 190))
    head.line(to: NSPoint(x: 377, y: 197))
    head.lineWidth = 2
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    hairline.setFill()
    NSRect(x: 0, y: 312, width: size.width, height: 1).fill()

    if isNotarized {
        text("dev-null.sh/apps", font: "GeistMono-Regular", size: 12, color: muted, centeredAt: 356)
    } else {
        text("If macOS says “DevNull” Not Opened", font: "Geist-SemiBold", size: 12.5, color: ink, centeredAt: 340)
        text("Click Done, then open System Settings → Privacy & Security\nand click Open Anyway. You only do this once.", font: "Geist-Regular", size: 12, color: muted, centeredAt: 371)
    }

    NSGraphicsContext.restoreGraphicsState()

    try rep.representation(using: .png, properties: [:])!.write(to: output.appending(path: scale == 1 ? "background.png" : "background@2x.png"))
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try render(scale: 1)
try render(scale: 2)
