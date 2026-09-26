import AppKit
import SwiftUI
import XCTest

import DoyahCore
@testable import DoyahStudioApp

/// **界面快照基建**（队列 L-01）。
///
/// ## 为什么是这条路
///
/// - `Scripts/design-mock.swift` 是**照着重画**的样张 —— 它证明"设计长这样"，证明不了"真界面长这样"；
/// - 屏幕录制权限还没拿到，助理截不了运行中 App 的图（spec §7「桌面操作能力」）；
/// - `SwiftUI.ImageRenderer` 是**离屏**渲染**真视图树**：不需要辅助功能、不需要屏幕录制、
///   不需要图形会话里的窗口 —— 于是 spec §5.2 的"静态观感类"条目第一次有了可复现的机器证据。
///
/// ## 三条纪律
///
/// 1. **不进每轮门禁**：`Scripts/verify-core.sh` 的 `swift test` 会**编译**本 target，但用例默认
///    `XCTSkip`（要 `DOYAH_UI_SNAPSHOT=1` 才跑）。快照是**取证工具**，塞进门禁只会拖慢门禁并制造假失败。
/// 2. **产物落在 `.build/ui-snapshots/`**（`.build/` 已在 `.gitignore` 里）—— 快照是**证据**，不是交付物。
/// 3. **每张图都要带断言**：渲染完立刻校验"非空白"（非背景像素占比下限）并把像素尺寸写进清单。
///    只产出 PNG 不断言的话，一张全白的图也会被当成"界面没问题"。
enum UISnapshot {

    static let enableKey = "DOYAH_UI_SNAPSHOT"

    static var isEnabled: Bool { ProcessInfo.processInfo.environment[enableKey] == "1" }

    /// 工程根（由 `#filePath` 反推，不依赖 cwd）。
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TestsUISnapshot/
        .deletingLastPathComponent()   // <root>/

    /// 产物目录：默认 `.build/ui-snapshots/`，可用 `DOYAH_SNAPSHOT_DIR` 覆盖。
    static var outputDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["DOYAH_SNAPSHOT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return packageRoot.appendingPathComponent(".build/ui-snapshots", isDirectory: true)
    }

    // MARK: - 清单

    struct Record: Codable {
        var name: String
        var file: String
        var width: Int
        var height: Int
        var scale: Double
        var scheme: String
        var bytes: Int
        /// 非背景像素占比（0~1）。用来挡"渲染成空白但文件不为空"这种假绿。
        var contentRatio: Double
        /// 实际画出内容的那条渲染路径（含两条路径各自的占比，便于排障）。
        var renderer: String
    }

    private(set) static var records: [Record] = []

    // MARK: - 渲染

    enum SnapshotError: Error, CustomStringConvertible {
        case renderFailed(String)
        case encodeFailed(String)
        /// 两条渲染路径都没画出内容：`(快照名, 各路径的内容占比说明)`
        case blank(String, String)

        var description: String {
            switch self {
            case .renderFailed(let name): return "渲染没产出位图：\(name)"
            case .encodeFailed(let name): return "PNG 编码失败：\(name)"
            case .blank(let name, let detail): return "快照没有内容：\(name)（各渲染路径的内容占比：\(detail)）"
            }
        }
    }

