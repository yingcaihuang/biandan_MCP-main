import Foundation

/// 云端或续期服务的错误，对应 Python `CloudError`。
struct CloudError: Error, LocalizedError, Sendable {
    var message: String
    var status: Int?
    var code: String?
    /// 429 / 503 时服务给出的重试秒数。
    var retryAfter: TimeInterval?

    init(_ message: String, status: Int? = nil, code: String? = nil, retryAfter: TimeInterval? = nil) {
        self.message = message
        self.status = status
        self.code = code
        self.retryAfter = retryAfter
    }

    var errorDescription: String? { message }

    var isReauthorizationRequired: Bool { status == 401 && code == "reauthorization_required" }
}

/// 不跟随任何重定向；3xx 按失败处理，与 Python 的 NoRedirect 一致。
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum HTTPTransport {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    /// 发送请求并返回 JSON 对象。空响应体返回空对象。
    /// 响应里出现非空的 `errors` / `error` 时按失败处理。
    static func requestJSON(method: String, url: URL, headers: [String: String] = [:],
                            body: Data? = nil) async throws -> JSONObject {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudError("\(method) 无法连接服务或请求超时")
        }
        guard let http = response as? HTTPURLResponse else {
            throw CloudError("服务返回了无法识别的响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            var code: String?
            if http.statusCode == 401,
               let failure = try? JSONValue.parseObject(data.prefix(4096)),
               failure.string("error") == "reauthorization_required" {
                code = "reauthorization_required"
            }
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            throw CloudError("\(method) 失败，HTTP \(http.statusCode)", status: http.statusCode,
                             code: code, retryAfter: retry)
        }
        if data.isEmpty { return [:] }
        guard let value = try? JSONValue.parse(data), case .object(let object) = value else {
            throw CloudError("服务返回了无效的 JSON")
        }
        if object["errors"]?.isTruthy == true || object["error"]?.isTruthy == true {
            throw CloudError("服务返回了错误或意外的响应")
        }
        return object
    }

    // MARK: - 编码工具

    /// 与 Python `urllib.parse.urlencode`（quote_plus）一致：只保留 ASCII 字母数字和 `-._~`，空格写成 `+`。
    static func formEncode(_ pairs: [(String, String)]) -> String {
        pairs.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&")
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: " "):
                out.append("+")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// 与 Python `parse_qs(keep_blank_values=True)` 一致：`+` 视为空格，再做百分号解码。
    static func parseQuery(_ query: String?) -> [String: [String]] {
        var result: [String: [String]] = [:]
        guard let query, !query.isEmpty else { return result }
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let spaced = s.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            let key = decode(pieces[0])
            let value = pieces.count > 1 ? decode(pieces[1]) : ""
            result[key, default: []].append(value)
        }
        return result
    }
}
