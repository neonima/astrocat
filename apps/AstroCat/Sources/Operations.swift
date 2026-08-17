import Foundation
import simd

/// What kind of data a stage expects to be handed.
///
/// The stretch is the boundary between the two, so this is enough to decide
/// every legal position without spelling out rules per pair of operations.
enum Domain: String, Codable {
    /// Its maths assumes values still proportional to photons.
    case linear
    /// It expects the stretch to have already happened.
    case nonLinear
    /// Correct on either side, differently. Noise reduction is the honest case:
    /// chrominance noise is best attacked while the channels are still linear,
    /// luminance noise after the stretch has decided what is visible. Neither
    /// is wrong, so this is advice rather than a rule.
    case either
    /// The boundary itself.
    case boundary
    /// Not a treatment at all — the source, the split, the result.
    case spine
}

/// One kind of operation, and everything the pipeline needs to know to place it.
struct OpKind: Identifiable {
    let id: String
    let domain: Domain
    /// More than one is meaningful for most stages — two Tone stages that each
    /// push a different band, a second Zone balance after a palette. Where it
    /// is not, this says so rather than letting a duplicate quietly do nothing.
    let maxInstances: Int
    /// Why a duplicate is refused, for the ones that refuse.
    let single: String?
    let summary: String

    var id_: String { id }
}

enum Ops {
    static let all: [OpKind] = [
        OpKind(
            id: "Master", domain: .spine, maxInstances: 1, single: nil,
            summary: "The frame as stacked. Everything below reads from it."),
        OpKind(
            id: "Background extraction", domain: .spine, maxInstances: 1, single: nil,
            summary: "Fitted and removed while stacking, not here."),
        OpKind(
            id: "Star separation", domain: .spine, maxInstances: 1, single: nil,
            summary: "Splits the frame in two. Everything below it belongs to one layer."),
        OpKind(
            id: "Colour calibration", domain: .linear, maxInstances: 1,
            single:
                "One measurement of one frame. A second would either repeat it or contradict it.",
            summary: "Star colours against a reference, as a gain and an offset per channel."),
        OpKind(
            id: "Screen stretch", domain: .boundary, maxInstances: 1,
            single: "The stretch is what makes the data non-linear. There is one such moment.",
            summary: "Linear data made visible. Display only — the file stays linear."),
        OpKind(
            id: "Narrowband palette", domain: .linear, maxInstances: 2, single: nil,
            summary: "Remaps emission lines onto output channels as a 3x3 mix."),
        OpKind(
            id: "Zone balance", domain: .nonLinear, maxInstances: 4, single: nil,
            summary: "Contrast allocated across the tonal range, as slopes per zone."),
        OpKind(
            id: "Tone", domain: .nonLinear, maxInstances: 4, single: nil,
            summary: "Exposure, contrast, highlights, shadows, vibrance, SCNR."),
        OpKind(
            id: "Detail", domain: .nonLinear, maxInstances: 1,
            single:
                "Clarity needs a blurred copy of the whole frame at this point, so it drives a second render pass. One is what that pass can carry.",
            summary: "Local contrast at two radii, on luminance."),
        OpKind(
            id: "Output", domain: .spine, maxInstances: 1, single: nil,
            summary: "The finished picture, and where it leaves the app."),
    ]

    static func kind(_ id: String) -> OpKind {
        all.first { $0.id == id } ?? all[0]
    }

    /// Shader op codes. 0 is a no-op, which is what an unimplemented or
    /// structural stage compiles to.
    static func code(_ id: String) -> Int32 {
        switch id {
        case "Colour calibration": return 1
        case "Narrowband palette": return 2
        case "Screen stretch": return 3
        case "Zone balance": return 4
        case "Tone": return 5
        default: return 0
        }
    }

