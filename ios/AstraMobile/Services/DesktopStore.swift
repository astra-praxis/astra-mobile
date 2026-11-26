import Foundation

/// 已绑定桌面端的注册表：元数据存 UserDefaults，secret 存 Keychain。
@MainActor
final class DesktopStore: ObservableObject {
    @Published private(set) var desktops: [BoundDesktop] = []
    @Published var currentID: String?

    private enum Keys {
        static let list = "boundDesktops.v1"
        static let current = "currentDesktop.v1"
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Keys.list),
           let list = try? JSONDecoder().decode([BoundDesktop].self, from: data) {
            desktops = list
        }
        let saved = UserDefaults.standard.string(forKey: Keys.current)
        currentID = (saved != nil && desktops.contains { $0.id == saved }) ? saved : nil
    }

    var current: BoundDesktop? {
        desktops.first { $0.id == currentID }
    }

    func bind(_ target: BindTarget) {
        KeychainStore.save(secret: target.secret, account: target.identifier)
        let now = Date()
        if let idx = desktops.firstIndex(where: { $0.id == target.identifier }) {
            desktops[idx].updatedAt = now
        } else {
            desktops.append(
                BoundDesktop(scheme: target.scheme,
                             host: target.host,
                             port: target.port,
                             addedAt: now,
                             updatedAt: now))
        }
        currentID = target.identifier
        persist()
    }

    func select(_ id: String) {
        guard desktops.contains(where: { $0.id == id }) else { return }
        currentID = id
        persist()
    }

    /// 删除绑定：Keychain 里的 secret 一并清除，手表侧绑定配置同步失效
    func remove(_ id: String) {
        KeychainStore.delete(account: id)
        desktops.removeAll { $0.id == id }
        if currentID == id { currentID = nil }
        persist()
        WatchLink.shared.updateBinding(scheme: nil, host: nil, port: nil, secret: nil)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(desktops) {
            UserDefaults.standard.set(data, forKey: Keys.list)
        }
        if let id = currentID {
            UserDefaults.standard.set(id, forKey: Keys.current)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.current)
        }
    }
}
