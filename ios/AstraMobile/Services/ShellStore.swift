import Foundation
import SwiftUI

/// 壳的中心状态：连接、会话列表、队列、配置、当前会话与消息中心（MessageStore）。
/// 状态模型与 web 手机页（mobile_bridge_mobile.html）完全同构：
/// - currentSessionId == nil 即「新对话」态（web 的 NEW）
/// - pickedNew：用户主动新建后不再自动跟进 PC 的 view
/// - pendingAdoptionText/At：从新对话发出的消息（剥过 /技能 前缀），60s 内文本精确匹配收养
/// - 消息不做本地回显：PC 前端按下发送即广播 user_message，气泡由广播驱动；toast 由 PC 权威下发
@MainActor
final class ShellStore: ObservableObject {
    enum ConnState: Equatable {
        case connecting, connected, disconnected
    }

    @Published private(set) var connState: ConnState = .connecting
    @Published private(set) var sessions: [SessionMeta] = []
    @Published private(set) var queue: [QueueItem] = []
    @Published private(set) var config: BridgeConfig?
    /// 当前查看的会话 id；nil = 新对话（web 的 current/NEW）
    @Published private(set) var currentSessionId: String?
    /// 用户主动点过「新对话」：true 时不再自动跟进 PC 的 view
    @Published private(set) var pickedNew = false
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
    private var secret: String
    private var ws: BridgeWebSocket?
    /// msg_id 设备内唯一前缀（持久化）：PC 端去重器按 msg_id 原值判重且 LRU 不随时间清空，
    /// 纯递增序号重启后从 1 重来，会撞上 web 手机页发过的 id 被静默丢弃
    private let msgClientId: String
    private var msgSeq = 0
    private var backoff: TimeInterval = 1
    private var reconnectTask: Task<Void, Never>?
    private var pendingAdoptionText: String?   // 新对话发出的消息文本（剥离后），收养匹配用
    private var pendingAdoptionAt = Date.distantPast
    private var toastResetTask: Task<Void, Never>?

