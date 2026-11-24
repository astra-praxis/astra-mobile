import SwiftUI

/// 原生消息流：全屏 ScrollView（内容从顶栏/输入条底下滚过）。
/// 设计点：首现弹性入场、接近底部才自动跟随、玻璃回底 FAB、hero 空状态。
struct ChatView: View {
    @EnvironmentObject var store: ShellStore
    @EnvironmentObject var messages: MessageStore

    @State private var seenIds: Set<UUID> = []   // 只对首次出现的条目播入场动画（滚动复用不重播）
    @State private var bottomGap: CGFloat = 0    // 内容底部距视口底部
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                scrollArea(proxy: proxy, viewport: outer)
            }
        }
    }

    private func scrollArea(proxy: ScrollViewProxy, viewport: GeometryProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                content
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                bottomSentinel
            }
        }
        .coordinateSpace(name: "chatSpace")
        .onAppear { viewportHeight = viewport.size.height }
        .onChange(of: viewport.size.height) { viewportHeight = $0 }
        .onPreferenceChange(ContentBottomKey.self) { bottomY in
            bottomGap = bottomY - viewportHeight
        }
        .onChange(of: messages.entries) { _ in autoScroll(proxy, force: false) }
        .onChange(of: messages.currentSessionId) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                autoScroll(proxy, force: true)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if bottomGap > 320 && !messages.entries.isEmpty {
                fab(proxy)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .padding(.trailing, 14)
                    .padding(.bottom, 96)   // 让出输入卡高度
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: bottomGap > 320)
    }

    private var bottomSentinel: some View {
        GeometryReader { geo in
            Color.clear
                .preference(key: ContentBottomKey.self,
                            value: geo.frame(in: .named("chatSpace")).maxY)
        }
        .frame(height: 1)
    }

    private func autoScroll(_ proxy: ScrollViewProxy, force: Bool) {
        guard let last = messages.entries.last else { return }
        guard force || bottomGap < 140 else { return }   // 用户上翻读历史时不拽走
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func fab(_ proxy: ScrollViewProxy) -> some View {
        Button {
            if let last = messages.entries.last {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.7))
                .glassCircle(size: 36)
                .glassMaterialize()
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内容分支

    @ViewBuilder
    private var content: some View {
        if isFreshNewChat {
            heroEmpty
        } else if messages.loading {
            loadingSkeleton
        } else if messages.loadFailed {
            emptyState(icon: "wifi.exclamationmark", title: "历史加载失败",
                       sub: "会话不可达或无权查看，可尝试重新进入。")
        } else if messages.entries.isEmpty {
            if store.isRunningCurrent {
                typingRow
            } else {
                emptyState(icon: "bubble.left.and.bubble.right", title: "还没有消息",
                           sub: "在下方输入框输入内容，直接发送到 PC 端。")
            }
        } else {
            ForEach(Array(messages.entries.enumerated()), id: \.element.id) { index, entry in
                row(entry, index: index)
            }
            if store.isRunningCurrent {
                typingRow
                    .padding(.top, -4)
            }
        }
    }

    private var isFreshNewChat: Bool {
        store.currentSessionId == nil   // web 语义：current 为 NEW/null 即新对话态
    }

    @ViewBuilder
    private func row(_ entry: ChatEntry, index: Int) -> some View {
        let isNew = !seenIds.contains(entry.id)
        if isNew {
            EntryRow(entry: entry)
                .id(entry.id)
                .modifier(AnimatedAppear(delay: min(Double(index) * 0.028, 0.18)))
                .onAppear { seenIds.insert(entry.id) }
        } else {
            EntryRow(entry: entry)
                .id(entry.id)
                .onAppear { seenIds.insert(entry.id) }
        }
    }

    /// Agent 执行中且还没有输出：呼吸点 + 「正在思考」
    private var typingRow: some View {
        HStack(spacing: 9) {
            PulseDots()
            Text("正在思考…")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCapsule()
    }

    private var heroEmpty: some View {
        VStack(spacing: 14) {
            Color.clear.frame(height: 90)
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(GlassTokens.brandGradient)
                .frame(width: 66, height: 66)
                .glassCircle(size: 66, interactive: false)
            Text("新的对话")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(GlassTokens.brandGradient)
            Text("发送第一条消息，PC 端会自动建立会话并开始执行")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }

    private var loadingSkeleton: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 15)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(x: CGFloat(52 + (i % 3) * 16) / 100, anchor: .leading)
                    .modifier(AnimatedAppear(delay: Double(i) * 0.08))
            }
        }
        .padding(.top, 24)
    }

    private func emptyState(icon: String, title: String, sub: String) -> some View {
        VStack(spacing: 12) {
            Color.clear.frame(height: 100)
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.quaternary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(sub)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 条件 ViewModifier（已内联到 ChatView.row 的 ViewBuilder 分支，保留空扩展占位）

private struct ContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - 单条条目

private struct EntryRow: View {
    let entry: ChatEntry
    @EnvironmentObject var store: ShellStore
    @EnvironmentObject var messages: MessageStore

    var body: some View {
        switch entry.kind {
        case "user": userRow
        case "assistant": assistantRow
        case "thinking": thinkingRow
        case "tool": ToolRow(entry: entry)
        case "permission": PermissionCard(entry: entry)
        case "question": QuestionCard(entry: entry)
        case "file_changes": filesRow
        case "error": errorRow
        case "notice": noticeRow
        case "terminal": terminalRow
        default: noticeRow
        }
    }

    // 用户消息：品牌渐变浅底气泡 + 来源徽标
    private var userRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let sender = senderLabel {
                Label(sender.name, systemImage: sender.icon)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.text)
                    .textSelection(.enabled)
                ForEach(Array(entry.images.enumerated()), id: \.offset) { _, data in
                    if let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(GlassTokens.userBubbleGradient,
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.accentColor.opacity(0.14), lineWidth: 0.5))
        }
    }

    private var senderLabel: (name: String, icon: String)? {
        if let sender = entry.sender {
            if sender == store.senderName { return nil }   // 自己的消息不标来源
            return (sender, "iphone")
        }
        return ("桌面端", "desktopcomputer")
    }

    // 助手消息：无底色全宽 + Markdown + 流式光标
    private var assistantRow: some View {
        HStack(alignment: .bottom, spacing: 3) {
            MarkdownText(text: entry.text)
                .textSelection(.enabled)
            if entry.streaming {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .modifier(BlinkModifier())
            }
        }
    }

    private var thinkingRow: some View {
        ThinkingBlock(entry: entry)
    }

    private var filesRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("修改了 \(entry.files.count) 个文件", systemImage: "doc.badge.clock")
                .font(.footnote.weight(.semibold))
            ForEach(Array(entry.files.prefix(6).enumerated()), id: \.offset) { _, f in
                Text(f.path + " · " + f.action)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if entry.files.count > 6 {
                Text("…等 \(entry.files.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground).opacity(0.65),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var errorRow: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
            Text(entry.text)
                .font(.footnote)
                .foregroundStyle(.red)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var noticeRow: some View {
        Text(entry.text)
            .font(.system(.caption2, design: .rounded))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var terminalRow: some View {
        HStack(spacing: 10) {
            Divider().opacity(0.4)
            Text("本轮结束")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Divider().opacity(0.4)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
    }
}

// MARK: - 思考块（折叠）

private struct ThinkingBlock: View {
    let entry: ChatEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                    Text(entry.done ? "思考过程" : "思考中…")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                    if !entry.done {
                        PulseDots().scaleEffect(0.7)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(entry.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glassCapsuleShape()
    }
}

// MARK: - 工具调用卡

struct ToolRow: View {
    let entry: ChatEntry
    @EnvironmentObject var store: ShellStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: toolIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text(entry.toolName ?? "tool")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                Text(entry.argsSummary ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                statusIcon
            }
            if let result = entry.result, !result.isEmpty {
                DisclosureGroup {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("结果")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if entry.permPending {
                permActions(summary: entry.permSummary ?? "")
            } else if let state = entry.permState {
                Label(state == "allow" ? "已允许" : "已拒绝",
                      systemImage: state == "allow" ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(state == "allow" ? .green : .red)
            }
        }
        .padding(11)
        .background(Color(.secondarySystemBackground).opacity(0.65),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch entry.status {
        case "running":
            ProgressView().controlSize(.mini)
        case "completed":
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
        case "denied":
            Image(systemName: "hand.raised").font(.system(size: 11)).foregroundStyle(.orange)
        case "failed":
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private var toolIcon: String {
        switch entry.toolName ?? "" {
        case "read_file", "write_file", "edit_file": return "doc.text"
        case "run_command", "terminal": return "terminal"
        case "search", "grep", "glob": return "magnifyingglass"
        default: return "wrench.and.screwdriver"
        }
    }

    private func permActions(summary: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("请求确认：\(summary)", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            HStack(spacing: 8) {
                Button {
                    store.permissionDecide(callId: entry.callId ?? "", decision: "allow")
                } label: {
                    Text("允许").font(.footnote.weight(.semibold))
                        .frame(minWidth: 52)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)

                Button {
                    store.permissionDecide(callId: entry.callId ?? "", decision: "deny")
                } label: {
                    Text("拒绝").font(.footnote.weight(.semibold))
                        .frame(minWidth: 52)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - 独立权限卡

struct PermissionCard: View {
    let entry: ChatEntry
    @EnvironmentObject var store: ShellStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("\(entry.toolName ?? "") 请求确认：\(entry.permSummary ?? "")", systemImage: "lock.fill")
                .font(.footnote)
            HStack(spacing: 8) {
                Button {
                    store.permissionDecide(callId: entry.callId ?? "", decision: "allow")
                } label: {
                    Text("允许").font(.footnote.weight(.semibold)).frame(minWidth: 52)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)

                Button {
                    store.permissionDecide(callId: entry.callId ?? "", decision: "deny")
                } label: {
                    Text("拒绝").font(.footnote.weight(.semibold)).frame(minWidth: 52)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let state = entry.permState {
                Text(state == "allow" ? "已允许" : "已拒绝")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

// MARK: - 提问卡

struct QuestionCard: View {
    let entry: ChatEntry
    @EnvironmentObject var store: ShellStore
    @EnvironmentObject var messages: MessageStore
    @State private var freeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(entry.question ?? "", systemImage: "questionmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(GlassTokens.brandGradient)
            if entry.answered || entry.declined {
                Text(entry.declined ? "已取消" : "已回答：\(entry.answer ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entry.options, id: \.self) { opt in
                        Button {
                            answer(opt)
                        } label: {
                            HStack {
                                Text(opt)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                            .background(Color(.tertiarySystemBackground).opacity(0.7),
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if entry.allowFreeText {
                    HStack(spacing: 8) {
                        TextField("自定义回答…", text: $freeText)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)
                        Button("发送") {
                            let t = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            answer(t)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.accentColor.opacity(0.18), lineWidth: 0.5))
    }

    private func answer(_ text: String) {
        store.questionAnswer(questionId: entry.questionId ?? "", answer: text)
        messages.markQuestionAnswered(questionId: entry.questionId ?? "", answer: text, declined: false)
    }
}

// MARK: - 流式光标闪烁

struct BlinkModifier: ViewModifier {
    @State private var visible = true
    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

// MARK: - 玻璃圆角面板（思考块等中小卡片的玻璃底）

extension View {
    @ViewBuilder
    func glassCapsuleShape() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }
}
