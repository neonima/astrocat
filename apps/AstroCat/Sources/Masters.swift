import Foundation

/// Stacks live in the project, not in a temp directory. A master is expensive
/// enough to make that the difference between reopening a project and stacking
/// it again.
enum Masters {
    static func directory(_ project: String) -> URL {
        URL(fileURLWithPath: project)
            .appendingPathComponent(".astrocat", isDirectory: true)
            .appendingPathComponent("masters", isDirectory: true)
    }

    @discardableResult
    static func ensure(_ project: String) -> URL {
        let dir = directory(project)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Enough to tell two stacks of the same target apart in a list: what, how
    /// many frames, how long each, through what filter, and which night.
    static func name(object: String, frames: Int, exposure: Float, filter: String, night: String)
        -> String
    {
        let target = object.isEmpty ? "Stack" : object.replacingOccurrences(of: " ", with: "")
        let band = filter.isEmpty ? "LP" : filter
        let when = night.isEmpty ? "" : "_\(night.replacingOccurrences(of: "-", with: ""))"
        return String(format: "%@_%dx%.0fs_%@%@.fit", target, frames, exposure, band, when)
    }

    static func all(_ project: String) -> [URL] {
        guard !project.isEmpty,
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory(project),
                includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }

        return entries
            .filter { ["fit", "fits"].contains($0.pathExtension.lowercased()) }
            .sorted { a, b in modified(a) > modified(b) }
    }

    static func newest(_ project: String) -> URL? { all(project).first }

    /// Develop parameters sit beside the master they describe, so moving or
    /// deleting one takes its edits with it.
    static func settingsURL(for master: String) -> URL {
        let u = URL(fileURLWithPath: master)
        return u.deletingPathExtension().appendingPathExtension("develop.json")
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    static func size(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    static func describe(_ url: URL) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        let when = DateFormatter()
        when.dateFormat = "d MMM HH:mm"
        return "\(f.string(fromByteCount: size(url))) · \(when.string(from: modified(url)))"
    }
}

/// Contrast allocated across the tonal range, in the zones an astro image
/// actually has. Each value is the *slope* the curve takes through its zone,
/// not the level it lands on — the curve is their running total, normalised.
///
/// That is what makes this safe where a freehand curve is not: slopes are
/// positive, so the result cannot fold back on itself and posterise, and
/// contrast given to one zone is visibly taken from another rather than
/// invented.
struct ZoneCurve: Equatable, Codable {
    var slopes: [Float] = Array(repeating: 1, count: 5)

    static let names = [
        "Sky background", "Faint nebulosity", "Midtones", "Bright nebulosity", "Stars",
    ]

    var isIdentity: Bool { slopes.allSatisfy { abs($0 - 1) < 0.005 } }

    /// 256 entries, monotonic and pinned to [0,1] at the ends.
    func table() -> [Float] {
        let n = max(slopes.count, 2)
        var running = [Float](repeating: 0, count: 256)
        var total: Float = 0

        // Starts at zero and ends at one, so equal slopes give back the
        // identity rather than a curve offset by one step.
        for i in 1..<256 {
            // Where this level sits across the zones, so the slope changes
            // smoothly rather than stepping at zone boundaries.
            let pos = Float(i) / 255 * Float(n - 1)
            let lo = min(Int(pos), n - 1)
            let hi = min(lo + 1, n - 1)
            let f = pos - Float(lo)
            total += max(0.01, slopes[lo] * (1 - f) + slopes[hi] * f)
            running[i] = total
        }

        let span = max(running[255], 1e-6)
        return running.map { $0 / span }
    }
}

/// Everything the Develop module lets you change, in a form that survives a
/// relaunch.
///
/// The stages themselves carry their own parameters, so this is the stack plus
/// the handful of things that belong to the frame rather than to any one stage.
/// Measurements are deliberately absent: the colour calibration is re-fitted
/// from the frame rather than trusted from a file that may now describe
/// different pixels.
struct DevelopSettings: Codable, Equatable {
    /// Optional so a file written before stages carried their own parameters
    /// still decodes — it simply falls back to the template. A non-optional
    /// field with a default does not fall back when the key is missing; it
    /// throws, and the whole file is discarded as unreadable.
    var stack: [OpInstance]?
    var sampleTolerance: Float = 2
    var colourReference: Int32 = 1
    var white: String = WhiteReference.g2v.rawValue
    /// Orientation only. Where you were looking is not an edit, so zoom and pan
    /// are reset rather than restored. A crop is an edit.
    var rotation = 0
    var flipH = false
    var flipV = false
    var crop = SIMD4<Float>(0, 0, 1, 1)
    var separationOn: Bool?

