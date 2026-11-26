import PhotosUI
import SwiftUI

/// 底部悬浮玻璃输入卡：多行输入 + 浅色工具钮（卡内不嵌玻璃）+ 品牌渐变发送键。
/// 队列/新对话/模型与思考收在卡内左下（单手可达），发送在右下。
/// 右侧语音/文字切换：语音模式输入区变为「按住说话」（Speech 实时转写，松手发送、上滑取消）。
/// 加号入口：发图片/文件到 PC（图片 PC 端归一化，文件 PC 端落盘粘贴目录）；
/// 以及浏览 PC 当前打开的项目文件（fs 转发到桌面前端）。
struct InputBar: View {
    @EnvironmentObject var store: ShellStore

    /// 待发送图片（已转 JPEG 的原始字节，展示用直接解 UIImage）
    struct PendingImage: Identifiable {
        let id = UUID()
        let data: Data
        var image: UIImage? { UIImage(data: data) }
    }

    /// 待发送文件（名字 + 字节，PC 端落盘粘贴目录后改写正文为 read_file 指令）
    struct PendingFile: Identifiable {
        let id = UUID()
        let name: String
        let data: Data
    }

    /// 单文件上限：桥 WS 单帧虽可到 64MB，弱网下大文件会卡死收发，主动自限
    private static let maxFileBytes = 8 * 1024 * 1024

    @State private var text = ""
    @State private var voiceMode = false
    @State private var pressHint = ""
    @State private var pressCancelling = false
    @StateObject private var speech = SpeechRecorder()
    @FocusState private var focused: Bool

    @State private var pendingImages: [PendingImage] = []
    @State private var pendingFiles: [PendingFile] = []
    @State private var showAttachTray = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showPCFiles = false
    @State private var pickerItems: [PhotosPickerItem] = []

