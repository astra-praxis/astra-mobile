import SwiftUI

/// 原生消息流：全屏 ScrollView，内容从顶栏/输入条底下滚过（DeepSeek 式）。
/// 条目样式对齐 PC/手机页：全部左对齐全宽，用户/助手以配色区分。
struct ChatView: View {
    @EnvironmentObject var store: ShellStore
    @EnvironmentObject var messages: MessageStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    content.padding(.horizontal, 14)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                }
            }
            .onChange(of: messages.entries) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: messages.currentSessionId) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    scrollToBottom(proxy)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.openTarget == .new || (messages.currentSessionId == nil && store.openTarget == .follow && store.pcCurrent == nil) {
            emptyState(title: "新对话", sub: "发送第一条消息，PC 端会自动建立会话并开始执行。")
        } else if messages.loading {
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray5))
                        .frame(height: 14)
                        .frame(maxWidth: .infinity)
                        .opacity(0.5)
                        .scaleEffect(x: CGFloat(56 + (i % 3) * 14) / 100, anchor: .leading)
                }
            }
            .padding(.top, 20)
        } else if messages.loadFailed {
            emptyState(title: "历史加载失败", sub: "会话不可达或无权查看，可尝试重新进入。")
        } else if messages.entries.isEmpty {
            emptyState(title: "还没有消息", sub: "在下方输入框输入内容，直接发送到 PC 端。")
        } else {
            ForEach(messages.entries) { entry in
                EntryRow(entry: entry)
                    .id(entry.id)
            }
        }
    }

    private func emptyState(title: String, sub: String) -> some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: 120)
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(sub)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messages.entries.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
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

    // 用户消息：强调色浅底气泡（其余端同款布局：左对齐、配色区分）
    private var userRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sender = senderLabel {
                Label(sender.name, systemImage: sender.icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var senderLabel: (name: String, icon: String)? {
        if let sender = entry.sender {
            // 自己的消息不标来源（与手机页同规则）
            if sender == store.senderName { return nil }
            return (sender, "iphone")
        }
        return ("桌面端", "desktopcomputer")
    }

    // 助手消息：无底色全宽，Markdown 渲染 + 流式光标
    private var assistantRow: some View {
        HStack(alignment: .bottom, spacing: 2) {
            MarkdownText(text: entry.text)
                .textSelection(.enabled)
            if entry.streaming {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .opacity(0.8)
                    .modifier(BlinkModifier())
            }
        }
    }

    // 思考过程：折叠面板，流式中默认展开
    private var thinkingRow: some View {
        ThinkingBlock(entry: entry)
    }

    private var filesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("修改了 \(entry.files.count) 个文件", systemImage: "doc.text")
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var errorRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.red)
            Text(entry.text)
                .font(.footnote)
                .foregroundStyle(.red)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var noticeRow: some View {
        Text(entry.text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var terminalRow: some View {
        Text("— 本轮结束 —")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
    }
}

// MARK: - 思考块

private struct ThinkingBlock: View {
    let entry: ChatEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                    Text(entry.done ? "思考过程" : "思考中…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !entry.done {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(entry.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(Color(.secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 工具调用卡

struct ToolRow: View {
    let entry: ChatEntry
    @EnvironmentObject var store: ShellStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: toolIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(entry.toolName ?? "tool")
                    .font(.footnote.weight(.medium))
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
                      systemImage: state == "allow" ? "checkmark.circle" : "xmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch entry.status {
        case "running":
            ProgressView().controlSize(.mini)
        case "completed":
            Image(systemName: "checkmark").font(.system(size: 12)).foregroundStyle(.green)
        case "denied":
            Image(systemName: "hand.raised").font(.system(size: 12)).foregroundStyle(.orange)
        case "failed":
            Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(.red)
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
        VStack(alignment: .leading, spacing: 6) {
            Label("请求确认：\(summary)", systemImage: "lock")
                .font(.caption2)
                .foregroundStyle(.orange)
            HStack(spacing: 8) {
                Button("允许") { store.permissionDecide(callId: entry.callId ?? "", decision: "allow") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("拒绝", role: .destructive) { store.permissionDecide(callId: entry.callId ?? "", decision: "deny") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - 独立权限卡（tool 卡缺失时的兜底，与手机页 permission 条目同源）

struct PermissionCard: View {
    let entry: ChatEntry
    @EnvironmentObject var store: ShellStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(entry.toolName ?? "") 请求确认：\(entry.permSummary ?? "")", systemImage: "lock")
                .font(.footnote)
            HStack(spacing: 8) {
                Button("允许") { store.permissionDecide(callId: entry.callId ?? "", decision: "allow") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("拒绝", role: .destructive) { store.permissionDecide(callId: entry.callId ?? "", decision: "deny") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if let state = entry.permState {
                Text(state == "allow" ? "已允许" : "已拒绝")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 提问卡

struct QuestionCard: View {
    let entry: ChatEntry
    @EnvironmentObject var store: ShellStore
    @EnvironmentObject var messages: MessageStore
    @State private var freeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(entry.question ?? "", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.medium))
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
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
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
