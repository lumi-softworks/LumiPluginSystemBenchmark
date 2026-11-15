import Foundation

/// 自基线指数：把六项核心子测试换算成「相对基线 × 1000」，再取几何平均。
///
/// 单机自基线只回答「这台机器和自己比」，不伪造跨设备百分位。
public enum BenchmarkIndexCalculator {
    /// 进入指数口径的六项核心子测试。增删这里必须同时升级 `BenchmarkIndex.currentVersion`。
    public static let coreTestIDs = [
        "cpu.single",
        "cpu.multi",
        "memory.copy",
        "memory.read",
        "disk.read",
        "disk.write",
    ]

    /// 首次合格运行才可作为基线：六项齐全，且每项至少采样三轮。
    ///
    /// 不因 CV 偏高否定整次运行：波动会通过 `verdict` 的噪声门槛体现，
    /// 直接丢弃基线会让首次运行永远看不到指数。
    public static func isEligibleBaseline(_ run: BenchmarkRun) -> Bool {
        let core = coreTestIDs.compactMap { run.measurement(id: $0) }
        guard core.count == coreTestIDs.count else { return false }
        return core.allSatisfy { $0.statistics.sampleCount >= 3 }
    }

    public static func baseline(for run: BenchmarkRun, in history: [BenchmarkRun]) -> BenchmarkRun? {
        ([run] + history)
            .filter { $0.suiteVersion == run.suiteVersion && isEligibleBaseline($0) }
            .min { $0.generatedAt < $1.generatedAt }
    }

    public static func attachingIndex(to run: BenchmarkRun, history: [BenchmarkRun]) -> BenchmarkRun {
        guard let baseline = baseline(for: run, in: history) else {
            return run
        }

        let isSelfBaseline = baseline.id == run.id
        var indices: [String: Double] = [:]
        var cvs: [Double] = []

        for testID in coreTestIDs {
            guard let current = run.measurement(id: testID),
                  let reference = baseline.measurement(id: testID),
                  reference.statistics.median > 0
            else {
                continue
            }
            let index = isSelfBaseline
                ? 1000
                : current.statistics.median / reference.statistics.median * 1000
            indices[testID] = index
            cvs.append(current.statistics.coefficientOfVariation)
        }

        // 少于四项时不硬凑分数，界面上只展示原始读数。
        guard indices.count >= 4 else { return run }

        let geometricMean = exp(
            indices.values.map { log($0) }.reduce(0, +) / Double(indices.count)
        )
        let rounded = (geometricMean * 10).rounded() / 10
        let overallCV = sqrt(cvs.map { $0 * $0 }.reduce(0, +) / Double(cvs.count))

        let index = BenchmarkIndex(
            value: rounded,
            baselineRunID: baseline.id,
            baselineDate: baseline.generatedAt,
            subtestIndices: indices,
            overallCV: overallCV
        )
        return BenchmarkRun(
            id: run.id,
            generatedAt: run.generatedAt,
            suiteVersion: run.suiteVersion,
            mode: run.mode,
            environment: run.environment,
            measurements: run.measurements,
            index: index,
            elapsedSeconds: run.elapsedSeconds
        )
    }

    /// 只有差值超过噪声门槛才给「变快 / 变慢」的结论。
    public static func verdict(current: BenchmarkIndex, previous: BenchmarkIndex) -> BenchmarkVerdict {
        guard previous.value > 0 else { return .unavailable }
        let delta = (current.value - previous.value) / previous.value
        let noise = max(0.02, 2 * max(current.overallCV, previous.overallCV))
        if abs(delta) <= noise { return .withinNoise(delta) }
        return delta > 0 ? .faster(delta) : .slower(delta)
    }
}
