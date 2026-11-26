import Foundation
import AVFoundation

/// 朗读（TTS）：把 agent 回复用 AVSpeechSynthesizer 读出来。
/// speak() 内做 markdown 清洗（代码块跳过、去标题/列表符号/行内标记/链接）。
@MainActor
final class TTSReader: NSObject, ObservableObject {
    @Published private(set) var speaking = false

    /// 当前音色（ShellStore 设置驱动；speak 时解析为设备实际声音）
    var selected: Voice = .first

    /// 朗读状态变化回调（手表端播报控制条需要知道 iPhone 是否在朗读）
    var onSpeakingChange: ((Bool) -> Void)?

    /// 内置音色（四档，全部普通话）：按本机已安装的 zh-CN 声音动态取前四个
    /// （默认声婷婷固定第一，其余按音质 premium > enhanced > default 排）。
    /// 档位即声音：已安装声音不足四款时，多余档位回落第一档并在设置页标注
    /// 「未安装」——已安装的档位之间切换必然换声音，不会静默同声
    enum Voice: String, CaseIterable, Identifiable {
        case first, second, third, fourth

        var id: String { rawValue }

        /// 本机 zh-CN 候选：默认声（婷婷）第一，其余音质高的在前、名称次序稳定
        static func candidates() -> [AVSpeechSynthesisVoice] {
            let zh = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "zh-CN" }
            guard let def = AVSpeechSynthesisVoice(language: "zh-CN") else { return zh }
            var rest = zh.filter { $0.identifier != def.identifier }
            rest.sort {
                let rank: (AVSpeechSynthesisVoice) -> Int = {
                    switch $0.quality {
                    case .premium: return 2
                    case .enhanced: return 1
                    default: return 0
                    }
                }
                return rank($0) != rank($1) ? rank($0) > rank($1) : $0.name < $1.name
            }
            return [def] + rest
        }

        private var index: Int {
            Self.allCases.firstIndex(of: self) ?? 0
        }

        /// 标签 = 本机实际声音名；未安装的档位如实标注
        var label: String {
            let all = Self.candidates()
            guard index < all.count else {
                return index == 0 ? "默认普通话" : "未安装（需下载）"
            }
            return all[index].name
        }

        /// 该档位对应的声音；超出已安装数量回落第一档
        func resolve() -> AVSpeechSynthesisVoice? {
            let all = Self.candidates()
            return index < all.count ? all[index] : all.first
        }
    }

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
        if let voice = selected.resolve() {
            utterance.voice = voice
        }   // 解析失败不设 voice → 系统默认语言兑底
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
        Task { @MainActor in
            self.speaking = true
            self.onSpeakingChange?(true)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speaking = false
            self.onSpeakingChange?(false)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speaking = false
            self.onSpeakingChange?(false)
        }
    }
}
