import SwiftUI

/// 底部原生输入条：发送走壳自持 WS 的 send 命令
struct InputBar: View {
    @EnvironmentObject var store: ShellStore

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if store.isRunningCurrent {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Agent 正在执行…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("发送消息到 PC…", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
                    .focused($focused)
                    .onSubmit(send)

                Button(action: send) {
                    if #available(iOS 26.0, *) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(
                                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color(.systemGray4)
                                    : Color.accentColor,
                                in: Circle()
                            )
                    }
                }
                .glassProminentButton()
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Text(hintText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 4)
        }
        .background(.bar)
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

// MARK: - 队列面板（原生）：同会话内排序 + 删除

struct QueueSheet: View {
    @EnvironmentObject var store: ShellStore

    var body: some View {
        NavigationStack {
            Group {
                if store.queue.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("队列为空")
                            .font(.headline)
                        Text("PC 运行中发送的消息会在这里排队，本轮结束后自动续发。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(Array(store.queue.enumerated()), id: \.element.id) { index, item in
                            QueueRow(item: item,
                                     canUp: index > 0 && store.queue[index - 1].sessionId == item.sessionId,
                                     canDown: index < store.queue.count - 1 && store.queue[index + 1].sessionId == item.sessionId,
                                     previous: index > 0 ? store.queue[index - 1] : nil,
                                     next: index < store.queue.count - 1 ? store.queue[index + 1] : nil)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("PC 发送队列")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let canUp: Bool
    let canDown: Bool
    let previous: QueueItem?
    let next: QueueItem?

    @EnvironmentObject var store: ShellStore

    private var sessionLabel: String {
        if item.sessionId.isEmpty { return "新对话" }
        return store.sessions.first { $0.id == item.sessionId }?.title ?? item.sessionId
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 6) {
                Button {
                    if let previous { store.queueReorder(item: item, target: previous, after: false) }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!canUp)

                Button {
                    if let next { store.queueReorder(item: item, target: next, after: true) }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(!canDown)
            }
            .font(.system(size: 13, weight: .medium))
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(sessionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let sender = item.sender {
                        Text(sender)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(item.text)
                    .font(.callout)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                store.queueRemove(item: item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
