import SwiftUI

/// 轻量详情：会话信息 + 最近 10 条回复。与主页同一套玻璃语言，历史用
/// 发丝线分隔的引用式排版（不做卡片堆叠）。
struct WatchDetailView: View {
    @EnvironmentObject var link: WatchSessionModel

    var body: some View {
        List {
            Section {
                infoRow(label: "会话", value: link.sessionTitle ?? "未配置")
                infoRow(label: "模型", value: link.model ?? "跟随桌面")
                infoRow(label: "状态", value: link.running ? "运行中" : "空闲",
                        leading: { AnyView(LiveDot(active: link.running).frame(width: 7, height: 7)) })
                infoRow(label: "iPhone", value: link.phoneReachable ? "已连接" : "不在线")
            } header: {
                Text("专用会话")
            }

            if !link.history.isEmpty {
                Section {
                    ForEach(Array(link.history.enumerated()), id: \.offset) { idx, text in
                        Text(text)
                            .font(.system(size: 12))
                            .foregroundStyle(idx == 0 ? .white.opacity(0.85) : .white.opacity(0.55))
                            .lineLimit(4)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("最近回复 · \(link.history.count)")
                }
            }

            Section {
                Text("完整对话请在 iPhone 上打开 Astra")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("详情")
    }

    private func infoRow(label: String, value: String,
                         leading: (() -> AnyView)? = nil) -> some View {
        HStack(spacing: 6) {
            if let leading { leading() }
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .listRowBackground(Color.clear)
    }
}
