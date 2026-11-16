import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import LumiUI
import SwiftUI

/// Main Activity Bar content for the local system benchmark plugin.
public struct SystemBenchmarkView: View {
    @ObservedObject private var viewModel: SystemBenchmarkViewModel

    public init(viewModel: SystemBenchmarkViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
    }

    public var body: some View {
        SystemBenchmarkDashboardView(viewModel: viewModel)
    }
}

private enum BenchmarkReportFormat {
    case json
    case markdown
}

private struct SystemBenchmarkDashboardView: View {
    @LumiTheme private var theme
    @ObservedObject var viewModel: SystemBenchmarkViewModel

    @State private var progressReceivedAt = Date()
    @State private var isConfirmingClear = false

    var body: some View {
        PluginSettingsScaffold(
            title: BenchmarkLocalization.string("System Benchmark"),
            subtitle: BenchmarkLocalization.string("A focused local performance report for this Mac.")
        ) {
            VStack(alignment: .leading, spacing: 20) {
                hero

                if viewModel.isRunning, let progress = viewModel.progress {
                    progressCard(progress)
                }

                if let cancellationMessage = viewModel.cancellationMessage {
                    AppStatusBanner(
                        kind: .info,
                        title: BenchmarkLocalization.string("Benchmark cancelled"),
                        message: cancellationMessage
                    )
                }

                if let exportError = viewModel.exportError {
                    AppStatusBanner(
                        kind: .error,
                        title: BenchmarkLocalization.string("Export failed"),
                        message: exportError
                    )
                }

                if let exportMessage = viewModel.exportMessage {
                    AppStatusBanner(
                        kind: .success,
                        title: BenchmarkLocalization.string("Report saved"),
                        message: exportMessage
                    )
                }

                if let errorMessage = viewModel.errorMessage {
                    AppStatusBanner(
                        kind: .error,
                        title: BenchmarkLocalization.string("Benchmark failed"),
                        message: errorMessage
                    )
                }

                if !viewModel.isRunning {
                    readinessCard
                }

                if let run = viewModel.latestRun {
                    reportCard(run)
                    evidenceCard(run)
                    environmentCard(run)
                    historyCard
                } else if !viewModel.isRunning {
                    emptyResults
                }

                methodCard
            }
        }
        .onChange(of: viewModel.progress) { _, _ in
            progressReceivedAt = Date()
        }
        .confirmationDialog(
            Text(BenchmarkLocalization.string("Delete the saved benchmark history?")),
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button(BenchmarkLocalization.string("Clear History"), role: .destructive) {
                Task { await viewModel.clearHistory() }
            }
            Button(BenchmarkLocalization.string("Cancel"), role: .cancel) {}
        }
    }

    // MARK: - Hero

    private var hero: some View {
        AppSettingSection(title: nil) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(theme.primary.opacity(0.14))
                            .frame(width: 52, height: 52)
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(theme.primary)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(BenchmarkLocalization.string("CPU, memory bandwidth, and disk throughput"))
                            .font(.appCaption)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                        AppTag(
                            viewModel.isRunning
                                ? BenchmarkLocalization.string("Running")
                                : BenchmarkLocalization.string("Ready"),
                            systemImage: viewModel.isRunning ? "waveform" : "checkmark.circle",
                            style: viewModel.isRunning ? .accent : .subtle
                        )
                    }

                    Spacer(minLength: 12)

