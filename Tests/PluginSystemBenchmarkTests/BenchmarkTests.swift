import Foundation
import KernelCore
import ProviderActivityBar
import ProviderContentView
import SwiftUI
import Testing
@testable import PluginSystemBenchmark

@Suite("PluginSystemBenchmark")
@MainActor
struct BenchmarkTests {
    @Test("plugin registers an Activity Bar entry and shared dashboard content")
    func pluginRegistersActivityBarEntry() throws {
        @MainActor final class TrackingContentView: ContentViewProviding {
            private(set) var setCount = 0

            func setContentView(_ view: AnyView?) {
                if view != nil {
                    setCount += 1
                }
            }

            func makeContentView() -> AnyView {
                AnyView(EmptyView())
            }
        }

        let kernel = KernelCoreContainer()
        let activityBar = DefaultActivityBarProviding()
        let contentView = TrackingContentView()
        activityBar.registerItems([
            ActivityBarItem(id: "other", title: "Other", systemImage: "circle"),
        ])
        try kernel.registerProvider((any ActivityBarProviding).self, activityBar)
        try kernel.registerProvider((any ContentViewProviding).self, contentView)

        let plugin = SystemBenchmarkPlugin()
        try plugin.onBoot(kernel: kernel)

        // 测速功能只通过 Activity Bar 暴露入口，不再注册设置项。
        let entry = activityBar.items.first { $0.id == "\(plugin.id).entry" }
        #expect(entry != nil)
        #expect(entry?.ownerPluginID == plugin.id)

        activityBar.activateItem(id: "\(plugin.id).entry")
        #expect(contentView.setCount == 1)
    }

    @Test("disable retracts the entry and enable restores it")
    func lifecycleTogglesEntryAndContent() async throws {
        @MainActor final class TrackingContentView: ContentViewProviding {
            var lastViewIsNil: Bool?

            func setContentView(_ view: AnyView?) {
                lastViewIsNil = view == nil
            }

            func makeContentView() -> AnyView {
                AnyView(EmptyView())
            }
        }

        let kernel = KernelCoreContainer()
        let activityBar = DefaultActivityBarProviding()
        let contentView = TrackingContentView()
        activityBar.registerItems([
            ActivityBarItem(id: "other", title: "Other", systemImage: "circle"),
        ])
        try kernel.registerProvider((any ActivityBarProviding).self, activityBar)
        try kernel.registerProvider((any ContentViewProviding).self, contentView)

        let plugin = SystemBenchmarkPlugin()
        try plugin.onBoot(kernel: kernel)
        let entryID = "\(plugin.id).entry"
        #expect(activityBar.items.contains { $0.id == entryID })

        try await plugin.onDisable(kernel: kernel)
        #expect(!activityBar.items.contains { $0.id == entryID })
        // 入口栏仍由另一个入口支撑，内容仍归入口栏管理，不应被清空。
        #expect(contentView.lastViewIsNil == nil)

        try await plugin.onEnable(kernel: kernel)
        #expect(activityBar.items.contains { $0.id == entryID })
    }
}

@Suite("BenchmarkStatistics")
struct StatisticsTests {
    @Test("median and spread use the measured samples")
    func medianAndSpread() {
        let statistics = BenchmarkStatistics(samples: [100, 102, 98, 101, 99])

        #expect(statistics.median == 100)
        #expect(statistics.mean == 100)
        #expect(statistics.sampleCount == 5)
        #expect(statistics.outlierCount == 0)
        #expect(statistics.coefficientOfVariation < 0.03)
        #expect(statistics.quality == .stable)
    }

    @Test("outliers are removed when the sample set is large enough")
    func outlierRemoval() {
        let statistics = BenchmarkStatistics(samples: [100, 100, 100, 100, 1000])

        #expect(statistics.outlierCount == 1)
        #expect(statistics.sampleCount == 4)
        #expect(statistics.median == 100)
    }

