import AppKit

// 量侧边栏顶部几何：交通灯下沿 vs 菜单第一行（紫胶囊）上沿。
// 用法: swift measure_topgap.swift <截图.png>
let args = CommandLine.arguments
guard args.count == 2 else { fatalError("usage: measure_topgap in.png") }
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("解码失败") }
let w = img.width, h = img.height
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let buf = ctx.data else { fatalError("ctx 失败") }
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)
func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * w + x) * 4
    return (Int(px[i]), Int(px[i+1]), Int(px[i+2]))
}

// 1) 交通灯（红/黄/绿）在左上区域的最大 y（下沿）。CG 坐标系 y 向下即视觉更靠下。
var lightsTop = Int.max, lightsBottom = -1
for y in 0..<min(120, h) {
    for x in 0..<min(140, w) {
        let (r, g, b) = rgb(x, y)
        let isRed = r > 200 && g < 140 && b < 140
        let isYellow = r > 220 && g > 160 && b < 110
        let isGreen = g > 170 && r < 130 && b < 130
        if isRed || isYellow || isGreen {
            lightsTop = min(lightsTop, y)
            lightsBottom = max(lightsBottom, y)
        }
    }
}

// 2) 侧栏紫色（选中胶囊 #7060EC≈(112,92,237)）最小 y → 第二行(应用)胶囊上沿
var purpleTop = Int.max
scan: for y in 0..<min(300, h) {
    for x in 0..<min(260, w) {
        let (r, g, b) = rgb(x, y)
        if abs(r-112) < 40 && abs(g-92) < 40 && b > 190 {
            purpleTop = y
            break scan
        }
    }
}

// 行高结构：行2胶囊上沿 - 行高(约45) = 行1胶囊上沿；行1胶囊内上留白9pt → 行1内容顶
let row1PillTop = purpleTop == Int.max ? -1 : purpleTop - 45
let row1TextTop = row1PillTop + 9

print("图片尺寸: \(w)x\(h)（坐标系 y=0 为顶）")
print("交通灯: 上沿 y=\(lightsTop == Int.max ? -1 : lightsTop), 下沿 y=\(lightsBottom)")
print("紫胶囊(应用行)上沿 y=\(purpleTop == Int.max ? -1 : purpleTop)")
print("推算 第一行(概览)胶囊上沿 y=\(row1PillTop)")
print("→ 交通灯下沿 与 第一行胶囊上沿 之间的空隙 = \(row1PillTop - lightsBottom)pt")
print("→ 交通灯下沿 与 第一行文字 之间 = \(row1TextTop - lightsBottom)pt")
