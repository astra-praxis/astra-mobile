import SwiftUI

/// 「用户」入口（暂为设置 + 绑定信息；账号体系后续提供）
struct UserSheet: View {
    @EnvironmentObject var store: ShellStore
    @EnvironmentObject var desktops: DesktopStore
    @EnvironmentObject var appState: AppState

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
