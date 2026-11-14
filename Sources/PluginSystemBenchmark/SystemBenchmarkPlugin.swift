import KernelCore
import ProviderActivityBar
import ProviderContentView
import ProviderRailView
import ProviderRootView
import ProviderToolbar
import SwiftUI

/// 宿主可注入的插件身份配置。
///
/// 默认保持 Lumi 的插件 id：Lumi 内的既有启用状态与数据目录不受影响；
/// 其它 App 传入自己的品牌 id，避免插件管理里的 id 与宿主其它插件不一致。
public struct SystemBenchmarkConfiguration: Sendable, Equatable {
    public let pluginID: String

    public init(pluginID: String = "com.coffic.lumi.plugin.system-benchmark") {
        self.pluginID = pluginID
    }

    public static let lumi = SystemBenchmarkConfiguration()
}

@MainActor
public final class SystemBenchmarkPlugin: SuperPlugin {
    public let id: String
    public let order = 7
    public let metadata: PluginMetadata

    private var viewModel: SystemBenchmarkViewModel?

    public init(configuration: SystemBenchmarkConfiguration = .lumi) {
        self.id = configuration.pluginID
        self.metadata = PluginMetadata(
            id: configuration.pluginID,
            name: BenchmarkLocalization.string("System Benchmark"),
            description: BenchmarkLocalization.string("Measure local CPU, memory, and disk performance."),
            category: .system,
            stage: .stable,
            policy: .disabledByDefault
        )
    }

    public func onBoot(kernel: KernelCoreContainer) throws {
        let viewModel = SystemBenchmarkViewModel()
        self.viewModel = viewModel

        let contentView = kernel.resolveProvider((any ContentViewProviding).self)
        let railView = kernel.resolveProvider((any RailViewProviding).self)
        let rootView = kernel.resolveProvider((any RootViewProviding).self)
        let toolbar = kernel.resolveProvider((any ToolbarProviding).self)
        if let activityBar = kernel.resolveProvider((any ActivityBarProviding).self) {
            let entryID = "\(id).entry"
            activityBar.addItems([
                ActivityBarItem(
                    id: entryID,
                    title: BenchmarkLocalization.string("System Benchmark"),
                    systemImage: "gauge.with.dots.needle.67percent",
                    order: order,
                    ownerPluginID: id
                ) { state in
                    if state == .activated {
                        toolbar?.setVisibleCategories([.global, .system])
                        contentView?.setContentView(AnyView(SystemBenchmarkView(viewModel: viewModel)))
                        rootView?.setRailView(nil)
                        rootView?.setContentHeaderViewHidden(true)
                    } else {
                        toolbar?.setVisibleCategories(Set(ToolbarItemCategory.allCases))
                        rootView?.setRailView(railView?.makeRailView())
                        rootView?.setRailViewVisible(railView?.hasVisibleTabs ?? false)
                        rootView?.setContentHeaderViewHidden(false)
                    }
                },
            ])
        } else {
            contentView?.setContentView(AnyView(SystemBenchmarkView(viewModel: viewModel)))
        }
    }

    public func onShutdown(kernel: KernelCoreContainer) throws {
        viewModel?.cancel()
        viewModel = nil

        let activityBar = kernel.resolveProvider((any ActivityBarProviding).self)
        activityBar?.removeItems(ids: ["\(id).entry"])

        let rootView = kernel.resolveProvider((any RootViewProviding).self)
        let railView = kernel.resolveProvider((any RailViewProviding).self)
        rootView?.setRailView(railView?.makeRailView())
        rootView?.setRailViewVisible(railView?.hasVisibleTabs ?? false)
        rootView?.setContentHeaderViewHidden(false)
        if activityBar == nil || activityBar?.activeItemID == nil {
            kernel.resolveProvider((any ContentViewProviding).self)?.setContentView(nil)
        }
    }
}
