import Foundation
import SwiftUI

/// 会话消息中心：HTTP 拉历史 + WS 实时事件增量维护条目流。
/// 行为对齐桌面端手机页（openSession / applyEnvelope / pending 缓冲回放）：
/// - 未加载完成的会话先缓冲事件，历史到达后以 replay=true 回放（user_message 去重）
/// - 流式 delta 合并 150ms 节流发布，避免每个 delta 触发整列表 diff
@MainActor
final class MessageStore: ObservableObject {
    @Published private(set) var entries: [ChatEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var currentSessionId: String?   // nil = 新对话/未定

    private let baseURL: String
    private var secret: String

    /// 各会话已加载条目（切会话时免重复拉取；「正在执行」的另一会话也在维护）
    private var loadedEntries: [String: [ChatEntry]] = [:]
    /// 历史未到达前缓冲的事件载荷
    private var pending: [String: [[String: Any]]] = [:]
    /// 流式节流：工作副本 + 定时器
    private var working: [ChatEntry] = []
    private var flushTimer: Timer?
    private var loadGeneration = 0  // 防过期响应覆盖（快速切会话）
    /// 当前会话 run 完成时最后一条 assistant 的完整文本（供 TTS 朗读；历史回放不触发）
    var onAssistantFinished: ((String) -> Void)?

    init(baseURL: String, secret: String) {
        self.baseURL = baseURL
        self.secret = secret
    }

    /// 重新绑定（换 key）后同步新凭证，历史拉取继续可用
    func updateSecret(_ newSecret: String) {
        secret = newSecret
    }

    // MARK: - 打开会话

    func open(target: ShellStore.OpenTarget) {
        switch target {
        case .new:
            setCurrent(sessionId: nil, entries: [])
        case .session(let sid):
            openSession(sid)
        case .follow:
            break  // 由 ShellStore 在 hello/view 时以具体会话调 openSession
        }
    }

    func openSession(_ sid: String) {
        guard sid != currentSessionId else { return }
        loadGeneration += 1
        let gen = loadGeneration
        if let cached = loadedEntries[sid] {
            setCurrent(sessionId: sid, entries: cached)
            return
        }
        loading = true
        loadFailed = false
        entries = []
        currentSessionId = sid
        Task { [weak self] in
            guard let self else { return }
            do {
                let history = try await BridgeAPI.sessionDetail(id: sid, base: baseURL, secret: secret)
                guard gen == self.loadGeneration else { return }
                self.loadedEntries[sid] = history
                self.setCurrent(sessionId: sid, entries: history)
            } catch {
                guard gen == self.loadGeneration else { return }
                self.setCurrent(sessionId: sid, entries: [])
                self.loadFailed = true
            }
        }
    }

    private func setCurrent(sessionId: String?, entries: [ChatEntry]) {
        flushTimer?.invalidate()
        flushTimer = nil
        currentSessionId = sessionId
        working = entries
        self.entries = entries
        loading = false
        // 回放缓冲事件（历史与实时缓冲可能重叠：user_message 需去重）
        if let sid = sessionId, let buffered = pending.removeValue(forKey: sid) {
            for item in buffered {
                if item["type"] as? String == "__question", let q = item["__q"] as? [String: Any],
                   let entry = ChatEnvelope.question(from: q) {
                    working.append(entry)
                } else {
                    ChatEnvelope.apply(item, to: &working, replay: true)
                }
            }
            self.entries = working
        }
    }

    // MARK: - 实时事件

    /// agent-event 载荷（含 user_message / delta / tool / permission / run 结束等）
    func applyEnvelope(_ env: [String: Any]) {
        guard let sid = env["session_id"] as? String else { return }
        guard sid == currentSessionId, !loading else {
            if loading || loadedEntries[sid] == nil {
                pending[sid, default: []].append(env)
            } else if var cached = loadedEntries[sid] {
                // 非当前会话但已加载：后台维护缓存，切回时直接呈现
                ChatEnvelope.apply(env, to: &cached, replay: false)
                loadedEntries[sid] = cached
            }
            return
        }
        applyToCurrent(env, replay: false)
    }

    /// agent-question 广播（同 questionId 重复推送时原地更新，不追加重复卡）
    func applyQuestion(_ q: [String: Any]) {
        guard let sid = q["session_id"] as? String else { return }
        guard let entry = ChatEnvelope.question(from: q) else { return }
        let qid = entry.questionId
        func upsert(_ list: inout [ChatEntry]) {
            if let i = list.firstIndex(where: { $0.kind == "question" && $0.questionId == qid }) {
                list[i] = entry
            } else {
                list.append(entry)
            }
        }
        guard sid == currentSessionId, !loading else {
            if loading || loadedEntries[sid] == nil {
                pending[sid, default: []].append(["type": "__question", "__q": q])
            } else {
                if loadedEntries[sid] != nil { upsert(&loadedEntries[sid]!) }
            }
            return
        }
        upsert(&working)
        publishNow()
        if let sid = currentSessionId { loadedEntries[sid] = working }
    }

    private func applyToCurrent(_ env: [String: Any], replay: Bool) {
        let type = env["type"] as? String ?? ""
        let streamingTypes: Set = ["message_delta", "thinking_delta"]
        ChatEnvelope.apply(env, to: &working, replay: replay)
        if streamingTypes.contains(type) {
            scheduleFlush()
        } else {
            publishNow()
        }
        // 同步缓存
        if let sid = currentSessionId {
            loadedEntries[sid] = working
        }
        if type == "run_completed", let text = working.last(where: { $0.kind == "assistant" })?.text {
            onAssistantFinished?(text)
        }
    }

    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flushDelta() }
        }
    }

    private func flushDelta() {
        flushTimer = nil
        guard currentSessionId != nil else { return }
        entries = working
    }

    private func publishNow() {
        flushTimer?.invalidate()
        flushTimer = nil
        entries = working
    }

    // MARK: - 本地动作回显

    /// 发送成功后的本地回显：立即上屏并标 pending，PC 广播 user_message 时确认去重。
    /// targetSessionId 传 nil（follow/新对话）时上屏到当前视图；指定会话且非当前视图时只维护缓存
    func echoOutgoing(_ text: String, sender: String, targetSessionId: String?) {
        var e = ChatEntry(id: UUID(), kind: "user")
        e.text = text
        e.sender = sender
        e.pending = true
        if targetSessionId == nil || targetSessionId == currentSessionId {
            working.append(e)
            publishNow()
            if let sid = currentSessionId { loadedEntries[sid] = working }
            return
        }
        if var cached = loadedEntries[targetSessionId!] {
            cached.append(e)
            loadedEntries[targetSessionId!] = cached
        }
    }

    func markQuestionAnswered(questionId: String, answer: String?, declined: Bool) {
        ChatEnvelope.markAnswered(questionId: questionId, answer: answer, declined: declined, in: &working)
        publishNow()
        if let sid = currentSessionId { loadedEntries[sid] = working }
    }
}