                    if viewModel.isRunning {
                        AppButton(
                            BenchmarkLocalization.string("Cancel"),
                            systemImage: "stop.fill",
                            style: .destructive,
                            size: .small
                        ) {
                            viewModel.cancel()
                        }
                    } else {
                        VStack(alignment: .trailing, spacing: 6) {
                            AppButton(
                                BenchmarkLocalization.string("Start Benchmark"),
                                systemImage: "play.fill",
                                style: .primary,
                                size: .medium
                            ) {
                                viewModel.start()
                            }
                            if viewModel.preflight?.canRun == false {
                                Text(BenchmarkLocalization.string("Blocked by a readiness check"))
                                    .font(.appCaption)
                                    .foregroundStyle(theme.error)
                            }
                        }
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    Text(BenchmarkLocalization.string("Test depth"))
                        .font(.appCaption)
                        .foregroundStyle(theme.textSecondary)

                    AppSegmentedControl(
                        [
                            BenchmarkLocalization.string("Quick"),
                            BenchmarkLocalization.string("Deep"),
                        ],
                        selection: Binding(
                            get: { viewModel.mode == .deep ? 1 : 0 },
                            set: { viewModel.mode = $0 == 1 ? .deep : .quick }
                        ),
                        maxWidth: 180
                    )
                    .disabled(viewModel.isRunning)

                    Text(
                        viewModel.mode == .deep
                            ? BenchmarkLocalization.string("Deep mode adds floating point, thread scaling, and random I/O.")
                            : BenchmarkLocalization.string("Quick mode uses warmup plus five timed rounds.")
                    )
                    .font(.appCaption)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Progress

    private func progressCard(_ progress: BenchmarkProgress) -> some View {
        AppSettingSection(title: nil) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = progress.elapsedSeconds + context.date.timeIntervalSince(progressReceivedAt)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(phaseTitle(progress.phase), systemImage: phaseIcon(progress.phase))
                            .font(.appBodyEmphasized)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text(String(format: "%.0f%%", progress.fraction * 100))
                            .font(.appMonoCaption)
                            .foregroundStyle(theme.primary)
                            .monospacedDigit()
                    }

                    ProgressView(value: progress.fraction)
                        .tint(theme.primary)

                    HStack(spacing: 10) {
                        Text(currentTestTitle(progress))
                            .font(.appCaption)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Text(String(format: BenchmarkLocalization.string("Step %d of %d"), progress.completedSteps + 1, progress.totalSteps))
                            .font(.appCaption)
                            .foregroundStyle(theme.textTertiary)
                            .monospacedDigit()
                        Text(formattedDuration(elapsed))
                            .font(.appMonoCaption)
                            .foregroundStyle(theme.textSecondary)
                            .monospacedDigit()
                        if let remaining = estimatedRemaining(elapsed: elapsed, fraction: progress.fraction) {
                            Text(String(format: BenchmarkLocalization.string("%@ left"), formattedDuration(remaining)))
                                .font(.appCaption)
                                .foregroundStyle(theme.textTertiary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Readiness

    private var readinessCard: some View {
        AppSettingSection(title: nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label(BenchmarkLocalization.string("Readiness checks"), systemImage: "checklist")
                        .font(.appBodyEmphasized)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    if viewModel.isCheckingPreflight {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        AppButton(
                            BenchmarkLocalization.string("Recheck"),
                            systemImage: "arrow.clockwise",
                            style: .ghost,
                            size: .small
                        ) {
                            Task { await viewModel.refreshPreflight() }
                        }
                    }
                }

                if let preflight = viewModel.preflight {
                    ForEach(preflight.checks) { check in
                        readinessRow(check)
                    }
                } else {
                    Text(BenchmarkLocalization.string("Checking the environment before the test."))
                        .font(.appCaption)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private func readinessRow(_ check: BenchmarkPreflight.Check) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: readinessIcon(check.status))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(readinessColor(check.status))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.appCaption)
                    .foregroundStyle(theme.textPrimary)
                Text(check.detail)
                    .font(.appCaption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Report

    private func reportCard(_ run: BenchmarkRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                AppSectionLabel(BenchmarkLocalization.string("Latest result"))
                Spacer()
                Text(Self.dateFormatter.string(from: run.generatedAt))
                    .font(.appCaption)
                    .foregroundStyle(theme.textTertiary)
                AppButton(
                    BenchmarkLocalization.string("JSON"),
                    systemImage: "square.and.arrow.up",
                    style: .ghost,
                    size: .small
                ) {
                    saveReport(.json)
                }
                AppButton(
                    BenchmarkLocalization.string("Markdown"),
                    systemImage: "doc.text",
                    style: .ghost,
                    size: .small
                ) {
                    saveReport(.markdown)
                }
            }

            AppSettingSection(title: nil) {
                VStack(alignment: .leading, spacing: 16) {
                    indexSummary(run)

                    if !run.coreMeasurements.isEmpty {
                        Divider()
                        categoryScores(run)
                    }
                }
            }
        }
    }

    private func indexSummary(_ run: BenchmarkRun) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(BenchmarkLocalization.string("Performance Index"))
                    .font(.appCaption)
                    .foregroundStyle(theme.textSecondary)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(run.index.map { String(format: "%.1f", $0.value) } ?? "—")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .monospacedDigit()
                    Text(BenchmarkLocalization.string("baseline = 1000"))
                        .font(.appCaption)
                        .foregroundStyle(theme.textTertiary)
                }

                Text(indexCaption(run))
                    .font(.appCaption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                if let verdict = viewModel.comparisonVerdict {
                    AppTag(verdictTitle(verdict), systemImage: verdictIcon(verdict), style: .accent)
                }
                AppTag(
                    qualityTitle(run.overallQuality),
                    systemImage: qualityIcon(run.overallQuality),
                    style: run.overallQuality == .stable ? .accent : .subtle
                )
                if let previous = viewModel.previousIndexedRun {
                    Text(
                        String(
                            format: BenchmarkLocalization.string("Compared with %@"),
                            Self.shortDateFormatter.string(from: previous.generatedAt)
                        )
                    )
                    .font(.appCaption)
                    .foregroundStyle(theme.textTertiary)
                }
                Text(modeTitle(run.mode))
                    .font(.appCaption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func categoryScores(_ run: BenchmarkRun) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
            spacing: 12
        ) {
            ForEach(BenchmarkKind.allCases) { kind in
                categoryCard(kind: kind, run: run)
            }
        }
    }

    private func categoryCard(kind: BenchmarkKind, run: BenchmarkRun) -> some View {
        let index = categoryIndex(kind: kind, run: run)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: kind.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kind.color(in: theme))
                Text(kind.title)
                    .font(.appCaption)
                    .foregroundStyle(theme.textSecondary)
            }

            Text(index.map { String(format: "%.0f", $0) } ?? "—")
                .font(.appSectionTitle)
                .foregroundStyle(theme.textPrimary)
                .monospacedDigit()

            if let index {
                let rawDelta = (index - 1000) / 10
                let delta = abs(rawDelta) < 0.05 ? 0 : rawDelta
                let format = delta > 0 ? "%+.1f%% vs baseline" : "%.1f%% vs baseline"
                Text(String(format: BenchmarkLocalization.string(format), delta))
                    .font(.appCaption)
                    .foregroundStyle(delta > 0 ? theme.success : delta < 0 ? theme.warning : theme.textSecondary)
                    .monospacedDigit()
            } else {
                Text(BenchmarkLocalization.string("Not in the index"))
                    .font(.appCaption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.elevatedSurface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.appSubtleBorder, lineWidth: 1)
        )
    }