    private var hasAttachments: Bool {
        !pendingImages.isEmpty || !pendingFiles.isEmpty
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments
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

            if !pendingImages.isEmpty || !pendingFiles.isEmpty {
                attachmentBar
            }

            if voiceMode {
                pressToTalk
            } else {
                TextField("发送消息到 PC…", text: $text)
                    .submitLabel(.send)   // 单行：回车键变蓝色「发送」，按下走 onSubmit
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .frame(minHeight: 58, alignment: .topLeading)
                    .focused($focused)
                    .onSubmit(send)
                    .contextMenu {
                        // 追加进系统长按编辑菜单（拷贝/粘贴保留）：需要换行时从这里插
                        Button {
                            text += "\n"
                        } label: {
                            Label("插入换行", systemImage: "arrow.turn.down.left")
                        }
                    }
            }

            // 加号展开的附件面板：内嵌在输入卡里，不是系统弹框
            if showAttachTray {
                attachTray
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 8) {
                toolButton("square.stack.3d.up", badge: store.queue.isEmpty ? nil : "\(store.queue.count)") {
                    store.showQueue = true
                }
                .disabled(false)

                toolButton("slider.horizontal.3") {
                    store.showConfig = true
                }

                Spacer(minLength: 0)

                // 右下角互斥单钮：有文字→发送；无文字→话筒（点击进语音模式）；
                // 语音模式下常驻键盘钮（点击回文字模式）。加号在话筒/发送左侧，
                // 点开是输入卡内的附件面板，再点收起（图标同步换成 ✕）
                toolButton(showAttachTray ? "xmark" : "plus") {
                    showAttachTray.toggle()
                }
                .disabled(speech.recording)

                if voiceMode {
                    modeSwitchButton(icon: "keyboard")
                } else if canSend {
                    sendButton
                } else {
                    modeSwitchButton(icon: "mic")
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .padding(.bottom, 2)
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: canSend)
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: voiceMode)
        }
        .padding(8)
        .glassCard(cornerRadius: 26)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.isRunningCurrent)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: voiceMode)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: showAttachTray)
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems,
                      maxSelectionCount: 4, matching: .images)
        .onChange(of: pickerItems) { items in
            loadPickedPhotos(items)
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data],
                      allowsMultipleSelection: true) { result in
            importPickedFiles(result)
        }
        .sheet(isPresented: $showPCFiles) {
            PCFilesView { path in
                // 引用：与桌面 @ 引用同款，路径塞回输入框由 Agent 自己 read_file
                showPCFiles = false
                text += "@\(path) "
                voiceMode = false
                focused = true
            }
        }
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

    // MARK: - 附件面板（加号内嵌展开，替代系统弹框）

    private var attachTray: some View {
        HStack(spacing: 10) {
            trayButton(icon: "photo", label: "图片") {
                showAttachTray = false
                showPhotoPicker = true
            }
            trayButton(icon: "folder", label: "文件") {
                showAttachTray = false
                showFileImporter = true
            }
            trayButton(icon: "desktopcomputer", label: "PC 文件") {
                showAttachTray = false
                showPCFiles = true
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// 面板选项钮：图标 + 文字，浅色圆角底与卡内工具钮同风格
    private func trayButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                Text(label)
                    .font(.system(size: 11, design: .rounded))
            }
            .foregroundStyle(.primary.opacity(0.75))
            .frame(width: 66, height: 52)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 附件条（图片缩略图 + 文件 chip，可逐个删除）

    private var attachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { img in
                    attachmentThumbnail(img)
                }
                ForEach(pendingFiles) { file in
                    attachmentFileChip(file)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
        }
        .frame(height: pendingFiles.isEmpty ? 54 : 34)
    }

    private func attachmentThumbnail(_ img: PendingImage) -> some View {
        Group {
            if let ui = img.image {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .frame(width: 46, height: 46)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .overlay(alignment: .topTrailing) {
            removeButton { pendingImages.removeAll { $0.id == img.id } }
        }
    }

    private func attachmentFileChip(_ file: PendingFile) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "doc")
                .font(.system(size: 11))
            Text(file.name)
                .font(.system(size: 12, design: .rounded))
                .lineLimit(1)
            Text(String(format: "%.1fMB", Double(file.data.count) / 1_048_576))
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(alignment: .topTrailing) {
            removeButton { pendingFiles.removeAll { $0.id == file.id } }
        }
    }

    /// chip 右上角的小叉（白底圆片保证在缩略图上也看得见）
    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white, .gray)
                .background(Circle().fill(Color(.systemBackground)).frame(width: 13, height: 13))
        }
        .buttonStyle(.plain)
        .offset(x: 5, y: -5)
    }

    /// 相册选图：统一转 JPEG 再入列（PC 端归一化只认 PNG/JPEG/WebP，
    /// 相册原图多为 HEIC，直接发原始字节会被拒）
    private func loadPickedPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let existing = pendingImages.count
        let room = max(0, 4 - existing)
        guard room > 0 else {
            pickerItems = []
            showToast("单条最多 4 张图片")
            return
        }
        let accepted = items.prefix(room)
        if items.count > room { showToast("单条最多 4 张图片，已取前 \(room) 张") }
        pickerItems = []
        Task {
            var loaded: [PendingImage] = []
            for item in accepted {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data),
                   let jpeg = img.jpegData(compressionQuality: 0.9) {
                    loaded.append(PendingImage(data: jpeg))
                }
            }
            if loaded.isEmpty {
                showToast("图片读取失败")
            }
            pendingImages += loaded
        }
    }

    /// 文件选择：读字节入列，单文件超限明确提示
    private func importPickedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e):
            showToast("文件读取失败：\(e.localizedDescription)")
        case .success(let urls):
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    if data.count > Self.maxFileBytes {
                        showToast("\(url.lastPathComponent) 超过 8MB 上限")
                        continue
                    }
                    pendingFiles.append(PendingFile(name: url.lastPathComponent, data: data))
                } catch {
                    showToast("\(url.lastPathComponent) 读取失败")
                }
            }
        }
    }

    private func showToast(_ text: String) {
        store.showToast(text)
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
    /// （无背景版：只用文字与录音红点表达状态，contentShape 保证整块可按）
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

    /// 语音/文字模式切换钮：与工具钮同规格（纯图标），收在卡内右下
    private func modeSwitchButton(icon: String) -> some View {
        Button {
            pressHint = ""
            showAttachTray = false
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                voiceMode.toggle()
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(0.7))
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.05), in: Circle())
                .contentShape(Circle())
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
        if store.currentSessionId == nil { return "新对话：发送后 PC 自动建立会话" }
        return voiceMode ? "按住说话松手即发送 · 运行中自动排队" : "回车快速发送 · 运行中自动排队"
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || hasAttachments else { return }
        // 图片/文件负载：图片已转 JPEG；文件原字节，PC 端落盘粘贴目录后改写正文
        let imgs = pendingImages.map { ["data": $0.data.base64EncodedString()] }
        let files = pendingFiles.map { ["name": $0.name, "data": $0.data.base64EncodedString()] }
        if store.send(text,
                      images: imgs.isEmpty ? nil : imgs,
                      files: files.isEmpty ? nil : files) {
            text = ""
            pendingImages = []
            pendingFiles = []
            showAttachTray = false
            // 不收键盘：保留焦点方便连续快速发送
        }
    }
}
