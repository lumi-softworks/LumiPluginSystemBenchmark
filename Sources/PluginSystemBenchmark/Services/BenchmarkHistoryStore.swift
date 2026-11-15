import Foundation

/// 结果持久化：只留最近 20 次，按新到旧排列。
///
/// 存放于宿主 App 的 Application Support 下，按 bundle id 隔离，
/// 因此 Lumi 与其它宿主不会互相覆盖历史。
public actor BenchmarkHistoryStore {
    public static let defaultLimit = 20

    public nonisolated let fileURL: URL
    private let limit: Int

    public init(fileURL: URL? = nil, limit: Int = BenchmarkHistoryStore.defaultLimit) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.limit = max(1, limit)
    }

    public func load() -> [BenchmarkRun] {
        guard let data = try? Data(contentsOf: fileURL),
              let runs = try? Self.decoder.decode([BenchmarkRun].self, from: data)
        else {
            return []
        }
        return Array(runs.sorted { $0.generatedAt > $1.generatedAt }.prefix(limit))
    }

    @discardableResult
    public func append(_ run: BenchmarkRun) throws -> [BenchmarkRun] {
        var runs = load().filter { $0.id != run.id }
        runs.append(run)
        runs.sort { $0.generatedAt > $1.generatedAt }
        runs = Array(runs.prefix(limit))
        try write(runs)
        return runs
    }

    public func replaceAll(_ runs: [BenchmarkRun]) throws {
        let sorted = Array(runs.sorted { $0.generatedAt > $1.generatedAt }.prefix(limit))
        try write(sorted)
    }

    public func clear() throws {
        try write([])
    }

    private func write(_ runs: [BenchmarkRun]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(runs)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "default"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("SystemBenchmark", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
