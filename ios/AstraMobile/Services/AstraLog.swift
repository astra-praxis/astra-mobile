import Foundation
import os

/// 真机诊断日志：统一 `ASTRA:` 前缀 + 固定 subsystem。
/// 用 os.Logger（非 print）：Console.app 按 subsystem 过滤也能看到，
/// Xcode 控制台同样可见。public 隐私级保证动态内容不被脱敏。
/// 仅 DEBUG 构建生效，Release 编译为空。
private let bridgeLogger = Logger(subsystem: "io.astra.mobile", category: "bridge")

func astraLog(_ items: Any...) {
    #if DEBUG
    let line = items.map { "\($0)" }.joined(separator: " ")
    bridgeLogger.info("ASTRA: \(line, privacy: .public)")
    #endif
}