    /// 渲染一张快照并落盘。`content` 拿到的视图**不要**自己设 frame —— 尺寸由这里统一给。
    @MainActor
    @discardableResult
    static func write<V: View>(
        _ name: String,
        size: CGSize,
        scheme: ColorScheme = .light,
        scale: CGFloat = 2,
        minimumContentRatio: Double = 0.002,
        @ViewBuilder content: () -> V
    ) throws -> Record {
        let directory = outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 合成在**窗口底色**上：真运行时这些视图背后就有这一层（面板自己不带不透明底），
        // 不铺的话导出的 PNG 是透明底 —— 看图的人分不清"这里是空白"还是"这里什么都没画"，
        // 而"什么都没画"恰恰是快照要抓的失败态。
        //
        // 注意 `.environment` 必须在**最外层**：写在 ZStack 内部时，后面的 `.background`
        // 之类会落在它的作用域之外，深色一遍就会用系统真实外观去解析动态色。
        let view = ZStack {
            Theme.surface(.window)
            content()
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, scheme)

        // 三条渲染路径都试，取能画出内容的那条（见 `renderer` 字段：证据要说明**怎么来的**）。
        //
        // 实测（本机 / Swift 6.4）：
        // · `ImageRenderer` 对 **`ScrollView`** 与 **`NSViewRepresentable`** 两种容器画不出内容 ——
        //   `ScrollView { Text(…) }`、工作区 Home 页、结果表主体（`ResultGrid` 是 AppKit 自绘）
        //   都渲染成**整幅背景**或干脆是系统的"不可渲染"占位图，结果表只画出 SwiftUI 那半边（工具栏）。
        // · 无窗口的 `NSHostingView` + `cacheDisplay` 能画 `ScrollView`，但 **AppKit 自绘的
        //   `List` / 侧栏**画不出来（第 10 轮实测：连接列表整幅背景）；
        // · 给它一个**离屏窗口**（路径一）后连 `List` 也能画出来。
        // 所以顺序是：窗口宿主 → 无窗口宿主 → `ImageRenderer`，**先密后疏**，
        // 并把 Apple 的占位图在选路阶段就淘汰掉（否则它比真界面还"有内容"，见 `placeholderShare`）。
        let attempts: [(label: String, render: () throws -> CGImage)] = [
            ("NSWindow+NSHostingView", { try windowHostedImage(view, size: size, scale: scale, scheme: scheme) }),
            ("NSHostingView", { try hostedImage(view, size: size, scale: scale, scheme: scheme) }),
            ("ImageRenderer", { try imageRenderer(view, size: size, scale: scale) }),
        ]

        var attemptsLog: [String] = []
        var picked: (label: String, image: CGImage, ratio: Double)?
        for attempt in attempts {
            do {
                let image = try attempt.render()
                // 占位图**先判**：Apple 那条"不可渲染"的路（黄底红圈）在像素上很密，
                // 非空白占比能到 0.18，光看占比会把一张占位图当成"界面没问题"（第 10 轮实测就是这么被骗的）。
                if let share = placeholderShare(image) {
                    attemptsLog.append("\(attempt.label)=不可渲染占位图（黄 \(String(format: "%.2f", share.yellow))/红 \(String(format: "%.2f", share.red))）")
                    continue
                }
                let ratio = contentRatio(of: image)
                attemptsLog.append("\(attempt.label)=\(String(format: "%.3f", ratio))")
                if ratio >= minimumContentRatio {
                    picked = (attempt.label, image, ratio)
                    break
                }
            } catch {
                attemptsLog.append("\(attempt.label)=失败(\(error))")
            }
        }

        guard let picked else {
            throw SnapshotError.blank(name, attemptsLog.joined(separator: " / "))
        }

        let cgImage = picked.image
        guard let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodeFailed(name)
        }
        let url = directory.appendingPathComponent("\(name).png", isDirectory: false)
        try data.write(to: url, options: .atomic)

        let ratio = picked.ratio