    @Test("confidence interval is deterministic and contains the median")
    func deterministicConfidenceInterval() {
        let samples = [100.0, 104.0, 99.0, 101.0, 97.0, 103.0]
        let first = BenchmarkStatistics(samples: samples)
        let second = BenchmarkStatistics(samples: samples)

        #expect(first.lowerBound == second.lowerBound)
        #expect(first.upperBound == second.upperBound)
        #expect(first.lowerBound <= first.median)
        #expect(first.median <= first.upperBound)
    }

    @Test("quality follows the coefficient of variation")
    func qualityBands() {
        #expect(BenchmarkStatistics(samples: [100, 100.5]).quality == .stable)
        #expect(BenchmarkStatistics(samples: [100, 105]).quality == .fair)
        #expect(BenchmarkStatistics(samples: [100, 130]).quality == .noisy)
        #expect(BenchmarkStatistics(samples: [100]).quality == .noisy)
    }

    @Test("overall quality averages noise instead of taking the worst subtest")
    func overallQualityUsesRMS() {
        let stable = makeRun(date: Date(), samples: [100, 100.5, 100.2])
        #expect(stable.overallQuality == .stable)

        let mixed = BenchmarkRun(
            generatedAt: Date(),
            mode: .quick,
            environment: testEnvironment(),
            measurements: BenchmarkIndexCalculator.coreTestIDs.map { id in
                makeMeasurement(
                    id: id,
                    kind: id.hasPrefix("cpu.") ? .cpu : (id.hasPrefix("memory.") ? .memory : .disk),
                    value: 100,
                    samples: id == "disk.write" ? [100, 130] : [100, 100.5, 100.2]
                )
            },
            elapsedSeconds: 5
        )

        #expect(mixed.measurement(id: "disk.write")?.quality == .noisy)
        #expect(mixed.overallQuality == .fair)
    }
}

@Suite("BenchmarkIndex")
struct IndexTests {
    @Test("first qualified run becomes a self baseline at 1000")
    func selfBaseline() {
        let run = makeRun(date: Date(timeIntervalSince1970: 1_700_000_000))
        let indexed = BenchmarkIndexCalculator.attachingIndex(to: run, history: [])

        #expect(indexed.index?.value == 1000)
        #expect(indexed.index?.baselineRunID == run.id)
        #expect(indexed.index?.subtestIndices.count == 6)
    }

    @Test("later runs are compared with the first qualified baseline")
    func relativeIndex() throws {
        let baseline = makeRun(date: Date(timeIntervalSince1970: 1_700_000_000))
        let faster = makeRun(
            date: Date(timeIntervalSince1970: 1_700_001_000),
            adjustments: Dictionary(uniqueKeysWithValues: BenchmarkIndexCalculator.coreTestIDs.map { ($0, 1.1) })
        )

        let indexed = BenchmarkIndexCalculator.attachingIndex(to: faster, history: [baseline])
        let index = try #require(indexed.index)

        #expect(abs(index.value - 1100) < 0.1)
        #expect(index.baselineRunID == baseline.id)
        #expect(abs(index.overallCV) < 0.02)
    }

    @Test("runs with noisy subtest samples are not eligible baselines")
    func noisyRunIsNotBaseline() {
        let noisy = makeRun(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            samples: [900, 1400]
        )
        #expect(!BenchmarkIndexCalculator.isEligibleBaseline(noisy))
    }

    @Test("verdict requires the change to exceed measurement noise")
    func verdictNoiseGate() {
        let current = BenchmarkIndex(
            value: 1030,
            baselineRunID: UUID(),
            baselineDate: Date(),
            subtestIndices: [:],
            overallCV: 0.01
        )
        let baseline = BenchmarkIndex(
            value: 1000,
            baselineRunID: UUID(),
            baselineDate: Date(),
            subtestIndices: [:],
            overallCV: 0.01
        )

        #expect(BenchmarkIndexCalculator.verdict(current: current, previous: baseline) == .faster(0.03))

        let slightlyFaster = BenchmarkIndex(
            value: 1010,
            baselineRunID: UUID(),
            baselineDate: Date(),
            subtestIndices: [:],
            overallCV: 0.01
        )
        guard case .withinNoise = BenchmarkIndexCalculator.verdict(current: slightlyFaster, previous: baseline) else {
            Issue.record("A 1% change should stay inside the noise band")
            return
        }
    }
}