    /// The stages above the split, in the one order they can run. They belong to
    /// the frame rather than to either layer.
    static let head = ["Master", "Background extraction", "Star separation"]
    /// Pinned below everything, for the same reason Master is pinned above it:
    /// there is nowhere else the finished picture could be.
    static let tail = "Output"

    static func isSpine(_ id: String) -> Bool {
        kind(id).domain == .spine
    }

    /// What a fresh layer starts with. The two layers want different things —
    /// a star field has no nebulosity to allocate contrast to and no sky whose
    /// cast wants neutralising, so offering it those stages by default is
    /// offering work that will not help.
    static func template(for layer: DevelopModel.Layer?) -> [OpInstance] {
        switch layer {
        case .stars:
            return [
                OpInstance(kind: "Screen stretch"),
                OpInstance(kind: "Tone", on: false),
            ]
        case .starless:
            return [
                OpInstance(kind: "Colour calibration", on: false),
                OpInstance(kind: "Screen stretch"),
                OpInstance(kind: "Narrowband palette", on: false),
                OpInstance(kind: "Zone balance", on: false),
                OpInstance(kind: "Tone", on: false),
                OpInstance(kind: "Detail", on: false),
            ]
        case nil:
            return [
                OpInstance(kind: "Colour calibration", on: false),
                OpInstance(kind: "Screen stretch"),
                OpInstance(kind: "Narrowband palette", on: false),
                OpInstance(kind: "Zone balance", on: false),
                OpInstance(kind: "Tone", on: false),
                OpInstance(kind: "Detail", on: false),
            ]
        }
    }

    /// Which kinds can still be added to `stack`, with the reason when they
    /// cannot — a greyed row that says why beats one that just fails.
    static func addable(to stack: [OpInstance]) -> [(kind: OpKind, refusal: String?)] {
        all.filter { $0.domain != .spine }.map { k in
            let count = stack.filter { $0.kind == k.id }.count
            guard count >= k.maxInstances else { return (k, nil) }
            return (k, k.single ?? "Already at \(k.maxInstances), the most that is useful.")
        }
    }
}

/// One stage in a layer's stack: which kind it is, whether it is switched on,
/// and its own parameters.
///
/// Carrying every parameter set rather than a union costs a couple of hundred
/// bytes per stage and buys Codable for free, which is what makes a stack
/// survive a relaunch without a custom decoder per kind.
struct OpInstance: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: String
    var on = true

    var algorithm: Int32 = 1
    var p0: Float = 10
    var p1: Float = 0.2
    var p0Base: Float = 10
    var blend: Float = 1
    var black: Float = 0
    var midtone: Float = 0.25
    var midtoneBase: Float = 0.25
    var linked = false
    var saturation: Float = 1.15

    var palette: String = Palette.natural.rawValue
    var mix = PaletteMix()
    var zones = ZoneCurve()
    var tone = ToneParams()
    var detail = DetailParams()

    init(kind: String, on: Bool = true) {
        self.kind = kind
        self.on = on
    }

    var isStretch: Bool { kind == "Screen stretch" }

    /// What the sidebar row says under the name, computed rather than stored.
    /// A stored description has to be updated everywhere a value can change,
    /// and the ones that were missed are why panes used to wear stale labels.
    func summary(paletteName: String) -> String {
        switch kind {
        case "Screen stretch":
            let algo = Algorithm(rawValue: algorithm) ?? .stf
            return "\(linked ? "linked" : "unlinked") "
                + (algo == .stf ? "STF" : algo.label.lowercased())
        case "Narrowband palette":
            return on ? paletteName.lowercased() : "natural"
        case "Zone balance":
            return on && !zones.isIdentity ? "custom" : "even"
        case "Tone":
            return on && !tone.isIdentity ? "adjusted" : "neutral"
        case "Detail":
            return on && !detail.isIdentity
                ? String(format: "clarity %+.2f · %.0f px", detail.clarity, detail.radius)
                : "none"
        default:
            return ""
        }
    }
}

