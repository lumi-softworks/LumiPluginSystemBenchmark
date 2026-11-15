import Foundation

/// 一组原始样本的统计摘要。
///
/// 中位数是主值：单轮读数受缓存、调度和后台负载影响，直接展示会误导。
/// 置信区间用确定种子的 bootstrap 求中位数区间，同一样本集每次算出的结果一致，
/// 便于测试与历史对比。
public struct BenchmarkStatistics: Codable, Equatable, Sendable {
    public let samples: [Double]
    public let median: Double
    public let mean: Double
    public let standardDeviation: Double
    public let coefficientOfVariation: Double
    public let lowerBound: Double
    public let upperBound: Double
    public let outlierCount: Int

    public var sampleCount: Int { samples.count }

    public init(samples rawSamples: [Double]) {
        let finite = rawSamples.filter { $0.isFinite && $0 >= 0 }
        guard !finite.isEmpty else {
            samples = []
            median = 0
            mean = 0
            standardDeviation = 0
            coefficientOfVariation = 0
            lowerBound = 0
            upperBound = 0
            outlierCount = 0
            return
        }

        let sorted = finite.sorted()
        var kept = sorted
        var outliers = 0
        // 样本太少时 IQR 围栏不可靠，只统计不剔除。
        if sorted.count >= 5 {
            let q1 = Self.percentile(sorted, 0.25)
            let q3 = Self.percentile(sorted, 0.75)
            let iqr = q3 - q1
            let low = q1 - 1.5 * iqr
            let high = q3 + 1.5 * iqr
            let filtered = sorted.filter { $0 >= low && $0 <= high }
            outliers = sorted.count - filtered.count
            if filtered.count >= 3 {
                kept = filtered
            }
        }

        let medianValue = Self.percentile(kept, 0.5)
        let meanValue = kept.reduce(0, +) / Double(kept.count)
        let variance: Double
        if kept.count > 1 {
            variance = kept.reduce(0) { $0 + pow($1 - meanValue, 2) } / Double(kept.count - 1)
        } else {
            variance = 0
        }
        let deviation = sqrt(variance)
        let bounds = Self.medianConfidenceInterval(kept)

        samples = kept
        median = medianValue
        mean = meanValue
        standardDeviation = deviation
        coefficientOfVariation = meanValue > 0 ? deviation / meanValue : 0
        lowerBound = bounds.lower
        upperBound = bounds.upper
        outlierCount = outliers
    }

    public var quality: BenchmarkQuality {
        guard samples.count >= 2 else { return .noisy }
        return BenchmarkQuality.from(coefficientOfVariation: coefficientOfVariation)
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    private static func medianConfidenceInterval(_ values: [Double]) -> (lower: Double, upper: Double) {
        guard values.count > 1 else {
            let value = values.first ?? 0
            return (value, value)
        }

        var generator = SplitMix64(seed: 0x9E37_79B9_7F4A_7C15)
        var resampledMedians: [Double] = []
        resampledMedians.reserveCapacity(1_000)
        var bucket = [Double](repeating: 0, count: values.count)

        for _ in 0..<1_000 {
            for index in bucket.indices {
                let draw = Int(generator.next() % UInt64(values.count))
                bucket[index] = values[draw]
            }
            resampledMedians.append(percentile(bucket, 0.5))
        }

        resampledMedians.sort()
        return (
            percentile(resampledMedians, 0.025),
            percentile(resampledMedians, 0.975)
        )
    }
}

/// 确定性 PRNG，保证 bootstrap 结果可复现。
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
