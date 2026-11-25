import Foundation

/// 真机诊断日志：统一 `ASTRA:` 前缀，Xcode 控制台 / Console.app 按前缀过滤。
/// 仅 DEBUG 构建生效，Release 编译为空。
func astraLog(_ items: Any...) {
    #if DEBUG
    let line = items.map { "\($0)" }.joined(separator: " ")
    print("ASTRA:", line)
    #endif
}
