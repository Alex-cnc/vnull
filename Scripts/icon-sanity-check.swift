// 图标客观检查（我看不到图像，只能量）：确认画面里有"居中的主体 + 背景"的结构，
// 而不是一张纯色 / 空白图。用法：swift Scripts/icon-sanity-check.swift <png>

import Foundation
import CoreGraphics
import ImageIO

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Resources/AppIcon-1024.png"
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("读不到：\(path)"); exit(1)
}

let width = image.width
let height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { print("建上下文失败"); exit(1) }
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func mean(x0: Double, y0: Double, x1: Double, y1: Double) -> (Int, Int, Int, Double) {
    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
    let xs = Int(Double(width) * x0), xe = Int(Double(width) * x1)
    let ys = Int(Double(height) * y0), ye = Int(Double(height) * y1)
    for y in stride(from: ys, to: ye, by: 2) {
        for x in stride(from: xs, to: xe, by: 2) {
            let i = (y * width + x) * 4
            r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2]); n += 1
        }
    }
    guard n > 0 else { return (0, 0, 0, 0) }
    return (Int(r / n), Int(g / n), Int(b / n), n)
}

// 中位区域的差异度：逐点与中心均值的距离，衡量"画面里到底有没有东西"
let center = mean(x0: 0.4, y0: 0.4, x1: 0.6, y1: 0.6)
var variance = 0.0, samples = 0.0
for y in stride(from: 0, to: height, by: 4) {
    for x in stride(from: 0, to: width, by: 4) {
        let i = (y * width + x) * 4
        let dr = Double(pixels[i]) - Double(center.0)
        let dg = Double(pixels[i + 1]) - Double(center.1)
        let db = Double(pixels[i + 2]) - Double(center.2)
        variance += dr * dr + dg * dg + db * db
        samples += 1
    }
}
let rms = (variance / max(1, samples)).squareRoot()

// 四角（圆角遮罩之外应当是透明的）
func alphaAt(x: Int, y: Int) -> Int { Int(pixels[(y * width + x) * 4 + 3]) }
let cornerAlpha = [alphaAt(x: 2, y: 2), alphaAt(x: width - 3, y: 2), alphaAt(x: 2, y: height - 3), alphaAt(x: width - 3, y: height - 3)]

print("文件      : \(path)")
print("尺寸      : \(width)×\(height)")
print("整体均值  : \(mean(x0: 0, y0: 0, x1: 1, y1: 1).0), \(mean(x0: 0, y0: 0, x1: 1, y1: 1).1), \(mean(x0: 0, y0: 0, x1: 1, y1: 1).2)")
print("中心均值  : \(center.0), \(center.1), \(center.2)")
print("左上角均值: \(mean(x0: 0.05, y0: 0.05, x1: 0.2, y1: 0.2).0), \(mean(x0: 0.05, y0: 0.05, x1: 0.2, y1: 0.2).1), \(mean(x0: 0.05, y0: 0.05, x1: 0.2, y1: 0.2).2)")
print("画面起伏  : \(String(format: "%.1f", rms))  （纯色图≈0，有主体应明显大于 0）")
print("四角透明度: \(cornerAlpha)  （圆角遮罩下应为 0 = 透明）")

// 简单的粗判：中心与左上角的色彩距离
let tl = mean(x0: 0.05, y0: 0.05, x1: 0.2, y1: 0.2)
let distance = (pow(Double(center.0 - tl.0), 2) + pow(Double(center.1 - tl.1), 2) + pow(Double(center.2 - tl.2), 2)).squareRoot()
print("中心↔左上 : \(String(format: "%.1f", distance))  （越大越说明中间有主体）")
print("结论      : " + (rms > 15 && cornerAlpha.allSatisfy { $0 == 0 }
      ? "有居中主体，且圆角遮罩生效 —— 结构正常（审美仍需人工确认）"
      : "结构可疑：画面过平或圆角未生效，需要重新生成或检查合成"))
