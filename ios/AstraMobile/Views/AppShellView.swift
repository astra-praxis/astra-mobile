import SwiftUI

/// 应用主壳：环境光背景 + 全屏消息流 + 悬浮玻璃顶栏/输入卡 + 玻璃抽屉（推挤）。
/// 内容从顶栏与输入条底下滚过（scroll-under）。
struct AppShellView: View {
    @EnvironmentObject var store: ShellStore
    @EnvironmentObject var appState: AppState

    @State private var drawerOpen = false

    private let drawerWidth: CGFloat = 292
    private let pushFraction: CGFloat = 0.88

    var body: some View {
        ZStack {
            AmbientBackground()

            ZStack(alignment: .leading) {
                mainContent
                    .offset(x: drawerOpen ? drawerWidth * pushFraction : 0)
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: drawerOpen)
                    .scaleEffect(drawerOpen ? 0.985 : 1)
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: drawerOpen)

                if drawerOpen {
                    // 主内容上的暗化层（点按收抽屉）
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .onTapGesture { closeDrawer() }
                        .transition(.opacity)
                        .zIndex(1)

                    DrawerView(isOpen: $drawerOpen, width: drawerWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(2)
                }
            }
        }
        .sheet(isPresented: $store.showQueue) { QueueSheet() }
        .sheet(isPresented: $store.showConfig) { ConfigSheet() }
        .overlay(alignment: .top) {
            if let msg = store.toast {
                Label(msg, systemImage: "info.circle")
                    .font(.system(.footnote, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassCapsule()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.toast)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    private func closeDrawer() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { drawerOpen = false }
    }

    private var mainContent: some View {
        ChatView()
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { InputBar() }
    }

    // MARK: - 悬浮玻璃顶栏：玻璃圆钮菜单 + 状态胶囊（同一 GlassEffectContainer，可融合/互变）

    private var topBar: some View {
        topBarRow
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private var topBarRow: some View {
        if #available(iOS 26.0, *) {
            // container spacing < HStack spacing：静止不融合，靠近/动画时才融合
            GlassEffectContainer(spacing: 8) {
                topBarContent
            }
        } else {
            topBarContent
        }
    }

    private var topBarContent: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { drawerOpen = true }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 34, height: 34)
            }
            .glassToolbarButton()

            HStack(spacing: 6) {
                Circle()
                    .fill(connColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: connColor.opacity(0.6), radius: 3)
                Text(connText)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .glassCapsule()

            Spacer(minLength: 0)
        }
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
        case .disconnected: return "未连接，重试中"
        }
    }
}

// MARK: - 左抽屉：悬浮玻璃面板（搜索 + 历史会话 + 用户入口）

struct DrawerView: View {
    @EnvironmentObject var store: ShellStore
    @Binding var isOpen: Bool
    let width: CGFloat

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
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 14)
                .padding(.top, 16)

            Text("历史会话")
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
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
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Divider().opacity(0.5)
            Button {
                showUser = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                    Text("用户")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .glassCard(cornerRadius: 26, shadow: true)
        .padding(.leading, 10)
        .padding(.vertical, 10)
        .sheet(isPresented: $showUser) { UserSheet() }
        .onAppear { store.refreshSessions() }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
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
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }

    private func sessionRow(_ session: SessionMeta) -> some View {
        let isCurrent = session.id == currentSessionIdForMark
        return Button {
            store.openSession(.session(session.id))
            close()
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? AnyShapeStyle(GlassTokens.brandGradient) : AnyShapeStyle(Color(.systemGray4).opacity(0.5)))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: isCurrent ? "bubble.left.fill" : "bubble.left")
                            .font(.system(size: 13))
                            .foregroundStyle(isCurrent ? .white : .secondary)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let date = session.updatedAtDate {
                            Text(date, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if store.isRunningCurrent && isCurrent {
                            PulseDots().scaleEffect(0.7)
                            Text("执行中")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isCurrent ? Color.accentColor.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var currentSessionIdForMark: String? {
        if case .session(let id) = store.openTarget { return id }
        return store.pcCurrent
    }

    private func close() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { isOpen = false }
    }
}
