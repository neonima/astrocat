import SwiftUI

extension Color {
    init(_ hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1)
    }
}

struct Tokens {
    let s0, s1, s2, s3, s4: Color
    let well, img: Color
    let line, line2, line3: Color
    let t1, t2, t3, t4: Color
    let sel, selLine, selT: Color
    let q1, q2, q3, q4, q5: Color
    let tl1, tl2, tl3: Color

    /// Percentile rank within a session, not an absolute score.
    func quality(_ rank: Double) -> Color {
        switch rank {
        case ..<0.2: return q1
        case ..<0.4: return q2
        case ..<0.6: return q3
        case ..<0.8: return q4
        default: return q5
        }
    }

    static let dark = Tokens(
        s0: Color(0x0a0a0a), s1: Color(0x121212), s2: Color(0x191919),
        s3: Color(0x212121), s4: Color(0x2b2b2b),
        well: Color(0x050505), img: Color(0x0d0d0d),
        line: Color(0x272727), line2: Color(0x383838), line3: Color(0x4d4d4d),
        t1: Color(0xededed), t2: Color(0x9a9a9a), t3: Color(0x6b6b6b), t4: Color(0x484848),
        sel: Color(0x333333), selLine: Color(0x828282), selT: Color(0xffffff),
        q1: Color(0xc8503c), q2: Color(0xe8964a), q3: Color(0xf7d08a),
        q4: Color(0xeef2f8), q5: Color(0xb9d6ff),
        tl1: Color(0xff5f57), tl2: Color(0xfebc2e), tl3: Color(0x28c840))

    static let nightVision = Tokens(
        s0: Color(0x050000), s1: Color(0x0d0000), s2: Color(0x140000),
        s3: Color(0x1e0000), s4: Color(0x290000),
        well: Color(0x030000), img: Color(0x0a0000),
        line: Color(0x330000), line2: Color(0x4a0000), line3: Color(0x630000),
        t1: Color(0xe00000), t2: Color(0x960000), t3: Color(0x6e0000), t4: Color(0x4a0000),
        sel: Color(0x3a0000), selLine: Color(0xc00000), selT: Color(0xff0000),
        q1: Color(0x460000), q2: Color(0x690000), q3: Color(0x930000),
        q4: Color(0xc40000), q5: Color(0xff0000),
        tl1: Color(0x8c0000), tl2: Color(0x6a0000), tl3: Color(0x4b0000))
}

enum Metric {
    static let toolbar: CGFloat = 44
    static let subToolbar: CGFloat = 34
    static let statusBar: CGFloat = 26
    static let panelPad: CGFloat = 12
    static let rowHeight: CGFloat = 28
    static let frameGap: CGFloat = 6
    /// Clears the window's traffic lights when the title bar is hidden.
    static let trafficLightInset: CGFloat = 78
}

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let h1: CGFloat = 24
    static let h2: CGFloat = 32
    static let h3: CGFloat = 40
}

enum Radius {
    static let swatch: CGFloat = 2
    static let control: CGFloat = 3
    static let panel: CGFloat = 5
    static let sheet: CGFloat = 8
    static let window: CGFloat = 10
}

enum Face {
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let sectionHeader = mono(10, .medium)
    static let secondary = text(11)
    static let body = text(12)
    static let title = text(13, .medium)
    static let screenTitle = text(15, .medium)
    static let document = text(22, .medium)

    static let sectionTracking: CGFloat = 0.6
    static let screenTitleTracking: CGFloat = -0.15
    static let documentTracking: CGFloat = -0.44
}

private struct TokensKey: EnvironmentKey {
    static let defaultValue = Tokens.dark
}

extension EnvironmentValues {
    var tokens: Tokens {
        get { self[TokensKey.self] }
        set { self[TokensKey.self] = newValue }
    }
}
