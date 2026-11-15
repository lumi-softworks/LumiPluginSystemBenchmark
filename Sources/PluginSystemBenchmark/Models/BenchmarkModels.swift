import Foundation

public enum BenchmarkKind: String, CaseIterable, Hashable, Identifiable, Codable, Sendable {
    case cpu
    case memory
    case disk

    public var id: String { rawValue }
}

public enum BenchmarkMode: String, CaseIterable, Codable, Sendable {
    case quick
    case deep

    public var isDeep: Bool { self == .deep }
}

/// 质量分档由变异系数决定：3% / 8% 是业界常用的「可比较」与「仅供参考」边界。
public enum BenchmarkQuality: String, Codable, Sendable {
    case stable
    case fair
    case noisy

    public static let stableThreshold = 0.03
    public static let fairThreshold = 0.08

    public static func from(coefficientOfVariation: Double) -> BenchmarkQuality {
        if coefficientOfVariation <= stableThreshold { return .stable }
        if coefficientOfVariation <= fairThreshold { return .fair }
        return .noisy
    }
}

public struct BenchmarkMeasurement: Identifiable, Equatable, Codable, Sendable {
    /// 稳定的测试标识（如 `cpu.single`），用于基线配对与历史对比。
    public let id: String
    public let kind: BenchmarkKind
    /// 本地化键，展示时再翻译，避免结果文件被写死成某一种语言。
    public let label: String
    public let unit: String
    public let statistics: BenchmarkStatistics
    public let durationMilliseconds: Double
    /// 本地化键，解释这项测得是什么。
    public let detail: String
    /// 可选的格式化参数（如线程数），与 `detail` 一起本地化。
    public let detailArgument: String?
    /// 诊断项只用于解释「为什么是这个分」，不参与指数。
    public let isDiagnostic: Bool

    public init(
        id: String,
        kind: BenchmarkKind,
        label: String,
        unit: String,
        statistics: BenchmarkStatistics,
        durationMilliseconds: Double,
        detail: String,
        detailArgument: String? = nil,
        isDiagnostic: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.unit = unit
        self.statistics = statistics
        self.durationMilliseconds = durationMilliseconds
        self.detail = detail
        self.detailArgument = detailArgument
        self.isDiagnostic = isDiagnostic
    }

    public var value: Double { statistics.median }
    public var quality: BenchmarkQuality { statistics.quality }
}

public struct BenchmarkIndex: Equatable, Codable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let value: Double
    public let baselineRunID: UUID
    public let baselineDate: Date
    /// 子测试相对基线 × 1000；噪声过大的子测试不进入这里。
    public let subtestIndices: [String: Double]
    /// 参与指数的子测试 CV 均方根，用作变化判定的噪声门槛。
    public let overallCV: Double

    public init(
        version: Int = BenchmarkIndex.currentVersion,
        value: Double,
        baselineRunID: UUID,
        baselineDate: Date,
        subtestIndices: [String: Double],
        overallCV: Double
    ) {
        self.version = version
        self.value = value
        self.baselineRunID = baselineRunID
        self.baselineDate = baselineDate
        self.subtestIndices = subtestIndices
        self.overallCV = overallCV
    }
}

public struct BenchmarkRun: Identifiable, Equatable, Codable, Sendable {
    public static let currentSuiteVersion = 1

    public let id: UUID
    public let generatedAt: Date
    public let suiteVersion: Int
    public let mode: BenchmarkMode
    public let environment: BenchmarkEnvironment
    public let measurements: [BenchmarkMeasurement]
    public let index: BenchmarkIndex?
    public let elapsedSeconds: Double

    public init(
        id: UUID = UUID(),
        generatedAt: Date = Date(),
        suiteVersion: Int = BenchmarkRun.currentSuiteVersion,
        mode: BenchmarkMode,
        environment: BenchmarkEnvironment,
        measurements: [BenchmarkMeasurement],
        index: BenchmarkIndex? = nil,
        elapsedSeconds: Double
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.suiteVersion = suiteVersion
        self.mode = mode
        self.environment = environment
        self.measurements = measurements
        self.index = index
        self.elapsedSeconds = elapsedSeconds
    }

    public func measurement(id: String) -> BenchmarkMeasurement? {
        measurements.first { $0.id == id }
    }

    public var coreMeasurements: [BenchmarkMeasurement] {
        measurements.filter { !$0.isDiagnostic }
    }

    public var diagnosticMeasurements: [BenchmarkMeasurement] {
        measurements.filter(\.isDiagnostic)
    }

    /// 与指数同一噪声口径：各核心子测试 CV 的均方根，
    /// 避免单项磁盘测试偏噪就把整轮结论压成「波动大」。
    public var overallQuality: BenchmarkQuality {
        guard !coreMeasurements.isEmpty else { return .stable }
        let cvs = coreMeasurements.map(\.statistics.coefficientOfVariation)
        let rms = (cvs.map { $0 * $0 }.reduce(0, +) / Double(cvs.count)).squareRoot()
        return BenchmarkQuality.from(coefficientOfVariation: rms)
    }
}

public enum BenchmarkVerdict: Equatable, Sendable {
    case faster(Double)
    case slower(Double)
    case withinNoise(Double)
    case unavailable
}

public struct BenchmarkProgress: Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case preparing
        case cpu
        case memory
        case disk
        case finished
    }

    public let phase: Phase
    public let completedSteps: Int
    public let totalSteps: Int
    public let currentTestID: String?
    public let fraction: Double
    public let elapsedSeconds: Double

    public init(
        phase: Phase,
        completedSteps: Int,
        totalSteps: Int,
        currentTestID: String? = nil,
        fraction: Double,
        elapsedSeconds: Double
    ) {
        self.phase = phase
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.currentTestID = currentTestID
        self.fraction = fraction
        self.elapsedSeconds = elapsedSeconds
    }

    public var estimatedRemainingSeconds: Double? {
        guard fraction > 0.05, fraction < 1, elapsedSeconds > 0 else { return nil }
        return elapsedSeconds / fraction * (1 - fraction)
    }
}

public enum BenchmarkError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case io(String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message), let .io(message):
            return message
        case let .insufficientDiskSpace(requiredBytes, availableBytes):
            let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            return "Disk space is too low for the disk test: \(available) available, \(required) required."
        }
    }
}
