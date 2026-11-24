import Foundation

enum BridgeError: LocalizedError {
    case auth
    case badPayload
    case forbidden

    var errorDescription: String? {
        switch self {
        case .auth: return "凭证无效或已失效"
        case .badPayload: return "响应格式异常"
        case .forbidden: return "该设备未授权查看此会话"
        }
    }
}

/// 桥的 HTTP API（壳侧只用两个：换票、会话列表；对话内容全在 WebView 页面里）
enum BridgeAPI {
    /// POST /api/ticket：长期凭证换一次性短时效票据（WS 用，避免凭证进 URL）
    static func ticket(base: String, secret: String) async throws -> String {
        var request = URLRequest(url: URL(string: base + "/api/ticket")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeError.auth
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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeError.auth
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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.auth }
        guard http.statusCode == 200 else {
            if http.statusCode == 403 { throw BridgeError.forbidden }
            throw BridgeError.auth
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["entries"] as? [Any] else {
            throw BridgeError.badPayload
        }
        return arr.compactMap { ($0 as? [String: Any]).flatMap(ChatEntry.from(historyDict:)) }
    }
}
