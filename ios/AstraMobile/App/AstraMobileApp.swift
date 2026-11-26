import SwiftUI

@main
struct AstraMobileApp: App {
    @StateObject private var store = DesktopStore()
    @StateObject private var appState = AppState()
    @StateObject private var watchConfig = WatchConfigStore()

    init() {
        // 手表桥：尽早激活 WCSession（幂等），配置由 WatchConfigStore 初始化时推入
        WatchLink.shared.activate()
        // 模拟器端到端测试钩子（仅 DEBUG）：launch 参数覆盖已绑定桌面的 Keychain 密钥，
        // 须在首帧求值前执行，否则 DesktopRoot 会拿旧 secret 建 ShellStore。
        // 用法：simctl launch <sim> <bundle> -mockBindSecret <secret>
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-mockBindSecret"), i + 1 < args.count {
            let secret = args[i + 1]
            for d in store.desktops {
                KeychainStore.save(secret: secret, account: d.id)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(appState)
                .environmentObject(watchConfig)
                .onOpenURL { url in
                    DeepLink.handle(url, store: store)
                }
        }
    }
}

/// 全局 UI 状态（欢迎页与对话页工具条共享的入口开关）
@MainActor
final class AppState: ObservableObject {
    /// 扫码 sheet 是否弹出
    @Published var showScanner = false
}

/// 深链：astra://bind?url=<URL 编码后的入口 URL>
enum DeepLink {
    @MainActor
    static func handle(_ url: URL, store: DesktopStore) {
        guard url.scheme?.lowercased() == "astra",
              url.host?.lowercased() == "bind" else { return }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let encoded = items.first(where: { $0.name == "url" })?.value,
              let inner = encoded.removingPercentEncoding,
              let target = BindTarget.parse(inner) else { return }
        store.bind(target)
    }
}
