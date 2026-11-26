import SwiftUI

/// 手表端设计语言：纯黑 OLED 底 + 白色玻璃两级 + 唯一强调色（与 iOS AccentColor
/// 同款靛蓝）。强调色只花在一处——麦克风与「活着的」状态；其余层级靠白色
/// 透明度与字重表达。
extension Color {
    /// iOS 端 AccentColor：srgb(0.388, 0.400, 0.945)
    static let astraAccent = Color(red: 0.388, green: 0.400, blue: 0.945)
}

/// 玻璃卡片：手表端统一容器（6% 白填充 + 发丝描边 + 连续圆角）
struct GlassCard: ViewModifier {
    var radius: CGFloat = 16
    var interactive: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.white.opacity(interactive ? 0.10 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            )
    }
}

extension View {
    func glassCard(radius: CGFloat = 16, interactive: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, interactive: interactive))
    }
}

/// 按压反馈：轻微缩放 + 变暗（所有可点元素统一手感）
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}

/// 运行中呼吸点：整块 UI 唯一的自主动效，传达「agent 活着」。
/// AOD（低亮度常显）下停止动画，只留静态点。
struct LiveDot: View {
    let active: Bool
    var animate: Bool = true
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(active ? Color.astraAccent : Color.white.opacity(0.35))
            .frame(width: 7, height: 7)
            .overlay {
                if active {
                    Circle()
                        .stroke(Color.astraAccent.opacity(0.5), lineWidth: 1.5)
                        .scaleEffect(pulsing ? 2.0 : 1.0)
                        .opacity(pulsing ? 0 : 1)
                }
            }
            .onChange(of: active) { now in
                pulsing = false
                if now && animate {
                    withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                        pulsing = true
                    }
                }
            }
            .onChange(of: animate) { now in
                pulsing = false
                if now && active {
                    withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                        pulsing = true
                    }
                }
            }
            .onAppear {
                if active && animate {
                    withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                        pulsing = true
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

/// 播报中的三根波形条（替代静态「播报中」文字）
struct WaveformBars: View {
    @State private var up = false
    private let heights: [CGFloat] = [10, 16, 7]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Color.astraAccent)
                    .frame(width: 2.5, height: up ? heights[(i + 1) % 3] : heights[i])
                    .animation(.easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.12), value: up)
            }
        }
        .frame(height: 16)
        .onAppear { up = true }
        .accessibilityLabel("播报中")
    }
}
