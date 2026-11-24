import SwiftUI

/// 底部悬浮玻璃输入卡：多行输入 + 浅色工具钮（卡内不嵌玻璃）+ 品牌渐变发送键。
/// 队列/新对话/模型与思考收在卡内左下（单手可达），发送在右下。
struct InputBar: View {
    @EnvironmentObject var store: ShellStore

    @State private var text = ""
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 7) {
            card
            Text(hintText)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    // MARK: - 输入卡

    private var card: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.isRunningCurrent {
                runningPill
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            TextField("发送消息到 PC…", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .focused($focused)
                .onSubmit(send)

            HStack(spacing: 8) {
                toolButton("square.stack.3d.up", badge: store.queue.isEmpty ? nil : "\(store.queue.count)") {
                    store.showQueue = true
                }
                .disabled(false)

                toolButton("plus.bubble") {
                    store.openSession(.new)
                }
                .disabled(store.isScoped)

                toolButton("slider.horizontal.3") {
                    store.showConfig = true
                }

                Spacer(minLength: 0)

                sendButton
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .padding(.bottom, 2)
        }
        .padding(8)
        .glassCard(cornerRadius: 26)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.isRunningCurrent)
    }

    /// 执行中指示：呼吸点胶囊（玻璃卡内部不嵌玻璃，用纯色胶囊）
    private var runningPill: some View {
        HStack(spacing: 7) {
            PulseDots()
            Text("Agent 正在执行，新消息进入队列")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12), in: Capsule())
        .padding(.leading, 4)
        .padding(.top, 4)
    }

    // MARK: - 工具钮 / 发送键

    /// 卡内工具钮：玻璃卡内部不嵌玻璃（官方规范），用浅色圆底 + 普通图标
    private func toolButton(_ system: String, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.7))
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.05), in: Circle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let badge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Color.red, in: Circle())
                    .offset(x: 7, y: -6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: store.queue.count)
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(
                    canSend ? AnyShapeStyle(GlassTokens.brandGradient) : AnyShapeStyle(Color(.systemGray3)),
                    in: Circle()
                )
                .shadow(color: canSend ? Color.accentColor.opacity(0.4) : .clear, radius: 9, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .scaleEffect(canSend ? 1 : 0.94)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: canSend)
    }

    // MARK: - 行为

    private var hintText: String {
        if store.connState == .disconnected { return "未连接，消息无法发送" }
        if store.isScoped { return "绑定会话模式：消息直接进入该会话" }
        if case .new = store.openTarget { return "新对话：发送后 PC 自动建立会话" }
        return "空闲：消息直接发送 · 运行中自动排队"
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if store.send(text) {
            text = ""
            focused = false
        }
    }
}
