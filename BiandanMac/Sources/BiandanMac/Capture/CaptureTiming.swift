import AppKit
import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - 识别日程：分阶段计时、预热端侧模型和文字识别

enum CaptureStage: String, Codable, Hashable, Sendable {
    case capture, ocr, model, rules, decision, ai

    var title: String {
        switch self {
        case .capture: return "截图"
        case .ocr: return "文字识别"
        case .model: return "端侧模型"
        case .rules: return "规则识别"
        case .decision: return "AI 决策"
        case .ai: return "AI 识别"
        }
    }

    var running: String {
        switch self {
        case .capture: return "正在截图…"
        case .ocr: return "正在识别文字…"
        case .model: return "正在用端侧模型提取日程…"
        case .rules: return "正在用规则提取日程…"
        case .decision: return "正在用 AI 决策判断有没有日程…"
        case .ai: return "正在用 AI 识别日程…"
        }
    }
}

struct CaptureStageTiming: Codable, Hashable, Sendable {
    var stage: CaptureStage
    var ms: Int
    /// 用户点了「改用规则识别」，这一段没等到结果。
    var interrupted = false
    /// 只对端侧模型：开始时是否已预热（或几分钟内刚用过）。
    var warm: Bool?
    /// 这一段没有运行（例如端侧模型不可用）的原因。
    var skipped: String? = nil
}

struct CaptureTimingRecord: Codable, Hashable, Sendable {
    var date: Date
    var source: String
    var stages: [CaptureStageTiming]
    var totalMs: Int
}

enum CaptureTimingLog {
    static let key = "biandan.capture.timings"
    static let limit = 100
    private static let logger = Logger(subsystem: "ai.racore.BiandanMac", category: "capture")

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    static func records(_ defaults: UserDefaults = .standard) -> [CaptureTimingRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CaptureTimingRecord].self, from: data)) ?? []
    }

    static func append(_ record: CaptureTimingRecord, defaults: UserDefaults = .standard, keep: Int = limit) {
        var all = records(defaults)
        all.append(record)
        if all.count > keep { all.removeFirst(all.count - keep) }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
        let line = "识别耗时：" + text(record.stages) + " · 合计 " + duration(record.totalMs) + " · " + record.source
        logger.info("\(line, privacy: .public)")
    }

    static func duration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) 毫秒" : String(format: "%.1f 秒", Double(ms) / 1000)
    }

    /// 「截图 0.2 秒 · 文字识别 0.9 秒 · 端侧模型 5.3 秒（未预热）」
    static func text(_ stages: [CaptureStageTiming]) -> String {
        stages.map { item in
            if let skipped = item.skipped { return item.stage.title + "不可用（" + skipped + "）" }
            var part = item.stage.title + " " + duration(item.ms)
            if item.interrupted {
                part += "（已中断）"
            } else if let warm = item.warm {
                part += warm ? "（已预热）" : "（未预热）"
            }
            return part
        }.joined(separator: " · ")
    }

    /// 端侧模型的平均耗时（毫秒）：未预热 / 已预热。被中断的不算。
    static func modelAverages(_ records: [CaptureTimingRecord]) -> (cold: Double?, warm: Double?) {
        var cold: [Int] = []
        var warm: [Int] = []
        for record in records {
            for item in record.stages where item.stage == .model && !item.interrupted && item.skipped == nil && item.ms > 0 {
                if item.warm == true { warm.append(item.ms) } else { cold.append(item.ms) }
            }
        }
        func average(_ values: [Int]) -> Double? {
            values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count)
        }
        return (average(cold), average(warm))
    }

    /// 鼠标悬停在耗时上时显示：最近 10 次，以及端侧模型的平均耗时。
    static func summary(_ defaults: UserDefaults = .standard) -> String {
        let all = records(defaults)
        guard !all.isEmpty else { return "还没有耗时记录" }
        var lines = ["最近 \(min(all.count, 10)) 次识别耗时："]
        for record in all.suffix(10).reversed() {
            lines.append(timeFormatter.string(from: record.date) + " · " + text(record.stages)
                         + " · 合计 " + duration(record.totalMs))
        }
        let averages = modelAverages(all)
        var parts: [String] = []
        if let cold = averages.cold { parts.append("未预热 " + duration(Int(cold.rounded()))) }
        if let warm = averages.warm { parts.append("已预热 " + duration(Int(warm.rounded()))) }
        if !parts.isEmpty { lines.append("端侧模型平均：" + parts.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 预热

/// 端侧模型第一次调用要先把模型读进内存（几秒）。鼠标移到浮窗球上、开始框选或启动后，
/// 在后台先建好一个对话并预热，识别时直接用它；文字识别也先跑一次小图，加载中文识别模型。
final class ModelWarmup: @unchecked Sendable {
    static let shared = ModelWarmup()
    /// 几分钟内用过端侧模型，系统通常还没释放，当作已预热。
    static let recentWindow: TimeInterval = 300

    private let lock = NSLock()
    private var session: AnyObject?
    private var lastAttempt: Date?
    private var lastUse: Date?
    private var ocrWarmed = false

    /// 有可用的端侧模型时，建好对话并预热；throttle 秒内不重复，已有预热好的对话时不再建。
    func prewarm(throttle: TimeInterval = 60) {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return }
        guard case .available = SystemLanguageModel.default.availability else { return }
        guard shouldAttempt(throttle) else { return }
        let fresh = LanguageModelSession(instructions: ModelScheduleExtractor.instructions)
        fresh.prewarm()
        store(fresh)
        #endif
    }

    /// 取走预热好的对话（用一次就换新的，免得上一次的对话内容带进来）。
    func take() -> AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        let taken = session
        session = nil
        lastUse = Date()
        return taken
    }

    var isWarm: Bool {
        lock.lock()
        defer { lock.unlock() }
        if session != nil { return true }
        return lastUse.map { Date().timeIntervalSince($0) < Self.recentWindow } ?? false
    }

    /// 每次启动只做一次。
    func warmOCROnce() {
        guard markOCR() else { return }
        TextRecognizer.prewarm()
    }

    private func shouldAttempt(_ throttle: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if session != nil { return false }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < throttle { return false }
        lastAttempt = Date()
        return true
    }

    private func store(_ fresh: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        session = fresh
    }

    private func markOCR() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if ocrWarmed { return false }
        ocrWarmed = true
        return true
    }
}

