import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension Color {
    init(hex: UInt, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    static func adaptive(
        light: UInt,
        dark: UInt,
        lightOpacity: Double = 1,
        darkOpacity: Double = 1
    ) -> Color {
        #if canImport(UIKit)
        return Color(
            uiColor: UIColor { traits in
                let isDark = traits.userInterfaceStyle == .dark
                let hex = isDark ? dark : light
                let opacity = isDark ? darkOpacity : lightOpacity
                let red = CGFloat((hex >> 16) & 0xFF) / 255
                let green = CGFloat((hex >> 8) & 0xFF) / 255
                let blue = CGFloat(hex & 0xFF) / 255
                return UIColor(red: red, green: green, blue: blue, alpha: opacity)
            }
        )
        #else
        return Color(hex: light, opacity: lightOpacity)
        #endif
    }
}
