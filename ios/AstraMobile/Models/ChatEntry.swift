import Foundation

// MARK: - 对话条目模型（与桌面端手机页同一套 kind/字段，见 mobile_bridge_mobile.html renderEntry）

/// 单条对话条目。字段按 kind 取用，用单一 struct + 可选字段避免多层枚举的样板代码
struct ChatEntry: Identifiable, Equatable {
    let id: UUID
    var kind: String

    // user / assistant / thinking / error / notice
    var text: String = ""
    var sender: String? = nil          // user：多设备同码时的来源标记
    var images: [Data] = []            // user：base64 PNG
    var streaming: Bool = false        // assistant：流式中
    var done: Bool = true              // thinking：是否已结束

    // tool / permission
    var callId: String? = nil
    var toolName: String? = nil
    var argsSummary: String? = nil
    var status: String? = nil          // tool: running | completed | failed | denied
    var result: String? = nil
    var permPending: Bool = false
    var permSummary: String? = nil
    var permState: String? = nil       // allow | deny

    // question
    var questionId: String? = nil
    var question: String? = nil
    var options: [String] = []
    var allowFreeText: Bool = false
    var answered: Bool = false
    var answer: String? = nil
    var declined: Bool = false

    // file_changes
    var files: [FileChange] = []

    struct FileChange: Equatable {
        let path: String
        let action: String
    }

    static func from(historyDict d: [String: Any]) -> ChatEntry? {
        guard let kind = d["kind"] as? String else { return nil }
        var e = ChatEntry(id: UUID(), kind: kind)
        e.text = d["text"] as? String ?? ""
        e.sender = d["sender"] as? String
        if let imgs = d["images"] as? [[String: Any]] {
            e.images = imgs.compactMap { img in
                (img["data"] as? String).flatMap { Data(base64Encoded: $0) }
            }
        }
        // 历史 assistant 不可能还在流式；thinking 一律视为已结束
        e.streaming = false
        e.done = true
        e.callId = d["callId"] as? String
        e.toolName = d["toolName"] as? String
        e.argsSummary = d["argsSummary"] as? String
        e.status = d["status"] as? String
        e.result = d["result"] as? String
        e.permPending = d["permPending"] as? Bool ?? false
        e.permSummary = d["permSummary"] as? String
        e.permState = d["permState"] as? String
        e.questionId = d["questionId"] as? String
        e.question = d["question"] as? String
        e.options = d["options"] as? [String] ?? []
        e.allowFreeText = d["allowFreeText"] as? Bool ?? false
        e.answered = d["answered"] as? Bool ?? false
        e.answer = d["answer"] as? String
        e.declined = d["declined"] as? Bool ?? false
        if let fs = d["files"] as? [[String: Any]] {
            e.files = fs.map {
                FileChange(path: ($0["path"] as? String) ?? ($0["file"] as? String) ?? "",
                           action: ($0["action"] as? String) ?? ($0["kind"] as? String) ?? "")
            }
        }
        return e
    }
}

// MARK: - 实时信封应用（对齐手机页 applyEnvelope；同一事件只在此处解释一次）

enum ChatEnvelope {

