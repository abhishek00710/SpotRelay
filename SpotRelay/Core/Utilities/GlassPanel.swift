import SwiftUI

struct GlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    let stroke: Color
    let shadow: Color
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(stroke, lineWidth: 1)
                    }
            }
            .shadow(color: shadow, radius: shadowRadius, y: shadowY)
    }
}

extension View {
    func glassPanel(
        cornerRadius: CGFloat,
        tint: Color = SpotRelayTheme.glassTint,
        stroke: Color = SpotRelayTheme.glassStroke,
        shadow: Color = SpotRelayTheme.shadow,
        shadowRadius: CGFloat = 20,
        shadowY: CGFloat = 10
    ) -> some View {
        modifier(
            GlassPanelModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                stroke: stroke,
                shadow: shadow,
                shadowRadius: shadowRadius,
                shadowY: shadowY
            )
        )
    }
}