extension TextRecognizer {
    /// 用一张写着中文的小图跑一次识别，让系统先加载中文识别模型。
    static func prewarm() {
        let width = 260, height = 64
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black,
        ]
        ("明天下午3点 项目周会" as NSString).draw(at: NSPoint(x: 10, y: 18), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return }
        Task.detached(priority: .utility) {
            _ = try? await TextRecognizer.recognize(image)
        }
    }
}

// MARK: - 确认卡片的阶段与计时

extension SchedulePreviewState {
    /// 端侧模型或 AI 还没返回时，可以改用规则识别。
    var canSkipToRules: Bool { loading && (stage == .model || stage == .ai) && !lines.isEmpty }

    var timingText: String { CaptureTimingLog.text(timings) }

    func resetTiming() {
        extractionTask?.cancel()
        extractionTask = nil
        runID = UUID()
        stage = nil
        timings = []
        modelWarm = nil
        flowStart = Date()
        stageStart = Date()
    }

    func enter(_ next: CaptureStage, warm: Bool? = nil, interruptPrevious: Bool = false) {
        closeStage(interrupted: interruptPrevious)
        if next == .model { modelWarm = warm }
        stage = next
        stageStart = Date()
    }

    /// 记下没有运行的阶段（不计时）。
    func skip(_ skipped: CaptureStage, reason: String) {
        closeStage(interrupted: false)
        timings.append(CaptureStageTiming(stage: skipped, ms: 0, skipped: reason))
    }

    /// 结束计时并记下这次的耗时。
    func finishTiming(source: String, defaults: UserDefaults = .standard) {
        closeStage(interrupted: false)
        guard !timings.isEmpty else { return }
        let total = max(Int(Date().timeIntervalSince(flowStart) * 1000), 0)
        CaptureTimingLog.append(CaptureTimingRecord(date: flowStart, source: source, stages: timings, totalMs: total),
                                defaults: defaults)
    }

    fileprivate func closeStage(interrupted: Bool) {
        guard let current = stage else { return }
        let ms = max(Int(Date().timeIntervalSince(stageStart) * 1000), 0)
        timings.append(CaptureStageTiming(stage: current, ms: ms, interrupted: interrupted,
                                          warm: current == .model ? modelWarm : nil))
        stage = nil
    }
}
