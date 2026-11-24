import SwiftUI

/// 底部悬浮玻璃输入卡：多行输入 + 浅色工具钮（卡内不嵌玻璃）+ 品牌渐变发送键。
/// 队列/新对话/模型与思考收在卡内左下（单手可达），发送在右下。
/// 右侧语音/文字切换：语音模式输入区变为「按住说话」（Speech 实时转写，松手发送、上滑取消）。
struct InputBar: View {
    @EnvironmentObject var store: ShellStore

    @State private var text = ""
    @State private var voiceMode = false
    @State private var pressHint = ""
    @State private var pressCancelling = false
    @StateObject private var speech = SpeechRecorder()
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 7) {
            card
            Text(hintText)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    // MARK: - 输入卡

    private var card: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.isRunningCurrent {
                runningPill
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if voiceMode {
                pressToTalk
            } else {
                TextField("发送消息到 PC…", text: $text, axis: .vertical)
                    .lineLimit(1...8)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .frame(minHeight: 58, alignment: .topLeading)   // 空态也有两三行高度，文本顶对齐
                    .focused($focused)
                    .onSubmit(send)
                    .onChange(of: text) { newValue in
                        // 轴向 TextField 的回车是插换行、不触发 onSubmit：
                        // 检测到末尾换行即视为键盘快速发送（拼音组合中的回车会先上屏，不会误发）
                        guard newValue.hasSuffix("\n") else { return }
                        text = String(newValue.dropLast())
                        send()
                    }
            }

            HStack(spacing: 8) {
                toolButton("square.stack.3d.up", badge: store.queue.isEmpty ? nil : "\(store.queue.count)") {
                    store.showQueue = true
                }
                .disabled(false)

                toolButton("plus.bubble") {
                    store.openSession(.new)
                }
                .disabled(store.isScoped)

                toolButton("slider.horizontal.3") {
                    store.showConfig = true
                }

                Spacer(minLength: 0)

                if voiceMode {
                    modeSwitchButton(icon: "keyboard", label: "键盘")
                } else {
                    modeSwitchButton(icon: "mic", label: "语音")
                    sendButton
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .padding(.bottom, 2)
        }
        .padding(8)
        .glassCard(cornerRadius: 26)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.isRunningCurrent)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: voiceMode)
        .onAppear {
            #if DEBUG
            // 模拟器截图/调试钩子：启动直接进入语音模式
            if ProcessInfo.processInfo.arguments.contains("-mockVoiceMode") {
                voiceMode = true
            }
            #endif
            // 录音到 30 秒上限：自动收尾并发送已识别文本
            speech.onTimeout = {
                guard speech.recording else { return }
                Task {
                    let said = await speech.stopAndFinalize()
                    if !said.isEmpty {
                        store.send(said)
                    } else {
                        pressHint = "录音超时，没识别到内容"
                    }
                }
            }
        }
    }

    /// 执行中指示：呼吸点胶囊（玻璃卡内部不嵌玻璃，用纯色胶囊）
    private var runningPill: some View {
        HStack(spacing: 7) {
            PulseDots()
            Text("Agent 正在执行，新消息进入队列")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12), in: Capsule())
        .padding(.leading, 4)
        .padding(.top, 4)
    }

    // MARK: - 按住说话

    /// 语音模式输入区：按住录音、实时转写、松手发送、上滑取消
    /// （内容定高、shape 只作 background，避免贪婪铺满整卡）
    private var pressToTalk: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                if speech.recording && !pressCancelling {
                    Circle().fill(.red).frame(width: 7, height: 7)
                        .modifier(BlinkModifier())
                }
                Text(pressTitle)
                    .font(speech.recording && !speech.transcript.isEmpty && !pressCancelling ? .subheadline : .callout.weight(.medium))
                    .foregroundStyle(pressCancelling ? AnyShapeStyle(.red)
                                      : (speech.recording && !speech.transcript.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
            if speech.recording {
                Text("松手发送 · 上滑取消")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(speech.recording
                      ? (pressCancelling ? Color.red.opacity(0.16) : Color.red.opacity(0.10))
                      : Color.primary.opacity(0.05)))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .gesture(pressGesture)
    }

    private var pressTitle: String {
        if pressCancelling { return "松手取消" }
        if speech.recording { return speech.transcript.isEmpty ? "聆听中…" : speech.transcript }
        return pressHint.isEmpty ? "按住说话" : pressHint
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                if !speech.recording {
                    pressHint = ""
                    pressCancelling = false
                    Task {
                        await speech.start()
                        if !speech.recording, let reason = speech.unavailableReason {
                            pressHint = reason
                        }
                    }
                }
                pressCancelling = speech.recording && v.translation.height < -60
            }
            .onEnded { v in
                let cancel = v.translation.height < -60
                pressCancelling = false
                Task {
                    if cancel {
                        await speech.cancel()
                        pressHint = "已取消"
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        if pressHint == "已取消" { pressHint = "" }
                    } else {
                        let said = await speech.stopAndFinalize()
                        if !said.isEmpty {
                            store.send(said)
                            pressHint = ""
                        } else if let reason = speech.unavailableReason {
                            pressHint = reason
                        } else {
                            pressHint = "没听清，再试一次"
                        }
                    }
                }
            }
    }

    // MARK: - 工具钮 / 发送键

    /// 语音/文字模式切换钮：与工具钮同规格，收在卡内右下
    private func modeSwitchButton(icon: String, label: String) -> some View {
        Button {
            pressHint = ""
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                voiceMode.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(label)
                    .font(.system(size: 12, design: .rounded).weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.primary.opacity(0.7))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(speech.recording)   // 录音中不许切，避免状态打架
    }

    /// 卡内工具钮：玻璃卡内部不嵌玻璃（官方规范），用浅色圆底 + 普通图标
    private func toolButton(_ system: String, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.7))
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.05), in: Circle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let badge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Color.red, in: Circle())
                    .offset(x: 7, y: -6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: store.queue.count)
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(
                    canSend ? AnyShapeStyle(GlassTokens.brandGradient) : AnyShapeStyle(Color(.systemGray3)),
                    in: Circle()
                )
                .shadow(color: canSend ? Color.accentColor.opacity(0.4) : .clear, radius: 9, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .scaleEffect(canSend ? 1 : 0.94)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: canSend)
    }

    // MARK: - 行为

    private var hintText: String {
        if store.connState == .disconnected { return "未连接，消息无法发送" }
        if store.isScoped { return "绑定会话模式：消息直接进入该会话" }
        if case .new = store.openTarget { return "新对话：发送后 PC 自动建立会话" }
        return voiceMode ? "按住说话松手即发送 · 运行中自动排队" : "回车快速发送 · 运行中自动排队"
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if store.send(text) {
            text = ""
            // 不收键盘：保留焦点方便连续快速发送
        }
    }
}
