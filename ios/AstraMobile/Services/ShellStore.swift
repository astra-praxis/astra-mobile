import Foundation
import SwiftUI

/// 壳的中心状态：连接、会话列表、队列、配置、当前会话与消息中心（MessageStore）。
/// 与页面遵循同一套行为规则（跟进 PC view、新对话发送后收养、运行状态），见协议文档。
@MainActor
final class ShellStore: ObservableObject {
    enum ConnState: Equatable {
        case connecting, connected, disconnected
    }

    enum OpenTarget: Equatable {
        case follow            // 默认态：跟随 PC 正在看的会话
        case new               // 新对话（主动新建，不再自动跟进）
        case session(String)   // 指定历史会话
    }

    @Published private(set) var connState: ConnState = .connecting
    @Published private(set) var sessions: [SessionMeta] = []
    @Published private(set) var queue: [QueueItem] = []
    @Published private(set) var config: BridgeConfig?
    @Published private(set) var openTarget: OpenTarget = .follow
    @Published private(set) var scopedSessionId: String?   // scope=one 时锁定
    @Published private(set) var runningSessionIds: Set<String> = []
    @Published private(set) var toast: String?
    @Published var showQueue = false
    @Published var showConfig = false
    @Published var senderName: String {
        didSet { UserDefaults.standard.set(senderName, forKey: "senderName.v1") }
    }
    /// 朗读开关：开启后当前会话 agent 回复完成时自动朗读
    @Published var ttsEnabled: Bool {
        didSet { UserDefaults.standard.set(ttsEnabled, forKey: "ttsEnabled.v1") }
    }

    /// 朗读器（顶栏开关控制；朗读中点按可停止本次）
    let tts = TTSReader()

    /// 消息中心：历史拉取 + 实时增量（AppShellView 环境注入）
    let messages: MessageStore

    let desktop: BoundDesktop
    private let secret: String
    private var ws: BridgeWebSocket?
    private var msgSeq = 0
    private var backoff: TimeInterval = 1
    private var reconnectTask: Task<Void, Never>?
    private var lastNewSendText: String?
    private var toastResetTask: Task<Void, Never>?
    private var didInitialOpen = false   // 仅首次 hello 自动打开 PC 当前会话；重连不拽走用户视图
    private(set) var pcCurrent: String?

    init(desktop: BoundDesktop, secret: String) {
        self.desktop = desktop
        self.secret = secret
        senderName = UserDefaults.standard.string(forKey: "senderName.v1") ?? "iPhone"
        ttsEnabled = UserDefaults.standard.bool(forKey: "ttsEnabled.v1")
        let baseURL = "\(desktop.scheme)://\(desktop.host):\(desktop.port)"
        self.messages = MessageStore(baseURL: baseURL, secret: secret)
        messages.onAssistantFinished = { [weak self] text in
            guard let self, self.ttsEnabled else { return }
            self.tts.speak(text)
        }
    }

    // MARK: - 派生状态

    var isScoped: Bool { scopedSessionId != nil }
    var isConnected: Bool { connState == .connected }

    /// 顶栏/抽屉用的当前会话标题
    var currentTitle: String {
        switch openTarget {
        case .session(let id):
            return sessions.first { $0.id == id }?.title ?? "会话"
        case .follow, .new:
            if let pc = pcCurrent, let s = sessions.first(where: { $0.id == pc }) {
                return s.title
            }
            return "新对话"
        }
    }

    var isRunningCurrent: Bool {
        let sid: String?
        switch openTarget {
        case .session(let id): sid = id
        case .follow, .new: sid = pcCurrent
        }
        guard let sid else { return false }
        return runningSessionIds.contains(sid)
    }

    var baseURL: String { "\(desktop.scheme)://\(desktop.host):\(desktop.port)" }

    // MARK: - 生命周期

    func start() {
        connect()
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        ws?.close()
        ws = nil
    }

    // MARK: - 动作

    /// 打开会话/新对话（MessageStore 负责拉历史或清空条目）
    func openSession(_ target: OpenTarget) {
        openTarget = target
        messages.open(target: target)
    }

    /// 发送消息进 PC（新对话时 session_id 传 null，PC 自动建会话）。
    /// PC 运行中时消息在 PC 侧自动进入队列（协议既定行为）
    @discardableResult
    func send(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        guard isConnected, let ws else {
            showToast("未连接到 PC，请稍候重试")
            return false
        }
        msgSeq += 1
        var command: [String: Any] = [
            "type": "send",
            "msg_id": msgSeq,
            "text": body,
            "sender": senderName,
        ]
        switch openTarget {
        case .session(let id): command["session_id"] = id
        case .follow, .new: command["session_id"] = NSNull()
        }
        if case .new = openTarget { lastNewSendText = body }
        sendCommand(command)
        return true
    }

    /// 工具调用权限裁决（手机页 permission_decide 同款命令）
    func permissionDecide(callId: String, decision: String) {
        sendCommand(["type": "permission_decide", "tool_call_id": callId, "decision": decision])
    }

