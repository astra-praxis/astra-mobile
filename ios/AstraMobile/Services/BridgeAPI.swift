import Foundation

enum BridgeError: LocalizedError {
    case auth
    case badPayload
    case forbidden
    /// 服务端带回了具体原因（401/429 响应体），优先展示
    case server(String)

    var errorDescription: String? {
        switch self {
        case .auth: return "凭证无效或已失效"
        case .badPayload: return "响应格式异常"
        case .forbidden: return "该设备未授权查看此会话"
        case .server(let msg): return msg
        }
    }
}

/// 桥的 HTTP API（壳侧只用两个：换票、会话列表；对话内容全在 WebView 页面里）
enum BridgeAPI {
    /// 桥是局域网直连，不走系统/WiFi 的 HTTP 代理：
    /// 空的 connectionProxyDictionary = 显式直连，避免代理挂了连带桥连不上
    /// （真机日志实证：WiFi 全局代理下 /api/ticket 被 172.x:7890 代理拉挂，-1004 Host is down）
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// 401/429 响应体携带服务端原因：PC 端 (status, message).into_response() 是纯文本，
    /// 兼容尝试 JSON {"message": ...}，失败则取纯文本；都拿不到再退回通用文案
    private static func rejectError(_ data: Data?, fallback: BridgeError) -> BridgeError {
        guard let data, !data.isEmpty else { return fallback }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["message"] as? String, !msg.isEmpty {
            return .server(msg)
        }
        if let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !msg.isEmpty {
            return .server(msg)
        }
        return fallback
    }
    /// POST /api/ticket：长期凭证换一次性短时效票据（WS 用，避免凭证进 URL）
    static func ticket(base: String, secret: String) async throws -> String {
        var request = URLRequest(url: URL(string: base + "/api/ticket")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw rejectError(data, fallback: .auth)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ticket = obj["ticket"] as? String else {
            throw BridgeError.badPayload
        }
        return ticket
    }

    /// GET /api/sessions：会话元数据（抽屉列表 + 搜索）
    static func sessions(base: String, secret: String) async throws -> [SessionMeta] {
        var request = URLRequest(url: URL(string: base + "/api/sessions")!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw rejectError(data, fallback: .auth)
        }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw BridgeError.badPayload
        }
        return ShellEvent.parseSessions(arr)
    }

    /// GET /api/session/:id：会话详情含 entries 条目流（历史对话原生渲染用）
    static func sessionDetail(id: String, base: String, secret: String) async throws -> [ChatEntry] {
        var request = URLRequest(
            url: URL(string: base + "/api/session/" + id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.auth }
        guard http.statusCode == 200 else {
            if http.statusCode == 403 { throw BridgeError.forbidden }
            throw rejectError(data, fallback: .auth)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["entries"] as? [Any] else {
            throw BridgeError.badPayload
        }
        return arr.compactMap { ($0 as? [String: Any]).flatMap(ChatEntry.from(historyDict:)) }
    }
}
