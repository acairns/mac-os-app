// Draws the app icon from the /dev/null mark's geometry (public/favicon.svg), as vectors, at every size it is shown:
//
// - <output>/AppIcon.icon: the Icon Composer source that actool compiles into Assets.car, which macOS 26 and later
//   draw in the Dock and Finder with their own light, dark and tinted looks.
// - <output>/AppIcon.iconset: the classic icon for macOS 14 and 15, and for the DMG's volume, hinted at 16px.
//
// Usage: swift make-icon.swift <output directory>
import AppKit

let output = URL(filePath: CommandLine.arguments[1])

/// The mark in favicon units: the ink slash, and the center line of the outlined lane-0 slash beside it.
let inkSlash = [CGPoint(x: 2, y: 42), CGPoint(x: 12, y: 42), CGPoint(x: 26, y: 6), CGPoint(x: 16, y: 6)]
let laneSlash = inkSlash.map { CGPoint(x: $0.x + 18, y: $0.y) }
let markCenter = CGPoint(x: 24.15, y: 24)

/// The favicon's outline is 3 units; the icon's is a little heavier so it survives the Dock's smaller sizes.
let outline: CGFloat = 3.6

let ink = (light: NSColor(hex: 0x121417), dark: NSColor(hex: 0xECECEC))
let lane = (light: NSColor(hex: 0xD9480F), dark: NSColor(hex: 0xFF8A4C))
let shell = (light: NSColor(hex: 0xF6F7F8), dark: NSColor(hex: 0x18181A))

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    var iconComposer: String {
        let color = usingColorSpace(.sRGB)!

        return String(format: "srgb:%.5f,%.5f,%.5f,1.00000", color.redComponent, color.greenComponent, color.blueComponent)
    }
}

/// A convex polygon moved outward (positive) or inward (negative) by `distance`, keeping its corners sharp.
func offset(_ polygon: [CGPoint], by distance: CGFloat) -> [CGPoint] {
    let count = polygon.count
    // The mark's polygons wind counterclockwise on screen (y down), so this normal of each edge points out of the shape.
    let lines = (0 ..< count).map { index -> (CGPoint, CGPoint) in
        let a = polygon[index], b = polygon[(index + 1) % count]
        let length = hypot(b.x - a.x, b.y - a.y)
        let normal = CGPoint(x: -(b.y - a.y) / length * distance, y: (b.x - a.x) / length * distance)

        return (CGPoint(x: a.x + normal.x, y: a.y + normal.y), CGPoint(x: b.x + normal.x, y: b.y + normal.y))
    }

    return (0 ..< count).map { index in
        let (p1, p2) = lines[(index + count - 1) % count], (p3, p4) = lines[index]
        let d = (p1.x - p2.x) * (p3.y - p4.y) - (p1.y - p2.y) * (p3.x - p4.x)
        let t = ((p1.x - p3.x) * (p3.y - p4.y) - (p1.y - p3.y) * (p3.x - p4.x)) / d

        return CGPoint(x: p1.x + t * (p2.x - p1.x), y: p1.y + t * (p2.y - p1.y))
    }
}

/// Maps favicon units onto a canvas: `scale` points per unit, the mark centered on `center`.
func place(_ polygon: [CGPoint], scale: CGFloat, center: CGPoint) -> [CGPoint] {
    polygon.map { CGPoint(x: center.x + ($0.x - markCenter.x) * scale, y: center.y + ($0.y - markCenter.y) * scale) }
}

// MARK: - Icon Composer source

/// On the 1024pt Icon Composer canvas, the mark spans about 54% of the width, like the site's icon.
let composerScale: CGFloat = 12.4

func svgPath(_ polygon: [CGPoint]) -> String {
    "M" + polygon.map { String(format: "%.2f %.2f", $0.x, $0.y) }.joined(separator: " L") + " Z"
}

func svg(_ path: String, fill: NSColor) -> String {
    let color = fill.usingColorSpace(.sRGB)!
    let hex = String(format: "#%02X%02X%02X", Int(round(color.redComponent * 255)), Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))

    return #"<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><path fill="\#(hex)" fill-rule="evenodd" d="\#(path)"/></svg>"#
}

let composer = output.appending(path: "AppIcon.icon")
try? FileManager.default.removeItem(at: composer)
try FileManager.default.createDirectory(at: composer.appending(path: "Assets"), withIntermediateDirectories: true)

let canvasCenter = CGPoint(x: 512, y: 512)
let inkPath = svgPath(place(inkSlash, scale: composerScale, center: canvasCenter))
let lanePath = svgPath(place(offset(laneSlash, by: outline / 2), scale: composerScale, center: canvasCenter))
    + " " + svgPath(place(offset(laneSlash, by: -outline / 2), scale: composerScale, center: canvasCenter))

