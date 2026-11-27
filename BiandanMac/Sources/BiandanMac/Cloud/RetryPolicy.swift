import Foundation

/// 云端请求遇到限流或服务暂时不可用时的重试规则。
enum RetryPolicy {
    /// 一个请求最多发几次（含第一次）。
    static let maxAttempts = 3

    /// 429（被限流，服务端没处理）所有请求都重试；503 只重试读请求，免得写请求重复写入。
    static func shouldRetry(status: Int?, method: String) -> Bool {
        status == 429 || (status == 503 && method == "GET")
    }

    /// 第 attempt 次（从 1 开始）失败后等多久：服务给了 Retry-After 就用它（最多 10 秒），否则 0.5、1、2 秒。
    static func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return min(retryAfter, 10) }
        return 0.5 * pow(2, Double(max(attempt, 1) - 1))
    }
}
