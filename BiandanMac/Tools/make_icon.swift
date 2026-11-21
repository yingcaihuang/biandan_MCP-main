// 把官方原图（Assets/icon-source.png）按 macOS 图标规范合成：1024 画布、824 圆角白底（四周各留 100）、轻微阴影。
// 输出 Assets/AppIcon-1024.png（生成 .icns 用）和 Assets/biandan.png（512，嵌进 App 用）。
// 用法：swift Tools/make_icon.swift ；之后运行 python3 Tools/embed_icon.py
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = root.appendingPathComponent("Assets/icon-source.png")
guard let source = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write("找不到 \(sourceURL.path)\n".data(using: .utf8)!)
    exit(1)
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = s / 1024
    let tile = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * scale, yRadius: 185 * scale)

    // 阴影
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 18 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 白底加一点暖色渐变，贴近便单的米色主题
    let gradient = NSGradient(starting: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1),
                              ending: NSColor(calibratedRed: 1.0, green: 0.976, blue: 0.94, alpha: 1))
    gradient?.draw(in: path, angle: -90)

    // 原图本身带约 17% 留白，直接铺满圆角底即可
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    source.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:]) ?? Data()
}

for (name, size) in [("Assets/AppIcon-1024.png", 1024), ("Assets/biandan.png", 512)] {
    let url = root.appendingPathComponent(name)
    try render(size: size).write(to: url)
    print("\(name) \(size)×\(size)")
}
