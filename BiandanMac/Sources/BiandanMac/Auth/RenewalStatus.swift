import Foundation
import SwiftUI

// MARK: - 续期状态（只读快照，供界面显示）

/// 三个时间：
/// - `nextRenewalAt`：访问令牌到期前的续期时刻（`expires_in` 减去提前量），精确。
/// - `refreshEstimatedExpiry`：刷新令牌按华为常规 180 天估算的失效时间（令牌本身不透明，读不出到期日）。
/// - `deviceGrantExpiry`：便单设备凭据若是 JWT，读其中的 `exp`，精确；不是 JWT 时为 nil。
/// 需要重新登录的时间取后两者中较早的那个。
struct RenewalStatus: Equatable, Sendable {
    static let refreshLifetimeDays = 180

    var nextRenewalAt: Date?
    var accessExpiresAt: Date?
    var refreshIssuedAt: Date?
    var deviceGrantExpiry: Date?

    enum Limit: Equatable, Sendable {
        /// 由刷新令牌的 180 天估算决定。
        case refreshEstimate
        /// 由设备凭据的到期时间决定（精确）。
        case deviceGrant
    }

    var refreshEstimatedExpiry: Date? {
        refreshIssuedAt.map { $0.addingTimeInterval(Double(Self.refreshLifetimeDays) * 86_400) }
    }

    var reloginBy: Date? { reloginLimit?.date }

    var reloginLimit: (date: Date, limit: Limit)? {
        switch (refreshEstimatedExpiry, deviceGrantExpiry) {
        case let (refresh?, device?):
            return device < refresh ? (device, .deviceGrant) : (refresh, .refreshEstimate)
        case let (refresh?, nil):
            return (refresh, .refreshEstimate)
        case let (nil, device?):
            return (device, .deviceGrant)
        default:
            return nil
        }
    }

    /// 按自然日计算还剩几天（今天到期为 0，已过期为负数）。
    func daysUntilRelogin(now: Date, calendar: Calendar = .current) -> Int? {
        guard let date = reloginBy else { return nil }
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: from, to: to).day
    }

    /// 读取 JWT payload 里的 `exp`；签名不校验，只用于显示。不是 JWT 时返回 nil。
    static func jwtExpiry(_ token: String?) -> Date? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONValue.parseObject(data),
              let exp = claims.double("exp"), exp > 0 else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

// MARK: - 显示文案

enum RenewalText {
    /// 剩余天数不超过这个值时提醒。
    static let warnDays = 14
    static let warning = Color(hex: 0xE8890C)

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/M/d"
        return formatter.string(from: date)
    }

    private static func minutesLeft(_ status: RenewalStatus?, now: Date) -> Int? {
        guard let at = status?.nextRenewalAt else { return nil }
        let seconds = at.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        return Int((seconds / 60).rounded(.up))
    }

    private static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }

    /// 「约 52 分钟后（23:38）」；还没取过访问令牌或已过时刻时，在下次访问云端时续期。
    static func nextRenewal(_ status: RenewalStatus?, now: Date) -> String {
        guard let minutes = minutesLeft(status, now: now), let at = status?.nextRenewalAt else {
            return "下次访问云端时续期"
        }
        return "约 \(duration(minutes))后（\(clock(at))）"
    }

    /// 设置页小卡片用的短文案。
    static func nextRenewalShort(_ status: RenewalStatus?, now: Date) -> String {
        guard let minutes = minutesLeft(status, now: now) else { return "访问云端时" }
        return "\(duration(minutes))后"
    }

    static func nextRenewalNote(_ status: RenewalStatus?) -> String {
        guard let at = status?.nextRenewalAt else { return "启动后首次访问云端时用刷新令牌换新" }
        return "\(clock(at)) 前用刷新令牌自动换新"
    }

    static func reloginValue(days: Int?) -> String {
        guard let days else { return "通常 180 天" }
        if days > 0 { return "\(days) 天后" }
        return days == 0 ? "今天" : "已到期"
    }

    static func reloginNote(_ status: RenewalStatus?) -> String {
        guard let limit = status?.reloginLimit else { return "改密码或撤销授权会提前失效" }
        switch limit.limit {
        case .refreshEstimate: return "约 \(day(limit.date)) · 按 180 天估算，改密码会提前失效"
        case .deviceGrant: return "\(day(limit.date)) · 设备凭据到期"
        }
    }

    /// 账户面板一行：「剩 179 天 · 约 2027/5/19」。
    static func reloginLine(_ status: RenewalStatus?, now: Date) -> String {
        guard let limit = status?.reloginLimit, let days = status?.daysUntilRelogin(now: now) else {
            return "通常 180 天后"
        }
        if days <= 0 { return "需要重新登录" }
        let prefix = limit.limit == .refreshEstimate ? "约 " : ""
        return "剩 \(days) 天 · \(prefix)\(day(limit.date))"
    }

    /// nil 表示正常，不需要特别着色。
    static func tint(days: Int?) -> Color? {
        guard let days else { return nil }
        if days <= 0 { return Theme.overdue }
        return days <= warnDays ? warning : nil
    }

    /// 侧栏账户卡片的状态文字和圆点颜色。
    static func cardStatus(days: Int?) -> (text: String, color: Color) {
        guard let days else { return ("华为账号 · 自动续期", Color(hex: 0x34C759)) }
        if days <= 0 { return ("需要重新登录", Theme.overdue) }
        if days <= warnDays { return ("剩 \(days) 天需重新登录", warning) }
        return ("自动续期 · 剩 \(days) 天", Color(hex: 0x34C759))
    }
}

// MARK: - 账户面板里的续期卡片

struct RenewalSummary: View {
    let renewal: RenewalStatus?
    let now: Date

    var body: some View {
        let days = renewal?.daysUntilRelogin(now: now)
        let warn = RenewalText.tint(days: days)
        VStack(spacing: 0) {
            row(icon: "arrow.triangle.2.circlepath", tint: Quadrant.notImportantUrgent.tint,
                title: "下次续期", value: RenewalText.nextRenewal(renewal, now: now), valueColor: Theme.text)
            Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1).padding(.leading, 40)
            row(icon: "hourglass", tint: warn ?? Quadrant.neither.tint,
                title: "重新登录", value: RenewalText.reloginLine(renewal, now: now), valueColor: warn ?? Theme.text)
        }
        .themedCard()
        .help("访问令牌到期前会用刷新令牌自动续期；刷新令牌通常 180 天有效，到期后需要在浏览器里重新授权。")
    }

    private func row(icon: String, tint: Color, title: String, value: String, valueColor: Color) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 22, height: 22)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
                .fixedSize()
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}
