import SwiftUI
import AppKit

/// Sol:OS 8-bit Grayscale Design Tokens for Daylight Computer (DC1) and LivePaper Display.
/// Complies with the official Daylight grayscale scale (--os-0 to --os-1000) and brand accents.
public enum SolOSTokens {
    // MARK: - Core 8-bit Grayscale Tokens
    
    /// --os-0: #FFFFFF (Base paper / ground)
    public static let os0 = Color(hex: "#FFFFFF")
    public static let nsOs0 = NSColor(hex: "#FFFFFF")
    
    /// --os-50: #F7F7F7 (Surface panels / cards)
    public static let os50 = Color(hex: "#F7F7F7")
    public static let nsOs50 = NSColor(hex: "#F7F7F7")
    
    /// --os-100: #DCD5C9 / rgba(0,0,0,0.08) (Hairline borders)
    public static let os100 = Color(hex: "#DCD5C9")
    public static let nsOs100 = NSColor(hex: "#DCD5C9")
    
    /// --os-150: #F5F5F5 (Recessed canvas)
    public static let os150 = Color(hex: "#F5F5F5")
    public static let nsOs150 = NSColor(hex: "#F5F5F5")
    
    /// --os-200: #CCCCCC (Disabled / muted)
    public static let os200 = Color(hex: "#CCCCCC")
    public static let nsOs200 = NSColor(hex: "#CCCCCC")
    
    /// --os-300: #858585 (Low emphasis / tertiary text)
    public static let os300 = Color(hex: "#858585")
    public static let nsOs300 = NSColor(hex: "#858585")
    
    /// --os-400: #535353 (Secondary text ink)
    public static let os400 = Color(hex: "#535353")
    public static let nsOs400 = NSColor(hex: "#535353")
    
    /// --os-800: #343434 (Dark fields / pressed states)
    public static let os800 = Color(hex: "#343434")
    public static let nsOs800 = NSColor(hex: "#343434")
    
    /// --os-900: #1A1A1A (Primary text ink / headlines)
    public static let os900 = Color(hex: "#1A1A1A")
    public static let nsOs900 = NSColor(hex: "#1A1A1A")
    
    /// --os-1000: #000000 (Max black ink)
    public static let os1000 = Color(hex: "#000000")
    public static let nsOs1000 = NSColor(hex: "#000000")
    
    // MARK: - Calibrated Brand Grays
    
    /// Brand Accent Yellow: #CECECE
    public static let brandYellow = Color(hex: "#CECECE")
    public static let nsBrandYellow = NSColor(hex: "#CECECE")
    
    /// Brand Accent Amber: #9D9D9E
    public static let brandAmber = Color(hex: "#9D9D9E")
    public static let nsBrandAmber = NSColor(hex: "#9D9D9E")
    
    /// Brand Accent Orange: #6C6C6D
    public static let brandOrange = Color(hex: "#6C6C6D")
    public static let nsBrandOrange = NSColor(hex: "#6C6C6D")
    
    // MARK: - Geometry & Metrics
    
    public static let cornerRadiusSmall: CGFloat = 6.0
    public static let cornerRadiusMedium: CGFloat = 8.0
    public static let cornerRadiusLarge: CGFloat = 12.0
    public static let hairlineBorderWidth: CGFloat = 1.0
    
    // MARK: - Contrast Ratio Helpers (WCAG 2.1)
    
    public static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func sRGBtoLin(_ c: Double) -> Double {
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let rLin = sRGBtoLin(r)
        let gLin = sRGBtoLin(g)
        let bLin = sRGBtoLin(b)
        return 0.2126 * rLin + 0.7152 * gLin + 0.0722 * bLin
    }
    
    public static func contrastRatio(lum1: Double, lum2: Double) -> Double {
        let l1 = max(lum1, lum2)
        let l2 = min(lum1, lum2)
        return (l1 + 0.05) / (l2 + 0.05)
    }
}

// MARK: - Color Extension for Hex Initializer

extension Color {
    public init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}

extension NSColor {
    public convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            srgbRed: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: CGFloat(a) / 255.0
        )
    }
}
