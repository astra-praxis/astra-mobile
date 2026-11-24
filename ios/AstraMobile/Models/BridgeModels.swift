import Foundation

// ===== 桥协议的数据模型与解析（全部来自壳自持 WS 的广播，见 docs/BINDING_PROTOCOL.md）=====

/// 会话元数据（/api/sessions 与 hello.sessions）
struct SessionMeta: Identifiable, Equatable {
    let id: String
    let title: String
    let projectName: String?
    let updatedAt: TimeInterval?

    var updatedAtDate: Date? {
        updatedAt.map { Date(timeIntervalSince1970: $0) }
    }
}

/// PC 发送队列条目（hello.queue / queue 事件）
struct QueueItem: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let text: String
    let sender: String?
}

/// 桥配置（hello.config / config 事件；set_model/set_thinking/set_auto_mode 的对象）
struct BridgeConfig: Equatable {
    struct RunningModel: Equatable {
        let port: Int
        let label: String
    }

    struct Provider: Equatable {
        let id: String
        let name: String
        let activeModel: String?
    }

    var sourceType: String?       // "model" | "provider"
    var modelPort: Int?
    var providerId: String?
    var overrideModel: String?
    var runningModels: [RunningModel]
    var providers: [Provider]
    var providerModels: [String]  // 当前 provider 的可选模型（name 或 id）
    var thinkingEnabled: Bool
    var thinkingEffort: String    // minimal | low | medium | high
    var autoMode: String          // off | project | workspace | all

    static let empty = BridgeConfig(
        sourceType: nil, modelPort: nil, providerId: nil, overrideModel: nil,
        runningModels: [], providers: [], providerModels: [],
        thinkingEnabled: false, thinkingEffort: "medium", autoMode: "off")

    static func parse(_ d: [String: Any]) -> BridgeConfig {
        let running = (d["running_models"] as? [Any] ?? []).compactMap { any -> RunningModel? in
            guard let m = any as? [String: Any],
                  let port = (m["port"] as? NSNumber)?.intValue else { return nil }
            return RunningModel(port: port, label: m["label"] as? String ?? "端口 \(port)")
        }
        let providers = (d["providers"] as? [Any] ?? []).compactMap { any -> Provider? in
            guard let p = any as? [String: Any],
                  let id = p["id"] as? String else { return nil }
            return Provider(id: id, name: p["name"] as? String ?? id,
                            activeModel: p["active_model"] as? String)
        }
        let pmodels = (d["provider_models"] as? [Any] ?? []).compactMap { any -> String? in
            guard let m = any as? [String: Any] else { return nil }
            return (m["name"] as? String) ?? (m["id"] as? String)
        }
        return BridgeConfig(
            sourceType: d["source_type"] as? String,
            modelPort: (d["model_port"] as? NSNumber)?.intValue,
            providerId: d["provider_id"] as? String,
            overrideModel: d["override_model"] as? String,
            runningModels: running,
            providers: providers,
            providerModels: pmodels,
            thinkingEnabled: d["thinking_enabled"] as? Bool ?? false,
            thinkingEffort: d["thinking_effort"] as? String ?? "medium",
            autoMode: d["auto_mode"] as? String ?? "off")
    }
}

/// 壳关心的事件子集（其余事件由 WebView 内的页面渲染）
enum ShellEvent {
    case hello(sessions: [SessionMeta], queue: [QueueItem], config: BridgeConfig?,
               current: String?, live: [[String: Any]], scope: String)
    case view(String)
    case queue([QueueItem])
    case config(BridgeConfig)
    case toast(String)
    case runSettled(String?)
    case envelope([String: Any])      // agent-event 载荷
    case question([String: Any])      // agent-question 载荷（提问/选项）

    static func parse(_ dict: [String: Any]) -> ShellEvent? {
        switch dict["type"] as? String {
        case "hello":
            return .hello(
                sessions: parseSessions(dict["sessions"] as? [Any] ?? []),
                queue: parseQueue(dict["queue"] as? [Any] ?? []),
                config: (dict["config"] as? [String: Any]).map(BridgeConfig.parse),
                current: dict["current"] as? String,
                live: (dict["live"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [],
                scope: dict["scope"] as? String ?? "all")
        case "view":
            return .view(dict["session_id"] as? String ?? "")
        case "queue":
            return .queue(parseQueue(dict["items"] as? [Any] ?? []))
        case "config":
            return .config((dict["config"] as? [String: Any]).map(BridgeConfig.parse) ?? .empty)
        case "toast":
            return .toast(dict["text"] as? String ?? "")
        case "run-settled":
            let sid = (dict["payload"] as? [String: Any])?["session_id"] as? String
            return .runSettled(sid)
        case "agent-event":
            return .envelope(dict["payload"] as? [String: Any] ?? [:])
        case "agent-question":
            return .question(dict["payload"] as? [String: Any] ?? [:])
        default:
            return nil  // pair/pong 等壳不关心
        }
    }

    static func parseSessions(_ arr: [Any]) -> [SessionMeta] {
        arr.compactMap { any in
            guard let d = any as? [String: Any], let id = d["id"] as? String else { return nil }
            return SessionMeta(
                id: id,
                title: d["title"] as? String ?? "未命名",
                projectName: d["project_name"] as? String,
                updatedAt: (d["updated_at"] as? NSNumber)?.doubleValue)
        }
    }

    static func parseQueue(_ arr: [Any]) -> [QueueItem] {
        arr.compactMap { any in
            guard let d = any as? [String: Any], let id = d["id"] as? String else { return nil }
            let sid = (d["sessionId"] as? String) ?? (d["session_id"] as? String) ?? ""
            let text = (d["text"] as? String) ?? (d["raw"] as? String) ?? ""
            return QueueItem(id: id, sessionId: sid, text: text, sender: d["sender"] as? String)
        }
    }
}
