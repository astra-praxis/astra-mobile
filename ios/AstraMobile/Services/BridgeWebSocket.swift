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
        // 桥是局域网直连，绕过系统/WiFi 的 HTTP 代理（真机实证：全局代理会把
        // 局域网请求也送进代理，代理一挂桥就 -1004 Host is down）
        config.connectionProxyDictionary = [:]
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

    /// 单次带超时的探活：true=pong 正常回来（回前台探活 / 心跳共用）。
    /// 挂起后的半开 socket：ping 发得进去但 pong 永远不来，必须靠超时判死
    func ping(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard let task, !closed else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        let probe = PingProbe()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            probe.finish(alive: false, completion: completion)
        }
        task.sendPing(pongReceiveHandler: { error in
            probe.finish(alive: error == nil, completion: completion)
        })
    }

    /// 主动判死并通知重连链路。close() 是静默拆除（closed 置位后不再回调），
    /// 需要触发 onStateChange(false) → 重连时用这个
    func forceDisconnect() {
        closed = true
        pingTimer?.cancel()
        pingTimer = nil
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(false)
        }
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

    /// 与页面同一节奏的应用层心跳（20 秒）。pong 出错或超时即判死 → 通知重连。
    /// 息屏挂起后 socket 常半开（无 RST，receive 不报错），此前 pong 回调
    /// 直接忽略错误且无超时，永远发现不了——息屏回来“连不上”的根因
    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            self.ping(timeout: 5) { [weak self] alive in
                if !alive { self?.notifyDisconnected() }
            }
        }
        timer.resume()
        pingTimer = timer
    }
}

/// 探活一次性守卫：pong 回调与超时看门狗谁先到谁生效，双到不重复
private final class PingProbe {
    private let lock = NSLock()
    private var done = false
    func finish(alive: Bool, completion: @escaping (Bool) -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        guard first else { return }
        DispatchQueue.main.async { completion(alive) }
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
