import Foundation
import SwiftUI

/// 跑一轮基准测试的最小契约。
///
/// 抽出协议是为了让 ViewModel 的取消 / 失败状态可以注入替身验证，
/// 而不必真的跑一遍 CPU / 内存 / 磁盘负载。
protocol SystemBenchmarkRunning: Sendable {
    func run(
        mode: BenchmarkMode,
        progress: @escaping @Sendable (BenchmarkProgress) async -> Void
    ) async throws -> BenchmarkRun
}

extension SystemBenchmarkRunner: SystemBenchmarkRunning {}

@MainActor
public final class SystemBenchmarkViewModel: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var isCheckingPreflight = false
    @Published public var mode: BenchmarkMode = .quick
    @Published public private(set) var progress: BenchmarkProgress?
    @Published public private(set) var latestRun: BenchmarkRun?
    @Published public private(set) var history: [BenchmarkRun] = []
    @Published public private(set) var preflight: BenchmarkPreflight?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var exportMessage: String?
    @Published public private(set) var exportError: String?

    /// 用户主动取消后的中性提示；与 `errorMessage` 互斥。
    ///
    /// 取消是用户行为，不是失败。混进错误横幅会让用户以为自己把测试跑挂了，
    /// 也会掩盖真正需要关注的失败信息。
    @Published public private(set) var cancellationMessage: String?

    private let runner: any SystemBenchmarkRunning
    private let store: BenchmarkHistoryStore
    private let preflightProvider: @Sendable () async -> BenchmarkPreflight
    private var task: Task<Void, Never>?

    public init() {
        self.runner = SystemBenchmarkRunner()
        self.store = BenchmarkHistoryStore()
        self.preflightProvider = { await BenchmarkPreflightChecker.check(diskBytes: 1024 * 1024 * 1024) }
        loadInitialState()
    }

    init(
        runner: any SystemBenchmarkRunning,
        store: BenchmarkHistoryStore = BenchmarkHistoryStore(),
        preflightProvider: (@Sendable () async -> BenchmarkPreflight)? = nil
    ) {
        self.runner = runner
        self.store = store
        self.preflightProvider = preflightProvider
            ?? { await BenchmarkPreflightChecker.check(diskBytes: 1024 * 1024 * 1024) }
        loadInitialState()
    }

    // MARK: - Derived state

    public var previousIndexedRun: BenchmarkRun? {
        guard let latestRun else { return nil }
        return history.first { $0.id != latestRun.id && $0.index != nil }
    }

    /// 只有环境可比、且差值超过噪声门槛时，才有「变快 / 变慢」的结论。
    public var comparisonVerdict: BenchmarkVerdict? {
        guard let latestRun, let current = latestRun.index else { return nil }
        guard let previousRun = previousIndexedRun, let previous = previousRun.index else { return nil }
        guard previousRun.environment.isComparable(to: latestRun.environment) else {
            return .unavailable
        }
        return BenchmarkIndexCalculator.verdict(current: current, previous: previous)
    }

    public var indexedHistory: [BenchmarkRun] {
        history
            .filter { $0.index != nil }
            .sorted { $0.generatedAt < $1.generatedAt }
    }

    public func subtestIndex(for measurementID: String) -> Double? {
        latestRun?.index?.subtestIndices[measurementID]
    }

    // MARK: - Actions

    public func refreshPreflight() async {
        guard !isRunning, !isCheckingPreflight else { return }
        isCheckingPreflight = true
        preflight = await preflightProvider()
        isCheckingPreflight = false
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        cancellationMessage = nil
        exportMessage = nil
        exportError = nil
        progress = BenchmarkProgress(
            phase: .preparing,
            completedSteps: 0,
            totalSteps: mode.isDeep ? 12 : 7,
            fraction: 0,
            elapsedSeconds: 0
        )
        let selectedMode = mode

        task = Task { [weak self] in
            guard let self else { return }

            let preflight = await preflightProvider()
            self.preflight = preflight
            guard preflight.canRun else {
                self.errorMessage = BenchmarkLocalization.string(
                    "The benchmark cannot start until the blocking checks pass."
                )
                self.isRunning = false
                self.progress = nil
                self.task = nil
                return
            }

            do {
                let run = try await runner.run(mode: selectedMode) { [weak self] nextProgress in
                    await MainActor.run {
                        self?.progress = nextProgress
                    }
                }
                let previousHistory = await store.load()
                let indexed = BenchmarkIndexCalculator.attachingIndex(to: run, history: previousHistory)
                let updated = try await store.append(indexed)
                history = updated
                latestRun = indexed
            } catch is CancellationError {
                cancellationMessage = BenchmarkLocalization.string("The test was cancelled before it finished.")
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false
            progress = nil
            task = nil
        }
    }

    public func cancel() {
        task?.cancel()
    }

    public func clearHistory() async {
        guard !isRunning else { return }
        try? await store.clear()
        history = []
        latestRun = nil
        exportMessage = nil
    }

    // MARK: - Export

    public func exportJSON() throws -> (suggestedName: String, content: String) {
        guard let latestRun else {
            throw BenchmarkError.io(BenchmarkLocalization.string("There is no result to export yet."))
        }
        return ("SystemBenchmark-\(Self.fileStamp(latestRun.generatedAt)).json", try BenchmarkReportExporter.json(run: latestRun))
    }

    public func exportMarkdown() throws -> (suggestedName: String, content: String) {
        guard let latestRun else {
            throw BenchmarkError.io(BenchmarkLocalization.string("There is no result to export yet."))
        }
        return (
            "SystemBenchmark-\(Self.fileStamp(latestRun.generatedAt)).md",
            BenchmarkReportExporter.markdown(run: latestRun, history: history)
        )
    }

    public func noteExported(fileName: String) {
        exportError = nil
        exportMessage = String(
            format: BenchmarkLocalization.string("Saved %@."),
            fileName
        )
    }

    public func noteExportFailure(_ error: Error) {
        exportMessage = nil
        exportError = error.localizedDescription
    }

    // MARK: - Private

    private func loadInitialState() {
        Task { [weak self] in
            guard let self else { return }
            let runs = await store.load()
            history = runs
            latestRun = runs.first
            await refreshPreflight()
        }
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }
}
