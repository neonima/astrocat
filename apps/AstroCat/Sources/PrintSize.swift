import Foundation

/// Turning a pixel count into a print size, which is the only form in which
/// "is this crop big enough" has an answer. A resolution on its own does not
/// say whether it will hold up at arm's length on a wall.
enum PrintSize {
    struct Format {
        let name: String
        /// Portrait orientation, millimetres.
        let mm: SIMD2<Double>
        var aspect: Double { mm.x / mm.y }
    }

    static let formats: [Format] = [
        Format(name: "10×15", mm: SIMD2(100, 150)),
        Format(name: "A5", mm: SIMD2(148, 210)),
        Format(name: "20×30", mm: SIMD2(200, 300)),
        Format(name: "A4", mm: SIMD2(210, 297)),
        Format(name: "30×40", mm: SIMD2(300, 400)),
        Format(name: "A3", mm: SIMD2(297, 420)),
        Format(name: "40×50", mm: SIMD2(400, 500)),
        Format(name: "A2", mm: SIMD2(420, 594)),
        Format(name: "50×70", mm: SIMD2(500, 700)),
        Format(name: "60×90", mm: SIMD2(600, 900)),
    ]

    /// Common crop shapes, as width over height in landscape.
    static let ratios: [(name: String, value: Double?)] = [
        ("Free", nil),
        ("1:1", 1),
        ("5:4", 5.0 / 4),
        ("3:2", 3.0 / 2),
        ("4:3", 4.0 / 3),
        ("16:9", 16.0 / 9),
        ("A", 297.0 / 210),
    ]

    static func size(px: (w: Int, h: Int), dpi: Double) -> SIMD2<Double> {
        SIMD2(Double(px.w) / dpi * 25.4, Double(px.h) / dpi * 25.4)
    }

    /// The largest standard format this crop still prints at `dpi` or better,
    /// in whichever orientation suits it. Bigger is reported in preference to
    /// sharper, because the limit people actually hit is paper size.
    static func largest(px: (w: Int, h: Int), atLeast dpi: Double = 240) -> (
        name: String, dpi: Double
    )? {
        var best: (name: String, dpi: Double, area: Double)?
        for f in formats {
            for mm in [f.mm, SIMD2(f.mm.y, f.mm.x)] {
                let density = min(
                    Double(px.w) / (mm.x / 25.4),
                    Double(px.h) / (mm.y / 25.4))
                guard density >= dpi else { continue }
                let area = mm.x * mm.y
                if best == nil || area > best!.area {
                    best = (f.name, density, area)
                }
            }
        }
        return best.map { ($0.name, $0.dpi) }
    }

    /// `1831 × 2109 px · 15.5 × 17.9 cm at 300 dpi · fills A4 at 221 dpi`
    static func describe(px: (w: Int, h: Int)) -> String {
        let cm = size(px: px, dpi: 300) / 10
        var text = String(
            format: "%d × %d px · %.1f × %.1f cm at 300 dpi", px.w, px.h, cm.x, cm.y)
        if let fit = largest(px: px) {
            text += String(format: " · fills %@ at %.0f dpi", fit.name, fit.dpi)
        } else {
            text += " · under 240 dpi at 10×15"
        }
        return text
    }
}
