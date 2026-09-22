// 由 Seedream 生成的原画产出 macOS 应用图标（AppIcon.icns）。
//
//   swift Scripts/make-app-icon.swift
//
// 为什么是 Swift 而不是 Python + Pillow：本机没有 Pillow，而 ImageIO / CoreGraphics
// 是系统自带的 —— 零依赖，且圆角遮罩这类合成用平台 API 写最直接。
//
// 做三件事：
//   1. 裁掉 Seedream 的水印（底部 180px，技能文档已实测：仅靠 prompt 抑制无效）；
//   2. 居中取正方形（宽高一致，图标必须方）；
//   3. 按 Apple 的 macOS 图标规范合成：1024 画布上放 824 的圆角矩形（约 80%），
//      圆角半径约 0.2225×824 —— 直接铺满整张画布会显得"方头方脑"，不像原生应用。
//
// 产出：App/Resources/AppIcon.icns，以及各尺寸的 iconset（交给 iconutil）。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("App/Resources/AppIcon-source.png")
let masterURL = root.appendingPathComponent("App/Resources/AppIcon-1024.png")
let iconsetURL = root.appendingPathComponent(".build/AppIcon.iconset")
let icnsURL = root.appendingPathComponent("App/Resources/AppIcon.icns")

let watermarkCrop: CGFloat = 180
let canvas: CGFloat = 1024
let iconInset: CGFloat = 100           // (1024 - 824) / 2
let cornerRadius: CGFloat = 183        // ≈ 0.2225 × 824

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("错误：" + message + "\n").data(using: .utf8)!)
    exit(1)
}

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("读不到原画：\(sourceURL.path)")
}

// 1) 裁掉底部水印
let width = CGFloat(image.width)
let height = CGFloat(image.height)
guard height > watermarkCrop else { fail("原画太矮，无法裁水印") }
guard let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: height - watermarkCrop)) else {
    fail("裁水印失败")
}

// 2) 居中取正方形
let side = min(CGFloat(cropped.width), CGFloat(cropped.height))
guard let square = cropped.cropping(to: CGRect(
    x: (CGFloat(cropped.width) - side) / 2,
    y: (CGFloat(cropped.height) - side) / 2,
    width: side,
    height: side
)) else {
    fail("取正方形失败")
}

// 3) 合成到规范画布
guard let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fail("创建画布失败")
}

context.interpolationQuality = .high
let iconRect = CGRect(
    x: iconInset,
    y: iconInset,
    width: canvas - iconInset * 2,
    height: canvas - iconInset * 2
)
context.saveGState()
context.addPath(CGPath(
    roundedRect: iconRect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
))
context.clip()
context.draw(square, in: iconRect)
context.restoreGState()

guard let composed = context.makeImage() else { fail("合成失败") }

func write(_ image: CGImage, to url: URL, size: Int? = nil) {
    let target: CGImage
    if let size, size != image.width {
        guard let scaled = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fail("缩放画布失败") }
        scaled.interpolationQuality = .high
        scaled.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let result = scaled.makeImage() else { fail("缩放失败") }
        target = result
    } else {
        target = image
    }

    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { fail("写文件失败：\(url.path)") }
    CGImageDestinationAddImage(destination, target, nil)
    guard CGImageDestinationFinalize(destination) else { fail("落盘失败：\(url.path)") }
}

write(composed, to: masterURL)

// 4) iconset：iconutil 需要的固定尺寸与命名
try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]
for variant in variants {
    write(composed, to: iconsetURL.appendingPathComponent(variant.name), size: variant.pixels)
}

print("已生成：\(masterURL.path)")
print("已生成 iconset：\(iconsetURL.path)")
print("下一步：iconutil -c icns \"\(iconsetURL.path)\" -o \"\(icnsURL.path)\"")
