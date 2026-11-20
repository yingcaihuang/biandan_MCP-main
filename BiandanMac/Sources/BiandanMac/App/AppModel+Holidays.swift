import Foundation

extension AppModel {
    private static let holidayCheckKey = "biandan.holidayCheckedAt"

    /// 检查有没有新一年的调休数据。非强制时每 24 小时最多检查一次。
    func checkHolidayUpdates(force: Bool) async {
        holidayLastYear = ChinaMakeup.lastYear
        guard !isCheckingHolidays else { return }
        let defaults = UserDefaults.standard
        if !force, let last = defaults.object(forKey: Self.holidayCheckKey) as? Date,
           Date().timeIntervalSince(last) < 86_400 {
            return
        }
        isCheckingHolidays = true
        let outcome = await HolidayUpdater.shared.checkForUpdates()
        isCheckingHolidays = false
        holidayLastYear = ChinaMakeup.lastYear
        switch outcome {
        case .upToDate(let year):
            holidayStatus = "已是最新，覆盖到 \(String(year)) 年。"
        case .updated(let year, let added):
            holidayStatus = "已补充 \(added.map(String.init).joined(separator: "、")) 年，覆盖到 \(String(year)) 年。"
        case .notPublished(let year):
            holidayStatus = "\(String(year)) 年的放假安排尚未发布。"
        case .failed(let message):
            holidayStatus = "检查失败：\(message)"
            return
        }
        defaults.set(Date(), forKey: Self.holidayCheckKey)
    }
}
