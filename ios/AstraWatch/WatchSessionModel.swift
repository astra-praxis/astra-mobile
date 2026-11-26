import Foundation
import WatchConnectivity

/// 手表端桥：iPhone 通过 applicationContext 推配置与状态，
/// 手表发送走 sendMessage。配置（专用会话 + 模型）由 iPhone 决定，手表不选模型。
@MainActor
final class WatchSessionModel: NSObject, ObservableObject {
    /// 发送结果文案状态
    enum SendState: Equatable {
        case none
        case sent          // 已发送
        case queued        // 已排队，当前任务结束后自动发送
        case failed(String)
    }

    @Published private(set) var sessionId: String?
    @Published private(set) var sessionTitle: String?
    @Published private(set) var model: String?
    @Published private(set) var running = false
    @Published private(set) var lastReply: String?
    @Published private(set) var ttsSpeaking = false
    @Published private(set) var sendState: SendState = .none
    /// 收到的最近回复（最多 10 条，新的在前）
    @Published private(set) var history: [String] = []
    @Published private(set) var phoneReachable = false

    private var lastConfigAt: TimeInterval = 0

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        applyContext(s.receivedApplicationContext)
    }

    // MARK: - 动作

    /// 发送到专用会话（语音转写后的文本）
    func send(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard sessionId != nil else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isReachable else {
            sendState = .failed("iPhone 不在线")
            return
        }
        // 发送语义（iPhone 侧裁决）：会话空闲 → 立即发送；运行中 → 仅排队
        sendState = running ? .queued : .sent
        s.sendMessage(["type": "send", "text": body], replyHandler: { [weak self] reply in
            Task { @MainActor in
                let ok = reply["ok"] as? Bool ?? false
                guard let self else { return }
                if !ok {
                    self.sendState = .failed("发送失败，请重试")
                } else {
                    self.sendState = self.running ? .queued : .sent
                }
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in
                self?.sendState = .failed("发送失败，请重试")
            }
        })
    }

    /// 播报控制：重播 / 停止（朗读由 iPhone 代劳）
    func ttsControl(_ action: String) {
        let s = WCSession.default
        guard s.activationState == .activated, s.isReachable else { return }
        s.sendMessage(["type": "tts", "action": action], replyHandler: nil, errorHandler: nil)
    }

    /// 语音输入改走主页输入面板：watchOS TextField 自带听写（键盘麦克风）
    func sendDraft(_ text: String) {
        send(text)
    }

    /// 配置是否失效（无会话）
    var isUnconfigured: Bool { sessionId == nil }

    private func applyContext(_ ctx: [String: Any]) {
        let updatedAt = ctx["updated_at"] as? TimeInterval ?? 0
        guard updatedAt >= lastConfigAt else { return }
        lastConfigAt = updatedAt
        let sid = ctx["session_id"] as? String
        sessionId = (sid?.isEmpty == true) ? nil : sid
        let title = ctx["session_title"] as? String
        sessionTitle = (title?.isEmpty == true) ? nil : title
        let m = ctx["model"] as? String
        model = (m?.isEmpty == true) ? nil : m
        let reply = ctx["last_reply"] as? String
        if let reply, !reply.isEmpty, lastReply != reply {
            lastReply = reply
            if !history.contains(reply) {
                history.insert(reply, at: 0)
                if history.count > 10 { history.removeLast(history.count - 10) }
            }
        }
        applyRunState(ctx["run_state"] as? String)
    }

    private func applyRunState(_ raw: String?) {
        switch raw {
        case "running": running = true
        case "idle": running = false
        default: break
        }
    }

    private func applyMessage(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "reply":
            if let text = message["text"] as? String, !text.isEmpty {
                lastReply = text
                running = false
                sendState = .none
                if !history.contains(text) {
                    history.insert(text, at: 0)
                    if history.count > 10 { history.removeLast(history.count - 10) }
                }
            }
        case "run_state":
            applyRunState((message["running"] as? Bool == true) ? "running" : "idle")
        case "tts_state":
            ttsSpeaking = message["speaking"] as? Bool ?? false
        case "send_result":
            if message["ok"] as? Bool != true {
                sendState = .failed("发送失败，请重试")
            }
        default:
            break
        }
    }
}

// MARK: - WCSessionDelegate（回调非主线程，统一切主线程）

extension WatchSessionModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.phoneReachable = session.isReachable
            if activationState == .activated {
                self.applyContext(session.receivedApplicationContext)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.applyContext(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.applyMessage(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReachabilityChange reachabilityChanged: Bool) {
        Task { @MainActor in
            self.phoneReachable = reachabilityChanged
        }
    }
}
