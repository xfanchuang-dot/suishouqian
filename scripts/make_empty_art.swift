import AppKit

// 从效果图裁出空状态插画区，并把近白背景抠成透明（边缘泛光自然半透明）。
// 用法: swift make_empty_art.swift <输入图> <输出.png> <cropX> <cropY> <cropW> <cropH>
// 坐标为「左上原点」视觉坐标。

let args = CommandLine.arguments
guard args.count == 7 else { fatalError("usage: make_empty_art in out x y w h") }
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let cx = Double(args[3])!, cy = Double(args[4])!
let cw = Double(args[5])!, ch = Double(args[6])!

guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fatalError("无法解码输入图（格式不支持？）")
}
// 视觉坐标（左上原点）→ CG 坐标（左下原点）
let cgRect = CGRect(x: cx, y: Double(full.height) - cy - ch, width: cw, height: ch)
guard let cropped = full.cropping(to: cgRect) else { fatalError("裁剪失败") }

let w = cropped.width, h = cropped.height
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let buf = ctx.data else { fatalError("位图上下文创建失败") }
ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)

func minRGB(_ i: Int) -> Int { min(Int(px[i*4]), Int(px[i*4+1]), Int(px[i*4+2])) }
func idx(_ x: Int, _ y: Int) -> Int { y * w + x }

// 近白背景判定（从边缘 BFS，只清除与边缘连通的白——不伤图标内部白色高光）
let nearWhite = 232
var isBG = [Bool](repeating: false, count: w * h)
var stack = [Int]()
for y in 0..<h {
    for x in 0..<w {
        if x == 0 || y == 0 || x == w-1 || y == h-1 {
            let i = idx(x, y)
            if minRGB(i) >= nearWhite { isBG[i] = true; stack.append(i) }
        }
    }
}
while let i = stack.popLast() {
    let x = i % w, y = i / w
    for (dx, dy) in [(1,0), (-1,0), (0,1), (0,-1)] {
        let nx = x+dx, ny = y+dy
        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
        let j = idx(nx, ny)
        if !isBG[j], minRGB(j) >= nearWhite { isBG[j] = true; stack.append(j) }
    }
}

// 背景→全透明；非背景但接近白的外缘光晕→按接近程度半透明（柔边）
for i in 0..<(w*h) where isBG[i] {
    px[i*4] = 0; px[i*4+1] = 0; px[i*4+2] = 0; px[i*4+3] = 0
}
for i in 0..<(w*h) where !isBG[i] {
    let mn = minRGB(i)
    if mn > 240 {
        let t = Double(255 - mn) / 15.0   // 240→1.0 … 255→0.0
        px[i*4+3] = UInt8(max(0, min(255, t * 255)))
    }
}

guard let out = ctx.makeImage() else { fatalError("生成 CGImage 失败") }
let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("写出 PNG 失败") }
print("已写出: \(outURL.path)（\(w)x\(h)）")
