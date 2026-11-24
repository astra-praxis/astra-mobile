import SwiftUI

// MARK: - 玻璃设计系统
// iOS 26+：真 Liquid Glass（glassEffect / GlassEffectContainer / materialize 过渡）；
// 准则：interactive 只给可交互组件、玻璃不叠玻璃、多个玻璃元素入 container。
// iOS 16~25：ultraThinMaterial + 发丝描边 + 柔影降级，观感一致。

/// 品牌渐变（AccentColor #6366F1 → 紫罗兰）
enum GlassTokens {
    static let brandGradient = LinearGradient(
        colors: [Color.accentColor, Color(red: 0.55, green: 0.37, blue: 0.95)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let userBubbleGradient = LinearGradient(
        colors: [Color.accentColor.opacity(0.18), Color(red: 0.55, green: 0.37, blue: 0.95).opacity(0.12)],
        startPoint: .top, endPoint: .bottom)
}

extension View {

    /// 图标圆钮（独立悬浮，须在 GlassEffectContainer 内使用才能与邻近玻璃融合）：
    /// iOS 26 用显式 glassEffect(interactive) 获得触摸流体反应并参与容器融合；
    /// 以下版本材质圆底。调用方负责给 label 设定尺寸。
    @ViewBuilder
    func glassToolbarButton() -> some View {
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            self
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }

    /// 玻璃卡片（输入卡 / 面板等被动容器）：不加 interactive——
    /// 官方规范 interactive 仅用于可交互组件；卡片内部也不得再嵌玻璃。
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat, shadow: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(shadow ? 0.10 : 0), radius: 16, y: 8)
        }
    }

    /// 玻璃胶囊（状态 pill / 小徽标）
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }

    /// 玻璃胶囊按钮（可交互胶囊，如顶栏搜索入口）：interactive 触摸流体反应
    @ViewBuilder
    func glassCapsuleButton() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }

    /// 玻璃圆面（FAB 等可交互圆钮；装饰座传 interactive: false）
    @ViewBuilder
    func glassCircle(size: CGFloat, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.frame(width: size, height: size)
                .glassEffect(interactive ? Glass.regular.interactive() : .regular, in: Circle())
        } else {
            self.frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
    }

    /// 玻璃元素的出现/消失过渡（materialize：远处出现时材质凝聚）。
    /// 仅 iOS 26 生效；条件出现请配合 withAnimation/animation(value:)。
    @ViewBuilder
    func glassMaterialize() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectTransition(.materialize)
        } else {
            self
        }
    }
}

// MARK: - 环境光背景
// 给玻璃提供可折射的色彩：两团低饱和品牌色光斑 + 系统底色。

struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            Circle()
                .fill(Color.accentColor.opacity(0.10))
                .frame(width: 320)
                .blur(radius: 90)
                .offset(x: -110, y: -260)
            Circle()
                .fill(Color(red: 0.55, green: 0.37, blue: 0.95).opacity(0.08))
                .frame(width: 280)
                .blur(radius: 100)
                .offset(x: 170, y: -320)
            Circle()
                .fill(Color.cyan.opacity(0.05))
                .frame(width: 260)
                .blur(radius: 100)
                .offset(x: 60, y: 380)
        }
        .ignoresSafeArea()
    }
}

// MARK: - 呼吸点（Agent 执行中的打字指示）

struct PulseDots: View {
    @State private var up = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                    .offset(y: up ? -3 : 1)
                    .opacity(up ? 1 : 0.45)
                    .animation(
                        .easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(Double(i) * 0.16),
                        value: up)
            }
        }
        .onAppear { up = true }
    }
}

// MARK: - 弹性入场（首现动画，配合 seen 集合只在首次出现时播放）

struct AnimatedAppear: ViewModifier {
    var delay: Double = 0
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82).delay(delay)) {
                    shown = true
                }
            }
    }
}
