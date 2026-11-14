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
- `SystemBenchmarkRunner`：仅在本机运行的 CPU、内存带宽、顺序磁盘读写测速（写入临时文件，结束后删除）。
- `SystemBenchmarkConfiguration`：允许宿主注入自己的插件 id；默认使用 Lumi 的 id，保证既有启用状态与数据目录稳定。

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
