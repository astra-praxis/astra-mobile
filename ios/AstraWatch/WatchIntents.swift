import AppIntents
import WatchConnectivity

/// Siri 语音入口：「嘿 Siri，问 Astra ……」抬腕即说，无需点开 App。
/// watchOS 不允许第三方自定义唤醒词（后台不开放麦克风），Siri 意图是
/// 平台允许的语音唤醒正路：说完由 Siri 转写后直接经 WCSession 发给 iPhone。
struct AskAstraIntent: AppIntent {
    static var title: LocalizedStringResource = "问 Astra"
    static var description = IntentDescription("把一句话发给 iPhone 上的专用会话")

    @Parameter(title: "内容", requestValueDialog: "想对 Astra 说什么？")
    var text: String

    /// 后台执行，不打开界面
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = WCSession.default
        // App 进程可能由意图后台拉起，此时 UI 侧的 WatchSessionModel 尚未初始化，
        // 需要兜底激活 WCSession（已有 delegate 说明 App 在跑，直接复用）
        if session.delegate == nil {
            session.delegate = SiriBridgeDelegate.shared
            session.activate()
        }
        // 等激活（最多 2s）
        for _ in 0..<20 where session.activationState != .activated {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard session.activationState == .activated,
              session.isReachable else {
            return .result(dialog: "iPhone 不在身边，稍后再试")
        }
        let ok: Bool = await withCheckedContinuation { continuation in
            session.sendMessage(["type": "send", "text": text], replyHandler: { reply in
                continuation.resume(returning: reply["ok"] as? Bool ?? false)
            }, errorHandler: { _ in
                continuation.resume(returning: false)
            })
        }
        return .result(dialog: ok ? "已发送，回复会在 iPhone 上出现" : "发送失败，请打开 App 重试")
    }
}

/// Siri 快捷指令注册：抬腕说「嘿 Siri，问 Astra + 内容」即可发送
struct AstraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAstraIntent(),
            phrases: [
                "问\(.applicationName)",
                "\(.applicationName) 问一下",
                "告诉\(.applicationName)",
            ],
            shortTitle: "问 Astra",
            systemImageName: "applewatch"
        )
    }
}

/// 意图后台拉起时的 WCSession 兜底 delegate（只保活，收发逻辑仍归 UI 侧模型）
final class SiriBridgeDelegate: NSObject, WCSessionDelegate {
    static let shared = SiriBridgeDelegate()

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {}
}
