import Foundation

/// 手表直连客户端：iPhone 不在身边时，用手表上同步的绑定配置
///（中继入口 + 设备密钥）自己换票、连桌面桥 WS。
/// 协议与手机端 BridgeAPI/BridgeWebSocket 一致：
/// POST /api/ticket（Bearer secret）→ wss://host:port/api/ws?ticket=…。
/// 桌面端把事件镜像给所有连接，手表是又一个客户端。
final class WatchDirectClient: NSObject {
    struct Binding: Equatable {
        let scheme: String
        let host: String
        let port: Int
        let secret: String
    }

    static let shared = WatchDirectClient()

    /// 事件回调（已在主线程）
    var onEvent: (([String: Any]) -> Void)?
    /// 连接断开回调（已在主线程）
    var onClosed: (() -> Void)?

    var isOpen: Bool { !closed }

    private var task: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var pingTimer: Timer?
    private var closed = true

    override private init() {
        super.init()
    }

    /// 换票并连接；已有连接时先静默拆除
    func open(_ binding: Binding) async throws {
        close()
        // 换票：长期凭证换一次性短时效票据（避免凭证进 URL）
        var req = URLRequest(url: URL(string: "\(binding.scheme)://\(binding.host):\(binding.port)/api/ticket")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(binding.secret)", forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [:]   // 桥直连，绕过系统/WiFi 代理（与手机端同因）
        config.timeoutIntervalForRequest = 15
        let http = URLSession(configuration: config)
        defer { http.finishTasksAndInvalidate() }
        let (data, response) = try await http.data(for: req)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ticket = obj["ticket"] as? String else {
            throw URLError(.badServerResponse)
        }
        // WS 连接
        let wsScheme = binding.scheme == "https" ? "wss" : "ws"
        guard let url = URL(string: "\(wsScheme)://\(binding.host):\(binding.port)/api/ws?ticket=\(ticket)") else {
            throw URLError(.badURL)
        }
        let ws = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        wsSession = ws
        let t = ws.webSocketTask(with: url)
        task = t
        closed = false
        t.resume()
        receive()
        startPing()
    }

    func send(json: [String: Any]) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8),
              let task else { return false }
        do {
            try await task.send(.string(text))
            return true
        } catch {
            return false
        }
    }

    func close() {
        let wasOpen = !closed
        closed = true
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        wsSession?.invalidateAndCancel()
        wsSession = nil
        task = nil
        if wasOpen {
            DispatchQueue.main.async { [weak self] in
                self?.onClosed?()
            }
        }
    }

    // MARK: - 私有

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    DispatchQueue.main.async { self.onEvent?(obj) }
                }
                self.receive()
            case .failure:
                DispatchQueue.main.async { self.close() }
            }
        }
    }

    /// 应用层心跳（20 秒）：挂起后的半开 socket 必须靠 pong 判死（手机端同款经验）
    private func startPing() {
        let timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, !self.closed, let task = self.task else { return }
            task.sendPing(pongReceiveHandler: { error in
                guard error != nil else { return }
                DispatchQueue.main.async {
                    self.close()
                }
            })
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }
}

extension WatchDirectClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol: String?) {}

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        DispatchQueue.main.async { self.close() }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if error != nil {
            DispatchQueue.main.async { self.close() }
        }
    }
}
