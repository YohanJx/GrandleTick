import SwiftUI

/// GrandleTick 的唯一视觉令牌集，数值直接提取自主菜单，避免宽屏页面另起一套风格。
enum AppDesign {
    static let appBackground = Color(nsColor: .windowBackgroundColor)
    static let panelBackground = Color.primary.opacity(0.05)
    static let elevatedPanelBackground = Color.primary.opacity(0.035)

    static let primaryBlue = Color.blue
    static let leisurePurple = Color.purple
    static let websiteTeal = Color.teal
    static let documentOrange = Color.orange
    static let successGreen = Color.green
    static let primaryBlueMuted = Color.blue.opacity(0.10)
    static let destructiveRed = Color.red.opacity(0.8)

    /// 图表只从这组克制的语义色中取色，既能区分类别，又避免统计页变成高饱和“彩虹面板”。
    static let chartPalette: [Color] = [primaryBlue, websiteTeal, documentOrange, leisurePurple, successGreen]

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.secondary.opacity(0.68)

    static let largeCornerRadius: CGFloat = 18
    static let mediumCornerRadius: CGFloat = 14
    static let controlCornerRadius: CGFloat = 12
    static let sectionSpacing: CGFloat = 16
    static let compactSectionSpacing: CGFloat = 12
    static let controlHeight: CGFloat = 36

    static let animationDuration = 0.24
    static let animationCurve = Animation.easeInOut(duration: animationDuration)
    static let springAnimation = Animation.spring(response: 0.38, dampingFraction: 0.82)

    static func tintedSurface(_ tint: Color, opacity: Double = 0.10) -> LinearGradient {
        LinearGradient(
            colors: [tint.opacity(opacity), tint.opacity(opacity * 0.35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum AppPanelVariant {
    case regular
    case compact
    case elevated

    var fill: Color {
        switch self {
        case .regular, .compact: return AppDesign.panelBackground
        case .elevated: return AppDesign.elevatedPanelBackground
        }
    }

    var radius: CGFloat {
        switch self {
        case .regular: return AppDesign.largeCornerRadius
        case .compact, .elevated: return AppDesign.mediumCornerRadius
        }
    }

    var padding: CGFloat {
        switch self {
        case .regular: return 16
        case .compact, .elevated: return 14
        }
    }
}

struct AppPanelModifier: ViewModifier {
    let variant: AppPanelVariant

    func body(content: Content) -> some View {
        content
            .padding(variant.padding)
            .background(
                RoundedRectangle(cornerRadius: variant.radius, style: .continuous)
                    .fill(variant.fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: variant.radius, style: .continuous)
                            .stroke(Color.primary.opacity(0.045), lineWidth: 1)
                    )
            )
    }
}

struct AppSectionHeader: View {
    let title: String
    var subtitle: String?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            Text(title)
                .font(.system(size: compact ? 14 : 18, weight: .bold))
                .foregroundStyle(AppDesign.primaryText)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundStyle(AppDesign.secondaryText)
            }
        }
    }
}

struct AppStatValue: View {
    let value: String
    var compact = false
    var emphasized = true
    var tint = AppDesign.primaryBlue

    var body: some View {
        Text(value)
            .font(.system(size: compact ? 18 : 36, weight: emphasized ? .bold : .semibold, design: .monospaced))
            .foregroundStyle(emphasized ? tint : AppDesign.primaryText)
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }
}

struct AppCapsuleButtonStyle: ButtonStyle {
    enum Role {
        case primary
        case secondary
        case destructive
    }

    let role: Role
    var compact = false

    private var foreground: Color {
        switch role {
        case .primary: return AppDesign.primaryBlue
        case .secondary: return AppDesign.secondaryText
        case .destructive: return AppDesign.destructiveRed
        }
    }

    private var fill: Color {
        switch role {
        case .primary: return AppDesign.primaryBlue.opacity(0.08)
        case .secondary: return Color.primary.opacity(0.05)
        case .destructive: return AppDesign.destructiveRed.opacity(0.10)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 13, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(minHeight: compact ? 30 : AppDesign.controlHeight)
            .padding(.horizontal, compact ? 10 : 14)
            .background(
                RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.72 : 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(AppDesign.animationCurve, value: configuration.isPressed)
    }
}

extension View {
    func appPanel(_ variant: AppPanelVariant = .regular) -> some View {
        modifier(AppPanelModifier(variant: variant))
    }
}
