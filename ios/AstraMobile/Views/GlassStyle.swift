import SwiftUI

// MARK: - Liquid Glass 兼容层
// iOS 26+ 使用系统玻璃按钮；iOS 16~25 原样回退（调用处自带降级背景）。

extension View {
    /// 顶栏/工具条图标按钮：iOS 26+ 套玻璃胶囊样式，自带按压反馈
    @ViewBuilder
    func glassToolbarButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self
        }
    }

    /// 强调色玻璃按钮（发送/主操作）：iOS 26+ 用 glassProminent
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self
        }
    }
}