@Suite("BenchmarkHistoryStore")
struct HistoryStoreTests {
    @Test("history round-trips and keeps only the newest runs")
    func roundTripAndLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmark-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BenchmarkHistoryStore(
            fileURL: directory.appendingPathComponent("history.json"),
            limit: 2
        )

        let runs = (0..<3).map { offset in
            makeRun(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset)))
        }
        for run in runs {
            try await store.append(run)
        }

        let loaded = await store.load()
        #expect(loaded.count == 2)
        #expect(loaded.map(\.id) == [runs[2].id, runs[1].id])
        #expect(loaded[0] == runs[2])

        try await store.clear()
        #expect(await store.load().isEmpty)
    }
}

@Suite("BenchmarkPreflight")
struct PreflightTests {
    @Test("battery, low power, heat, and background load surface as warnings")
    func warningsDoNotBlock() async {
        let environment = BenchmarkEnvironment(
            chip: "Test Chip",
            processorCount: 8,
            memoryBytes: 16 * 1024 * 1024 * 1024,
            macOSVersion: "14.0",
            powerSource: .battery,
            isLowPowerModeEnabled: true,
            thermalState: .serious,
            backgroundLoad: 0.35
        )

        let preflight = await BenchmarkPreflightChecker.check(diskBytes: 1024 * 1024, environment: environment)

        #expect(preflight.canRun)
        #expect(preflight.checks.contains { $0.id == "power" && $0.status == .warning })
        #expect(preflight.checks.contains { $0.id == "lowPower" && $0.status == .warning })
        #expect(preflight.checks.contains { $0.id == "thermal" && $0.status == .warning })
        #expect(preflight.checks.contains { $0.id == "background" && $0.status == .warning })
    }

    @Test("critical thermal state blocks the run")
    func criticalThermalBlocks() async {
        let environment = BenchmarkEnvironment(
            chip: "Test Chip",
            processorCount: 8,
            memoryBytes: 16 * 1024 * 1024 * 1024,
            macOSVersion: "14.0",
            powerSource: .adapter,
            isLowPowerModeEnabled: false,
            thermalState: .critical,
            backgroundLoad: 0.0
        )

        let preflight = await BenchmarkPreflightChecker.check(diskBytes: 1024 * 1024, environment: environment)

        #expect(!preflight.canRun)
        #expect(preflight.checks.contains { $0.id == "thermal" && $0.status == .blocked })
    }
}

@Suite("SystemBenchmarkRunner")
struct RunnerTests {
    @Test("small configuration runs every quick-mode subtest")
    func smallBenchmarkRuns() async throws {
        let runner = SystemBenchmarkRunner(
            configuration: .init(
                cpuIterations: 50_000,
                warmupRounds: 0,
                repeats: 1,
                memoryBufferBytes: 64 * 1024,
                memoryPasses: 1,
                diskBytes: 128 * 1024,
                diskChunkBytes: 16 * 1024,
                randomMemoryBytes: 32 * 1024,
                randomMemoryOperations: 1_000,
                randomDiskOperations: 64,
                diskQueueDepth: 4
            )
        )

        let recorder = ProgressRecorder()
        let run = try await runner.run(mode: .quick) { progress in
            await recorder.record(progress)
        }

        let ids = Set(run.measurements.map(\.id))
        #expect(ids == [
            "cpu.single", "cpu.multi",
            "memory.write", "memory.copy", "memory.read",
            "disk.write", "disk.read",
        ])
        #expect(run.measurements.allSatisfy { $0.value > 0 })
        #expect(run.measurements.allSatisfy { $0.statistics.sampleCount == 1 })
        #expect(run.measurements.allSatisfy { !$0.isDiagnostic })
        #expect(run.mode == .quick)
        #expect(run.environment.processorCount > 0)

        let events = await recorder.events
        #expect(events.first?.phase == .preparing)
        #expect(events.last?.phase == .finished)
        #expect(events.last?.fraction == 1)
    }

    @Test("deep mode adds diagnostics on top of the core subtests")
    func deepModeDiagnostics() async throws {
        let runner = SystemBenchmarkRunner(
            configuration: .init(
                cpuIterations: 30_000,
                warmupRounds: 0,
                repeats: 1,
                memoryBufferBytes: 64 * 1024,
                memoryPasses: 1,
                diskBytes: 128 * 1024,
                diskChunkBytes: 16 * 1024,
                randomMemoryBytes: 32 * 1024,
                randomMemoryOperations: 500,
                randomDiskOperations: 32,
                diskQueueDepth: 4
            )
        )

        let run = try await runner.run(mode: .deep)
        let ids = Set(run.measurements.map(\.id))

        #expect(ids.isSuperset(of: ["cpu.fp", "memory.random", "disk.random.qd1", "disk.random.qd4"]))
        #expect(ids.contains { $0.hasPrefix("cpu.scaling.") })
        #expect(run.measurements.allSatisfy { $0.value > 0 })
        #expect(run.diagnosticMeasurements.allSatisfy { $0.isDiagnostic })
        #expect(run.coreMeasurements.allSatisfy { !$0.isDiagnostic })
        #expect(run.coreMeasurements.count == 7)
        #expect(run.mode == .deep)
    }

    @Test("invalid configuration is rejected")
    func invalidConfiguration() async {
        let runner = SystemBenchmarkRunner(configuration: .init(cpuIterations: 0))

        await #expect(throws: BenchmarkError.self) {
            try await runner.run()
        }
    }
}

