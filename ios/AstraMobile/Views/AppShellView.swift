import SwiftUI

/// 应用主壳：环境光背景 + 全屏消息流 + 悬浮玻璃顶栏/输入卡 + 左侧负一屏。
/// 内容从顶栏与输入条底下滚过（scroll-under）。
/// 负一屏为进度驱动（0→1）：贴边全高、占屏宽 85%、与主界面同底色，
/// 与主屏等速推移（同一根弹簧，像两页相邻的纸推来推去，无暗化遮罩）：
/// 左缘右滑跟手拉出，露出的主屏右缘点按收起，松手按甩动意图/过半判定落点。
struct AppShellView: View {
    @EnvironmentObject var store: ShellStore
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    /// 负一屏进度 0(关)→1(开)：拖动中逐帧跟手，松手后弹簧落到端点
    @State private var drawerProgress: CGFloat = 0
    @State private var dragBase: CGFloat?
    @State private var dragHorizontal: Bool?

    var body: some View {
        GeometryReader { geo in
            let panelWidth = geo.size.width * 0.85
            ZStack {
                AmbientBackground()

                ZStack(alignment: .leading) {
                    // 主屏与负一屏等速推移：开 = 整体右移一个屏宽的 85%，像两页纸推来推去
                    mainContent
                        .offset(x: panelWidth * drawerProgress)

                    // 左缘手势条：屏幕左缘右滑，负一屏跟手拉出
                    Color.clear
                        .frame(width: 18)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(edgeDrag(width: panelWidth))
                        .allowsHitTesting(drawerProgress < 0.05)
                        .zIndex(1)

                    // 露出的主屏右缘：点按收起（负一屏盖住左侧，只有这条缝可点）
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { closeDrawer() }
                        .allowsHitTesting(drawerProgress > 0.05)
                        .zIndex(2)

                    // 负一屏常驻树：不随开合增删，保持 List 滚动位置与状态；
                    // 关闭时整体滑出屏外，点按命中随进度门控
                    DrawerView(isOpen: drawerIsOpen, width: panelWidth, progress: drawerProgress)
                        .simultaneousGesture(edgeDrag(width: panelWidth))   // 本体上左滑也能收（与 List 纵向滚动方向竞争）
                        .offset(x: (drawerProgress - 1) * panelWidth)
                        .allowsHitTesting(drawerProgress > 0.02)
                        .zIndex(3)
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
        .onAppear {
            store.start()
            #if DEBUG
            // 模拟器截图/调试钩子：启动直接展开负一屏
            if ProcessInfo.processInfo.arguments.contains("-mockOpenPanel") {
                drawerProgress = 1
                store.refreshSessions()
            }
            #endif
        }
        .onDisappear { store.stop() }
        .onChange(of: scenePhase) { phase in
            // 息屏/切走后回来：socket 可能被 iOS 挂起掐成半开且不报错，
            // 主动探活/重连（ShellStore.appDidBecomeActive）
            if phase == .active { store.appDidBecomeActive() }
        }
    }

    // MARK: - 抽屉手势与开合

    /// 同一根跟手拖拽：开（左缘条）、收（暗化层）、收（本体横向甩动）共用。
    /// 首帧判定横向轴，纵向拖动不劫持（负一屏内 List 照常滚动）。
    private func edgeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .global)
            .onChanged { updateDrag($0, width: width) }
            .onEnded { finishDrag($0, width: width) }
    }

    private func updateDrag(_ v: DragGesture.Value, width: CGFloat) {
        if dragBase == nil {
            dragBase = drawerProgress
            dragHorizontal = abs(v.translation.width) >= abs(v.translation.height)
        }
        guard dragHorizontal == true else { return }
        drawerProgress = min(1, max(0, (dragBase ?? 0) + v.translation.width / width))
    }

    private func finishDrag(_ v: DragGesture.Value, width: CGFloat) {
        defer {
            dragBase = nil
            dragHorizontal = nil
        }
        guard dragHorizontal == true else { return }
        // 甩动意图优先（预测位移超过阈值），否则看过没过半程
        let predicted = v.predictedEndTranslation.width
        let shouldOpen = abs(predicted) > 70 ? predicted > 0 : drawerProgress > 0.5
        withAnimation(.spring(response: 0.34, dampingFraction: 0.87)) {
            drawerProgress = shouldOpen ? 1 : 0
        }
        if shouldOpen { store.refreshSessions() }
    }

    private func openDrawer() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.87)) { drawerProgress = 1 }
        store.refreshSessions()
    }

    private func closeDrawer() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { drawerProgress = 0 }
    }

    /// DrawerView 只认 Bool：>0.5 视为开，置 false 即弹簧收起
    private var drawerIsOpen: Binding<Bool> {
        Binding(
            get: { drawerProgress > 0.5 },
            set: { if !$0 { closeDrawer() } })
    }

    private var mainContent: some View {
        ChatView()
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { InputBar() }
    }

    // MARK: - 悬浮玻璃顶栏：玻璃圆钮菜单 + 状态胶囊（同一 GlassEffectContainer，可融合/互变）

    private var topBar: some View {
        topBarRow
            .padding(.horizontal, 18)
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
                openDrawer()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 34, height: 34)
            }
            .glassToolbarButton()

            ttsButton

            Button {
                store.openNew()
            } label: {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 34, height: 34)
            }
            .glassToolbarButton()
            .disabled(store.isScoped)
            .opacity(store.isScoped ? 0.4 : 1)

            Spacer(minLength: 8)

            statusPill
        }
    }

    /// 朗读开关：关→开（agent 回复完成自动朗读）；朗读中点按停止本次；开→关
    private var ttsButton: some View {
        Button {
            if store.tts.speaking {
                store.tts.stop()
            } else if store.ttsEnabled {
                store.ttsEnabled = false
            } else {
                store.ttsEnabled = true
            }
        } label: {
            Image(systemName: store.ttsEnabled ? "speaker.wave.2" : "speaker.slash")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(topBarIconTint)
                .frame(width: 34, height: 34)
        }
        .glassToolbarButton()
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: store.ttsEnabled)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: store.tts.speaking)
    }

    private var topBarIconTint: Color {
        if store.tts.speaking { return .accentColor }
        return store.ttsEnabled ? .primary.opacity(0.85) : .primary.opacity(0.45)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connColor)
                .frame(width: 7, height: 7)
                .shadow(color: connColor.opacity(0.6), radius: 3)
            Text(connText)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassCapsule()
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
        case .connected: return store.isScoped ? "绑定会话" : "\(store.sessions.count) 个会话"
        case .connecting: return "连接中…"
        case .disconnected: return "未连接"
        }
    }
}