    // MARK: - Evidence

    private func evidenceCard(_ run: BenchmarkRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionLabel(BenchmarkLocalization.string("Evidence"))

            AppSettingSection(title: nil) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(run.coreMeasurements) { measurement in
                        evidenceRow(measurement, run: run)
                    }

                    if !run.diagnosticMeasurements.isEmpty {
                        Divider()
                        Text(BenchmarkLocalization.string("Diagnostics"))
                            .font(.appCaption)
                            .foregroundStyle(theme.textTertiary)
                        ForEach(run.diagnosticMeasurements) { measurement in
                            diagnosticRow(measurement)
                        }
                    }
                }
            }
        }
    }

    private func evidenceRow(_ measurement: BenchmarkMeasurement, run: BenchmarkRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(BenchmarkLocalization.string(measurement.label))
                    .font(.appBodyEmphasized)
                    .foregroundStyle(theme.textPrimary)
                AppTag(
                    qualityTitle(measurement.quality),
                    systemImage: qualityIcon(measurement.quality),
                    style: measurement.quality == .stable ? .accent : .subtle
                )
                Spacer()
                Text("\(formattedValue(measurement.value)) \(measurement.unit)")
                    .font(.appBodyEmphasized)
                    .foregroundStyle(theme.textPrimary)
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                Text(
                    String(
                        format: BenchmarkLocalization.string("95%% CI %@–%@"),
                        formattedValue(measurement.statistics.lowerBound),
                        formattedValue(measurement.statistics.upperBound)
                    )
                )
                .font(.appCaption)
                .foregroundStyle(theme.textSecondary)
                .monospacedDigit()

                Text(String(format: "CV %.1f%%", measurement.statistics.coefficientOfVariation * 100))
                    .font(.appCaption)
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()

                if let subtestIndex = run.index?.subtestIndices[measurement.id] {
                    Text(String(format: BenchmarkLocalization.string("Index %.0f"), subtestIndex))
                        .font(.appCaption)
                        .foregroundStyle(theme.textTertiary)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)

                Text(String(format: "%.0f ms", measurement.durationMilliseconds))
                    .font(.appCaption)
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
            }

            Text(detailText(measurement.detail, argument: measurement.detailArgument))
                .font(.appCaption)
                .foregroundStyle(theme.textTertiary)
        }
    }

    private func diagnosticRow(_ measurement: BenchmarkMeasurement) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(BenchmarkLocalization.string(measurement.label))
                .font(.appCaption)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Text("\(formattedValue(measurement.value)) \(measurement.unit)")
                .font(.appCaption)
                .foregroundStyle(theme.textPrimary)
                .monospacedDigit()
            if let argument = measurement.detailArgument {
                Text(argument)
                    .font(.appCaption)
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Environment

    private func environmentCard(_ run: BenchmarkRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionLabel(BenchmarkLocalization.string("Environment"))

            AppSettingSection(title: nil) {
                VStack(spacing: 0) {
                    environmentRow(
                        BenchmarkLocalization.string("Chip"),
                        value: run.environment.chip,
                        icon: "cpu"
                    )
                    Divider().padding(.vertical, 8)
                    environmentRow(
                        BenchmarkLocalization.string("Cores"),
                        value: String(run.environment.processorCount),
                        icon: "square.grid.3x3"
                    )
                    Divider().padding(.vertical, 8)
                    environmentRow(
                        BenchmarkLocalization.string("Memory"),
                        value: Self.formatBytes(run.environment.memoryBytes),
                        icon: "memorychip"
                    )
                    Divider().padding(.vertical, 8)
                    environmentRow(
                        "macOS",
                        value: run.environment.macOSVersion,
                        icon: "desktopcomputer"
                    )
                    Divider().padding(.vertical, 8)
                    environmentRow(
                        BenchmarkLocalization.string("Power"),
                        value: powerTitle(run.environment.powerSource),
                        icon: "powerplug"
                    )
                    Divider().padding(.vertical, 8)
                    environmentRow(
                        BenchmarkLocalization.string("Thermal state"),
                        value: thermalTitle(run.environment.thermalState),
                        icon: "thermometer.medium"
                    )
                    Divider().padding(.vertical, 8)
                    environmentRow(
                        BenchmarkLocalization.string("Background load"),
                        value: String(format: "%.0f%%", run.environment.backgroundLoad * 100),
                        icon: "waveform.path.ecg"
                    )
                }
            }
        }
    }

    private func environmentRow(_ title: String, value: String, icon: String) -> some View {
        AppSettingRow(title: title, description: nil, icon: icon) {
            Text(value)
                .font(.appCaption)
                .foregroundStyle(theme.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    // MARK: - History

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                AppSectionLabel(BenchmarkLocalization.string("History"))
                Spacer()
                Text(
                    String(
                        format: BenchmarkLocalization.string("%d runs kept"),
                        viewModel.history.count
                    )
                )
                .font(.appCaption)
                .foregroundStyle(theme.textTertiary)
                AppButton(
                    BenchmarkLocalization.string("Clear History"),
                    systemImage: "trash",
                    style: .ghost,
                    size: .small
                ) {
                    isConfirmingClear = true
                }
            }

            AppSettingSection(title: nil) {
                if viewModel.indexedHistory.count >= 2 {
                    VStack(alignment: .leading, spacing: 8) {
                        AppLineChart(
                            points: viewModel.indexedHistory.map {
                                AppLineChartPoint(date: $0.generatedAt, value: $0.index?.value ?? 0)
                            },
                            accessibilityLabel: BenchmarkLocalization.string("Performance index history"),
                            valueLabel: { String(format: "%.0f", $0) },
                            pointStyle: .automatic,
                            showsAxisTicks: true,
                            showsDateLabels: true
                        )
                        .frame(height: 150)

                        ForEach(viewModel.indexedHistory.suffix(5).reversed()) { run in
                            historyRow(run)
                        }
                    }
                } else {
                    Text(BenchmarkLocalization.string("Run the benchmark again to build a trend."))
                        .font(.appCaption)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private func historyRow(_ run: BenchmarkRun) -> some View {
        HStack(spacing: 8) {
            Text(Self.dateFormatter.string(from: run.generatedAt))
                .font(.appCaption)
                .foregroundStyle(theme.textSecondary)
            Text(modeTitle(run.mode))
                .font(.appCaption)
                .foregroundStyle(theme.textTertiary)
            Spacer()
            Text(run.index.map { String(format: "%.1f", $0.value) } ?? "—")
                .font(.appBodyEmphasized)
                .foregroundStyle(theme.textPrimary)
                .monospacedDigit()
            Text(qualityTitle(run.overallQuality))
                .font(.appCaption)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Empty / Method

    private var emptyResults: some View {
        AppSettingSection(title: nil) {
            AppEmptyState(
                icon: "chart.bar.xaxis",
                title: BenchmarkLocalization.string("No benchmark yet"),
                description: BenchmarkLocalization.string("Run a test to see the measured throughput for this Mac.")
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var methodCard: some View {
        AppSettingSection(title: nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(theme.info)
                    Text(BenchmarkLocalization.string("About this test"))
                        .font(.appBodyEmphasized)
                        .foregroundStyle(theme.textPrimary)
                }

                Text(
                    BenchmarkLocalization.string(
                        "Warmup is discarded, the median of the measured rounds is reported, and the 95% confidence interval comes from bootstrap resampling. The index is the geometric mean of each core subtest relative to the first qualified local run."
                    )
                )
                .font(.appCaption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                Text(BenchmarkLocalization.string("Network testing is intentionally not included in this version."))
                    .font(.appCaption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    // MARK: - Helpers

    private func saveReport(_ format: BenchmarkReportFormat) {
        let exported: (suggestedName: String, content: String)
        do {
            switch format {
            case .json: exported = try viewModel.exportJSON()
            case .markdown: exported = try viewModel.exportMarkdown()
            }
        } catch {
            viewModel.noteExportFailure(error)
            return
        }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exported.suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try exported.content.write(to: url, atomically: true, encoding: .utf8)
            viewModel.noteExported(fileName: url.lastPathComponent)
        } catch {
            viewModel.noteExportFailure(error)
        }
        #else
        // iOS 没有 NSSavePanel：写入临时目录后交给系统分享面板。
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(exported.suggestedName)
            try exported.content.write(to: url, atomically: true, encoding: .utf8)
            let activity = UIActivityViewController(
                activityItems: [url],
                applicationActivities: nil
            )
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first?
                .rootViewController?
                .present(activity, animated: true)
            viewModel.noteExported(fileName: exported.suggestedName)
        } catch {
            viewModel.noteExportFailure(error)
        }
        #endif
    }

    private func phaseTitle(_ phase: BenchmarkProgress.Phase) -> String {
        switch phase {
        case .preparing: return BenchmarkLocalization.string("Preparing")
        case .cpu: return BenchmarkLocalization.string("Testing CPU")
        case .memory: return BenchmarkLocalization.string("Testing Memory")
        case .disk: return BenchmarkLocalization.string("Testing Disk")
        case .finished: return BenchmarkLocalization.string("Finished")
        }
    }

    private func phaseIcon(_ phase: BenchmarkProgress.Phase) -> String {
        switch phase {
        case .preparing: return "ellipsis"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .finished: return "checkmark.circle"
        }
    }

    private func currentTestTitle(_ progress: BenchmarkProgress) -> String {
        guard let testID = progress.currentTestID else {
            return phaseTitle(progress.phase)
        }
        return Self.testTitle(for: testID)
    }

    private func estimatedRemaining(elapsed: Double, fraction: Double) -> Double? {
        guard fraction > 0.05, fraction < 1, elapsed > 0 else { return nil }
        return elapsed / fraction * (1 - fraction)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 60 {
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return String(format: "%ds", total)
    }

    private func indexCaption(_ run: BenchmarkRun) -> String {
        guard let index = run.index else {
            return BenchmarkLocalization.string(
                "The index appears once the six core subtests are complete."
            )
        }
        if index.baselineRunID == run.id {
            return BenchmarkLocalization.string("This run is the baseline; later runs are compared against it.")
        }
        return String(
            format: BenchmarkLocalization.string("Baseline captured %@."),
            Self.shortDateFormatter.string(from: index.baselineDate)
        )
    }

    private func categoryIndex(kind: BenchmarkKind, run: BenchmarkRun) -> Double? {
        guard let index = run.index else { return nil }
        let values = index.subtestIndices.compactMap { key, value -> Double? in
            Self.kind(for: key) == kind ? value : nil
        }
        guard !values.isEmpty else { return nil }
        return exp(values.map { log($0) }.reduce(0, +) / Double(values.count))
    }

    private func verdictTitle(_ verdict: BenchmarkVerdict) -> String {
        switch verdict {
        case let .faster(delta):
            return String(format: BenchmarkLocalization.string("Faster %@"), String(format: "%+.1f%%", delta * 100))
        case let .slower(delta):
            return String(format: BenchmarkLocalization.string("Slower %@"), String(format: "%+.1f%%", delta * 100))
        case .withinNoise:
            return BenchmarkLocalization.string("Within noise")
        case .unavailable:
            return BenchmarkLocalization.string("Not comparable")
        }
    }

    private func verdictIcon(_ verdict: BenchmarkVerdict) -> String {
        switch verdict {
        case .faster: return "arrow.up.right"
        case .slower: return "arrow.down.right"
        case .withinNoise: return "equal"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    private func qualityTitle(_ quality: BenchmarkQuality) -> String {
        switch quality {
        case .stable: return BenchmarkLocalization.string("Stable")
        case .fair: return BenchmarkLocalization.string("Fair")
        case .noisy: return BenchmarkLocalization.string("Noisy")
        }
    }

    private func qualityIcon(_ quality: BenchmarkQuality) -> String {
        switch quality {
        case .stable: return "checkmark.circle"
        case .fair: return "minus.circle"
        case .noisy: return "exclamationmark.triangle"
        }
    }

    private func modeTitle(_ mode: BenchmarkMode) -> String {
        mode == .deep
            ? BenchmarkLocalization.string("Deep test")
            : BenchmarkLocalization.string("Quick test")
    }

    private func readinessIcon(_ status: BenchmarkPreflight.Status) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    private func readinessColor(_ status: BenchmarkPreflight.Status) -> Color {
        switch status {
        case .ok: return theme.success
        case .warning: return theme.warning
        case .blocked: return theme.error
        }
    }

    private func powerTitle(_ source: BenchmarkEnvironment.PowerSource) -> String {
        switch source {
        case .adapter: return BenchmarkLocalization.string("Power adapter")
        case .battery: return BenchmarkLocalization.string("Battery")
        case .unknown: return "—"
        }
    }

    private func thermalTitle(_ state: BenchmarkEnvironment.ThermalState) -> String {
        switch state {
        case .nominal: return BenchmarkLocalization.string("Normal")
        case .fair: return BenchmarkLocalization.string("Fair")
        case .serious: return BenchmarkLocalization.string("Serious")
        case .critical: return BenchmarkLocalization.string("Critical")
        case .unknown: return "—"
        }
    }

    private func detailText(_ key: String, argument: String?) -> String {
        let base = BenchmarkLocalization.string(key)
        guard let argument else { return base }
        return String(format: base, argument)
    }

    private func formattedValue(_ value: Double) -> String {
        Self.valueFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    private static func testTitle(for testID: String) -> String {
        if testID.hasPrefix("cpu.scaling.") {
            return BenchmarkLocalization.string("CPU thread scaling")
        }
        switch testID {
        case "cpu.single": return BenchmarkLocalization.string("CPU single-core")
        case "cpu.multi": return BenchmarkLocalization.string("CPU multi-core")
        case "cpu.fp": return BenchmarkLocalization.string("CPU floating point")
        case "memory.write": return BenchmarkLocalization.string("Memory write")
        case "memory.copy": return BenchmarkLocalization.string("Memory copy")
        case "memory.read": return BenchmarkLocalization.string("Memory read")
        case "memory.random": return BenchmarkLocalization.string("Memory random access")
        case "disk.write": return BenchmarkLocalization.string("Disk write")
        case "disk.read": return BenchmarkLocalization.string("Disk read")
        case "disk.random.qd1", "disk.random.qd32": return BenchmarkLocalization.string("Disk random read")
        default: return testID
        }
    }

    private static func kind(for subtestID: String) -> BenchmarkKind? {
        if subtestID.hasPrefix("cpu.") { return .cpu }
        if subtestID.hasPrefix("memory.") { return .memory }
        if subtestID.hasPrefix("disk.") { return .disk }
        return nil
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let valueFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        return formatter
    }()
}

private extension BenchmarkKind {
    var title: String {
        switch self {
        case .cpu: return BenchmarkLocalization.string("CPU")
        case .memory: return BenchmarkLocalization.string("Memory")
        case .disk: return BenchmarkLocalization.string("Disk")
        }
    }

    var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        }
    }

    func color(in theme: any LumiUITheme) -> Color {
        switch self {
        case .cpu: return theme.info
        case .memory: return theme.success
        case .disk: return theme.warning
        }
    }
}