@Suite("SystemBenchmarkViewModel")
@MainActor
struct ViewModelTests {
    @Test("用户主动取消显示中性的已取消状态，而不是失败")
    func cancellingReportsNeutralState() async throws {
        let viewModel = makeViewModel(runner: EndlessBenchmarkRunner())
        viewModel.start()
        try await waitUntil { viewModel.progress?.phase == .cpu }

        viewModel.cancel()
        try await waitUntil { !viewModel.isRunning }

        #expect(viewModel.cancellationMessage != nil)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.latestRun == nil)
    }

    @Test("真实测试错误仍显示为失败")
    func failureStillReportsError() async throws {
        let viewModel = makeViewModel(runner: FailingBenchmarkRunner())
        viewModel.start()
        try await waitUntil { !viewModel.isRunning }

        #expect(viewModel.errorMessage == "benchmark exploded")
        #expect(viewModel.cancellationMessage == nil)
        #expect(viewModel.latestRun == nil)
    }

    @Test("a completed run gets an index and is persisted")
    func successPersistsIndexedRun() async throws {
        let run = makeRun(date: Date())
        let viewModel = makeViewModel(runner: FixedBenchmarkRunner(run: run))

        viewModel.start()
        try await waitUntil { !viewModel.isRunning }

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.latestRun?.id == run.id)
        #expect(viewModel.latestRun?.index?.value == 1000)
        #expect(viewModel.history.count == 1)
        #expect(viewModel.indexedHistory.count == 1)

        let exportedJSON = try viewModel.exportJSON()
        #expect(exportedJSON.content.contains("\"suiteVersion\""))
        #expect(exportedJSON.content.contains(run.id.uuidString))

        let exportedMarkdown = try viewModel.exportMarkdown()
        #expect(exportedMarkdown.content.contains("# "))
        #expect(exportedMarkdown.content.contains("1000"))
    }

    @Test("a blocked preflight prevents the run")
    func blockedPreflight() async throws {
        let viewModel = makeViewModel(
            runner: FixedBenchmarkRunner(run: makeRun(date: Date())),
            preflight: .init(
                environment: testEnvironment(thermalState: .critical),
                checks: [
                    .init(id: "thermal", status: .blocked, title: "Thermal", detail: "Too hot")
                ]
            )
        )

        viewModel.start()
        try await waitUntil { !viewModel.isRunning }

        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.latestRun == nil)
    }
}

// MARK: - Fixtures

private let testCoreValues: [String: Double] = {
    Dictionary(uniqueKeysWithValues: BenchmarkIndexCalculator.coreTestIDs.map { ($0, 1000) })
}()

