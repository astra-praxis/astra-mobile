import Foundation

/// Apple Watch 配置：专用会话 + 模型偏好，UserDefaults 持久化，
/// 每次 save 推给 WatchLink 同步到手表。
@MainActor
final class WatchConfigStore: ObservableObject {
    @Published var sessionId: String?
    /// 缓存的会话标题（会话列表里没有它时展示用，比如刚被删）
    @Published private(set) var sessionTitle: String?
    /// 手表模型偏好；nil = 跟随桌面当前模型
    @Published var model: String?

    private enum Keys {
        static let sessionId = "watch.sessionId.v1"
        static let sessionTitle = "watch.sessionTitle.v1"
        static let model = "watch.model.v1"
    }

    init() {
        let d = UserDefaults.standard
        sessionId = d.string(forKey: Keys.sessionId)
        sessionTitle = d.string(forKey: Keys.sessionTitle)
        model = d.string(forKey: Keys.model)
        WatchLink.shared.updateConfig(sessionId: sessionId, title: sessionTitle, model: model)
    }

    /// 保存配置并同步到手表（设置页每改一项调用）
    func save(sessionId: String?, title: String?, model: String?) {
        self.sessionId = sessionId
        sessionTitle = title
        self.model = model
        let d = UserDefaults.standard
        if let sessionId {
            d.set(sessionId, forKey: Keys.sessionId)
        } else {
            d.removeObject(forKey: Keys.sessionId)
        }
        if let title {
            d.set(title, forKey: Keys.sessionTitle)
        } else {
            d.removeObject(forKey: Keys.sessionTitle)
        }
        if let model {
            d.set(model, forKey: Keys.model)
        } else {
            d.removeObject(forKey: Keys.model)
        }
        WatchLink.shared.updateConfig(sessionId: sessionId, title: title, model: model)
    }

    /// 配置的会话是否还存在于桌面会话列表（不存在 = 失效）
    func isValid(in sessions: [SessionMeta]) -> Bool {
        guard let sessionId else { return false }
        return sessions.contains { $0.id == sessionId }
    }
}
