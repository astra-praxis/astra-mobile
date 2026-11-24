import SwiftUI

/// 根视图：有选中的桌面端 → 应用主壳；否则 → 欢迎页（绑定入口）
struct RootView: View {
    @EnvironmentObject var store: DesktopStore
    @EnvironmentObject var appState: AppState
    @State private var bindError: String?

    var body: some View {
        Group {
            if let desktop = store.current,
               KeychainStore.load(account: desktop.id) != nil {
                DesktopRoot(desktop: desktop)
            } else {
                WelcomeView()
            }
        }
        .sheet(isPresented: $appState.showScanner) {
            ScanSheet()
        }
        .alert("无法绑定",
               isPresented: Binding(get: { bindError != nil },
                                    set: { if !$0 { bindError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(bindError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .bindFailed)) { notification in
            bindError = notification.object as? String ?? "二维码内容不是 Astra 绑定链接"
        }
    }
}

extension Notification.Name {
    static let bindFailed = Notification.Name("bindFailed")
}

/// 单个已绑定桌面的壳根：创建并持有该桌面的 ShellStore
struct DesktopRoot: View {
    @StateObject private var shell: ShellStore
    private let desktop: BoundDesktop

    init(desktop: BoundDesktop) {
        self.desktop = desktop
        let secret = KeychainStore.load(account: desktop.id) ?? ""
        _shell = StateObject(wrappedValue: ShellStore(desktop: desktop, secret: secret))
    }

    var body: some View {
        AppShellView()
            .environmentObject(shell)
            .environmentObject(shell.messages)
            .id(desktop.id)
    }
}

/// 扫码 sheet：识别成功即绑定并进入对话页
struct ScanSheet: View {
    @EnvironmentObject var store: DesktopStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScanView { code in
            if let target = BindTarget.parse(code) {
                store.bind(target)
                dismiss()
            } else {
                NotificationCenter.default.post(
                    name: .bindFailed,
                    object: "二维码内容不是 Astra 绑定链接：\n\(code)")
            }
        } onCancel: {
            dismiss()
        }
        .ignoresSafeArea()
    }
}
