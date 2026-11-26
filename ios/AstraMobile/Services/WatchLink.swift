import Foundation
import WatchConnectivity

/// iPhone ⇄ Apple Watch 的 WCSession 桥。
/// 职责：
/// - 把手表配置（专用会话 + 模型名）通过 applicationContext 推给手表（watch 启动即读到）
/// - 接收手表的发送请求，转交 ShellStore 发往专用会话
/// - 专用会话的运行状态/最终回复转发给手表（reachable 用 sendMessage，否则落 applicationContext）
@MainActor
final class WatchLink: NSObject, ObservableObject {
    static let shared = WatchLink()

    @Published private(set) var isPaired = false
    @Published private(set) var isInstalled = false
    @Published private(set) var isReachable = false
    @Published private(set) var lastSyncAt: Date?
    /// 最近一次同步失败的描述（nil = 没有失败）
    @Published private(set) var syncError: String?

    /// 手表配置快照（由 WatchConfigStore 推入；转发事件时用它判断目标会话）
    private(set) var watchSessionId: String?
    private(set) var watchSessionTitle: String?
    private(set) var watchModel: String?

    /// 手表端发来的消息回调（ShellStore attach 后设置）
    private weak var shell: ShellStore?

    /// 专用会话的回复累积（message_delta 拼接，run 结束时发给手表）
    private var replyBuffer: String?
    private var replyRunning = false

    private var pendingContext: [String: Any] = [:]

    override private init() {
        super.init()
    }

    /// 激活 WCSession（幂等；App 启动时调用一次）
    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        if session.activationState != .activated {
            session.activate()
        }
        refreshDeviceState()
    }

    /// 更新手表配置并同步（WatchConfigStore 每次 save 后调用）
    func updateConfig(sessionId: String?, title: String?, model: String?) {
        watchSessionId = sessionId
        watchSessionTitle = title
        watchModel = model
        var context: [String: Any] = [
            "session_id": sessionId ?? "",
            "session_title": title ?? "",
            "model": model ?? "",
            "updated_at": Date().timeIntervalSince1970,
        ]
        // 保留未送达的回复（手表重进还能看到最后一条）
        if let last = pendingContext["last_reply"] { context["last_reply"] = last }
        if let lastState = pendingContext["run_state"] { context["run_state"] = lastState }
        pendingContext = context
        pushContext()
    }

    /// 手动触发一次重新同步（设置页按钮）
    func resync() {
        refreshDeviceState()
        pushContext()
    }

    private func refreshDeviceState() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        isPaired = s.isPaired
        isInstalled = s.isWatchAppInstalled
        isReachable = s.isReachable
    }

    private func pushContext() {
        guard WCSession.isSupported(), !pendingContext.isEmpty else { return }
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        do {
            try s.updateApplicationContext(pendingContext)
            lastSyncAt = Date()
            syncError = nil
        } catch {
            syncError = error.localizedDescription
            astraLog("watch 同步失败:", error.localizedDescription)
        }
    }

    /// 向手表发即时消息（不阻塞；失败静默落 applicationContext 兜底）
    private func sendToWatch(_ message: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isReachable else { return }
        s.sendMessage(message, replyHandler: nil) { error in
            Task { @MainActor in
                astraLog("watch sendMessage 失败:", error.localizedDescription)
            }
        }
    }

    // MARK: - 事件转发（ShellStore 调用）

    /// agent-event 载荷：只处理专用会话的，给手表拼紧凑状态
    func forwardEnvelope(_ env: [String: Any]) {
        guard let sid = env["session_id"] as? String, sid == watchSessionId,
              WCSession.isSupported() else { return }
        switch env["type"] as? String {
        case "message_delta":
            // 拼最终回复文本（手表只显示最后一条回复摘要）
            if let chunk = env["text"] as? String {
                replyBuffer = (replyBuffer ?? "") + chunk
            }
            if !replyRunning {
                replyRunning = true
                sendToWatch(["type": "run_state", "running": true])
            }
        case "run_completed":
            let reply = replyBuffer
            replyBuffer = nil
            replyRunning = false
            if let reply, !reply.isEmpty {
                pendingContext["last_reply"] = reply
                pendingContext["run_state"] = "idle"
                pushContext()
                sendToWatch(["type": "reply", "text": reply])
            } else {
                sendToWatch(["type": "run_state", "running": false])
            }
        case "run_failed", "run_cancelled":
            replyBuffer = nil
            replyRunning = false
            sendToWatch(["type": "run_state", "running": false])
        default:
            break
        }
    }

    // MARK: - 手表 → 手机

    private func handleWatchMessage(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "send":
            guard let text = message["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard let sid = watchSessionId else {
                sendToWatch(["type": "send_result", "ok": false, "reason": "unconfigured"])
                return
            }
            guard let shell else {
                sendToWatch(["type": "send_result", "ok": false, "reason": "not_connected"])
                return
            }
            let ok = shell.sendToWatchSession(sid, text: text)
            var result: [String: Any] = ["type": "send_result", "ok": ok]
            if !ok { result["reason"] = "not_connected" }
            sendToWatch(result)
        default:
            astraLog("watch 未知消息:", message["type"] as? String ?? "?")
        }
    }
}

// MARK: - WCSessionDelegate（回调在非主线程，统一切主线程）

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.refreshDeviceState()
            if let error {
                self.syncError = error.localizedDescription
            }
            self.pushContext()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// 必须在此（或 deactivate 完成）重新 activate，否则多表切换后桥失效
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.handleWatchMessage(message)
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshDeviceState()
        }
    }

    nonisolated func session(_ session: WCSession, didReachabilityChange reachabilityChanged: Bool) {
        Task { @MainActor in
            self.isReachable = reachabilityChanged
            if reachabilityChanged {
                // 手表重新可达：补推最新配置（applicationContext 之外的即时兜底）
                self.pushContext()
            }
        }
    }
}

// MARK: - ShellStore 挂接

extension WatchLink {
    /// ShellStore 创建后挂接（手表发送请求的落点）；桌面解绑时传 nil
    func attach(_ store: ShellStore?) {
        shell = store
    }
}
