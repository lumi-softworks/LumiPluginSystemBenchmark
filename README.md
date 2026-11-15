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
- `SystemBenchmarkRunner`: quick and deep local-only benchmarks with CPU (single/multi core, deep mode adds floating point and thread scaling), memory bandwidth (write/copy/read, deep mode adds random access), and disk throughput (1 GiB sequential, deep mode adds 4 KiB random reads at QD1/QD32). Disk tests write a temporary file and remove it afterwards.
- Measurement statistics: one warmup round is discarded, five timed rounds are measured (deep mode adds two), and each result reports the median, a bootstrapped 95% confidence interval, the coefficient of variation, and a quality band.
- Self-baseline performance index: the geometric mean of six core subtests relative to this Mac's first qualified run (baseline = 1000). Index comparisons respect a noise gate and require a comparable environment.
- Readiness checks: free disk space, power source, low power mode, thermal state, and background CPU load.
- History and export: the last 20 runs are kept in Application Support, isolated per host bundle id; reports export locally as JSON or Markdown.
- `SystemBenchmarkConfiguration`: lets a host inject its own plugin id; defaults to Lumi's id so existing enable states and data directories stay stable.

All measurements run locally; nothing is uploaded.

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
