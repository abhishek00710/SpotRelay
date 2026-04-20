import SwiftUI

struct MapRecenterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "location.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .glassPanel(
            cornerRadius: 18,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.glassStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
        .accessibilityLabel("Center on current location")
    }
}