private func testEnvironment(
    powerSource: BenchmarkEnvironment.PowerSource = .adapter,
    thermalState: BenchmarkEnvironment.ThermalState = .nominal
) -> BenchmarkEnvironment {
    BenchmarkEnvironment(
        chip: "Test Chip",
        processorCount: 8,
        memoryBytes: 16 * 1024 * 1024 * 1024,
        macOSVersion: "14.0",
        powerSource: powerSource,
        isLowPowerModeEnabled: false,
        thermalState: thermalState,
        backgroundLoad: 0.01,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func makeMeasurement(
    id: String,
    kind: BenchmarkKind,
    value: Double,
    samples: [Double]? = nil,
    isDiagnostic: Bool = false
) -> BenchmarkMeasurement {
    BenchmarkMeasurement(
        id: id,
        kind: kind,
        label: id,
        unit: "ops/s",
        statistics: BenchmarkStatistics(samples: samples ?? [value * 0.99, value, value * 1.01]),
        durationMilliseconds: 10,
        detail: id,
        isDiagnostic: isDiagnostic
    )
}

private func makeRun(
    date: Date,
    adjustments: [String: Double] = [:],
    samples: [Double]? = nil
) -> BenchmarkRun {
    let measurements = BenchmarkIndexCalculator.coreTestIDs.map { id in
        makeMeasurement(
            id: id,
            kind: id.hasPrefix("cpu.") ? .cpu : (id.hasPrefix("memory.") ? .memory : .disk),
            value: (testCoreValues[id] ?? 1000) * (adjustments[id] ?? 1),
            samples: samples
        )
    }
    return BenchmarkRun(
        generatedAt: date,
        mode: .quick,
        environment: testEnvironment(),
        measurements: measurements,
        elapsedSeconds: 12
    )
}

@MainActor
private func makeViewModel(
    runner: any SystemBenchmarkRunning,
    preflight: BenchmarkPreflight? = nil
) -> SystemBenchmarkViewModel {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("benchmark-vm-\(UUID().uuidString)", isDirectory: true)
    let store = BenchmarkHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
    let resolvedPreflight = preflight ?? BenchmarkPreflight(
        environment: testEnvironment(),
        checks: [.init(id: "thermal", status: .ok, title: "Thermal", detail: "Fine")]
    )
    return SystemBenchmarkViewModel(
        runner: runner,
        store: store,
        preflightProvider: { resolvedPreflight }
    )
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<600 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition(), "condition not met before timeout")
}

private actor ProgressRecorder {
    private(set) var events: [BenchmarkProgress] = []

    func record(_ event: BenchmarkProgress) {
        events.append(event)
    }
}

/// 跑到 CPU 阶段后一直挂起，直到任务被取消。
private actor EndlessBenchmarkRunner: SystemBenchmarkRunning {
    func run(
        mode: BenchmarkMode,
        progress: @escaping @Sendable (BenchmarkProgress) async -> Void
    ) async throws -> BenchmarkRun {
        await progress(
            BenchmarkProgress(
                phase: .cpu,
                completedSteps: 0,
                totalSteps: 7,
                currentTestID: "cpu.single",
                fraction: 0.1,
                elapsedSeconds: 1
            )
        )
        while true {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct FixedBenchmarkRunner: SystemBenchmarkRunning {
    let run: BenchmarkRun

    func run(
        mode: BenchmarkMode,
        progress: @escaping @Sendable (BenchmarkProgress) async -> Void
    ) async throws -> BenchmarkRun {
        await progress(
            BenchmarkProgress(
                phase: .preparing,
                completedSteps: 0,
                totalSteps: 7,
                fraction: 0,
                elapsedSeconds: 0
            )
        )
        return run
    }
}

private struct FailingBenchmarkRunner: SystemBenchmarkRunning {
    struct Failure: LocalizedError {
        var errorDescription: String? { "benchmark exploded" }
    }

    func run(
        mode: BenchmarkMode,
        progress: @escaping @Sendable (BenchmarkProgress) async -> Void
    ) async throws -> BenchmarkRun {
        throw Failure()
    }
}