/// A stage as the shader sees it. Field order and types mirror `OpSlot` in
/// Shaders.metal exactly; a mismatch here is a silent misread there.
struct OpSlot {
    var shadows = SIMD3<Float>(repeating: 0)
    var midtone = SIMD3<Float>(repeating: 0.5)
    var calOffset = SIMD3<Float>(repeating: 0)
    var calGain = SIMD3<Float>(repeating: 1)
    var paletteR = SIMD3<Float>(1, 0, 0)
    var paletteG = SIMD3<Float>(0, 1, 0)
    var paletteB = SIMD3<Float>(0, 0, 1)
    var p0: Float = 10
    var p1: Float = 0.2
    var blend: Float = 1
    var saturation: Float = 1
    var exposure: Float = 0
    var contrast: Float = 0
    var toneHighlights: Float = 0
    var toneShadows: Float = 0
    var whites: Float = 0
    var blacks: Float = 0
    var vibrance: Float = 0
    var scnr: Float = 0
    var code: Int32 = 0
    var algorithm: Int32 = 1
    var lut: Int32 = 0

    /// A plain auto-stretch and nothing else, for the views that only ever want
    /// to look at a frame — stack previews, the as-stacked comparison.
    static func stf(shadows: SIMD3<Float>, midtone: SIMD3<Float>) -> OpSlot {
        var s = OpSlot()
        s.code = Ops.code("Screen stretch")
        s.algorithm = Algorithm.stf.rawValue
        s.shadows = shadows
        s.midtone = midtone
        s.blend = 1
        s.saturation = 1
        return s
    }
}

/// Where a stage may be dropped, and why not where it may not.
enum Placement {
    /// Legal indices in `stack` this instance could move to.
    static func legalTargets(for instance: OpInstance, in stack: [OpInstance]) -> Set<Int> {
        guard !Ops.isSpine(instance.kind) else { return [] }
        var ok = Set<Int>()
        for i in stack.indices {
            var next = stack
            if let from = next.firstIndex(where: { $0.id == instance.id }) {
                let moved = next.remove(at: from)
                next.insert(moved, at: min(i, next.count))
            }
            if refusal(next) == nil { ok.insert(i) }
        }
        return ok
    }

    /// Why an arrangement is refused, or nil when it is merely unusual.
    static func refusal(_ stack: [OpInstance]) -> String? {
        guard let stretch = stack.firstIndex(where: { $0.isStretch }) else { return nil }
        for (i, op) in stack.enumerated() {
            switch Ops.kind(op.kind).domain {
            case .linear where i > stretch:
                return
                    "\(op.kind) runs on linear data. The screen stretch is what makes the data non-linear, so it has to come first."
            case .nonLinear where i < stretch:
                return
                    "\(op.kind) expects the stretch to have happened. On linear data it would be acting on values that are all but zero."
            default:
                continue
            }
        }
        return nil
    }

    /// Allowed, but worth a word.
    static func warning(_ stack: [OpInstance], paletteActive: Bool) -> String? {
        guard let stretch = stack.firstIndex(where: { $0.isStretch }) else { return nil }
        for (i, op) in stack.enumerated() where Ops.kind(op.kind).domain == .either && op.on {
            return i < stretch
                ? "\(op.kind) is running on linear data, which suits chrominance noise and not much else."
                : "\(op.kind) is running after the stretch, which suits luminance noise. Chrominance noise is easier to reach before it."
        }
        if paletteActive,
            let tone = stack.firstIndex(where: { $0.kind == "Tone" && $0.on && $0.tone.scnr > 0 }),
            let mix = stack.firstIndex(where: { $0.kind == "Narrowband palette" && $0.on }),
            tone > mix
        {
            return
                "SCNR runs after the palette here. It pulls green toward the average of red and blue on the grounds that green is sensor cast — but after a narrowband palette green is OIII, so this will erase the emission line the palette exists to show."
        }
        return nil
    }
}
