import Foundation
import AVFoundation

/// 朗读（TTS）：把 agent 回复用 AVSpeechSynthesizer 读出来。
/// speak() 内做 markdown 清洗（代码块跳过、去标题/列表符号/行内标记/链接）。
@MainActor
final class TTSReader: NSObject, ObservableObject {
    @Published private(set) var speaking = false

    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ raw: String) {
        let text = Self.cleaned(raw)
        guard !text.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)   // 新回复到来打断上一条
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.52
        synth.speak(utterance)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    /// markdown → 纯朗读文本：围栏代码块整段跳过，其余去标记留正文
    static func cleaned(_ raw: String) -> String {
        var out: [String] = []
        var inCode = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var l = String(line)
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode { continue }
            l = l.replacingOccurrences(of: "^\\s*#{1,6}\\s+", with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: "^\\s*>\\s?", with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: "^\\s*[-*+]\\s+", with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: "^\\s*\\d+[.)]\\s+", with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: "^\\s*-{3,}\\s*$", with: "", options: .regularExpression, range: nil)
            l = l.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
            l = l.replacingOccurrences(of: "`+|\\*\\*|__|\\*|_", with: "", options: .regularExpression)
            out.append(l)
        }
        return out.joined(separator: " ")
    }
}

extension TTSReader: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}
