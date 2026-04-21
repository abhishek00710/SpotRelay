import SwiftUI

enum SpotRelayTheme {
    static let primary = Color(hex: 0x4B6BFF)
    static let accent = Color(hex: 0x22CDB4)
    static let success = Color(hex: 0x22C55E)
    static let danger = Color.adaptive(light: 0xE65766, dark: 0xFF7B87)
    static let warning = Color(hex: 0xF59E0B)
    static let background = Color.adaptive(light: 0xF6F8FB, dark: 0x07111D)
    static let elevatedBackground = Color.adaptive(light: 0xFCFDFF, dark: 0x0C1626)
    static let textPrimary = Color.adaptive(light: 0x111827, dark: 0xF8FAFF)
    static let textSecondary = Color.adaptive(light: 0x64748B, dark: 0x9FB0C5)
    static let panel = Color.adaptive(light: 0xFFFFFF, dark: 0x101A2C, lightOpacity: 0.58, darkOpacity: 0.54)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x131F34, lightOpacity: 0.76, darkOpacity: 0.74)
    static let chrome = Color.adaptive(light: 0xFFFFFF, dark: 0x0E1728, lightOpacity: 0.94, darkOpacity: 0.9)
    static let glassTint = Color.adaptive(light: 0xFFFFFF, dark: 0x0C1728, lightOpacity: 0.30, darkOpacity: 0.36)
    static let strongGlassTint = Color.adaptive(light: 0xFFFFFF, dark: 0x0E1728, lightOpacity: 0.48, darkOpacity: 0.54)
    static let glassStroke = Color.adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, lightOpacity: 0.62, darkOpacity: 0.08)
    static let softStroke = Color.adaptive(light: 0xD6DEEA, dark: 0xA5B5CF, lightOpacity: 0.52, darkOpacity: 0.10)
    static let badgeFill = Color.adaptive(light: 0xEEF3FF, dark: 0x162139, lightOpacity: 0.84, darkOpacity: 0.88)
    static let badgeText = Color.adaptive(light: 0x314263, dark: 0xD7E3FF)
    static let shadow = Color.adaptive(light: 0x0B1324, dark: 0x000000, lightOpacity: 0.10, darkOpacity: 0.22)
    static let rowShadow = Color.adaptive(light: 0x0B1324, dark: 0x000000, lightOpacity: 0.06, darkOpacity: 0.14)
    static let mapOverlayMid = Color.adaptive(light: 0x08111F, dark: 0x000000, lightOpacity: 0.08, darkOpacity: 0.16)
    static let mapOverlayBottom = Color.adaptive(light: 0x08111F, dark: 0x000000, lightOpacity: 0.22, darkOpacity: 0.36)

    static let heroGradient = LinearGradient(
        colors: [
            Color(hex: 0x5A78FF),
            Color(hex: 0x3D5CFF),
            Color(hex: 0x22CDB4).opacity(0.9)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let orbGradient = LinearGradient(
        colors: [Color(hex: 0x5A78FF), Color(hex: 0x22CDB4)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let mapGlow = RadialGradient(
        colors: [Color(hex: 0x22CDB4).opacity(0.18), .clear],
        center: .center,
        startRadius: 16,
        endRadius: 220
    )

    static let canvasGradient = LinearGradient(
        colors: [background, elevatedBackground],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
