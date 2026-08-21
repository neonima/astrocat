import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Exporter {
    /// Siril reads FITS bottom-up and wants the pedestal left in so it can find
    /// the same black point; everything else expects it gone.
    private static func conventions(_ target: ExportTarget) -> (bottomUp: Bool, pedestal: Bool) {
        switch target {
        case .siril: return (true, true)
        case .pixinsight: return (true, false)
        case .lightroom, .png, .jpeg: return (false, false)
        }
    }

    static func suggestedName(
        _ target: ExportTarget, object: String = "", frames: Int, exposure: Float, filter: String
    ) -> String {
        // Named after what it is a picture of, which is the only part of the
        // filename anyone reads later.
        let target_ = object.replacingOccurrences(of: " ", with: "")
        let stem = target_.isEmpty ? "Stack" : target_
        let base =
            frames > 0
            ? String(
                format: "%@_%dx%.0fs_%@", stem, frames, exposure,
                filter.isEmpty ? "LP" : filter)
            : "\(stem)_\(filter.isEmpty ? "LP" : filter)"
        switch target {
        case .lightroom: return base + ".tif"
        case .png: return base + ".png"
        case .jpeg: return base + ".jpg"
        default: return base + ".fit"
        }
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
        panel.message = "\(target.label) — \(target.settings)"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        if target == .lightroom {
            return writeTIFF(
                source: source, to: url, stretch: stretch, calibration: calibration)
        }
        if target.isFinishedImage {
            // These go through `exportImage` on the model, which has the
            // renderer. Reaching here means a caller took the wrong path.
            return "\(target.label) is exported from the develop view."
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

    /// Writes what the renderer produced, with the frame's provenance in EXIF.
    ///
    /// The pixels come from the same shader that drew the screen, so this is the
    /// picture you were looking at rather than a second implementation of the
    /// pipeline. `pixels` is BGRA, top row first, straight out of the Metal
    /// texture.
    @MainActor
    static func writeImage(
        pixels: [UInt8], width: Int, height: Int, target: ExportTarget, meta: FrameMeta?,
        to url: URL
    ) -> String? {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else {
            return "Nothing rendered to export"
        }

        // Metal gives BGRA; CoreGraphics is told so rather than the bytes being
        // shuffled here.
        var data = pixels
        guard
            let provider = CGDataProvider(
                data: Data(bytes: &data, count: width * height * 4) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                    .union(.byteOrder32Little),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { return "Could not build the image" }

        let type = target == .png ? UTType.png : UTType.jpeg
        guard
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, type.identifier as CFString, 1, nil)
        else { return "Could not create \(url.lastPathComponent)" }

        CGImageDestinationAddImage(dest, image, properties(meta, target) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return "Could not write \(url.lastPathComponent)"
        }
        return nil
    }

    /// What the picture is of and what took it.
    ///
    /// A FITS header carries all of this, and a PNG posted to a forum carries
    /// none of it unless it is written here — so the target, the optics and the
    /// integration go into EXIF where any viewer will show them. Fields the
    /// header did not supply are left out rather than written as zero.
    private static func properties(_ meta: FrameMeta?, _ target: ExportTarget) -> [CFString: Any] {
        var tiff: [CFString: Any] = [kCGImagePropertyTIFFSoftware: "AstroCat"]
        var exif: [CFString: Any] = [:]
        var props: [CFString: Any] = [
            kCGImagePropertyOrientation: 1
        ]
        if target == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }

        guard let m = meta else {
            props[kCGImagePropertyTIFFDictionary] = tiff
            return props
        }

        if !m.telescope.isEmpty {
            tiff[kCGImagePropertyTIFFMake] = m.telescope
            tiff[kCGImagePropertyTIFFModel] = m.telescope
            exif[kCGImagePropertyExifLensModel] = m.telescope
        }
        // The subject, which is the one thing a viewer most wants back.
        let subject = m.object.isEmpty ? "Deep sky" : m.object
        tiff[kCGImagePropertyTIFFImageDescription] = describe(m, subject: subject)

        if m.focalLen > 0 {
            exif[kCGImagePropertyExifFocalLength] = m.focalLen
            exif[kCGImagePropertyExifLensSpecification] = [m.focalLen, m.focalLen, 0, 0]
        }
        // Total integration, not the length of one sub — that is the exposure
        // this picture actually represents.
        let integration = m.totalExp > 0 ? m.totalExp : m.exposure
        if integration > 0 { exif[kCGImagePropertyExifExposureTime] = integration }
        if m.gain > 0 { exif[kCGImagePropertyExifISOSpeedRatings] = [Int(m.gain)] }
        if !m.dateObs.isEmpty {
            // FITS writes ISO 8601; EXIF wants colons in the date.
            let stamp = m.dateObs.replacingOccurrences(of: "T", with: " ")
            let exifDate = stamp.prefix(10).replacingOccurrences(of: "-", with: ":")
                + stamp.dropFirst(10).prefix(9)
            exif[kCGImagePropertyExifDateTimeOriginal] = String(exifDate)
            tiff[kCGImagePropertyTIFFDateTime] = String(exifDate)
        }
        exif[kCGImagePropertyExifUserComment] = describe(m, subject: subject)

        props[kCGImagePropertyTIFFDictionary] = tiff
        props[kCGImagePropertyExifDictionary] = exif
        if let gps = location(m) { props[kCGImagePropertyGPSDictionary] = gps }
        return props
    }

    /// One line a human can read in any image viewer.
    private static func describe(_ m: FrameMeta, subject: String) -> String {
        var parts = [subject]
        if m.stackCount > 0 {
            parts.append(
                m.exposure > 0
                    ? String(format: "%d × %.0fs", m.stackCount, m.exposure)
                    : "\(m.stackCount) frames")
        }
        if m.totalExp > 0 {
            parts.append(String(format: "%.1f h integration", m.totalExp / 3600))
        }
        if !m.filter.isEmpty { parts.append(m.filter) }
        if !m.telescope.isEmpty { parts.append(m.telescope) }
        if m.focalLen > 0 { parts.append(String(format: "%.0f mm", m.focalLen)) }
        return parts.joined(separator: " · ")
    }

    /// Where it was shot, when the header says. Absent rather than (0, 0),
    /// which is a real place in the Gulf of Guinea.
    private static func location(_ m: FrameMeta) -> [CFString: Any]? {
        guard m.siteLat != 0 || m.siteLong != 0 else { return nil }
        return [
            kCGImagePropertyGPSLatitude: abs(Double(m.siteLat)),
            kCGImagePropertyGPSLatitudeRef: m.siteLat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(Double(m.siteLong)),
            kCGImagePropertyGPSLongitudeRef: m.siteLong >= 0 ? "E" : "W",
        ]
    }

    static func mtfPublic(_ m: Float, _ x: Float) -> Float { mtf(m, x) }

    private static func mtf(_ m: Float, _ x: Float) -> Float {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        if abs(m - 0.5) < 1e-6 { return x }
        return ((m - 1) * x) / (((2 * m - 1) * x) - m)
    }
}
