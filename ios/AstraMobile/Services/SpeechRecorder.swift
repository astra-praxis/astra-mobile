import Foundation
import Speech
import AVFoundation

/// 按住说话：AVAudioSession 麦克风采集 + SFSpeechRecognizer 实时转写。
/// 松手 stopAndFinalize() 返回已识别文本；上滑 cancel() 丢弃；
/// 权限被拒/引擎不可用时置 unavailableReason，由调用方展示。
@MainActor
final class SpeechRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var transcript = ""
    @Published private(set) var unavailableReason: String?

    /// 到达时长上限自动收尾并回调（调用方据此发送已识别文本）
    var onTimeout: (() -> Void)?

    /// 单次录音上限（秒），避免长时间占用麦克风
    private let maxDuration: TimeInterval = 30

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var timeoutTask: Task<Void, Never>?
    /// start() 重入防抖：授权弹窗等待期间，拖拽 onChanged 连续触发不会重复 installTap
    private var starting = false

    /// 权限与识别引擎是否就绪；失败时填 unavailableReason
    func prepare() async -> Bool {
        unavailableReason = nil

        let micGranted = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
        guard micGranted else {
            unavailableReason = "麦克风权限被拒绝，请在系统设置里开启"
            return false
        }

        let speechGranted = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speechGranted else {
            unavailableReason = "语音识别权限被拒绝，请在系统设置里开启"
            return false
        }

        if recognizer == nil {
            // 跟随系统语言；拿不到或不可用则回退中文普通话
            let preferred = Locale.preferredLanguages.first ?? "zh-CN"
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: preferred))
                ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        }
        guard let recognizer, recognizer.isAvailable else {
            unavailableReason = "当前设备不支持语音识别"
            return false
        }
        return true
    }

    func start() async {
        guard !recording, !starting else { return }
        starting = true
        defer { starting = false }
        guard await prepare() else { return }
        guard !recording else { return }

        transcript = ""
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()

            task = recognizer?.recognitionTask(with: req) { [weak self] result, _ in
                guard let self, let result else { return }
                let text = result.bestTranscription.formattedString
                Task { @MainActor in self.transcript = text }
            }

            recording = true
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.maxDuration ?? 30) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.timeoutTask = nil
                self?.onTimeout?()
            }
        } catch {
            unavailableReason = "录音启动失败：\(error.localizedDescription)"
            stopEngine()
            reset()
        }
    }

    /// 松手收尾：返回最终识别文本（空/失败返回 ""）
    func stopAndFinalize() async -> String {
        stopEngine()
        let text = transcript
        reset()
        return text
    }

    /// 上滑取消：丢弃文本
    func cancel() async {
        stopEngine()
        reset()
    }

    // MARK: - 私有

    private func stopEngine() {
        timeoutTask?.cancel()
        timeoutTask = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        task?.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func reset() {
        recording = false
        request = nil
        task = nil
        transcript = ""
    }
}
