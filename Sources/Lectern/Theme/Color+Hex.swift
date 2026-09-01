import SwiftUI

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        var sanitized = hex.trimmingCharacters(in: .whitespaces)
        if sanitized.hasPrefix("#") { sanitized.removeFirst() }
        Scanner(string: sanitized).scanHexInt64(&value)

        let red, green, blue: Double
        switch sanitized.count {
        case 6:
            red = Double((value >> 16) & 0xFF) / 255.0
            green = Double((value >> 8) & 0xFF) / 255.0
            blue = Double(value & 0xFF) / 255.0
        default:
            red = 0.4; green = 0.4; blue = 0.45
        }

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
