import Foundation

/// 开跑前的环境检查。警告不阻止运行，只有空间不足这类硬条件才拦截。
public struct BenchmarkPreflight: Equatable, Sendable {
    public enum Status: String, Sendable {
        case ok
        case warning
        case blocked
    }

    public struct Check: Identifiable, Equatable, Sendable {
        public let id: String
        public let status: Status
        public let title: String
        public let detail: String

        public init(id: String, status: Status, title: String, detail: String) {
            self.id = id
            self.status = status
            self.title = title
            self.detail = detail
        }
    }

    public let environment: BenchmarkEnvironment
    public let checks: [Check]

    public var canRun: Bool {
        !checks.contains { $0.status == .blocked }
    }

    public var pendingWarnings: [Check] {
        checks.filter { $0.status == .warning }
    }
}

public enum BenchmarkPreflightChecker {
    public static func check(
        diskBytes: Int,
        environment: BenchmarkEnvironment? = nil
    ) async -> BenchmarkPreflight {
        let resolvedEnvironment: BenchmarkEnvironment
        if let environment {
            resolvedEnvironment = environment
        } else {
            resolvedEnvironment = await BenchmarkEnvironment.capture()
        }
        var checks: [BenchmarkPreflight.Check] = []
        let environment = resolvedEnvironment

        let requiredBytes = max(Int64(2 * 1024 * 1024 * 1024), Int64(diskBytes) * 2)
        let availableBytes = availableDiskBytes()
        if availableBytes <= 0 {
            checks.append(
                .init(
                    id: "disk",
                    status: .warning,
                    title: BenchmarkLocalization.string("Storage"),
                    detail: BenchmarkLocalization.string("Unable to read free disk space.")
                )
            )
        } else if availableBytes < requiredBytes {
            let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            checks.append(
                .init(
                    id: "disk",
                    status: .blocked,
                    title: BenchmarkLocalization.string("Storage"),
                    detail: String(
                        format: BenchmarkLocalization.string("At least %@ free space is required for the disk test."),
                        required
                    )
                )
            )
        } else {
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            checks.append(
                .init(
                    id: "disk",
                    status: .ok,
                    title: BenchmarkLocalization.string("Storage"),
                    detail: String(
                        format: BenchmarkLocalization.string("%@ available; the disk test uses a temporary file."),
                        available
                    )
                )
            )
        }

        switch environment.powerSource {
        case .adapter:
            checks.append(
                .init(
                    id: "power",
                    status: .ok,
                    title: BenchmarkLocalization.string("Power"),
                    detail: BenchmarkLocalization.string("Connected to power.")
                )
            )
        case .battery:
            checks.append(
                .init(
                    id: "power",
                    status: .warning,
                    title: BenchmarkLocalization.string("Power"),
                    detail: BenchmarkLocalization.string("Running on battery; connect power for a stable result.")
                )
            )
        case .unknown:
            break
        }

        checks.append(
            .init(
                id: "lowPower",
                status: environment.isLowPowerModeEnabled ? .warning : .ok,
                title: BenchmarkLocalization.string("Low Power Mode"),
                detail: environment.isLowPowerModeEnabled
                    ? BenchmarkLocalization.string("Low Power Mode is on; results may be lower.")
                    : BenchmarkLocalization.string("Low Power Mode is off.")
            )
        )

        switch environment.thermalState {
        case .nominal, .fair:
            checks.append(
                .init(
                    id: "thermal",
                    status: .ok,
                    title: BenchmarkLocalization.string("Thermal state"),
                    detail: BenchmarkLocalization.string("Thermal state is normal.")
                )
            )
        case .serious:
            checks.append(
                .init(
                    id: "thermal",
                    status: .warning,
                    title: BenchmarkLocalization.string("Thermal state"),
                    detail: BenchmarkLocalization.string("The Mac is warm; results may be throttled.")
                )
            )
        case .critical:
            checks.append(
                .init(
                    id: "thermal",
                    status: .blocked,
                    title: BenchmarkLocalization.string("Thermal state"),
                    detail: BenchmarkLocalization.string("The Mac is critically hot; let it cool down before testing.")
                )
            )
        case .unknown:
            break
        }

        let loadPercent = Int((environment.backgroundLoad * 100).rounded())
        if loadPercent >= 20 {
            checks.append(
                .init(
                    id: "background",
                    status: .warning,
                    title: BenchmarkLocalization.string("Background load"),
                    detail: String(
                        format: BenchmarkLocalization.string("Background CPU load is %d%%; close heavy apps for a cleaner result."),
                        loadPercent
                    )
                )
            )
        } else {
            checks.append(
                .init(
                    id: "background",
                    status: .ok,
                    title: BenchmarkLocalization.string("Background load"),
                    detail: BenchmarkLocalization.string("Background CPU load is low.")
                )
            )
        }

        return BenchmarkPreflight(environment: environment, checks: checks)
    }

    private static func availableDiskBytes() -> Int64 {
        let url = FileManager.default.temporaryDirectory
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