    init(desktop: BoundDesktop, secret: String) {
        self.desktop = desktop
        self.secret = secret
        if let saved = UserDefaults.standard.string(forKey: "msgClientId.v1") {
            msgClientId = saved
        } else {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: "msgClientId.v1")
            msgClientId = fresh
        }
        senderName = UserDefaults.standard.string(forKey: "senderName.v1") ?? "iPhone"
        ttsEnabled = UserDefaults.standard.bool(forKey: "ttsEnabled.v1")
        let baseURL = "\(desktop.scheme)://\(desktop.host):\(desktop.port)"
        self.messages = MessageStore(baseURL: baseURL, secret: secret)
        messages.onAssistantFinished = { [weak self] text in
            guard let self, self.ttsEnabled else { return }
            self.tts.speak(text)
        }
        // pending 回放时同步运行状态（web 回放路径的 trackRunning）
        messages.onReplayEvent = { [weak self] env in
            guard let self, let sid = env["session_id"] as? String else { return }
            self.trackRunning(sid, env)
        }
    }

    // MARK: - 派生状态

    var isScoped: Bool { scopedSessionId != nil }
    var isConnected: Bool { connState == .connected }

    /// 顶栏/抽屉用的当前会话标题（web sessionLabel 语义）
    var currentTitle: String {
        guard let sid = currentSessionId else { return "新对话" }
        return sessions.first { $0.id == sid }?.title ?? "会话 " + String(sid.prefix(8))
    }

    var isRunningCurrent: Bool {
        guard let sid = currentSessionId else { return false }
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

    /// 重新扫码/换 key 后热更新凭证：断开旧连接、清退避，用新 secret 重连。
    /// 桌面项 id 不变（host:port），DesktopRoot 不会重建，secret 只能在这里换。
    func rebind(secret newSecret: String) {
        guard newSecret != secret else { return }
        stop()
        secret = newSecret
        messages.updateSecret(newSecret)
        backoff = 1
        connect()
    }

    // MARK: - 动作

    /// 打开指定历史会话（web openSession：pickedNew=false，拉历史 + 回放缓冲）
    func openSession(_ sid: String) {
        pickedNew = false
        currentSessionId = sid
        messages.openSession(sid)
    }

    /// 主动新建（web openSession(NEW)：pickedNew=true，PC 的 view 不再跟进）
    func openNew() {
        pickedNew = true
        currentSessionId = nil
        messages.openNew()
    }

    /// web adoptSession：清除收养等待态 → 切 current → 拉历史回放缓冲
    private func adoptSession(_ sid: String) {
        astraLog("adoptSession →", String(sid.prefix(8)))
        pendingAdoptionAt = .distantPast
        pendingAdoptionText = nil
        pickedNew = false
        currentSessionId = sid
        messages.openSession(sid)
    }

    /// 发送消息进 PC（web doSend 语义：仅「新对话」发 session_id=null 由 PC 建会话，
    /// 其余发当前会话 id）。PC 运行中时消息在 PC 侧自动进入队列（协议既定行为）；
    /// 气泡与发送结果 toast 均由 PC 广播/下发，本地不回显
    @discardableResult
    func send(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        guard isConnected, let ws else {
            astraLog("send ✗ 未连接 state:", connState, "ws:", ws != nil)
            showToast("未连接到 PC，请稍候重试")
            return false
        }
        astraLog("send current:", currentSessionId ?? "nil(新对话)",
                 "pickedNew:", pickedNew, "awaitingAdoption:", pendingAdoptionText != nil,
                 "text:", body)
        msgSeq += 1
        var command: [String: Any] = [
            "type": "send",
            "msg_id": "\(msgClientId)-\(msgSeq)",
            "text": body,
            "sender": senderName,
        ]
        command["session_id"] = currentSessionId ?? NSNull()
        // 新对话发送：记录剥离后的文本供收养匹配（web sentAt/sentText，发送成功才记录）
        let awaitingAdoption = currentSessionId == nil
        let adoptionText = stripSkillPrefix(body)
        sendCommand(command) { [weak self] ok in
            guard let self, ok, awaitingAdoption else { return }
            self.pendingAdoptionAt = Date()
            self.pendingAdoptionText = adoptionText
        }
        return true
    }

    /// 与 PC 同款正则剥掉 /技能 前缀（PC 广播的 user_message 文本是剥过的，
    /// 收养必须用同款预剥离才能精确匹配）
    private func stripSkillPrefix(_ text: String) -> String {
        guard text.hasPrefix("/") else { return text }
        let pattern = "^/[\\w\\u{4E00}-\\u{9FFF}.-]+(?:\\s+([\\s\\S]*))?$"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return "" }
        if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) {
            return text[r].trimmingCharacters(in: .whitespaces)
        }
        return ""
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
                astraLog("connect ✓ ticket.len", ticket.count, "base:", baseURL)
                ws?.close()  // 换新连接前先收掉旧的
                let socket = BridgeWebSocket(scheme: desktop.scheme, host: desktop.host, port: desktop.port)
                socket.onEvent = { [weak self] event in self?.handleEvent(event) }
                socket.onStateChange = { [weak self] open in
                    astraLog("connect onStateChange:", open)
                    if !open { self?.handleDisconnected() }
                }
                ws = socket
                socket.connect(ticket: ticket)
            } catch {
                astraLog("connect ✗ ticket 失败:", error.localizedDescription)
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

    private func sendCommand(_ command: [String: Any], onSent: ((Bool) -> Void)? = nil) {
        guard isConnected, let ws else {
            astraLog("sendCommand ✗ 未连接 type:", command["type"] as? String ?? "?")
            showToast("未连接到 PC，请稍候重试")
            onSent?(false)
            return
        }
        ws.send(json: command) { [weak self] ok in
            DispatchQueue.main.async {
                if !ok { self?.showToast("发送失败，请稍候重试") }
                onSent?(ok)
            }
        }
    }

    private func showToast(_ text: String) {
        astraLog("toast:", text)
        toast = text
        toastResetTask?.cancel()
        toastResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - 事件处理（与 web 手机页 handleServer/onEnvelope 同一套规则）

    private func handleEvent(_ event: ShellEvent) {
        switch event {
        case .hello(let sessions, let queue, let config, let current, let live, let scope):
            astraLog("hello ✓ sessions:", sessions.count, "queue:", queue.count,
                     "current:", current ?? "nil", "live:", live.count, "scope:", scope,
                     "| 本机 current:", currentSessionId ?? "nil",
                     "pickedNew:", pickedNew, "awaitingAdoption:", pendingAdoptionText != nil)
            self.sessions = sessions
            self.queue = queue
            self.config = config
            scopedSessionId = scope == "one" ? current : nil
            connState = .connected
            backoff = 1
            // mid-run 加入：进行中 Run 的实时事件进 pending 缓冲，
            // 打开/收养该会话时回放补看当前轮（磁盘历史缺当前轮）
            for env in live {
                guard let sid = env["session_id"] as? String, !sid.isEmpty else { continue }
                trackRunning(sid, env)
            }
            messages.bufferLive(live)
            // PC 正在看某个会话而本机停在「新对话」：跟进收养（web 同款条件——
            // 主动新建过或正在等收养时不劫持）
            if let sid = current, currentSessionId == nil,
               !pickedNew, pendingAdoptionText == nil {
                adoptSession(sid)
            }
            // 模拟器端到端测试钩子（仅 DEBUG）：连接后自动发送一条消息
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-mockAutoSend"), i + 1 < args.count {
                let text = args[i + 1]
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    self?.send(text)
                }
            }
            #endif
        case .view(let sid):
            // PC 切换会话：仅跟进停在「新对话」且未主动新建、未等收养的手机
            astraLog("view:", sid, "| 本机 current:", currentSessionId ?? "nil",
                     "pickedNew:", pickedNew, "awaitingAdoption:", pendingAdoptionText != nil)
            guard !sid.isEmpty else { return }
            if currentSessionId == nil, !pickedNew, pendingAdoptionText == nil {
                adoptSession(sid)
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

    /// web onEnvelope 语义：未初始化的会话先试收养（新对话发送的文本精确匹配），
    /// 事件一律进缓冲；已初始化的交给消息中心按 current/缓存路由
    private var envelopeDeltaCount = 0

    private func handleEnvelope(_ env: [String: Any]) {
        guard let sid = env["session_id"] as? String, !sid.isEmpty else { return }
        switch env["type"] as? String {
        case "message_delta", "thinking_delta", "tool_call_args_delta":
            envelopeDeltaCount += 1
            if envelopeDeltaCount % 20 == 1 {
                astraLog("envelope delta ×\(envelopeDeltaCount) sid:", String(sid.prefix(8)))
            }
        default:
            astraLog("envelope:", env["type"] as? String ?? "?", "sid:", String(sid.prefix(8)))
        }
        if !messages.isInitialized(sid),
           env["type"] as? String == "user_message",
           currentSessionId == nil,
           let sent = pendingAdoptionText,
           env["text"] as? String == sent,
           Date().timeIntervalSince(pendingAdoptionAt) < 60 {
            adoptSession(sid)
        }
        trackRunning(sid, env)
        messages.applyEnvelope(env)
    }

    /// web trackRunning：流式/工具事件 → 会话运行中；run 结束 → 清除
    private func trackRunning(_ sid: String, _ env: [String: Any]) {
        switch env["type"] as? String {
        case "message_delta", "thinking_delta", "tool_call_started",
             "tool_call_args_delta", "permission_requested", "status_changed":
            runningSessionIds.insert(sid)
        case "run_completed", "run_failed", "run_cancelled":
            runningSessionIds.remove(sid)
        default:
            break
        }
    }
}
