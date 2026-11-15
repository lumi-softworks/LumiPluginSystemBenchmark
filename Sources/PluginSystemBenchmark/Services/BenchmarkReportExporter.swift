import Foundation

/// 结果导出。所有格式都在本地生成，不经过网络。
public enum BenchmarkReportExporter {
    public static func json(run: BenchmarkRun) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(run)
        return String(decoding: data, as: UTF8.self)
    }

    public static func markdown(
        run: BenchmarkRun,
        history: [BenchmarkRun],
        locale: Locale = .current
    ) -> String {
        func string(_ key: String) -> String {
            BenchmarkLocalization.string(key, locale: locale)
        }

        var lines: [String] = []
        lines.append("# \(string("System Benchmark"))")
        lines.append("")
        lines.append("- \(string("Date")): \(ISO8601DateFormatter().string(from: run.generatedAt))")
        lines.append("- \(string("Mode")): \(run.mode == .deep ? string("Deep test") : string("Quick test"))")
        lines.append("- Suite v\(run.suiteVersion)")
        if let index = run.index {
            lines.append("- \(string("Performance Index")) v\(index.version): **\(format(index.value, decimals: 1))**")
        } else {
            lines.append("- \(string("Performance Index")): \(string("Baseline not established"))")
        }
        lines.append("")

        lines.append("## \(string("Environment"))")
        lines.append("")
        lines.append("| \(string("Item")) | \(string("Value")) |")
        lines.append("| --- | --- |")
        lines.append("| \(string("Chip")) | \(run.environment.chip) |")
        lines.append("| \(string("Cores")) | \(run.environment.processorCount) |")
        lines.append("| \(string("Memory")) | \(formatBytes(run.environment.memoryBytes)) |")
        lines.append("| macOS | \(run.environment.macOSVersion) |")
        lines.append("| \(string("Power")) | \(powerText(run.environment.powerSource, string: string)) |")
        lines.append("| \(string("Thermal state")) | \(thermalText(run.environment.thermalState, string: string)) |")
        lines.append("| \(string("Background load")) | \(String(format: "%.0f%%", run.environment.backgroundLoad * 100)) |")
        lines.append("")

        lines.append("## \(string("Results"))")
        lines.append("")
        lines.append(
            "| \(string("Test")) | \(string("Median")) | \(string("95% CI")) | CV | \(string("Relative")) |"
        )
        lines.append("| --- | --- | --- | --- | --- |")
        for measurement in run.coreMeasurements {
            let ci = "\(format(measurement.statistics.lowerBound, decimals: 1))–\(format(measurement.statistics.upperBound, decimals: 1))"
            let relative: String
            if let value = run.index?.subtestIndices[measurement.id] {
                relative = format((value - 1000) / 10, decimals: 1) + "%"
            } else {
                relative = "—"
            }
            lines.append(
                "| \(string(measurement.label)) | \(format(measurement.value, decimals: 1)) \(measurement.unit) | \(ci) | \(String(format: "%.1f%%", measurement.statistics.coefficientOfVariation * 100)) | \(relative) |"
            )
        }

        if !run.diagnosticMeasurements.isEmpty {
            lines.append("")
            lines.append("## \(string("Diagnostics"))")
            lines.append("")
            for measurement in run.diagnosticMeasurements {
                lines.append(
                    "- \(string(measurement.label)): \(format(measurement.value, decimals: 1)) \(measurement.unit)"
                )
            }
        }

        lines.append("")
        lines.append("## \(string("Method"))")
        lines.append("")
        lines.append(
            string("Warmup is discarded, the median of the measured rounds is reported, and the 95% confidence interval comes from bootstrap resampling. The index is the geometric mean of each subtest relative to the first qualified local run.")
        )
        lines.append("")
        lines.append(string("Tests ran locally; no data was uploaded."))

        if history.count > 1, run.index != nil {
            lines.append("")
            lines.append("## \(string("History"))")
            lines.append("")
            lines.append("| \(string("Date")) | \(string("Performance Index")) |")
            lines.append("| --- | --- |")
            for item in history.prefix(8) {
                if let value = item.index?.value {
                    lines.append("| \(ISO8601DateFormatter().string(from: item.generatedAt)) | \(format(value, decimals: 1)) |")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func powerText(
        _ source: BenchmarkEnvironment.PowerSource,
        string: (String) -> String
    ) -> String {
        switch source {
        case .adapter: return string("Power adapter")
        case .battery: return string("Battery")
        case .unknown: return "—"
        }
    }

    private static func thermalText(
        _ state: BenchmarkEnvironment.ThermalState,
        string: (String) -> String
    ) -> String {
        switch state {
        case .nominal: return string("Normal")
        case .fair: return string("Fair")
        case .serious: return string("Serious")
        case .critical: return string("Critical")
        case .unknown: return "—"
        }
    }

    private static func format(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
