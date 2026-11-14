# LumiPluginSystemBenchmark

📖 English | [中文版](README_zh.md)

Local system benchmark plugin for Lumi-family macOS apps.

> **Important rule: this plugin package must not depend on other plugin packages, and must not be depended on by other plugin packages.**
>
> Plugins communicate only through Provider contracts: shared capabilities go into `Provider*` / `Kit*` packages, assembled uniformly by the host (`Factory*`); cross-plugin references break independent plugin assembly and uninstallation.

## Package

- Product: `PluginSystemBenchmark`
- Platform: macOS 14+
- Swift tools: 6.0

## What It Provides

- `SystemBenchmarkPlugin`: registers a "System Benchmark" Activity Bar entry and injects the benchmark dashboard into the main window content.
- `SystemBenchmarkRunner`: local-only CPU, memory-bandwidth, and sequential disk benchmarks (writes a temporary file and removes it afterwards).
- `SystemBenchmarkConfiguration`: lets a host inject its own plugin id; defaults to Lumi's id so existing enable states and data directories stay stable.

The plugin is `disabledByDefault`; hosts expose it through their plugin manager.

## Dependencies and Integration

```swift
dependencies: [
    .package(url: "https://github.com/lumi-softworks/LumiPluginSystemBenchmark.git", from: "1.0.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: ["PluginSystemBenchmark"]),
]
```

Hosts must register an `ActivityBarProviding` (for example `DefaultActivityBarProviding`) before starting plugins; without it the plugin falls back to replacing the main content view directly.

## Testing

From this package directory:

```sh
swift test
```