    /// 回答 Agent 提问（手机页 question_answer 同款命令）
    func questionAnswer(questionId: String, answer: String) {
        sendCommand(["type": "question_answer", "question_id": questionId, "answer": answer])
    }

    func queueReorder(item: QueueItem, target: QueueItem, after: Bool) {
        sendCommand(["type": "queue_reorder", "id": item.id,
                     "target_id": target.id, "after": after])
    }

    func queueRemove(item: QueueItem) {
        sendCommand(["type": "queue_remove", "id": item.id])
    }

    func setThinking(enabled: Bool) {
        let effort = config?.thinkingEffort ?? "medium"
        sendCommand(["type": "set_thinking", "enabled": enabled, "effort": effort])
    }

    func setThinkingEffort(_ effort: String) {
        sendCommand(["type": "set_thinking", "enabled": true, "effort": effort])
    }

    func setModelPort(_ port: Int) {
        sendCommand(["type": "set_model", "source": "model", "port": port])
    }

    func setModelProvider(_ providerId: String) {
        sendCommand(["type": "set_model", "source": "provider", "provider_id": providerId])
    }

    func setOverrideModel(_ model: String) {
        guard let pid = config?.providerId else { return }
        sendCommand(["type": "set_model", "source": "provider", "provider_id": pid, "model": model])
    }

    func setAutoMode(_ mode: String) {
        sendCommand(["type": "set_auto_mode", "mode": mode])
    }

    func refreshSessions() {
        Task {
            if let list = try? await BridgeAPI.sessions(base: baseURL, secret: secret) {
                sessions = list
            }
        }
    }

    // MARK: - 连接管理

    private func connect() {
        connState = .connecting
        Task {
            do {
                let ticket = try await BridgeAPI.ticket(base: baseURL, secret: secret)
                ws?.close()  // 换新连接前先收掉旧的
                let socket = BridgeWebSocket(scheme: desktop.scheme, host: desktop.host, port: desktop.port)
                socket.onEvent = { [weak self] event in self?.handleEvent(event) }
                socket.onStateChange = { [weak self] open in
                    if !open { self?.handleDisconnected() }
                }
                ws = socket
                socket.connect(ticket: ticket)
            } catch {
                showToast("连接失败：\(error.localizedDescription)")
                scheduleReconnect()
            }
        }
    }

    private func handleDisconnected() {
        guard connState != .disconnected else { return }
        connState = .disconnected
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = backoff
        backoff = min(backoff * 2, 10)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func sendCommand(_ command: [String: Any]) {
        guard isConnected, let ws else {
            showToast("未连接到 PC，请稍候重试")
            return
        }
        ws.send(json: command) { [weak self] ok in
            DispatchQueue.main.async {
                if !ok { self?.showToast("发送失败，请稍候重试") }
            }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        toastResetTask?.cancel()
        toastResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - 事件处理（与页面 handleServer/trackRunning 同一套规则）

    private func handleEvent(_ event: ShellEvent) {
        switch event {
        case .hello(let sessions, let queue, let config, let current, let scope):
            self.sessions = sessions
            self.queue = queue
            self.config = config
            pcCurrent = current
            scopedSessionId = scope == "one" ? current : nil
            connState = .connected
            backoff = 1
            // 首次连接：停在默认态（follow）时自动打开 PC 当前会话（页面「收养」语义）
            if !didInitialOpen {
                didInitialOpen = true
                if case .follow = openTarget, let sid = current {
                    messages.openSession(sid)
                }
            }
        case .view(let sid):
            // 与页面同一规则：仅停在默认态（follow）时收养 PC 切换的会话；
            // 用户已显式选择（指定会话/新对话）时不拽走视图
            pcCurrent = sid
            if case .follow = openTarget {
                messages.openSession(sid)
            }
        case .queue(let items):
            queue = items
        case .config(let config):
            self.config = config
        case .toast(let text):
            showToast(text)
        case .runSettled(let sid):
            if let sid { runningSessionIds.remove(sid) }
            refreshSessions()  // 新会话首次落盘后让列表出现
        case .envelope(let env):
            handleEnvelope(env)
        case .question(let q):
            messages.applyQuestion(q)
        }
    }

    private func handleEnvelope(_ env: [String: Any]) {
        let sid = env["session_id"] as? String
        // 全量喂给消息中心（历史/流式渲染的唯一来源）
        messages.applyEnvelope(env)
        // 壳侧只额外维护「正在执行」与收养
        switch env["type"] as? String {
        case "message_delta", "thinking_delta", "tool_call_started",
             "tool_call_args_delta", "permission_requested", "status_changed":
            if let sid { runningSessionIds.insert(sid) }
        case "run_completed", "run_failed", "run_cancelled":
            if let sid { runningSessionIds.remove(sid) }
        case "user_message":
            // 新对话发送后的收养：PC 广播的 user_message 与本机最近一次发送文本匹配。
            // 此时消息中心还没该会话历史，envelope 已在其 pending 缓冲，切过去即回放
            if case .new = openTarget, let sid,
               let text = env["text"] as? String,
               text == lastNewSendText {
                lastNewSendText = nil
                openSession(.session(sid))
            }
        default:
            break
        }
    }
}
