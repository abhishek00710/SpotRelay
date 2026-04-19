import SwiftUI

enum SpotRelayTheme {
    static let primary = Color(hex: 0x3A5BFF)
    static let accent = Color(hex: 0x2ED3B7)
    static let success = Color(hex: 0x22C55E)
    static let warning = Color(hex: 0xF59E0B)
    static let background = Color(hex: 0xF5F7FA)
    static let textPrimary = Color(hex: 0x1F2937)
    static let textSecondary = Color(hex: 0x5B6472)
    static let panel = Color.white.opacity(0.86)
    static let surface = Color.white.opacity(0.72)

    static let heroGradient = LinearGradient(
        colors: [
            Color(hex: 0x3A5BFF),
            Color(hex: 0x2744C7),
            Color(hex: 0x2ED3B7).opacity(0.85)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let mapGlow = RadialGradient(
        colors: [Color(hex: 0x2ED3B7).opacity(0.22), .clear],
        center: .center,
        startRadius: 16,
        endRadius: 220
    )
}
