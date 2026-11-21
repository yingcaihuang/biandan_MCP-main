import AppKit
import Foundation

/// 便单官方图标（512×512 PNG，已获官方授权）。数据嵌在 BrandIconData.swift，不走网络、不依赖资源包。
enum BrandIcon {
    static var pngData: Data { Data(base64Encoded: pngBase64) ?? Data() }
    /// 本地回调页用的 data URI；对应页面的 CSP 需放行 img-src data:。
    static var dataURI: String { "data:image/png;base64," + pngBase64 }
    static var image: NSImage? { NSImage(data: pngData) }
}
