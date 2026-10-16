import SwiftUI

/// A restrained console look, monochrome throughout: near-black
/// neutral surfaces, a grey type scale, hairlines, and one pale cyan accent
/// reserved for "live" (presenting, attacks, the selected scene).
enum Theme {
    static let background = Color(red: 0.043, green: 0.047, blue: 0.051)   // #0B0C0D
    static let surface    = Color(red: 0.078, green: 0.083, blue: 0.090)   // #141517
    static let surfaceHi  = Color(red: 0.115, green: 0.122, blue: 0.132)   // #1D1F22

    static let textPrimary   = Color(red: 0.91, green: 0.92, blue: 0.93)
    static let textSecondary = Color(red: 0.58, green: 0.60, blue: 0.63)
    static let textTertiary  = Color(red: 0.38, green: 0.40, blue: 0.43)

    static let accent     = Color(red: 0.55, green: 0.86, blue: 0.96)       // #8CDBF5
    static let accentSoft = Color(red: 0.55, green: 0.86, blue: 0.96).opacity(0.13)

    static let alert = Color(red: 0.93, green: 0.35, blue: 0.31)

    static let hairline = Color.white.opacity(0.07)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func label(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }
}

/// Small uppercase tracked caption used for section labels.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label())
            .tracking(1.6)
            .foregroundStyle(Theme.textTertiary)
    }
}

extension View {
    /// A subtle card surface with a hairline border.
    func cardSurface(_ color: Color = Theme.surface, radius: CGFloat = 10) -> some View {
        self
            .background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}
