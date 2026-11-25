import Foundation

/// 壳自持的桥 WebSocket：发消息 / 队列操作 / 配置变更都在这条连接上；
/// 对话记录的渲染由 WebView 内页面自己的连接负责（桌面端把事件镜像给所有连接）。
final class BridgeWebSocket: NSObject {
    /// 事件回调（已在主线程）
    var onEvent: ((ShellEvent) -> Void)?
    /// 连接状态变化回调（已在主线程；true=socket 已打开，false=已断开）
    var onStateChange: ((Bool) -> Void)?

    private let scheme: String
    private let host: String
    private let port: Int
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: DispatchSourceTimer?
    private var closed = false

    init(scheme: String, host: String, port: Int) {
        self.scheme = scheme
        self.host = host
        self.port = port
        super.init()
    }

    /// 一次性票据只在连接时使用，重连必须重新换票（30 秒一次性）
    func connect(ticket: String) {
        closed = false
        let wsScheme = scheme == "https" ? "wss" : "ws"
        guard let url = URL(string: "\(wsScheme)://\(host):\(port)/api/ws?ticket=\(ticket)") else {
            astraLog("ws", "URL 构造失败", wsScheme, host, port)
            DispatchQueue.main.async { self.onStateChange?(false) }
            return
        }
        astraLog("ws", "connect →", url.host ?? "?", "port", port, "ticket.len", ticket.count)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = s
        let t = s.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
        startPing()
    }

    func close() {
        closed = true
        pingTimer?.cancel()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        session = nil
        task = nil
    }

    func send(json: [String: Any], completion: @escaping (Bool) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else {
            astraLog("ws send", "JSON 序列化失败")
            completion(false)
            return
        }
        astraLog("ws send →", text)
        task?.send(.string(text)) { error in
            if let error {
                astraLog("ws send ✗", error.localizedDescription)
            } else {
                astraLog("ws send ✓")
            }
            completion(error == nil)
        }
    }

    // MARK: - 私有

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.dispatch(text: text)
                case .data(let data):
                    self.dispatch(data: data)
                @unknown default:
                    break
                }
                self.receive()
            case .failure:
                self.notifyDisconnected()
            }
        }
    }

    private func dispatch(text: String) {
        dispatch(data: Data(text.utf8))
    }

    private func dispatch(data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            astraLog("ws recv ✗ 非 JSON", String(data: data.prefix(200), encoding: .utf8) ?? "?")
            return
        }
        let type = obj["type"] as? String ?? "?"
        guard let event = ShellEvent.parse(obj) else {
            astraLog("ws recv (parse nil) type:", type)
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    private func notifyDisconnected() {
        guard !closed else { return }
        astraLog("ws ✗ 断开（notifyDisconnected）")
        pingTimer?.cancel()
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(false)
        }
    }

    /// 与页面同一节奏的应用层心跳（20 秒）
    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            self.task?.sendPing(pongReceiveHandler: { _ in })
        }
        timer.resume()
        pingTimer = timer
    }
}

extension BridgeWebSocket: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol: String?) {
        astraLog("ws ✓ open protocol:", didOpenWithProtocol ?? "nil")
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(true)
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
        astraLog("ws close code:", closeCode.rawValue, "reason:", reasonText)
        notifyDisconnected()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            astraLog("ws complete(err)", (error as NSError).code, error.localizedDescription)
            notifyDisconnected()
        }
    }
}
