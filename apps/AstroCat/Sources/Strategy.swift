import Foundation

/// The raw values are stable identifiers, not labels — a stack settings file
/// stores one. See `WhiteReference`.
enum StrategyChoice: String, CaseIterable, Codable {
    case full, drizzle, binned

    var label: String {
        switch self {
        case .full: return "Full resolution"
        case .drizzle: return "Drizzle 2×"
        case .binned: return "Binned 2×2"
        }
    }

    /// What it does to the output, in terms you can check afterwards.
    var effect: String {
        switch self {
        case .full:
            return "Sensor scale, cubic resampling. Keeps the sampling you have."
        case .drizzle:
            return "Doubles the grid and drops raw Bayer samples onto it, no demosaic. Recovers detail only if frames are dithered. Four times the memory and slower."
        case .binned:
            return "Averages 2×2 before stacking. Halves the noise, halves the scale."
        }
    }

    func matches(_ s: Strategy) -> Bool {
        switch self {
        case .drizzle: return s.drizzle > 0
        case .binned: return !s.fullResolution && s.drizzle == 0
        case .full: return s.fullResolution && s.drizzle == 0
        }
    }
}

enum Sampling: String {
    case under = "undersampled"
    case critical = "critically sampled"
    case over = "oversampled"
}

struct Strategy {
    var fullResolution: Bool
    var drizzle: Int
    var sampling: Sampling
    var scale: Float
    var fwhmPx: Float
    var reason: String
    var caveat: String?

    var label: String {
        if drizzle > 1 { return "Drizzle \(drizzle)×" }
        if drizzle == 1 { return "Drizzle 1×" }
        return fullResolution ? "Full resolution" : "Binned 2×2"
    }
}

/// The right combine strategy is a property of the data, not a preference.
/// Pixel scale against star size decides it; dither and frame count decide
/// whether drizzle can deliver what it promises.
enum Strategist {
    static func recommend(frames: [Frame], measuredDrift: Float?) -> Strategy? {
        guard !frames.isEmpty else { return nil }

        let scale = frames.first?.scale ?? 0
        var hfrs = frames.map(\.hfr).sorted()
        // HFR is measured on the half-res green channel, so a full-res star is
        // twice as wide; FWHM runs about twice HFR again.
        let fwhmPx = hfrs[hfrs.count / 2] * 4
        hfrs.removeAll()

        let sampling: Sampling =
            fwhmPx < 2.5 ? .under : (fwhmPx > 5 ? .over : .critical)
        let n = frames.count

        switch sampling {
        case .over:
            return Strategy(
                fullResolution: false, drizzle: 0, sampling: sampling, scale: scale,
                fwhmPx: fwhmPx,
                reason:
                    "Stars span \(fmt(fwhmPx)) px, comfortably more than the sampling needs. Binning 2×2 halves the noise and costs no real detail.",
                caveat: nil)

        case .critical:
            return Strategy(
                fullResolution: true, drizzle: 0, sampling: sampling, scale: scale,
                fwhmPx: fwhmPx,
                reason:
                    "Stars span \(fmt(fwhmPx)) px, close to ideal sampling. Full resolution with a cubic kernel keeps that; drizzle would add noise for no detail.",
                caveat: nil)

        case .under:
            let dither = measuredDrift
            let enoughFrames = n >= 50

            if let d = dither, d < 0.5 {
                return Strategy(
                    fullResolution: true, drizzle: 0, sampling: sampling, scale: scale,
                    fwhmPx: fwhmPx,
                    reason:
                        "Undersampled at \(fmt(scale))″/px, but frame-to-frame motion is only \(fmt(d)) px. Drizzle needs sub-pixel dither to recover anything, so full resolution is the honest choice.",
                    caveat: "Dithering between frames would make drizzle worth using.")
            }

            if !enoughFrames {
                return Strategy(
                    fullResolution: true, drizzle: 0, sampling: sampling, scale: scale,
                    fwhmPx: fwhmPx,
                    reason:
                        "Undersampled at \(fmt(scale))″/px, but \(n) frames is too few to fill a finer grid — drizzle would leave gaps.",
                    caveat: "Around 50 frames makes drizzle 2× viable.")
            }

            return Strategy(
                fullResolution: true, drizzle: 2, sampling: sampling, scale: scale,
                fwhmPx: fwhmPx,
                reason:
                    "Undersampled at \(fmt(scale))″/px with stars only \(fmt(fwhmPx)) px wide"
                    + (dither.map { ", and \(fmt($0)) px of dither across \(n) frames" }
                        ?? " across \(n) frames")
                    + ". Drizzle recovers detail the sensor never sampled directly.",
                caveat: dither == nil
                    ? "Dither is assumed from the mount type — run once to measure it."
                    : nil)
        }
    }

    /// Why the alternatives are not recommended, so the choice is arguable
    /// rather than taken on trust.
    static func rejected(_ chosen: Strategy) -> [(String, String)] {
        var out: [(String, String)] = []
        if chosen.drizzle == 0 {
            out.append(
                ("Drizzle 2×", chosen.sampling == .under
                    ? "Preconditions not met on this set."
                    : "Only helps undersampled data; this is \(chosen.sampling.rawValue)."))
        }
        if chosen.fullResolution {
            out.append(
                ("Binned 2×2", "Halves the scale to \(fmt(chosen.scale * 2))″/px — throws away detail this data has."))
        } else {
            out.append(("Full resolution", "Keeps the sampling but no extra detail, at four times the cost."))
        }
        return out
    }

    private static func fmt(_ v: Float) -> String {
        String(format: v < 10 ? "%.2f" : "%.0f", v)
    }
}
