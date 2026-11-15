import Darwin
import Foundation
import IOKit.ps

/// 结果的一部分：同一台机器在不同电源、热状态与后台负载下会给出不同分数。
///
/// 快照随结果一起保存，只有条件一致时才允许下「变快 / 变慢」的结论。
public struct BenchmarkEnvironment: Equatable, Codable, Sendable {
    public enum PowerSource: String, Codable, Sendable {
        case adapter
        case battery
        case unknown
    }

    public enum ThermalState: String, Codable, Sendable {
        case nominal
        case fair
        case serious
        case critical
        case unknown
    }

    public let chip: String
    public let processorCount: Int
    public let memoryBytes: UInt64
    public let macOSVersion: String
    public let powerSource: PowerSource
    public let isLowPowerModeEnabled: Bool
    public let thermalState: ThermalState
    /// 开测前 150 ms 的平均 CPU 占用，0...1。
    public let backgroundLoad: Double
    public let capturedAt: Date

    public init(
        chip: String,
        processorCount: Int,
        memoryBytes: UInt64,
        macOSVersion: String,
        powerSource: PowerSource,
        isLowPowerModeEnabled: Bool,
        thermalState: ThermalState,
        backgroundLoad: Double,
        capturedAt: Date = Date()
    ) {
        self.chip = chip
        self.processorCount = processorCount
        self.memoryBytes = memoryBytes
        self.macOSVersion = macOSVersion
        self.powerSource = powerSource
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
        self.backgroundLoad = backgroundLoad
        self.capturedAt = capturedAt
    }

    public static func capture(sampleBackgroundLoad: Bool = true) async -> BenchmarkEnvironment {
        let firstTicks = cpuLoadTicks()
        if sampleBackgroundLoad {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let secondTicks = cpuLoadTicks()

        let processInfo = ProcessInfo.processInfo
        let version = processInfo.operatingSystemVersion
        return BenchmarkEnvironment(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            processorCount: processInfo.activeProcessorCount,
            memoryBytes: processInfo.physicalMemory,
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            powerSource: currentPowerSource(),
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: thermalState(of: processInfo.thermalState),
            backgroundLoad: backgroundLoad(from: firstTicks, to: secondTicks)
        )
    }

    /// 条件可比性只看会影响分数的维度；日期与后台负载作为上下文保留。
    public func isComparable(to other: BenchmarkEnvironment) -> Bool {
        chip == other.chip
            && powerSource == other.powerSource
            && isLowPowerModeEnabled == other.isLowPowerModeEnabled
            && thermalState == other.thermalState
            && macOSVersion == other.macOSVersion
    }

    private static func thermalState(of state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }

    private static func currentPowerSource() -> PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else {
            return .unknown
        }
        switch type {
        case "AC Power": return .adapter
        case "Battery Power": return .battery
        default: return .unknown
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        let bytes = buffer[..<end].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private typealias CPUTicks = (busy: UInt64, total: UInt64)

    private static func cpuLoadTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)
        return (busy, busy + UInt64(ticks.2))
    }

    private static func backgroundLoad(from first: CPUTicks?, to second: CPUTicks?) -> Double {
        guard let first, let second,
              second.total > first.total,
              second.busy >= first.busy
        else {
            return 0
        }
        let busy = Double(second.busy - first.busy)
        let total = Double(second.total - first.total)
        guard total > 0 else { return 0 }
        return min(max(busy / total, 0), 1)
    }
}
