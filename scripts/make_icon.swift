import AppKit

// 随手迁图标生成器：渐变圆角底座 + 白色外置盘符号 + 迁移箭头角标
// 用法：swift make_icon.swift <输出 1024 PNG 路径>

let canvas: CGFloat = 1024

func tinted(_ image: NSImage, color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    let rect = NSRect(origin: .zero, size: image.size)
    image.draw(in: rect)
    color.set()
    rect.fill(using: .sourceAtop)
    out.unlockFocus()
    out.isTemplate = false
    return out
}

func fittedRect(_ size: NSSize, in rect: NSRect, scale: CGFloat = 1) -> NSRect {
    let ratio = min(rect.width / size.width, rect.height / size.height) * scale
    let w = size.width * ratio
    let h = size.height * ratio
    return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
}

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// 渐变圆角底座（与主界面 Theme.accent 同款蓝→青）
let box = NSRect(x: 100, y: 100, width: canvas - 200, height: canvas - 200)
let basePath = NSBezierPath(roundedRect: box, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor.systemBlue, NSColor.systemTeal])!.draw(in: basePath, angle: -55)

// 主符号：白色外置硬盘，整体略偏上给角标留位
if let base = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil) {
    let cfg = NSImage.SymbolConfiguration(pointSize: 380, weight: .medium)
    let sym = base.withSymbolConfiguration(cfg) ?? base
    let target = NSRect(x: 132, y: 232 + 60, width: 760, height: 560)
    let tintedDrive = tinted(sym, color: .white)
    tintedDrive.draw(in: fittedRect(sym.size, in: target, scale: 1))
}

// 角标：白圆 + 蓝色右上箭头（数据迁往外置盘的意象）
let badgeCenter = NSPoint(x: 680, y: 340)
let badgeRadius: CGFloat = 150
NSColor.white.set()
NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                            width: badgeRadius * 2, height: badgeRadius * 2)).fill()
if let base = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil) {
    let cfg = NSImage.SymbolConfiguration(pointSize: 160, weight: .bold)
    let sym = base.withSymbolConfiguration(cfg) ?? base
    let target = NSRect(x: badgeCenter.x - 100, y: badgeCenter.y - 100,
                        width: 200, height: 200)
    let tintedArrow = tinted(sym, color: NSColor.systemBlue)
    tintedArrow.draw(in: fittedRect(sym.size, in: target, scale: 1))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("图标渲染失败")
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("图标已渲染: \(CommandLine.arguments[1])")
