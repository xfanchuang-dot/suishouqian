import Cocoa

let iconName = "arrow.triangle.swap"
let config = NSImage.SymbolConfiguration(pointSize: 600, weight: .medium)

let sizes: [(Int, Int)] = [(16, 1), (32, 2), (64, 1), (128, 2), (256, 1), (512, 2)]

let fm = FileManager.default
let iconset = fm.currentDirectoryPath + "/AppIcon.iconset"
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for (size, scale) in sizes {
    // Create an NSImage for drawing
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    
    // Blue rounded rect background
    NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.95, alpha: 1.0).setFill()
    let rect = NSRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: CGFloat(size) / 5, yRadius: CGFloat(size) / 5)
    bgPath.fill()
    
    // Draw SF Symbol in white
    let symbol = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)!
    let symbolCfg = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.55, weight: .medium)
    let sizedSymbol = symbol.withSymbolConfiguration(symbolCfg)!
    sizedSymbol.isTemplate = true
    NSColor.white.setFill()
    let symSize = sizedSymbol.size
    let symRect = NSRect(x: (CGFloat(size) - symSize.width) / 2,
                         y: (CGFloat(size) - symSize.height) / 2,
                         width: symSize.width, height: symSize.height)
    sizedSymbol.draw(in: symRect)
    
    image.unlockFocus()
    
    // Extract PNG
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let pngData = rep.representation(using: .png, properties: [:])!
    let scaleStr = scale == 1 ? "" : "@\(scale)x"
    let filename = "icon_\(size)x\(size)\(scaleStr).png"
    let path = iconset + "/" + filename
    try! pngData.write(to: URL(fileURLWithPath: path))
    print("Wrote \(filename)")
}
