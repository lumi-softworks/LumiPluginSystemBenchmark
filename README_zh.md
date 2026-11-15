# LumiPluginSystemBenchmark

📖 [English](README.md) | 中文版

Lumi 系 macOS App 的本地系统测速插件。

> **重要规则：本插件包不得依赖其它插件包，也不得被其它插件包依赖。**
>
> 插件之间只通过 Provider 契约通信：共享能力放进 `Provider*` / `Kit*` 包，由宿主（`Factory*`）统一装配；跨插件引用会破坏独立装配与卸载。

## 包信息

- Product：`PluginSystemBenchmark`
- 平台：macOS 14+
- Swift tools：6.0

## 提供的能力

- `SystemBenchmarkPlugin`：注册「系统测速」Activity Bar 入口，并把测速面板注入主窗口内容区。
- `SystemBenchmarkRunner`：仅在本机运行的快速 / 深度测速。CPU 覆盖单核与多核，深度模式增加浮点与线程扩展；内存覆盖写入、复制、读取，深度模式增加随机访问；磁盘覆盖 1 GiB 顺序读写，深度模式增加 4 KiB 随机读（QD1/QD32）。磁盘测试写入临时文件，结束后删除。
- 统计口径：丢弃一轮预热，记录五轮计时（深度模式再加两轮），每项给出中位数、自助法 95% 置信区间、变异系数与质量分档。
- 自基线性能指数：六项核心子测试相对本机首次合格运行的几何平均（基线 = 1000）。指数对比带噪声门槛，并要求运行环境可比。
- 开跑前检查：可用磁盘空间、电源、低电量模式、热状态、后台 CPU 负载。
- 历史与导出：按宿主 bundle id 隔离，在 Application Support 保留最近 20 次；报告可在本地导出为 JSON 或 Markdown。
- `SystemBenchmarkConfiguration`：允许宿主注入自己的插件 id；默认使用 Lumi 的 id，保证既有启用状态与数据目录稳定。

所有测量都在本机完成，不上传任何数据。

插件默认 `disabledByDefault`，由宿主的插件管理页决定何时启用。

## 依赖与接入

```swift
dependencies: [
    .package(url: "https://github.com/lumi-softworks/LumiPluginSystemBenchmark.git", from: "1.0.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: ["PluginSystemBenchmark"]),
]
```

宿主需在启动插件前注册 `ActivityBarProviding`（例如 `DefaultActivityBarProviding`）；没有 Activity Bar 的宿主会退化为直接替换主内容区。

## 测试

在本包目录执行：

```sh
swift test
```
