import SwiftUI

@main
struct AstraMobileApp: App {
    @StateObject private var store = DesktopStore()
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(appState)
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
