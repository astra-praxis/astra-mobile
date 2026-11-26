import SwiftUI

/// 手表主页：状态胶囊 + 最近回复卡片 + 播报控制条 + 大麦克风按钮。
/// 无模型选择页——模型在 iPhone 设置里配好共享过来。
struct WatchHomeView: View {
    @EnvironmentObject var link: WatchSessionModel
    @State private var expanded = false
    @State private var showInput = false
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                statusCapsule
                if link.isUnconfigured {
                    unconfigured
                } else {
                    replyCard
                    ttsBar
                    micButton
                    sendStatusText
                    NavigationLink {
                        WatchDetailView()
                    } label: {
                        Label("最近回复", systemImage: "list.bullet")
                            .font(.system(size: 12))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(link.sessionTitle ?? "Astra")
    }

    // MARK: - 子视图

    private var statusCapsule: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(link.running ? Color.green : Color.gray.opacity(0.6))
                .frame(width: 7, height: 7)
            Text(link.running ? "运行中" : "空闲")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if let model = link.model {
                Text(model)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.08), in: Capsule())
    }

    /// 配置失效提示（专用会话未配置/被删）
    private var unconfigured: some View {
        VStack(spacing: 8) {
            Image(systemName: "applewatch.questionmark")
                .font(.title2)
                .foregroundStyle(.red)
            Text("配置失效，请在 iPhone 上重新配置")
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
            Text("iPhone › 用户 › Apple Watch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    private var replyCard: some View {
        Group {
            if let reply = link.lastReply {
                Text(reply)
                    .font(.system(size: 14))
                    .lineLimit(expanded ? nil : 3)
                    .onTapGesture { expanded.toggle() }
            } else {
                Text("还没有回复。按下麦克风说点什么吧。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 播报控制条：有回复可重播；朗读中可停止
    @ViewBuilder
    private var ttsBar: some View {
        if link.lastReply != nil {
            HStack(spacing: 12) {
                Button {
                    link.ttsControl(link.ttsSpeaking ? "stop" : "replay")
                } label: {
                    Image(systemName: link.ttsSpeaking ? "stop.fill" : "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if link.ttsSpeaking {
                    Text("播报中")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var micButton: some View {
        Button {
            showInput = true
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(link.running ? .orange : .green)
        .sheet(isPresented: $showInput) {
            inputPanel
        }
    }

    /// 发送面板：watchOS TextField 自带听写（键盘麦克风），发送后回落主页
    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("发送到「\(link.sessionTitle ?? "专用会话")」")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("说点什么…", text: $draft, axis: .vertical)
                .lineLimit(4)
            HStack(spacing: 8) {
                Button("发送") {
                    link.send(draft)
                    draft = ""
                    showInput = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) {
                    draft = ""
                    showInput = false
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var sendStatusText: some View {
        switch link.sendState {
        case .none:
            EmptyView()
        case .sent:
            statusText("已发送", error: false)
        case .queued:
            statusText("已排队，当前任务结束后自动发送", error: false)
        case .failed(let reason):
            statusText("\(reason)", error: true)
        }
    }

    private func statusText(_ text: String, error: Bool) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(error ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
    }
}