    static func load(_ master: String) -> DevelopSettings? {
        guard !master.isEmpty,
            let data = try? Data(contentsOf: Masters.settingsURL(for: master))
        else { return nil }
        return try? JSONDecoder().decode(DevelopSettings.self, from: data)
    }

    func save(_ master: String) {
        guard !master.isEmpty, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Masters.settingsURL(for: master), options: .atomic)
    }
}

/// Lightroom-style tonal controls, in the same ranges the Lighthouse script
/// uses so a setting means the same thing in both.
struct ToneParams: Equatable, Codable {
    var exposure: Float = 0
    var contrast: Float = 0
    var highlights: Float = 0
    var shadows: Float = 0
    var whites: Float = 0
    var blacks: Float = 0
    var vibrance: Float = 0
    var scnr: Float = 0

    var isIdentity: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0
            && whites == 0 && blacks == 0 && vibrance == 0 && scnr == 0
    }

    /// The luminance transfer this produces, mirroring the shader so the drawn
    /// curve is the one actually applied rather than an illustration of it.
    func curve() -> [Float] {
        (0..<256).map { i in
            let base = Float(i) / 255
            var l = base

            if exposure != 0 {
                let scale = pow(2, exposure * (exposure > 0 ? 0.72 : 0.62))
                l = (l * scale) / (1 + l * (scale - 1))
            }
            if contrast != 0 {
                let c = 0.48 * contrast
                let x = min(max(l, 0), 1)
                l = x + 4 * c * (x - 0.5) * x * (1 - x)
            }
            if blacks < 0 {
                let bp = min(0.95, -blacks * 0.22)
                l = max((l - bp) / (1 - bp), 0)
            } else if blacks > 0 {
                let lift = min(0.95, blacks * 0.22)
                l = lift + (1 - lift) * l
            }
            if whites > 0 {
                l = max(l / max(0.05, 1 - whites * 0.22), 0)
            } else if whites < 0 {
                l = (1 - min(0.95, -whites * 0.22)) * l
            }

            if highlights != 0 {
                let mask = pow(min(max((base - 0.25) / 0.75, 0), 1), 1.3)
                if highlights < 0 {
                    let amount = -highlights
                    let comp = l / (1 + amount * 3 * mask * l)
                    l += (comp - l) * mask * amount
                } else {
                    let clamped = min(max(l, 0), 1)
                    l += highlights * mask * (1 - clamped * clamped) * 0.5
                }
            }
            if shadows != 0 {
                let mask = pow(min(max((0.5 - base) / 0.5, 0), 1), 1.3)
                l += shadows * mask * min(max(1 - l, 0), 1) * 0.5
            }
            return min(max(l, 0), 1)
        }
    }
}

/// Detail controls, which unlike everything else in Develop need a blurred copy
/// of the frame and so drive the two-pass path.
struct DetailParams: Equatable, Codable {
    var clarity: Float = 0
    var texture: Float = 0
    /// Blur sigma for clarity, in drawable pixels.
    var radius: Float = 10

    var isIdentity: Bool { clarity == 0 && texture == 0 }
}
