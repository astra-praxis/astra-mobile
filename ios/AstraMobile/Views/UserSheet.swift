import SwiftUI

/// 「用户」入口（暂为设置 + 绑定信息；账号体系后续提供）
struct UserSheet: View {
    @EnvironmentObject var store: ShellStore
    @EnvironmentObject var desktops: DesktopStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var watchConfig: WatchConfigStore

    @State private var confirmUnbind = false

    var body: some View {
        NavigationStack {
            Form {
                Section("绑定信息") {
                    LabeledRow(label: "桌面端", value: store.desktop.label)
                    LabeledRow(label: "设备密钥", value: fingerprint)
                    LabeledRow(label: "权限范围", value: scopeText)
                    LabeledRow(label: "连接", value: connText)
                }

                Section("设置") {
                    HStack {
                        Text("本机名称")
                        Spacer()
                        Text(store.senderName)
                            .foregroundStyle(.secondary)
                    }
                    Text("多设备扫同一码时，发送的消息会标注此名称。可在「模型与思考」面板修改。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("朗读音色", selection: $store.ttsVoice) {
                        ForEach(TTSReader.Voice.allCases) { voice in
                            Text(voice.label).tag(voice.rawValue)
                        }
                    }
                    Text("本机实际使用：\(resolvedVoiceName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        store.tts.speak("你好，这是当前朗读音色的试听。切换音色后再听一次，就能听出区别。")
                    } label: {
                        Label("试听当前音色", systemImage: "speaker.wave.2")
                    }
                } header: {
                    Text("朗读")
                } footer: {
                    Text("四款均为普通话，按本机已安装声音排列。想多几款：系统设置 › 辅助功能 › 朗读内容 › 声音 下载后回到这里即可选到。开启顶栏朗读开关后，agent 回复完成时自动朗读。")
                }

                Section {
                    Button {
                        appState.showScanner = true
                    } label: {
                        Label("重新扫码绑定", systemImage: "qrcode.viewfinder")
                    }
                    Button(role: .destructive) {
                        confirmUnbind = true
                    } label: {
                        Label("解除绑定（删除本机密钥）", systemImage: "link.badge.plus")
                    }
                }

                WatchSection()
            }
            .navigationTitle("用户")
            .navigationBarTitleDisplayMode(.inline)
            .alert("解除绑定？", isPresented: $confirmUnbind) {
                Button("解除", role: .destructive) {
                    desktops.remove(store.desktop.id)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除本机保存的设备密钥；桌面端密钥不受影响，可重新扫码绑定。")
            }
        }
    }

    private var resolvedVoiceName: String {
        guard let voice = TTSReader.Voice(rawValue: store.ttsVoice)?.resolve() else {
            return "默认"
        }
        return voice.name
    }

    private var fingerprint: String {
        guard let secret = KeychainStore.load(account: store.desktop.id) else { return "不可用" }
        guard secret.count > 12 else { return String(repeating: "•", count: secret.count) }
        let head = String(secret.prefix(8))
        let tail = String(secret.suffix(4))
        return "\(head)••••\(tail)"
    }

    private var scopeText: String {
        if let sid = store.scopedSessionId {
            let title = store.sessions.first { $0.id == sid }?.title ?? sid
            return "仅会话「\(title)」"
        }
        return "全部会话"
    }

    private var connText: String {
        switch store.connState {
        case .connected: return "已连接"
        case .connecting: return "连接中…"
        case .disconnected: return "未连接"
        }
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Apple Watch 配置区块：专用会话 + 模型偏好，改动即同步到手表。
/// 手表端无模型选择，模型偏好在这里选好共享过去。
private struct WatchSection: View {
    @EnvironmentObject var store: ShellStore
    @EnvironmentObject var watchConfig: WatchConfigStore
    @ObservedObject private var link = WatchLink.shared

    var body: some View {
        Section {
            Picker("专用会话", selection: sessionBinding) {
                Text("未配置").tag(String?.none)
                ForEach(sortedSessions) { session in
                    Text(session.title).tag(String?.some(session.id))
                }
                if let sid = watchConfig.sessionId,
                   !sortedSessions.contains(where: { $0.id == sid }) {
                    Text("\(watchConfig.sessionTitle ?? sid)（已失效）")
                        .tag(String?.some(sid))
                }
            }
            .pickerStyle(.menu)
            Picker("模型偏好", selection: modelBinding) {
                Text("跟随桌面当前").tag(String?.none)
                ForEach(store.config?.providerModels ?? [], id: \.self) { model in
                    Text(model).tag(String?.some(model))
                }
            }
            .pickerStyle(.menu)
            statusRow
            Toggle("回复完成自动朗读", isOn: announceBinding)
            Button {
                link.resync()
            } label: {
                Label("重新同步到手表", systemImage: "arrow.triangle.2.circlepath")
            }
        } header: {
            Label("Apple Watch", systemImage: "applewatch")
        } footer: {
            Text("手表发送固定到这个会话：空闲立即发送，运行中自动排队。模型偏好即桌面全局模型（手表端不选模型）。朗读由本机代劳，手表只控制重播/停止。")
        }
    }

    private var sortedSessions: [SessionMeta] {
        store.sessions.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    private var sessionBinding: Binding<String?> {
        Binding(
            get: { watchConfig.sessionId },
            set: { newId in
                let title = newId.flatMap { id in store.sessions.first { $0.id == id }?.title }
                watchConfig.save(sessionId: newId, title: title, model: watchConfig.model)
            })
    }

    /// 模型偏好：切换即同步改桌面全局模型（provider 来源时）
    private var modelBinding: Binding<String?> {
        Binding(
            get: { watchConfig.model },
            set: { newModel in
                watchConfig.save(sessionId: watchConfig.sessionId,
                                 title: watchConfig.sessionTitle,
                                 model: newModel)
                if let newModel, store.config?.sourceType == "provider" {
                    store.setOverrideModel(newModel)
                }
            })
    }

    private var announceBinding: Binding<Bool> {
        Binding(
            get: { watchConfig.announce },
            set: { newValue in
                watchConfig.save(sessionId: watchConfig.sessionId,
                                 title: watchConfig.sessionTitle,
                                 model: watchConfig.model,
                                 announce: newValue)
            })
    }

    @ViewBuilder
    private var statusRow: some View {
        if !link.isPaired || !link.isInstalled {
            HStack {
                Text("手表")
                Spacer()
                Text(link.isPaired ? "未安装 App" : "未配对")
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Text("同步")
                Spacer()
                if let error = link.syncError {
                    Text("失败：\(error)").foregroundStyle(.red).lineLimit(1)
                } else if let at = link.lastSyncAt {
                    Text(at.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                } else {
                    Text("待同步").foregroundStyle(.secondary)
                }
            }
        }
    }
}
