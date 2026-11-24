import SwiftUI

/// 应用主壳：全屏原生消息流 + 悬浮顶栏（仅菜单/状态）+ 悬浮输入卡（工具钮已收入卡内）
/// + 左抽屉。内容从顶栏与输入条底下滚过（DeepSeek 式 scroll-under）。
struct AppShellView: View {
    @EnvironmentObject var store: ShellStore
    @EnvironmentObject var appState: AppState

    @State private var drawerOpen = false

    var body: some View {
        ZStack(alignment: .leading) {
            ChatView()
                .safeAreaInset(edge: .top, spacing: 0) { topBar }
                .safeAreaInset(edge: .bottom, spacing: 0) { InputBar() }

            if drawerOpen {
                DrawerView(isOpen: $drawerOpen)
                    .transition(.move(edge: .leading))
                    .zIndex(2)
            }
        }
        .sheet(isPresented: $store.showQueue) { QueueSheet() }
        .sheet(isPresented: $store.showConfig) { ConfigSheet() }
        .overlay(alignment: .top) {
            if let msg = store.toast {
                Text(msg)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.toast)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    // MARK: - 悬浮顶栏：菜单 + 连接状态（队列/新对话/配置已移入输入卡）

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { drawerOpen = true }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17, weight: .medium))
            }
            .glassToolbarButton()

            HStack(spacing: 5) {
                Circle()
                    .fill(connColor)
                    .frame(width: 7, height: 7)
                Text(connText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var connColor: Color {
        switch store.connState {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        }
    }

    private var connText: String {
        switch store.connState {
        case .connected: return store.isScoped ? "已连接 · 绑定会话" : "已连接 · \(store.sessions.count) 个会话"
        case .connecting: return "连接中…"
        case .disconnected: return "未连接，重试中…"
        }
    }
}

// MARK: - 左抽屉：搜索 + 历史会话 + 底部用户入口

struct DrawerView: View {
    @EnvironmentObject var store: ShellStore
    @EnvironmentObject var appState: AppState
    @Binding var isOpen: Bool

    @State private var query = ""
    @State private var showUser = false

    private var filtered: [SessionMeta] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.sessions }
        return store.sessions.filter {
            ($0.title + " " + ($0.projectName ?? "")).lowercased().contains(q)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Text(store.sessions.isEmpty ? "暂无历史会话" : "没有匹配的会话")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List(filtered) { session in
                        sessionRow(session)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    }
                    .listStyle(.plain)
                }

                Divider()
                Button {
                    showUser = true
                } label: {
                    Label("用户", systemImage: "person.circle")
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            }
            .frame(width: 300)
            .frame(maxHeight: .infinity)
            .background(Color(.systemBackground))

            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showUser) { UserSheet() }
        .onAppear { store.refreshSessions() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("搜索历史对话", text: $query)
                .font(.body)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    private func sessionRow(_ session: SessionMeta) -> some View {
        Button {
            store.openSession(.session(session.id))
            close()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let project = session.projectName, !project.isEmpty {
                        Text(project)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let date = session.updatedAtDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if store.isRunningCurrent && session.id == currentSessionIdForMark {
                        Text("执行中")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var currentSessionIdForMark: String? {
        if case .session(let id) = store.openTarget { return id }
        return store.pcCurrent
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.22)) { isOpen = false }
    }
}
