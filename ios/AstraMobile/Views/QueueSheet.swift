import SwiftUI

/// PC 发送队列面板（原生）：同会话内排序 + 删除
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