// MARK: - 左侧负一屏：贴边全高（占屏宽 85%），与主界面同底色（同一张壁纸），
// 右缘发丝线 + 投影分层；搜索 + 历史会话 + 用户入口

struct DrawerView: View {
    @EnvironmentObject var store: ShellStore
    @Binding var isOpen: Bool
    let width: CGFloat
    /// 负一屏进度（0→1）：发丝线/阴影随进度淡入淡出，关闭时不泄入主屏
    let progress: CGFloat

    @State private var query = ""
    @State private var showUser = false
    @State private var searchMode = false   // 搜索页：搜索框聚焦进入，返回按钮退出
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filtered: [SessionMeta] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.sessions }
        return store.sessions.filter {
            ($0.title + " " + ($0.projectName ?? "")).lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部：常规态只有搜索框；搜索态是返回按钮 + 搜索框
            HStack(spacing: 10) {
                if searchMode {
                    Button {
                        exitSearch()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 30, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                searchField
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: searchMode)

            if searchMode {
                searchPage
            } else {
                historyPage
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background {
            // 同一张环境光壁纸：负一屏与主界面共底色，像同一张屏的左右两页
            AmbientBackground()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 0.5)
                .opacity(Double(progress))   // 关闭时发丝线贴屏左缘，随进度淡出避免常驻
        }
        .shadow(color: .black.opacity(0.16 * Double(progress)), radius: 22, x: 8)   // 同理：关闭时阴影不泄入主屏
        .sheet(isPresented: $showUser) { UserSheet() }
        .onAppear {
            store.refreshSessions()
        }
        .onChange(of: isOpen) { open in
            if !open {
                searchFocused = false
                query = ""
                searchMode = false
            }
        }
        .onChange(of: searchFocused) { focused in
            guard focused, !searchMode else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { searchMode = true }
        }
    }

    /// 常规页：历史会话列表 + 用户入口
    private var historyPage: some View {
        VStack(spacing: 0) {
            Text("历史会话")
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 4)

            if filtered.isEmpty {
                emptyState(icon: "clock.arrow.circlepath",
                           text: store.sessions.isEmpty ? "暂无历史会话" : "没有匹配的会话")
            } else {
                sessionList(filtered)
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
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
    }

    /// 搜索页：聚焦即进入；空关键词显示引导，有关键词才搜历史记录
    @ViewBuilder
    private var searchPage: some View {
        if trimmedQuery.isEmpty {
            emptyState(icon: "text.magnifyingglass",
                       text: "搜索对话记录",
                       hint: "输入关键词查找会话标题与项目")
        } else if filtered.isEmpty {
            emptyState(icon: "questionmark.text.magnifyingglass",
                       text: "没有匹配的会话")
        } else {
            sessionList(filtered)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("搜索历史对话", text: $query)
                .font(.body)
                .submitLabel(.search)
                .focused($searchFocused)
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
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .glassCapsuleButton()
    }

    private func sessionList(_ sessions: [SessionMeta]) -> some View {
        List(sessions) { session in
            sessionRow(session)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func emptyState(icon: String, text: String, hint: String? = nil) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exitSearch() {
        searchFocused = false
        query = ""
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { searchMode = false }
    }

    private func sessionRow(_ session: SessionMeta) -> some View {
        let isCurrent = session.id == currentSessionIdForMark
        return Button {
            store.openSession(session.id)
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
        store.currentSessionId
    }

    private func close() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { isOpen = false }
    }
}
