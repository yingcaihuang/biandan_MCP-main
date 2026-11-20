import Foundation

typealias JSONObject = [String: JSONValue]

enum JSONValueError: Error {
    case notAnObject
}

/// 云端 attributes 的无损 JSON 表示。
/// 用 JSONSerialization 解析并按 NSNumber 真实类型区分布尔、整数、小数，
/// 避免 0/1 与 true/false 混淆。
enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                let type = String(cString: number.objCType)
                if type == "d" || type == "f" {
                    self = .double(number.doubleValue)
                } else {
                    self = .int(number.int64Value)
                }
            }
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    /// 转回 Foundation 对象供 JSONSerialization 使用。非有限小数写成 null，避免序列化崩溃。
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return NSNumber(value: value)
        case .int(let value): return NSNumber(value: value)
        case .double(let value): return value.isFinite ? NSNumber(value: value) : NSNull()
        case .string(let value): return value
        case .array(let values): return values.map { $0.anyValue }
        case .object(let values): return values.mapValues { $0.anyValue }
        }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: object)
    }

    static func parseObject(_ data: Data) throws -> JSONObject {
        guard case .object(let object) = try parse(data) else { throw JSONValueError.notAnObject }
        return object
    }

    static func parseObject(_ text: String) -> JSONObject? {
        try? parseObject(Data(text.utf8))
    }

    func serialized(pretty: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if pretty {
            options.insert(.prettyPrinted)
            options.insert(.sortedKeys)
        }
        return try JSONSerialization.data(withJSONObject: anyValue, options: options)
    }

    func serializedString(pretty: Bool = false) -> String {
        guard let data = try? serialized(pretty: pretty) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 宽松读取

    var intValue: Int? {
        switch self {
        case .int(let value): return Int(exactly: value)
        case .double(let value):
            guard value.isFinite, value.rounded() == value, let exact = Int64(exactly: value) else { return nil }
            return Int(exactly: exact)
        case .bool(let value): return value ? 1 : 0
        case .string(let value): return Int(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .string(let value): return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// 业务 ID 兼容数字或数字字符串，统一转为十进制字符串。
    var identifierString: String? {
        switch self {
        case .int(let value):
            return String(value)
        case .double(let value):
            guard let exact = Int64(exactly: value) else { return nil }
            return String(exact)
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if let number = Int64(trimmed) { return String(number) }
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }

    /// 检查器里显示的简短文本。
    var displayText: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value.isEmpty ? "\"\"" : value
        case .array, .object: return serializedString()
        }
    }

    /// 与 Python `bool(value)` 一致的真值判断。
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .double(let value): return value != 0
        case .string(let value): return !value.isEmpty
        case .array(let values): return !values.isEmpty
        case .object(let values): return !values.isEmpty
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func double(_ key: String) -> Double? { self[key]?.doubleValue }
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func identifier(_ key: String) -> String? { self[key]?.identifierString }
    func truthy(_ key: String) -> Bool { self[key]?.isTruthy ?? false }
}
