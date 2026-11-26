import SwiftUI

/// 轻量详情：最近 10 条回复 + 模型信息 + 「在 iPhone 上打开」提示。
struct WatchDetailView: View {
    @EnvironmentObject var link: WatchSessionModel

    var body: some View {
        List {
            Section("会话") {
                LabeledRow(label: "专用会话", value: link.sessionTitle ?? "未配置")
                LabeledRow(label: "模型", value: link.model ?? "跟随桌面")
                LabeledRow(label: "状态", value: link.running ? "运行中" : "空闲")
                LabeledRow(label: "iPhone", value: link.phoneReachable ? "已连接" : "不在线")
            }
            if !link.history.isEmpty {
                Section("最近回复（\(link.history.count)）") {
                    ForEach(Array(link.history.enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(.system(size: 12))
                            .lineLimit(4)
                    }
                }
            }
            Section {
                Text("完整对话请在 iPhone 上打开 Astra")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("详情")
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
    }
}
