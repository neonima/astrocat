import AppKit
import Foundation

enum Exporter {
    /// Siril reads FITS bottom-up and wants the pedestal left in so it can find
    /// the same black point; everything else expects it gone.
    private static func conventions(_ target: ExportTarget) -> (bottomUp: Bool, pedestal: Bool) {
        switch target {
        case .siril: return (true, true)
        case .pixinsight: return (true, false)
        case .lightroom: return (false, false)
        }
    }

    static func suggestedName(_ target: ExportTarget, frames: Int, exposure: Float, filter: String)
        -> String
    {
        let base = String(
            format: "NGC7000_%dx%.0fs_%@", frames, exposure,
            filter.isEmpty ? "LP" : filter)
        return base + (target == .lightroom ? ".tif" : ".fit")
    }

    @MainActor
    static func run(
        source: String, target: ExportTarget, suggested: String,
        stretch: (shadows: SIMD3<Float>, midtone: SIMD3<Float>)?,
        calibration: (offset: SIMD3<Float>, gain: SIMD3<Float>)? = nil
    ) -> String? {
        guard !source.isEmpty, FileManager.default.fileExists(atPath: source) else {
            return "Nothing to export yet — run a stack first."
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        panel.message = "\(target.rawValue) — \(target.settings)"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        if target == .lightroom {
            return writeTIFF(
                source: source, to: url, stretch: stretch, calibration: calibration)
        }

        let c = conventions(target)
        let ok = source.withCString { s in
            url.path.withCString { d in
                ac_export_fits(s, d, c.bottomUp ? 1 : 0, c.pedestal ? 1 : 0)
            }
        }
        return ok == 1 ? nil : "Could not write \(url.lastPathComponent)"
    }

    /// Neither Lightroom nor Photoshop reads FITS or linear data, so this is the
    /// one target where the stretch has to be baked in.
    private static func writeTIFF(
        source: String, to url: URL,
        stretch: (shadows: SIMD3<Float>, midtone: SIMD3<Float>)?,
        calibration: (offset: SIMD3<Float>, gain: SIMD3<Float>)?
    ) -> String? {
        guard let frame = try? LoadedFrame(url: URL(fileURLWithPath: source)) else {
            return "Could not read the master"
        }
        let w = frame.meta.width
        let h = frame.meta.height
        guard w > 0, h > 0 else { return "Master has no pixels" }

        let sh = stretch?.shadows ?? frame.meta.shadows
        let mid = stretch?.midtone ?? frame.meta.midtone
        let calOffset = calibration?.offset ?? .zero
        let calGain = calibration?.gain ?? SIMD3(repeating: 1)

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 16, samplesPerPixel: 3, hasAlpha: false,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: w * 6, bitsPerPixel: 48),
            let dst = rep.bitmapData
        else { return "Could not allocate the image" }

        let out = dst.withMemoryRebound(to: UInt16.self, capacity: w * h * 3) { $0 }
        for y in 0..<h {
            // FITS row 0 is the bottom; TIFF starts at the top.
            let src = (h - 1 - y) * w
            for x in 0..<w {
                for c in 0..<3 {
                    let raw = Float(frame.pixels[(src + x) * 4 + c]) / 65535
                    let o = c == 0 ? calOffset.x : (c == 1 ? calOffset.y : calOffset.z)
                    let g = c == 0 ? calGain.x : (c == 1 ? calGain.y : calGain.z)
                    let v = (raw - o) * g
                    let s = c == 0 ? sh.x : (c == 1 ? sh.y : sh.z)
                    let m = c == 0 ? mid.x : (c == 1 ? mid.y : mid.z)
                    let n = max(0, min(1, (v - s) / max(1e-6, 1 - s)))
                    let stretched = mtf(m, n)
                    out[(y * w + x) * 3 + c] = UInt16(max(0, min(1, stretched)) * 65535)
                }
            }
        }

        guard let data = rep.representation(using: .tiff, properties: [:]) else {
            return "Could not encode TIFF"
        }
        do {
            try data.write(to: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func mtfPublic(_ m: Float, _ x: Float) -> Float { mtf(m, x) }

    private static func mtf(_ m: Float, _ x: Float) -> Float {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        if abs(m - 0.5) < 1e-6 { return x }
        return ((m - 1) * x) / (((2 * m - 1) * x) - m)
    }
}
