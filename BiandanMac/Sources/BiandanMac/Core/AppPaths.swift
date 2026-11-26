import Foundation

/// 本机数据放在哪：~/Library/Application Support/BiandanMac。开发版（标识符以 .dev 结尾）用 BiandanMac.dev，
/// 和正式版分开：清理、卸载开发版时，不会连正式版的数据库、备份、统计一起删掉。
enum AppPaths {
    static func folderName(bundleID: String? = Bundle.main.bundleIdentifier) -> String {
        bundleID?.hasSuffix(".dev") == true ? "BiandanMac.dev" : "BiandanMac"
    }

    /// 数据目录，不存在时创建；取不到 Application Support 时为 nil。
    static func supportDirectory() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let directory = base.appendingPathComponent(folderName(), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