try svg(inkPath, fill: ink.light).write(to: composer.appending(path: "Assets/ink.svg"), atomically: true, encoding: .utf8)
try svg(lanePath, fill: lane.light).write(to: composer.appending(path: "Assets/lane.svg"), atomically: true, encoding: .utf8)

/// Light keeps the SVGs' own colors; dark lifts them the way the site's dark theme does, on graphite.
func layer(_ name: String, dark: NSColor) -> String {
    """
            {
              "glass" : false,
              "image-name" : "\(name).svg",
              "name" : "\(name)",
              "fill-specializations" : [
                { "value" : "automatic" },
                { "appearance" : "dark", "value" : { "solid" : "\(dark.iconComposer)" } }
              ]
            }
    """
}

try """
{
  "fill-specializations" : [
    { "value" : { "solid" : "\(shell.light.iconComposer)" } },
    { "appearance" : "dark", "value" : { "solid" : "\(shell.dark.iconComposer)" } }
  ],
  "groups" : [
    {
      "layers" : [
\(layer("lane", dark: lane.dark)),
\(layer("ink", dark: ink.dark))
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.35 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : {
    "squares" : [ "macOS" ]
  }
}
""".write(to: composer.appending(path: "icon.json"), atomically: true, encoding: .utf8)

// MARK: - Classic icon

/// Apple's macOS 14 grid: an 824pt continuous-corner square on a 1024pt canvas, nudged up for its shadow.
func tile(in canvas: CGFloat) -> NSBezierPath {
    let side = canvas * 824 / 1024
    let rect = NSRect(x: (canvas - side) / 2, y: (canvas - side) / 2 + canvas * 10 / 1024, width: side, height: side)
    let path = NSBezierPath()
    // A superellipse with an exponent of 5 traces the continuous corners closely.
    let steps = 360

    for step in 0 ... steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(angle), s = sin(angle)
        let point = NSPoint(
            x: rect.midX + side / 2 * copysign(pow(abs(c), 2 / 5), c),
            y: rect.midY + side / 2 * copysign(pow(abs(s), 2 / 5), s)
        )

        step == 0 ? path.move(to: point) : path.line(to: point)
    }

    path.close()

    return path
}

func polygonPath(_ polygon: [CGPoint], canvas: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    // The geometry is y-down like the SVG; AppKit draws y-up.
    let flipped = polygon.map { NSPoint(x: $0.x, y: canvas - $0.y) }
    path.move(to: flipped[0])
    flipped.dropFirst().forEach { path.line(to: $0) }
    path.close()

    return path
}

func render(_ pixels: Int) -> Data {
    let canvas = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let shape = tile(in: canvas)
    let side = canvas * 824 / 1024

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = canvas * 10 / 1024
    shadow.shadowOffset = NSSize(width: 0, height: -canvas * 6 / 1024)
    shadow.set()
    shell.light.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: .white, ending: shell.light.blended(withFraction: 0.35, of: NSColor(hex: 0xE1E4E8))!)!.draw(in: shape, angle: -90)

    // At 16px the outline would be half a pixel wide, so the small sizes draw the mark larger, with the lane slash
    // filled: still two slashes, ink then lane, which is what reads at that size.
    let isTiny = pixels <= 16
    let isSmall = pixels <= 32
    let scale = side * (isTiny ? 0.7 : isSmall ? 0.64 : 0.6) / 44.2
    let center = CGPoint(x: canvas / 2, y: canvas / 2 - canvas * 10 / 1024)
    let weight = isSmall ? max(outline, 1.5 / scale) : outline

    // Thinner slashes at 16px keep a visible gap between them.
    let thinning: CGFloat = isTiny ? -0.9 : 0

    ink.light.setFill()
    polygonPath(place(offset(inkSlash, by: thinning), scale: scale, center: center), canvas: canvas).fill()

    lane.light.setFill()
    let laneShape = polygonPath(place(offset(laneSlash, by: isTiny ? thinning : weight / 2), scale: scale, center: center), canvas: canvas)
    if !isTiny {
        laneShape.append(polygonPath(place(offset(laneSlash, by: -weight / 2), scale: scale, center: center), canvas: canvas))
        laneShape.windingRule = .evenOdd
    }
    laneShape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // A hairline edge keeps the light tile from dissolving into a light Finder window or Dock.
    NSColor.black.withAlphaComponent(0.1).setStroke()
    shape.lineWidth = max(1, canvas / 512)
    shape.stroke()

    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

let iconset = output.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
