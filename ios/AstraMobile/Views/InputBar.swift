import SwiftUI

/// 底部悬浮输入卡（DeepSeek 式）：玻璃圆角卡内含多行输入 + 工具钮 + 发送键。
/// 顶栏右侧的队列/新对话/配置全部收进这里（靠下拇指区，单手可达）。
struct InputBar: View {
    @EnvironmentObject var store: ShellStore

    @State private var text = ""
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            card
            Text(hintText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.isRunningCurrent {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Agent 正在执行，新消息进入队列")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .padding(.leading, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            TextField("发送消息到 PC…", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .focused($focused)
                .onSubmit(send)

            HStack(spacing: 6) {
                // 队列（带未读角标）
                Button {
                    store.showQueue = true
                } label: {
                    toolIcon("square.stack.3d.up", badge: store.queue.isEmpty ? nil : "\(store.queue.count)")
                }
                .glassToolbarButton()

                // 新对话
                Button {
                    store.openSession(.new)
                } label: {
                    toolIcon("plus.bubble")
                }
                .glassToolbarButton()
                .disabled(store.isScoped)

                // 模型与思考
                Button {
                    store.showConfig = true
                } label: {
                    toolIcon("slider.horizontal.3")
                }
                .glassToolbarButton()

                Spacer()

                // 发送键：卡内右下角
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            canSend ? Color.accentColor : Color(.systemGray3),
                            in: Circle()
                        )
                }
                .glassProminentButton()
                .disabled(!canSend)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private func toolIcon(_ system: String, badge: String? = nil) -> some View {
        Image(systemName: system)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary.opacity(0.75))
            .frame(width: 34, height: 34)
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Color.red, in: Circle())
                        .offset(x: 6, y: -5)
                }
            }
    }

    private var hintText: String {
        if store.connState == .disconnected { return "未连接，消息无法发送" }
        if store.isScoped { return "绑定会话模式：消息直接进入该会话" }
        if case .new = store.openTarget { return "新对话：发送后 PC 自动建立会话" }
        return "空闲：消息直接发送"
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
