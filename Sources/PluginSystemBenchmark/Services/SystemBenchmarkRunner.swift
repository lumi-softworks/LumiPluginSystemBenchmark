import Darwin
import Foundation

/// 本机测速的执行器。每个子测试先跑丢弃的预热轮，再采多轮样本求中位数，
/// 单轮读数只作为样本，不再直接当作结果。
public actor SystemBenchmarkRunner {
    /// `quick` 口径的基础工作量；深度模式在此基础上加轮次和诊断项。
    public struct Configuration: Sendable {
        public let cpuIterations: Int
        public let warmupRounds: Int
        public let repeats: Int
        public let memoryBufferBytes: Int
        public let memoryPasses: Int
        public let diskBytes: Int
        public let diskChunkBytes: Int
        public let randomMemoryBytes: Int
        public let randomMemoryOperations: Int
        public let randomDiskOperations: Int
        public let diskQueueDepth: Int

        public init(
            cpuIterations: Int = 12_000_000,
            warmupRounds: Int = 1,
            repeats: Int = 5,
            memoryBufferBytes: Int = 256 * 1024 * 1024,
            memoryPasses: Int = 3,
            diskBytes: Int = 1024 * 1024 * 1024,
            diskChunkBytes: Int = 1024 * 1024,
            randomMemoryBytes: Int = 64 * 1024 * 1024,
            randomMemoryOperations: Int = 500_000,
            randomDiskOperations: Int = 4_096,
            diskQueueDepth: Int = 32
        ) {
            self.cpuIterations = cpuIterations
            self.warmupRounds = warmupRounds
            self.repeats = repeats
            self.memoryBufferBytes = memoryBufferBytes
            self.memoryPasses = memoryPasses
            self.diskBytes = diskBytes
            self.diskChunkBytes = diskChunkBytes
            self.randomMemoryBytes = randomMemoryBytes
            self.randomMemoryOperations = randomMemoryOperations
            self.randomDiskOperations = randomDiskOperations
            self.diskQueueDepth = diskQueueDepth
        }

        fileprivate func validate() throws {
            guard cpuIterations > 0 else { throw BenchmarkError.invalidConfiguration("CPU iterations must be positive") }
            guard warmupRounds >= 0, repeats >= 1 else {
                throw BenchmarkError.invalidConfiguration("A benchmark needs at least one timed round")
            }
            guard memoryBufferBytes >= 4096, memoryBufferBytes % 64 == 0, memoryPasses > 0 else {
                throw BenchmarkError.invalidConfiguration("Memory benchmark configuration is invalid")
            }
            guard diskBytes >= 4096, diskChunkBytes > 0, diskBytes >= diskChunkBytes else {
                throw BenchmarkError.invalidConfiguration("Disk benchmark configuration is invalid")
            }
            guard randomMemoryBytes > 0, randomMemoryBytes <= memoryBufferBytes, randomMemoryOperations > 0 else {
                throw BenchmarkError.invalidConfiguration("Random memory configuration is invalid")
            }
            guard randomDiskOperations > 0, diskQueueDepth > 0 else {
                throw BenchmarkError.invalidConfiguration("Random disk configuration is invalid")
            }
        }
    }

    private struct Workload {
        let repeats: Int
        let warmup: Int
        let diskBytes: Int
        let randomMemoryOperations: Int
        let randomDiskOperations: Int

        init(configuration: Configuration, mode: BenchmarkMode) {
            if mode.isDeep {
                repeats = configuration.repeats + 2
                warmup = configuration.warmupRounds + 1
                diskBytes = configuration.diskBytes * 3 / 2
                randomMemoryOperations = configuration.randomMemoryOperations * 2
                randomDiskOperations = configuration.randomDiskOperations * 2
            } else {
                repeats = configuration.repeats
                warmup = configuration.warmupRounds
                diskBytes = configuration.diskBytes
                randomMemoryOperations = configuration.randomMemoryOperations
                randomDiskOperations = configuration.randomDiskOperations
            }
        }
    }

    public nonisolated let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func run(
        mode: BenchmarkMode = .quick,
        progress: @escaping @Sendable (BenchmarkProgress) async -> Void = { _ in }
    ) async throws -> BenchmarkRun {
        try configuration.validate()

        let startTicks = DispatchTime.now().uptimeNanoseconds
        let workload = Workload(configuration: configuration, mode: mode)
        let totalSteps = Self.stepCount(for: mode)
        let emitter = BenchmarkProgressEmitter(totalSteps: totalSteps, startedAt: startTicks, handler: progress)
        var completed = 0

        await emitter.emit(.preparing, completed: 0, testID: nil)
        try Task.checkCancellation()
        try Self.ensureDiskSpace(required: Int64(workload.diskBytes) * 2 + 128 * 1024 * 1024)
        let environment = await BenchmarkEnvironment.capture()

        var measurements: [BenchmarkMeasurement] = []
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let cpuIterations = configuration.cpuIterations

        // MARK: CPU

        await emitter.emit(.cpu, completed: completed, testID: "cpu.single")
        try Task.checkCancellation()
        let single = try await Self.collect(warmup: workload.warmup, repeats: workload.repeats) {
            let start = DispatchTime.now().uptimeNanoseconds
            let checksum = try Self.integerWork(iterations: cpuIterations, seed: 0xA5A5_A5A5)
            let seconds = Self.seconds(since: start)
            withExtendedLifetime(checksum) {}
            return (Double(cpuIterations), seconds)
        }
        measurements.append(
            Self.measurement(
                id: "cpu.single",
                kind: .cpu,
                label: "CPU single-core",
                unit: "ops/s",
                result: single,
                detail: "Runs a fixed integer workload on one thread."
            )
        )
        completed += 1

        await emitter.emit(.cpu, completed: completed, testID: "cpu.multi")
        try Task.checkCancellation()
        let iterationsPerWorker = max(1, cpuIterations / cores)
        let multi = try await Self.collect(warmup: workload.warmup, repeats: workload.repeats) {
            let start = DispatchTime.now().uptimeNanoseconds
            let checksum = try await Self.aggregateWork(iterationsPerWorker: iterationsPerWorker, workers: cores)
            let seconds = Self.seconds(since: start)
            withExtendedLifetime(checksum) {}
            return (Double(iterationsPerWorker * cores), seconds)
        }
        measurements.append(
            Self.measurement(
                id: "cpu.multi",
                kind: .cpu,
                label: "CPU multi-core",
                unit: "ops/s",
                result: multi,
                detail: "Aggregate integer throughput across %@ threads.",
                detailArgument: String(cores)
            )
        )
        completed += 1

        if mode.isDeep {
            await emitter.emit(.cpu, completed: completed, testID: "cpu.fp")
            try Task.checkCancellation()
            let fpIterations = max(1, cpuIterations / 2)
            let floatingPoint = try await Self.collect(warmup: workload.warmup, repeats: workload.repeats) {
                let start = DispatchTime.now().uptimeNanoseconds
                let checksum = try Self.floatingPointWork(iterations: fpIterations, seed: 1.000_001)
                let seconds = Self.seconds(since: start)
                withExtendedLifetime(checksum) {}
                return (Double(fpIterations), seconds)
            }
            measurements.append(
                Self.measurement(
                    id: "cpu.fp",
                    kind: .cpu,
                    label: "CPU floating point",
                    unit: "ops/s",
                    result: floatingPoint,
                    detail: "Measures fused multiply-add throughput on one thread.",
                    isDiagnostic: true
                )
            )
            completed += 1

            await emitter.emit(.cpu, completed: completed, testID: "cpu.scaling")
            try Task.checkCancellation()
            for threads in Self.threadCounts(maximum: cores) {
                let perWorker = max(1, cpuIterations / 4 / threads)
                let scaling = try await Self.collect(warmup: 0, repeats: min(2, workload.repeats)) {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let checksum = try await Self.aggregateWork(iterationsPerWorker: perWorker, workers: threads)
                    let seconds = Self.seconds(since: start)
                    withExtendedLifetime(checksum) {}
                    return (Double(perWorker * threads), seconds)
                }
                measurements.append(
                    Self.measurement(
                        id: "cpu.scaling.\(threads)",
                        kind: .cpu,
                        label: "CPU thread scaling",
                        unit: "ops/s",
                        result: scaling,
                        detail: "Aggregate integer throughput with %@ active workers.",
                        detailArgument: String(threads),
                        isDiagnostic: true
                    )
                )
            }
            completed += 1
        }

        // MARK: Memory

        let memorySource = MemoryBuffer(byteCount: configuration.memoryBufferBytes, fill: 0xA5)
        let memoryDestination = MemoryBuffer(byteCount: configuration.memoryBufferBytes, fill: 0)
        let memoryBytes = configuration.memoryBufferBytes
        let passes = configuration.memoryPasses
        let bufferMiB = memoryBytes / (1024 * 1024)

        await emitter.emit(.memory, completed: completed, testID: "memory.write")
        try Task.checkCancellation()
        let memoryWrite = try await Self.collect(warmup: workload.warmup, repeats: workload.repeats) {
            let start = DispatchTime.now().uptimeNanoseconds
            for pass in 0..<passes {
                try Task.checkCancellation()
                memset(memoryDestination.pointer, Int32((pass + 1) & 0xFF), memoryBytes)
            }
            return (Double(memoryBytes * passes) / 1_048_576, Self.seconds(since: start))
        }
        measurements.append(
            Self.measurement(
                id: "memory.write",
                kind: .memory,
                label: "Memory write",
                unit: "MiB/s",
                result: memoryWrite,
                detail: "Sequential write pass over a %@ buffer.",
                detailArgument: "\(bufferMiB) MiB"
            )
        )
        completed += 1

        await emitter.emit(.memory, completed: completed, testID: "memory.copy")
        try Task.checkCancellation()
        let memoryCopy = try await Self.collect(warmup: workload.warmup, repeats: workload.repeats) {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<passes {
                try Task.checkCancellation()
                memoryDestination.pointer.copyMemory(from: memorySource.pointer, byteCount: memoryBytes)
            }
            return (Double(memoryBytes * passes) / 1_048_576, Self.seconds(since: start))
        }
        measurements.append(
            Self.measurement(
                id: "memory.copy",
                kind: .memory,
                label: "Memory copy",
                unit: "MiB/s",
                result: memoryCopy,
                detail: "Copy pass over a %@ buffer.",
                detailArgument: "\(bufferMiB) MiB"
            )
        )
        completed += 1

        await emitter.emit(.memory, completed: completed, testID: "memory.read")
        try Task.checkCancellation()
        let memoryRead = try await Self.collect(warmup: workload.warmup, repeats: workload.repeats) {
            let start = DispatchTime.now().uptimeNanoseconds
            let checksum = try Self.sequentialRead(pointer: memorySource.pointer, byteCount: memoryBytes, passes: passes)
            let seconds = Self.seconds(since: start)
            withExtendedLifetime(checksum) {}
            return (Double(memoryBytes * passes) / 1_048_576, seconds)
        }
        measurements.append(
            Self.measurement(
                id: "memory.read",
                kind: .memory,
                label: "Memory read",
                unit: "MiB/s",
                result: memoryRead,
                detail: "Read pass over a %@ buffer.",
                detailArgument: "\(bufferMiB) MiB"
            )
        )
        completed += 1

        if mode.isDeep {
            await emitter.emit(.memory, completed: completed, testID: "memory.random")
            try Task.checkCancellation()
            let randomBytes = configuration.randomMemoryBytes
            let randomOperations = workload.randomMemoryOperations
            let randomMemory = try await Self.collect(warmup: workload.warmup, repeats: workload.repeats) {
                let start = DispatchTime.now().uptimeNanoseconds
                let checksum = try Self.randomMemoryReads(
                    pointer: memorySource.pointer,
                    byteCount: randomBytes,
                    operations: randomOperations
                )
                let seconds = Self.seconds(since: start)
                withExtendedLifetime(checksum) {}
                return (Double(randomOperations), seconds)
            }
            measurements.append(
                Self.measurement(
                    id: "memory.random",
                    kind: .memory,
                    label: "Memory random access",
                    unit: "ops/s",
                    result: randomMemory,
                    detail: "Random 64-bit loads across a %@ buffer.",
                    detailArgument: "\(randomBytes / (1024 * 1024)) MiB",
                    isDiagnostic: true
                )
            )
            completed += 1
        }

        // MARK: Disk

        let tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-system-benchmark-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempFileURL) }

        let diskMiB = workload.diskBytes / (1024 * 1024)
        let chunk = Self.patternData(byteCount: min(configuration.diskChunkBytes, workload.diskBytes))

        await emitter.emit(.disk, completed: completed, testID: "disk.write")
        try Task.checkCancellation()
        let diskWrite = try await Self.collect(warmup: workload.warmup, repeats: workload.repeats) {
            let start = DispatchTime.now().uptimeNanoseconds
            try Self.writeFile(at: tempFileURL, totalBytes: workload.diskBytes, chunk: chunk)
            return (Double(workload.diskBytes) / 1_048_576, Self.seconds(since: start))
        }
        measurements.append(
            Self.measurement(
                id: "disk.write",
                kind: .disk,
                label: "Disk write",
                unit: "MiB/s",
                result: diskWrite,
                detail: "Writes a %@ temporary file bypassing the cache, then forces a full flush.",
                detailArgument: "\(diskMiB) MiB"
            )
        )
        completed += 1

        await emitter.emit(.disk, completed: completed, testID: "disk.read")
        try Task.checkCancellation()
        let diskRead = try await Self.collect(warmup: workload.warmup, repeats: workload.repeats) {
            let start = DispatchTime.now().uptimeNanoseconds
            let checksum = try Self.readFile(at: tempFileURL, totalBytes: workload.diskBytes, chunkBytes: chunk.count)
            let seconds = Self.seconds(since: start)
            withExtendedLifetime(checksum) {}
            return (Double(workload.diskBytes) / 1_048_576, seconds)
        }
        measurements.append(
            Self.measurement(
                id: "disk.read",
                kind: .disk,
                label: "Disk read",
                unit: "MiB/s",
                result: diskRead,
                detail: "Reads the %@ temporary file back without using the cache.",
                detailArgument: "\(diskMiB) MiB"
            )
        )
        completed += 1

        if mode.isDeep {
            let descriptor = tempFileURL.path.withCString { open($0, O_RDONLY) }
            guard descriptor >= 0 else { throw Self.ioError("Unable to open the benchmark file") }
            defer { close(descriptor) }
            _ = fcntl(descriptor, F_NOCACHE, 1)

            for queueDepth in [1, min(configuration.diskQueueDepth, 64)] {
                let testID = "disk.random.qd\(queueDepth)"
                await emitter.emit(.disk, completed: completed, testID: testID)
                try Task.checkCancellation()
                let operations = workload.randomDiskOperations
                let randomDisk = try await Self.collect(warmup: 0, repeats: min(2, workload.repeats)) {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let checksum = try await Self.randomDiskReads(
                        descriptor: descriptor,
                        fileBytes: workload.diskBytes,
                        operations: operations,
                        queueDepth: queueDepth,
                        seed: 0xC0FFEE &+ UInt64(queueDepth)
                    )
                    let seconds = Self.seconds(since: start)
                    withExtendedLifetime(checksum) {}
                    return (Double(operations), seconds)
                }
                measurements.append(
                    Self.measurement(
                        id: testID,
                        kind: .disk,
                        label: "Disk random read",
                        unit: "IOPS",
                        result: randomDisk,
                        detail: "4 KiB random reads at queue depth %@.",
                        detailArgument: String(queueDepth),
                        isDiagnostic: true
                    )
                )
                completed += 1
            }
        }

        await emitter.emit(.finished, completed: totalSteps, testID: nil)
        return BenchmarkRun(
            mode: mode,
            environment: environment,
            measurements: measurements,
            elapsedSeconds: Self.seconds(since: startTicks)
        )
    }

    // MARK: - Step accounting

    private nonisolated static func stepCount(for mode: BenchmarkMode) -> Int {
        mode.isDeep ? 12 : 7
    }

    private nonisolated static func threadCounts(maximum: Int) -> [Int] {
        var counts = [1, 2, 4, 8, 16].filter { $0 <= maximum }
        if !counts.contains(maximum) { counts.append(maximum) }
        return counts.sorted()
    }

    // MARK: - Sampling

    private nonisolated static func collect(
        warmup: Int,
        repeats: Int,
        sample: () async throws -> (units: Double, seconds: Double)
    ) async throws -> (statistics: BenchmarkStatistics, durationMilliseconds: Double) {
        for _ in 0..<max(0, warmup) {
            try Task.checkCancellation()
            _ = try await sample()
        }

        var values: [Double] = []
        values.reserveCapacity(max(1, repeats))
        var totalSeconds = 0.0
        for _ in 0..<max(1, repeats) {
            try Task.checkCancellation()
            let result = try await sample()
            values.append(result.seconds > 0 ? result.units / result.seconds : 0)
            totalSeconds += result.seconds
        }
        return (BenchmarkStatistics(samples: values), totalSeconds * 1_000)
    }

    private nonisolated static func measurement(
        id: String,
        kind: BenchmarkKind,
        label: String,
        unit: String,
        result: (statistics: BenchmarkStatistics, durationMilliseconds: Double),
        detail: String,
        detailArgument: String? = nil,
        isDiagnostic: Bool = false
    ) -> BenchmarkMeasurement {
        BenchmarkMeasurement(
            id: id,
            kind: kind,
            label: label,
            unit: unit,
            statistics: result.statistics,
            durationMilliseconds: result.durationMilliseconds,
            detail: detail,
            detailArgument: detailArgument,
            isDiagnostic: isDiagnostic
        )
    }

    // MARK: - CPU

    @inline(never)
    private nonisolated static func integerWork(iterations: Int, seed: UInt64) throws -> UInt64 {
        var value = seed
        var completed = 0
        while completed < iterations {
            try Task.checkCancellation()
            let end = min(completed + 65_536, iterations)
            for _ in completed..<end {
                value = value &* 1_664_525 &+ 1_013_904_223
                value ^= value >> 13
                value = value &* 2_862_933_555_777_941_757
                value ^= value << 17
            }
            completed = end
        }
        return value
    }

    @inline(never)
    private nonisolated static func floatingPointWork(iterations: Int, seed: Double) throws -> Double {
        var value = seed
        var completed = 0
        while completed < iterations {
            try Task.checkCancellation()
            let end = min(completed + 65_536, iterations)
            for _ in completed..<end {
                value = fma(value, 1.000_001, 0.000_000_1)
            }
            completed = end
        }
        return value
    }

    private nonisolated static func aggregateWork(iterationsPerWorker: Int, workers: Int) async throws -> UInt64 {
        try await withThrowingTaskGroup(of: UInt64.self) { group in
            for worker in 0..<max(1, workers) {
                let seed = UInt64(worker + 1)
                group.addTask {
                    try integerWork(iterations: iterationsPerWorker, seed: seed)
                }
            }
            var checksum: UInt64 = 0
            for try await value in group {
                checksum ^= value
            }
            return checksum
        }
    }

    // MARK: - Memory

    private final class MemoryBuffer {
        let pointer: UnsafeMutableRawPointer
        let byteCount: Int

        init(byteCount: Int, fill: Int32) {
            self.byteCount = byteCount
            pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
            memset(pointer, fill, byteCount)
        }

        deinit {
            pointer.deallocate()
        }
    }

    private nonisolated static func sequentialRead(pointer: UnsafeRawPointer, byteCount: Int, passes: Int) throws -> UInt64 {
        var checksum: UInt64 = 0
        let lastReadableOffset = max(0, byteCount - MemoryLayout<UInt64>.size)
        for _ in 0..<passes {
            try Task.checkCancellation()
            var offset = 0
            while offset <= lastReadableOffset {
                checksum &+= pointer.load(fromByteOffset: offset, as: UInt64.self)
                offset += 64
            }
        }
        return checksum
    }

    private nonisolated static func randomMemoryReads(
        pointer: UnsafeRawPointer,
        byteCount: Int,
        operations: Int
    ) throws -> UInt64 {
        let slots = max(1, byteCount / MemoryLayout<UInt64>.size)
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var checksum: UInt64 = 0
        var completed = 0
        while completed < operations {
            try Task.checkCancellation()
            let end = min(completed + 8_192, operations)
            while completed < end {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let slot = Int((state >> 33) % UInt64(slots))
                checksum &+= pointer.load(fromByteOffset: slot * MemoryLayout<UInt64>.size, as: UInt64.self)
                completed += 1
            }
        }
        return checksum
    }

    // MARK: - Disk

    private nonisolated static func patternData(byteCount: Int) -> Data {
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            for index in 0..<byteCount {
                baseAddress.storeBytes(
                    of: UInt8(truncatingIfNeeded: index &* 31 &+ 0xA5),
                    toByteOffset: index,
                    as: UInt8.self
                )
            }
        }
        return data
    }

    private nonisolated static func writeFile(at url: URL, totalBytes: Int, chunk: Data) throws {
        let descriptor = url.path.withCString { open($0, O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw ioError("Unable to create the benchmark file") }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_NOCACHE, 1)

        try chunk.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw BenchmarkError.io("Disk buffer allocation failed")
            }
            var remaining = totalBytes
            while remaining > 0 {
                try Task.checkCancellation()
                let requested = min(remaining, chunk.count)
                let written = write(descriptor, baseAddress, requested)
                guard written > 0 else { throw ioError("Disk write failed") }
                remaining -= written
            }
        }
        try flush(descriptor)
    }

    private nonisolated static func flush(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC, 0) == 0 { return }
        guard fsync(descriptor) == 0 else { throw ioError("fsync failed") }
    }

    private nonisolated static func readFile(at url: URL, totalBytes: Int, chunkBytes: Int) throws -> UInt64 {
        let descriptor = url.path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw ioError("Unable to open the benchmark file") }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_NOCACHE, 1)

        var buffer = [UInt8](repeating: 0, count: max(1, chunkBytes))
        let bufferBytes = buffer.count
        var remaining = totalBytes
        var checksum: UInt64 = 0
        return try buffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw BenchmarkError.io("Disk buffer allocation failed")
            }
            while remaining > 0 {
                try Task.checkCancellation()
                let requested = min(remaining, bufferBytes)
                let count = read(descriptor, baseAddress, requested)
                guard count > 0 else { throw ioError("Disk read failed") }
                var offset = 0
                while offset < count {
                    checksum &+= UInt64(baseAddress.load(fromByteOffset: offset, as: UInt8.self))
                    offset += 64
                }
                remaining -= count
            }
            return checksum
        }
    }

    private nonisolated static func randomDiskReads(
        descriptor: Int32,
        fileBytes: Int,
        operations: Int,
        queueDepth: Int,
        seed: UInt64
    ) async throws -> UInt64 {
        let depth = max(1, min(queueDepth, operations))
        guard depth > 1 else {
            return try randomDiskReadBatch(
                descriptor: descriptor,
                fileBytes: fileBytes,
                operations: operations,
                seed: seed
            )
        }

        return try await withThrowingTaskGroup(of: UInt64.self) { group in
            let perWorker = operations / depth
            var assigned = 0
            for worker in 0..<depth {
                let count = worker == depth - 1 ? operations - assigned : perWorker
                assigned += count
                let workerSeed = seed &+ UInt64(worker) &* 7_919
                group.addTask {
                    try randomDiskReadBatch(
                        descriptor: descriptor,
                        fileBytes: fileBytes,
                        operations: count,
                        seed: workerSeed
                    )
                }
            }
            var checksum: UInt64 = 0
            for try await value in group {
                checksum ^= value
            }
            return checksum
        }
    }

    private nonisolated static func randomDiskReadBatch(
        descriptor: Int32,
        fileBytes: Int,
        operations: Int,
        seed: UInt64
    ) throws -> UInt64 {
        let blockSize = 4_096
        let maxOffset = max(0, fileBytes - blockSize)
        var buffer = [UInt8](repeating: 0, count: blockSize)
        var state = seed
        var checksum: UInt64 = 0
        return try buffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw BenchmarkError.io("Disk buffer allocation failed")
            }
            for _ in 0..<operations {
                try Task.checkCancellation()
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let offset = off_t((state >> 33) % UInt64(maxOffset + 1))
                let count = pread(descriptor, baseAddress, blockSize, offset)
                guard count == blockSize else { throw ioError("Random disk read failed") }
                checksum &+= UInt64(baseAddress.load(fromByteOffset: 0, as: UInt8.self))
                checksum &+= UInt64(baseAddress.load(fromByteOffset: blockSize - 1, as: UInt8.self))
            }
            return checksum
        }
    }

    // MARK: - Support

    private nonisolated static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private nonisolated static func ensureDiskSpace(required: Int64) throws {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage, available > 0 else { return }
        guard available >= required else {
            throw BenchmarkError.insufficientDiskSpace(requiredBytes: required, availableBytes: available)
        }
    }

    private nonisolated static func ioError(_ message: String) -> BenchmarkError {
        let reason = String(cString: strerror(errno))
        return .io("\(message): \(reason)")
    }
}

private struct BenchmarkProgressEmitter: Sendable {
    let totalSteps: Int
    let startedAt: UInt64
    let handler: @Sendable (BenchmarkProgress) async -> Void

    func emit(_ phase: BenchmarkProgress.Phase, completed: Int, testID: String?) async {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        let fraction = totalSteps > 0 ? min(1, Double(completed) / Double(totalSteps)) : 0
        await handler(
            BenchmarkProgress(
                phase: phase,
                completedSteps: completed,
                totalSteps: totalSteps,
                currentTestID: testID,
                fraction: fraction,
                elapsedSeconds: elapsed
            )
        )
    }
}