    /// 把一条 agent-event 载荷应用到会话条目列表。replay=true 表示「历史拉取后回放缓冲事件」，
    /// user_message 需向前扫描同文本条目防止与历史重复；实时事件直接追加（连发两条相同文本合法）
    static func apply(_ env: [String: Any], to list: inout [ChatEntry], replay: Bool) {
        let type = env["type"] as? String ?? ""
        switch type {
        case "user_message":
            // 用户消息镜像：PC 前端按下发送（pushUser）即广播，不等 Run 准入；
            // sender：多设备同码时标记来源。回放（历史+缓冲可能重叠）才向前扫描
            // 同文本条目防重复；实时事件直接追加——连发两条相同文本是合法消息
            let text = env["text"] as? String ?? ""
            var e = ChatEntry(id: UUID(), kind: "user")
            e.text = text
            e.sender = env["sender"] as? String
            if replay {
                for i in stride(from: list.count - 1, through: 0, by: -1) {
                    if list[i].kind == "user" {
                        if list[i].text == text { return }  // 历史里已有，跳过
                        list.append(e); return
                    }
                }
                list.append(e)
            } else {
                list.append(e)
            }

        case "message_delta":
            let delta = env["text"] as? String ?? ""
            if let last = list.last, last.kind == "assistant", last.streaming {
                list[list.count - 1].text += delta
            } else {
                var e = ChatEntry(id: UUID(), kind: "assistant")
                e.text = delta
                e.streaming = true
                list.append(e)
            }

        case "thinking_delta":
            let delta = env["text"] as? String ?? ""
            if var last = list.last, last.kind == "thinking", !last.done {
                last.text += delta
                list[list.count - 1] = last
            } else {
                var e = ChatEntry(id: UUID(), kind: "thinking")
                e.text = delta
                e.done = false
                list.append(e)
            }

        case "tool_call_args_delta":
            break  // 参数流式仅表示活跃；原生端不做参数逐字展示

        case "tool_call_started":
            let callId = env["tool_call_id"] as? String ?? ""
            // 覆盖骨架卡：若已有同 callId 条目先移除
            if let i = list.lastIndex(where: { $0.kind == "tool" && $0.callId == callId }) {
                list.remove(at: i)
            }
            var e = ChatEntry(id: UUID(), kind: "tool")
            e.callId = callId
            e.toolName = env["tool_name"] as? String ?? ""
            e.argsSummary = env["args_summary"] as? String ?? ""
            e.status = "running"
            list.append(e)

        case "tool_call_completed":
            patchTool(env["tool_call_id"] as? String ?? "", &list) { e in
                e.status = "completed"
                e.result = env["result_summary"] as? String ?? ""
            }

        case "tool_call_failed":
            let err = env["error"] as? String ?? ""
            patchTool(env["tool_call_id"] as? String ?? "", &list) { e in
                e.status = err.contains("拒绝") ? "denied" : "failed"
                e.result = err
            }

        case "permission_requested":
            let callId = env["tool_call_id"] as? String ?? ""
            patchTool(callId, &list) { e in
                e.permPending = true
                e.permSummary = env["summary"] as? String ?? ""
            }
            if !list.contains(where: { $0.kind == "tool" && $0.callId == callId }) {
                var e = ChatEntry(id: UUID(), kind: "permission")
                e.callId = callId
                e.toolName = env["tool_name"] as? String ?? ""
                e.permSummary = env["summary"] as? String ?? ""
                list.append(e)
            }

        case "permission_decided":
            let callId = env["tool_call_id"] as? String ?? ""
            let decision = env["decision"] as? String
            patchTool(callId, &list) { e in
                e.permPending = false
                e.permState = decision
            }
            for i in list.indices where list[i].kind == "permission" && list[i].callId == callId {
                list[i].permState = decision
            }

        case "run_completed", "run_cancelled":
            for i in list.indices where list[i].kind == "assistant" {
                list[i].streaming = false
            }
            for i in list.indices where list[i].kind == "thinking" {
                list[i].done = true
            }

        case "run_failed":
            for i in list.indices where list[i].kind == "assistant" {
                list[i].streaming = false
            }
            for i in list.indices where list[i].kind == "thinking" {
                list[i].done = true
            }
            var e = ChatEntry(id: UUID(), kind: "error")
            e.text = env["error"] as? String ?? "运行失败"
            list.append(e)

        case "compaction_completed":
            var e = ChatEntry(id: UUID(), kind: "notice")
            e.text = "上下文已压缩"
            list.append(e)

        default:
            break
        }
    }

    /// 收养问题事件（agent-question 广播；onQuestion 等价）
    static func question(from q: [String: Any]) -> ChatEntry? {
        guard let qid = q["question_id"] as? String else { return nil }
        var e = ChatEntry(id: UUID(), kind: "question")
        e.questionId = qid
        e.question = q["question"] as? String ?? ""
        e.options = q["options"] as? [String] ?? []
        e.allowFreeText = q["allow_free_text"] as? Bool ?? false
        return e
    }

    /// 收养后标记已回答（question_answer 的本地回显由 PC 广播 agent-question 更新，
    /// 若桥不回显则本地立即标记，避免按钮停留在可点状态）
    static func markAnswered(questionId: String, answer: String?, declined: Bool, in list: inout [ChatEntry]) {
        for i in list.indices where list[i].kind == "question" && list[i].questionId == questionId {
            list[i].answered = true
            list[i].answer = answer
            list[i].declined = declined
        }
    }

    private static func patchTool(_ callId: String, _ list: inout [ChatEntry], patch: (inout ChatEntry) -> Void) {
        guard !callId.isEmpty else { return }
        for i in stride(from: list.count - 1, through: 0, by: -1) {
            if list[i].kind == "tool" && list[i].callId == callId {
                patch(&list[i])
                return
            }
        }
    }
}