        let record = Record(
            name: name,
            file: url.path,
            width: cgImage.width,
            height: cgImage.height,
            scale: Double(scale),
            scheme: scheme == .dark ? "dark" : "light",
            bytes: data.count,
            contentRatio: ratio,
            renderer: "\(picked.label)（尝试 \(attemptsLog.joined(separator: "、"))）"
        )
        records.append(record)
        print("📷 \(name)  \(cgImage.width)×\(cgImage.height)px  \(data.count) B  内容占比 \(String(format: "%.3f", ratio))  [\(picked.label)]  → \(url.path)")
        return record
    }

    /// 路径一：`SwiftUI.ImageRenderer`（不需要 AppKit 宿主，但对滚动容器与 AppKit 子视图画不出内容）。
    @MainActor
    private static func imageRenderer<V: View>(_ view: V, size: CGSize, scale: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage else { throw SnapshotError.renderFailed("ImageRenderer") }
        return image
    }

    /// 路径一：**离屏窗口**里的 `NSHostingView`（本轮新增）。
    ///
    /// 为什么需要这一条（第 10 轮实测）：`List` / 侧栏这类 AppKit 自绘容器在**没有窗口**的
    /// 宿主里画不出内容（`cacheDisplay` 拿到的是整幅背景），于是退到 `ImageRenderer`，
    /// 而它给出的是 Apple 的"不可渲染"占位图 —— 一张黄底红圈的图。给宿主一个真实的
    /// `NSWindow`（**不** order、不显示）后 AppKit 才会真正 tile 这些控件。
    ///
    /// 窗口刻意不上屏：无人值守的机器上不该"闪一下"。这里只用它的布局与 backing store 通道。
    @MainActor
    private static func windowHostedImage<V: View>(
        _ view: V, size: CGSize, scale: CGFloat, scheme: ColorScheme
    ) throws -> CGImage {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        let rep = try bitmap(size: size, scale: scale)
        hostDisplay(hosting, into: rep)
        return try cgImage(from: rep, label: "NSWindow+NSHostingView")
    }

    /// 路径二：`NSHostingView` 真实布局 + `cacheDisplay`（打印/导出同一条路）。
    /// 没有窗口的宿主：SwiftUI 那半边能画，AppKit 自绘容器画不出来（所以要配上路径一）。
    @MainActor
    private static func hostedImage<V: View>(_ view: V, size: CGSize, scale: CGFloat, scheme: ColorScheme) throws -> CGImage {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let rep = try bitmap(size: size, scale: scale)
        hostDisplay(hosting, into: rep)
        return try cgImage(from: rep, label: "NSHostingView")
    }

    /// 位图自己按 `scale` 建（`cacheDisplay` 会按 rep 的 `size` 换算），这样离屏也有 2× 图。
    private static func bitmap(size: CGSize, scale: CGFloat) throws -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { throw SnapshotError.renderFailed("位图分配失败") }
        rep.size = size
        return rep
    }

    private static func hostDisplay(_ hosting: NSView, into rep: NSBitmapImageRep) {
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
    }

    private static func cgImage(from rep: NSBitmapImageRep, label: String) throws -> CGImage {
        guard let image = rep.cgImage else { throw SnapshotError.renderFailed("\(label)（取不到位图）") }
        return image
    }

    /// Apple 那条「这个视图我画不出来」的占位图的配色（实测像素值）。
    ///
    /// 为什么必须单独识别它：这张图**相当密**（本机实测：黄 81.4% + 红 18.1%，内容占比 0.185），
    /// 「非空白」那道断言拦不住 —— 它比绝大多数真界面都"有内容"。第 10 轮实测就踩了这个坑：
    /// `List` 这类 AppKit 自绘容器在**无窗口**宿主里画不出内容，退到 `ImageRenderer` 后
    /// 拿回来的正是这张占位图，于是被当成有效证据落进清单。
    ///
    /// 判据写成颜色而不是"看起来像"：命中（黄占比 > 0.4 且红占比 > 0.03）就在**选路阶段**
    /// 淘汰该条路径。容差 8 用来抗色彩空间换算。
    static func placeholderShare(_ image: CGImage) -> (yellow: Double, red: Double)? {
        guard let buffer = rgbaBuffer(of: image) else { return nil }
        let yellow: (Int, Int, Int) = (255, 204, 0)
        let red: (Int, Int, Int) = (255, 56, 60)
        var yellowCount = 0
        var redCount = 0
        var total = 0
        for index in stride(from: 0, to: buffer.pixels.count, by: 4) {
            total += 1
            let r = Int(buffer.pixels[index])
            let g = Int(buffer.pixels[index + 1])
            let b = Int(buffer.pixels[index + 2])
            if abs(r - yellow.0) <= 8, abs(g - yellow.1) <= 8, abs(b - yellow.2) <= 8 {
                yellowCount += 1
            } else if abs(r - red.0) <= 8, abs(g - red.1) <= 8, abs(b - red.2) <= 8 {
                redCount += 1
            }
        }
        guard total > 0 else { return nil }
        let yellowShare = Double(yellowCount) / Double(total)
        let redShare = Double(redCount) / Double(total)
        guard yellowShare > 0.4, redShare > 0.03 else { return nil }
        return (yellowShare, redShare)
    }

    /// 非背景像素占比：把图重画进 8 位 RGBA 缓冲，逐点与"左上角像素"比较。
    ///
    /// 为什么用左上角当背景基准而不是取众数：界面快照的左上角在**所有**目标视图里
    /// 都是空白底色（面板内边距），这个前提比"众数是背景"更稳定 —— 结果表这种大面积
    /// 文字+网格的图，众数可能直接落在文字色上。
    private static func contentRatio(of image: CGImage) -> Double {
        guard let buffer = rgbaBuffer(of: image), buffer.width > 0, buffer.height > 0 else { return 0 }
        let pixels = buffer.pixels

        let baseline = (pixels[0], pixels[1], pixels[2], pixels[3])
        var differing = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            // 容差 6：抗锯齿与压缩噪点不该被算成"内容"。
            // **四个通道都要比**：原先只比 RGB 时，"透明底上的黑色文字"整幅被判成空白
            // （预乘 alpha 下透明像素与纯黑像素的 RGB 都是 0）—— 这正是本轮踩到的坑。
            if abs(Int(pixels[index]) - Int(baseline.0)) > 6
                || abs(Int(pixels[index + 1]) - Int(baseline.1)) > 6
                || abs(Int(pixels[index + 2]) - Int(baseline.2)) > 6
                || abs(Int(pixels[index + 3]) - Int(baseline.3)) > 6 {
                differing += 1
            }
        }
        return Double(differing) / Double(buffer.width * buffer.height)
    }

    /// 把 `CGImage` 重画进 8 位 RGBA 缓冲，供逐点分析（内容占比 / 占位图识别共用）。
    private static func rgbaBuffer(of image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let context = buffer.withUnsafeMutableBytes({ raw -> CGContext? in
            guard let base = raw.baseAddress else { return nil }
            return CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (buffer, width, height)
    }

    /// 类级收尾：整组用例跑完再写清单。
    ///
    /// 为什么要一个共用入口：清单里的 `records` 是**跨用例、跨测试类**累积的静态数组，
    /// 而"谁最后跑完"由 XCTest 决定。于是每个测试类都在类级收尾里调这里 ——
    /// 后跑的那一类写出来的就是**全量**清单（先跑的那一类写的会被后一个覆盖，但内容更全）。
    static func finishManifestIfEnabled() {
        guard isEnabled, !records.isEmpty else { return }
        do {
            if let url = try writeManifest(extra: ["snapshotCount": String(records.count)]) {
                print("🧾 清单：\(url.path)（\(records.count) 张）")
            }
        } catch {
            print("⚠️ 清单写入失败：\(error)")
        }
    }

    /// 把本轮清单写成 `manifest.json`：谁在什么时候渲染了什么、多大、内容占比多少。
    /// 不写空清单覆盖上一轮产物（`records` 为空时说明这一轮什么都没渲染）。
    static func writeManifest(extra: [String: String] = [:]) throws -> URL? {
        guard !records.isEmpty else { return nil }
        let directory = outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("manifest.json", isDirectory: false)

        var payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "snapshots": records.map { record -> [String: Any] in
                [
                    "name": record.name,
                    "file": record.file,
                    "width": record.width,
                    "height": record.height,
                    "scale": record.scale,
                    "scheme": record.scheme,
                    "bytes": record.bytes,
                    "contentRatio": record.contentRatio,
                    "renderer": record.renderer
                ]
            }
        ]
        for (key, value) in extra { payload[key] = value }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 许可证（三档呈现要用真签名，不能"假装备注"）

    /// 临时密钥对（每次运行现生成，不落仓库）。
    struct TierKeys { var privateKey: Data; var publicKey: Data }

    static let tierKeys = LicenseIssuing.makeKeyPair()

    static var licenseDirectory: URL {
        outputDirectory.deletingLastPathComponent().appendingPathComponent("ui-snapshot-licenses", isDirectory: true)
    }

    /// 签一份指定档位的临时许可证，**用环境变量把 AppState 指过去**，然后让它自己重读。
    ///
    /// 走的是产品里真实存在的两条路（`DOYAH_LICENSE_PATH` / `DOYAH_LICENSE_PUBLIC_KEY`）与真实的
    /// `reloadLicense()`（用户放好许可证、不重启就生效的那个动作）—— 不是测试专用的后门。
    @MainActor
    @discardableResult
    static func applyLicense(_ edition: LicenseEdition, to state: AppState) throws -> LicenseLoader.LoadResult {
        let license = License(
            issuedTo: "ui-snapshot",
            capabilities: edition.capabilities,
            maxDevices: License.defaultMaxDevices,
            expiresAt: nil,
            devices: [LicenseDevice(name: "snapshot-runner")]
        )
        let file = try LicenseIssuing.sign(license, privateKey: tierKeys.privateKey)
        let url = licenseDirectory.appendingPathComponent("snapshot-\(edition.rawValue).doyahlicense", isDirectory: false)
        try FileManager.default.createDirectory(at: licenseDirectory, withIntermediateDirectories: true)
        try file.encoded().write(to: url, atomically: true, encoding: .utf8)

        setenv(LicenseLoader.licensePathEnvironmentKey, url.path, 1)
        setenv("DOYAH_LICENSE_PUBLIC_KEY", tierKeys.publicKey.base64EncodedString(), 1)
        state.reloadLicense()
        return state.licenseLoad
    }

    /// 清掉这一轮的临时许可指向（不给后续用例留脏环境）。
    @MainActor
    static func clearLicense(from state: AppState) {
        unsetenv(LicenseLoader.licensePathEnvironmentKey)
        unsetenv("DOYAH_LICENSE_PUBLIC_KEY")
        state.reloadLicense()
    }
}

// MARK: - 视图宿主

extension View {
    /// 按 `DoyahStudioApp.swift` 根部的注入顺序补上环境对象。
    ///
    /// 只有 genuinely 需要的对象会被真正读到；但**一次性把根视图那套注入全给上**，
    /// 是因为少了任何一个都会在渲染时崩（SwiftUI 对缺失的 `@EnvironmentObject` 直接 fatalError），
    /// 而"这次要哪几个"会随视图演进而变 —— 让宿主跟着根视图走，比逐张图猜依赖稳。
    @MainActor
    func snapshotEnvironment(
        state: AppState,
        workspace: WorkspaceStore,
        tabs: WorkspaceTabsModel,
        accent: AccentManager = .shared,
        localization: LocalizationManager = .shared,
        terminal: TerminalModel
    ) -> some View {
        environmentObject(state)
            .environmentObject(workspace)
            .environmentObject(tabs)
            .environmentObject(accent)
            .environmentObject(localization)
            .environmentObject(terminal)
    }
}
