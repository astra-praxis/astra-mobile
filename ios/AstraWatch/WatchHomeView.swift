import SwiftUI
import WatchKit

/// 手表主页：状态行 + 回复卡片（主角）+ 播报控制 + 麦克风（唯一强调色）。
/// 动效只回应动作：发送、展开、状态翻转；运行中呼吸点是唯一的自主动效。
struct WatchHomeView: View {
    @EnvironmentObject var link: WatchSessionModel
    @State private var expanded = false
    @State private var showInput = false
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if link.isUnconfigured {
                    unconfigured
                } else {
                    statusRow
                    replyCard
                    ttsBar
                    micButton
                    sendStatusText
                    detailLink
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: link.sendState)
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: link.ttsSpeaking)
        }
        .navigationTitle(link.sessionTitle ?? "Astra")
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showInput) {
            inputPanel
        }
    }

    // MARK: - 状态行

    private var statusRow: some View {
        HStack(spacing: 6) {
            LiveDot(active: link.running)
            Text(link.running ? "运行中" : "空闲")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            if let model = link.model {
                Text(model)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 回复卡片（主角）

    private var replyCard: some View {
        Group {
            if let reply = link.lastReply {
                Text(reply)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(4)
                    .lineLimit(expanded ? nil : 3)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("按下麦克风，说点什么")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Text("回复会出现在这里")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .glassCard()
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            guard link.lastReply != nil else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                expanded.toggle()
            }
        }
        .accessibilityHint("点按展开全文")
    }

    // MARK: - 播报控制

    @ViewBuilder
    private var ttsBar: some View {
        if link.lastReply != nil {
            HStack(spacing: 8) {
                if link.ttsSpeaking {
                    WaveformBars()
                }
                Spacer()
                Button {
                    link.ttsControl(link.ttsSpeaking ? "stop" : "replay")
                } label: {
                    Label(link.ttsSpeaking ? "停止" : "重播",
                          systemImage: link.ttsSpeaking ? "stop.fill" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PressableButtonStyle())
                .background(.white.opacity(0.10), in: Capsule())
                .padding(.horizontal, -6)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - 麦克风

    private var micButton: some View {
        Button {
            showInput = true
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.astraAccent)
                )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("说话")
    }

    // MARK: - 发送状态

    @ViewBuilder
    private var sendStatusText: some View {
        switch link.sendState {
        case .none:
            EmptyView()
        case .sent:
            statusBanner(icon: "checkmark.circle.fill", tint: .astraAccent, text: "已发送")
        case .queued:
            statusBanner(icon: "clock.fill", tint: .astraAccent, text: "已排队，稍后自动发送")
        case .failed(let reason):
            statusBanner(icon: "exclamationmark.circle.fill", tint: .red, text: reason)
        }
    }

    private func statusBanner(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .glassCard(radius: 12, interactive: false)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var detailLink: some View {
        NavigationLink {
            WatchDetailView()
        } label: {
            HStack {
                Text("最近回复")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.30))
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - 未配置

    private var unconfigured: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "applewatch")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.55))
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .background(Color.black.clipShape(Circle()).padding(-1))
            }
            Text("配置失效")
                .font(.system(size: 15, weight: .semibold))
            Text("请在 iPhone 的 Astra › 用户 › Apple Watch 里重新选择会话")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }

    // MARK: - 发送面板

    /// 发送面板：TextField 自带听写（键盘麦克风）；发送后回落主页
    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("发送到「\(link.sessionTitle ?? "专用会话")」")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            TextField("说点什么", text: $draft, axis: .vertical)
                .lineLimit(4)
                .padding(10)
                .background(.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 10) {
                Button {
                    link.send(draft)
                    draft = ""
                    showInput = false
                } label: {
                    Text("发送")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                      ? Color.astraAccent.opacity(0.35) : Color.astraAccent)
                        )
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    draft = ""
                    showInput = false
                } label: {
                    Text("取消")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(14)
        .presentationDetents([.fraction(0.55)])
        .presentationBackground(Color.black)
    }
}
