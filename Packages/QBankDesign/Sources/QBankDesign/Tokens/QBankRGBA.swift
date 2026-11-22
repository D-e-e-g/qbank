/// An sRGB color value, written the way the web tokens write it (`#7C3F60`,
/// `rgba(28, 27, 24, 0.4)`), so Swift and CSS values compare one to one.
public struct QBankRGBA: Hashable, Sendable, CustomStringConvertible {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    /// Opacity from 0 to 1.
    public let alpha: Double

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = min(max(alpha, 0), 1)
    }

    /// `QBankRGBA(0x7C3F60)` is CSS `#7C3F60`.
    public init(_ hex: UInt32, alpha: Double = 1) {
        self.init(
            red: UInt8((hex >> 16) & 0xFF),
            green: UInt8((hex >> 8) & 0xFF),
            blue: UInt8(hex & 0xFF),
            alpha: alpha
        )
    }

    /// `#RRGGBB`, uppercase, without the alpha.
    public var hex: String {
        "#"
            + [red, green, blue].map { byte in
                let digits = String(byte, radix: 16, uppercase: true)
                return digits.count == 1 ? "0" + digits : digits
            }.joined()
    }

    /// `#RRGGBB` when opaque, otherwise `rgba(r, g, b, a)` as in the CSS.
    public var description: String {
        alpha == 1 ? hex : "rgba(\(red), \(green), \(blue), \(alpha))"
    }
}
