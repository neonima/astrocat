import AppKit
import SwiftUI
import simd

enum Algorithm: Int32, CaseIterable, Identifiable {
    case none = 0, stf = 1, arcsinh = 2, hyperbolic = 3, logarithmic = 4, equalise = 5

    var id: Int32 { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .stf: return "Midtone transfer (STF)"
        case .arcsinh: return "Arcsinh"
        case .hyperbolic: return "Generalised hyperbolic"
        case .logarithmic: return "Logarithmic"
        case .equalise: return "Histogram equalisation"
        }
    }

    /// Whether the algorithm expects linear input. Pairing it with non-linear
    /// data is the mistake the segmented control warns about.
    var wantsLinear: Bool {
        switch self {
        case .equalise, .none: return false
        default: return true
        }
    }
}

enum SplitMode: String, CaseIterable {
    case both = "Before / after", after = "After", before = "Before"
}

enum ColorReference: Int32, CaseIterable {
    case background = 0, starField = 1, catalogue = 2

    var label: String {
        switch self {
        case .background: return "Sky"
        case .starField: return "Stars"
        case .catalogue: return "Catalogue"
        }
    }

    /// What the mode assumes, stated plainly — each one buys accuracy with a
    /// different assumption, and the assumption is the part worth knowing.
    var claim: String {
        switch self {
        case .background:
            return "Equalises the three sky backgrounds and nothing else. Removes the light-pollution cast without claiming anything about star colour, so it is safe on any target."
        case .starField:
            return "Assumes the average field star is white and corrects the gains until it is. Wrong wherever the field is genuinely reddened — in the galactic plane the average star really is red, and this will scrub that out."
        case .catalogue:
            return "Matches detected stars to catalogue photometry and solves the gains against a chosen white. The only mode that assumes nothing about this field, and the only one that needs the frame plate-solved first."
        }
    }
}

/// What should come out neutral, as a Gaia `BP - RP` colour index. The choice
/// is an editorial one — there is no such thing as the correct white for a
/// picture of the sky, only a stated one.
enum WhiteReference: String, CaseIterable {
    case g2v = "G2V (Sun-like)"
    case spiral = "Average spiral galaxy"
    case a0v = "A0V (Vega)"

    var index: Float {
        switch self {
        case .g2v: return 0.82
        case .spiral: return 0.85
        case .a0v: return 0.0
        }
    }

    var note: String {
        switch self {
        case .g2v:
            return "A star like the Sun renders neutral. The usual choice, and the one that makes a galaxy's stellar population look right."
        case .spiral:
            return "The integrated light of an average spiral galaxy renders neutral. Marginally redder than G2V."
        case .a0v:
            return "Vega renders neutral, the old photometric zero point. Makes everything else look warm."
        }
    }
}

/// The palette in the terms that mean something physically: two extracted
/// emission signals, and how much of each reaches every output channel. The
/// 3x3 the shader wants falls out of this — driving nine numbers directly would
/// be a matrix editor, not a colour control.
struct PaletteMix: Equatable, Codable {
    /// Ha's share of each output channel; OIII takes the remainder.
    var red: Float = 1
    var green: Float = 0
    var blue: Float = 0
    /// Where OIII is read from. It lands across G and B on an OSC sensor, but
    /// not evenly — the split depends on the filter and the sensor's response.
    var oiiiBalance: Float = 0.5
    var haGain: Float = 1
    var oiiiGain: Float = 1

    /// Channels straight through, for when the palette is off.
    static let identity = (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1))

    var rows: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let ha = SIMD3<Float>(1, 0, 0) * haGain
        let oiii = SIMD3<Float>(0, oiiiBalance, 1 - oiiiBalance) * oiiiGain
        let row = { (share: Float) in ha * share + oiii * (1 - share) }
        return (row(red), row(green), row(blue))
    }
}

/// Narrowband palettes as a 3x3 mix on linear channels.
///
/// On a one-shot-colour camera the emission lines are not separate exposures:
/// through a dual-band filter Ha lands in R and OIII lands across G and B.
/// That makes HOO a real mapping and SII a fiction, and the difference is
/// stated rather than hidden.
enum Palette: String, CaseIterable {
    case natural = "Natural"
    case hoo = "HOO"
    case ohh = "OHH"
    case sho = "SHO (synthetic SII)"

    var mix: PaletteMix {
        switch self {
        case .natural: return PaletteMix()
        case .hoo: return PaletteMix(red: 1, green: 0, blue: 0)
        case .ohh: return PaletteMix(red: 0, green: 1, blue: 1)
        // The red channel is Ha standing in for SII, which this data does not
        // contain; green is half Ha, blue the genuine OIII.
        case .sho: return PaletteMix(red: 1, green: 0.5, blue: 0)
        }
    }

    var note: String {
        switch self {
        case .natural:
            return "Channels as recorded. The only mapping that claims nothing."
        case .hoo:
            return "Ha to red, OIII to green and blue. On dual-band data this is a real mapping — the filter genuinely separates those two lines onto those sensor channels."
        case .ohh:
            return "OIII to red, Ha to green and blue. The same real separation as HOO, swapped — a teal-and-gold look rather than red-and-cyan."
        case .sho:
            return "The Hubble arrangement, but a one-shot-colour sensor records no SII. The red channel here is Ha standing in for it. Green and blue are genuine. Treat it as a look, not a measurement."
        }
    }
}

struct ColorCal {
    var offset = SIMD3<Float>(repeating: 0)
    var gain = SIMD3<Float>(repeating: 1)
    var skyBefore = SIMD3<Float>(repeating: 0)
    var skyAfter: Float = 0
    var ratioR: Float = 1
    var ratioB: Float = 1
    var scatterR: Float = 0
    var scatterB: Float = 0
    var starsFound = 0
    var starsUsed = 0
    var shadows = SIMD3<Float>(repeating: 0)
    var midtone = SIMD3<Float>(repeating: 0.5)
    var linkedShadows: Float = 0
    var linkedMidtone: Float = 0.5
    var matched = 0
    var slopeR: Float = 0
    var slopeB: Float = 0
    var colourSpan: Float = 0
    var white: Float = 0
    var medianColour: Float = 0
    var ms: Float = 0

    init(_ c: AcColorCal) {
        matched = Int(c.matched)
        slopeR = c.slope_r
        slopeB = c.slope_b
        colourSpan = c.colour_span
        white = c.white
        medianColour = c.median_colour
        offset = SIMD3(c.offset_r, c.offset_g, c.offset_b)
        gain = SIMD3(c.gain_r, c.gain_g, c.gain_b)
        skyBefore = SIMD3(c.sky_r, c.sky_g, c.sky_b)
        skyAfter = c.sky_after
        ratioR = c.ratio_r
        ratioB = c.ratio_b
        scatterR = c.scatter_r
        scatterB = c.scatter_b
        starsFound = Int(c.stars_found)
        starsUsed = Int(c.stars_used)
        shadows = SIMD3(c.shadows_r, c.shadows_g, c.shadows_b)
        midtone = SIMD3(c.midtone_r, c.midtone_g, c.midtone_b)
        linkedShadows = c.linked_shadows
        linkedMidtone = c.linked_midtone
        ms = c.ms
    }
}

@MainActor
final class DevelopModel: ObservableObject {
    // MARK: Layers

    /// The frame as stacked. Everything derived from it inherits its geometry
    /// and its calibration, so it stays loaded whether or not it is on screen.
    let master = LayerState(template: Ops.template(for: nil))
    @Published private(set) var starless: LayerState?
    @Published private(set) var stars: LayerState?

    enum Layer: String, CaseIterable {
        case starless = "Starless"
        case stars = "Stars"

        var other: Layer { self == .starless ? .stars : .starless }
    }

    /// Where the merged result sits relative to the two layers.
    enum SplitLayout: String, CaseIterable {
        case stacked = "Merged above"
        case triptych = "Merged between"
    }

    @Published var splitLayout: SplitLayout = .stacked
    @Published var activeLayer: Layer = .starless
    @Published var layers: (starless: URL, stars: URL)?

    func state(for layer: Layer) -> LayerState? {
        layer == .starless ? starless : stars
    }

    /// The picture the inspector is pointed at. Every parameter below reads and
    /// writes through this — which is what makes selecting a pane a change of
    /// address and nothing else. The other layer is already loaded, already
    /// configured and already drawn, so switching moves no pixels and reloads
    /// no files.
    var active: LayerState {
        guard separated, let s = state(for: activeLayer) else { return master }
        return s
    }

    /// Every picture currently being edited. Both layers are configured on each
    /// push, so neither pane can be showing a stale set of parameters.
    var liveStates: [LayerState] {
        separated ? [starless, stars].compactMap { $0 } : [master]
    }

    var separated: Bool {
        layers != nil && starless != nil && stars != nil && sharedOn.contains("Star separation")
    }

    /// The two stacks hold different instances, so a stage id from one layer
    /// names nothing in the other. Carrying the *kind* across keeps the
    /// inspector on the thing you were working on; without this, switching
    /// layers left the selection pointing at nothing, which reads as every
    /// control silently refusing to do anything.
    func select(_ layer: Layer) {
        guard layer != activeLayer else { return }
        let wanted = selectedName
        activeLayer = layer
        guard case .stage = selection else { return }
        if let match = active.stack.first(where: { $0.kind == wanted }) {
            selection = .stage(match.id)
        } else {
            selection = .head("Master")
        }
    }

    /// One layer back to its template, leaving the other alone. The layers are
    /// independent everywhere else, so undoing a mess on one should not cost
    /// the work on the other.
    func resetLayer(_ layer: Layer) {
        guard let s = state(for: layer) else { return }
        objectWillChange.send()
        s.clear(template: Ops.template(for: layer))
        var stretch = s.stretch
        stretch.linked = layer == .stars
        let base = baseline(for: s).midtone
        stretch.midtone = stretch.linked ? (base.x + base.y + base.z) / 3 : base.y
        stretch.midtoneBase = stretch.midtone
        s.stretch = stretch
        if activeLayer == layer { selection = .head("Master") }
        push()
    }

    /// Which stages are switched on, per layer. The whole class of confusion
    /// here is a stage being on somewhere you are not looking, so both lists are
    /// shown side by side rather than only the selected one's.
    func stagesOn(_ layer: Layer) -> String {
        guard let s = state(for: layer) else { return "—" }
        let on = s.stack.filter(\.on).map { $0.kind == "Colour calibration" ? "cal" : $0.kind }
        return on.isEmpty ? "nothing on" : on.joined(separator: ", ").lowercased()
    }

    /// What each layer is actually running, for the readout in the layer bar.
    /// Stage count is what you asked for; slot count is what reached the shader,
    /// and the two differing is the whole diagnosis when a control does nothing.
    func pipelineSummary(_ layer: Layer) -> String {
        guard let s = state(for: layer) else { return "—" }
        let on = s.stack.filter(\.on).count
        return "\(on)/\(s.stack.count) on · \(s.renderer.ops.count) applied"
    }

    func path(for layer: Layer) -> String? { state(for: layer)?.path }

    // MARK: Operations

    /// Which stage the inspector is editing.
    ///
    /// A stage is addressed by identity, not by index, so reordering the stack
    /// or switching to a layer with a different stack cannot silently point the
    /// panels at someone else's parameters.
    enum Selection: Hashable {
        /// Above the split, so it belongs to the frame.
        case head(String)
        case stage(UUID)
        case output
    }

    @Published var selection: Selection = .head("Master") {
        didSet {
            if selection == .stage(colourStageID ?? UUID()), colorCal == nil { measureColour() }
        }
    }

    /// Whether the spine stages are on. Only these are shared: the source, the
    /// stack-time extraction, and the split itself. Everything else lives in a
    /// layer's own stack.
    @Published private var sharedOn: Set<String> = ["Master", "Background extraction"]

    var stack: [OpInstance] { active.stack }

    private var colourStageID: UUID? {
        active.stack.first { $0.kind == "Colour calibration" }?.id
    }

    /// The rows the sidebar shows: the shared head, this layer's stack, the
    /// pinned result. Built rather than stored — a parallel array of switches
    /// and labels has to be kept in step by hand in as many places as there are
    /// ways to change a value, and every stale label so far was one of those
    /// places missed.
    struct Row: Identifiable {
        let id: Selection
        let name: String
        let state: String
        let on: Bool
        let fixed: Bool
        /// Nil for a head or the output row.
        let stage: OpInstance?

        var isSpine: Bool { stage == nil }
    }

    var rows: [Row] {
        var out = Ops.head.map { name in
            Row(
                id: .head(name), name: name, state: describeHead(name),
                on: sharedOn.contains(name), fixed: true, stage: nil)
        }
        out += active.stack.map { op in
            Row(
                id: .stage(op.id), name: op.kind,
                state: op.kind == "Colour calibration"
                    ? (op.on
                        ? colourState : (colorCal == nil ? "not measured" : "measured · not applied"))
                    : op.summary(paletteName: Self.paletteName(op.mix, op.palette)),
                on: op.on, fixed: false, stage: op)
        }
        out.append(
            Row(
                id: .output, name: Ops.tail, state: outputState, on: true, fixed: true,
                stage: nil))
        return out
    }

    var selectedName: String {
        switch selection {
        case .head(let n): return n
        case .output: return Ops.tail
        case .stage(let id): return active.stack.first { $0.id == id }?.kind ?? "Master"
        }
    }

    /// The stage the panels edit, or nil when a spine row is selected.
    var stage: OpInstance? {
        guard case .stage(let id) = selection else { return nil }
        return active.stack.first { $0.id == id }
    }

    /// Reads and writes the selected stage. Everything the panels bind to goes
    /// through here, which is what makes a second Tone stage genuinely second
    /// rather than another view of the first.
    func editStage(_ body: (inout OpInstance) -> Void) {
        guard case .stage(let id) = selection, let i = active.index(of: id) else { return }
        objectWillChange.send()
        body(&active.stack[i])
        push()
    }

    private func describeHead(_ name: String) -> String {
        switch name {
        case "Master":
            return "as stacked"
        case "Background extraction":
            return gradientAfter > 0
                ? String(
                    format: "degree 2 · removed %.0f×", gradientBefore / max(gradientAfter, 1e-9))
                : "degree 2 · one-sided rejection"
        default:
            if separating { return "running \(StarSeparation.remover(removerID).name)…" }
            guard layers != nil else { return "not separated" }
            return separated ? "starless + stars" : "layers cached"
        }
    }

    private var outputState: String {
        separated ? "merged · \(activeLayer.rawValue.lowercased()) selected" : "single frame"
    }

    // MARK: Stack editing

    func setStage(_ id: UUID, on: Bool) {
        guard let i = active.index(of: id) else { return }
        objectWillChange.send()
        active.stack[i].on = on
        // Calibration moves the stretch onto a different baseline, so it is the
        // one switch that has to do more than redraw.
        if active.stack[i].kind == "Colour calibration" {
            if on, colorCal == nil {
                measureColour()
                push()
            } else {
                applyBaseline()
            }
            return
        }
        push()
    }

    func setHead(_ name: String, on: Bool) {
        if name == "Star separation" {
            guard layers != nil else {
                if on { separateStars() }
                return
            }
            objectWillChange.send()
            if on {
                sharedOn.insert(name)
                if starless == nil || stars == nil { attachLayers(for: master.path) }
            } else {
                sharedOn.remove(name)
            }
            push()
            return
        }
        objectWillChange.send()
        if on { sharedOn.insert(name) } else { sharedOn.remove(name) }
        push()
    }

    /// Adds a stage at the first position that is legal for it, so the common
    /// case needs no dragging at all.
    func addStage(_ kind: String) {
        objectWillChange.send()
        let op = OpInstance(kind: kind)
        var next = active.stack
        // Last legal slot: a new stage is nearly always meant to act on what is
        // already there rather than before it.
        var placed = false
        for i in stride(from: next.count, through: 0, by: -1) {
            var trial = next
            trial.insert(op, at: i)
            if Placement.refusal(trial) == nil {
                next = trial
                placed = true
                break
            }
        }
        if !placed { next.append(op) }
        active.stack = next
        selection = .stage(op.id)
        orderError = nil
        push()
    }

    func duplicateStage(_ id: UUID) {
        guard let i = active.index(of: id) else { return }
        let kind = Ops.kind(active.stack[i].kind)
        guard active.stack.filter({ $0.kind == kind.id }).count < kind.maxInstances else {
            orderError = kind.single ?? "Already at \(kind.maxInstances)."
            return
        }
        objectWillChange.send()
        var copy = active.stack[i]
        copy.id = UUID()
        active.stack.insert(copy, at: i + 1)
        selection = .stage(copy.id)
        orderError = nil
        push()
    }

    func removeStage(_ id: UUID) {
        guard let i = active.index(of: id) else { return }
        if active.stack[i].isStretch {
            orderError =
                "The stretch is what makes linear data visible. Removing it leaves a black frame, so it stays."
            return
        }
        objectWillChange.send()
        active.stack.remove(at: i)
        if selection == .stage(id) { selection = .head("Master") }
        orderError = nil
        push()
    }

    /// Which positions a drag could legally land in, so the sidebar can show the
    /// answer during the gesture rather than refusing after it.
    func legalTargets(for id: UUID) -> Set<Int> {
        guard let op = active.stack.first(where: { $0.id == id }) else { return [] }
        return Placement.legalTargets(for: op, in: active.stack)
    }

    @discardableResult
    func moveStage(_ id: UUID, to index: Int) -> Bool {
        guard let from = active.index(of: id), from != index,
            active.stack.indices.contains(index)
        else { return false }

        var next = active.stack
        let moved = next.remove(at: from)
        next.insert(moved, at: min(index, next.count))
        if let why = Placement.refusal(next) {
            orderError = why
            return false
        }
        objectWillChange.send()
        orderError = nil
        active.stack = next
        push()
        return true
    }

    // MARK: Parameters, forwarded to the selected layer

    /// Mutating a layer is not a change SwiftUI can see by itself — `LayerState`
    /// is a reference the model hands out, not a published value — so the
    /// announcement is made here.
    private func edit(_ body: (LayerState) -> Void) {
        objectWillChange.send()
        body(active)
    }

    /// The stretch stage's parameters, reached directly rather than through the
    /// selection. There is one stretch per layer and it is the tonal baseline
    /// everything else is expressed against, so the histogram's black point and
    /// link toggle mean the same thing whatever stage happens to be open.
    private func editStretch(_ body: (inout OpInstance) -> Void) {
        objectWillChange.send()
        var s = active.stretch
        body(&s)
        active.stretch = s
        push()
    }

    var algorithm: Algorithm {
        get { Algorithm(rawValue: active.stretch.algorithm) ?? .stf }
        set {
            guard newValue.rawValue != active.stretch.algorithm else { return }
            editStretch { $0.algorithm = newValue.rawValue }
            autoFit()
            push()
        }
    }

    var linked: Bool {
        get { active.stretch.linked }
        set { editStretch { $0.linked = newValue } }
    }

    /// Every algorithm gets fitted the way STF is — solve its parameter so the
    /// measured background lands on the same target. Without this, arcsinh and
    /// logarithmic default to values that render linear data black.
    /// `preserving` re-fits the baseline but keeps however far the slider had
    /// been moved away from it, so a change of baseline rescales the tuning
    /// instead of discarding it.
    private func autoFit(preserving: Bool = false) {
        guard let m = master.meta else { return }
        let s = active
        let shadow = Double(baseline(for: s).shadows.y)
        var median = Double(m.median)
        if calibrated(s), let c = colorCal {
            median = Double((m.median - c.offset.y) * c.gain.y)
        }
        let bg = max(1e-9, (median - shadow) / max(1e-6, 1 - shadow))
        let target = 0.25

        func solve(_ f: (Double, Double) -> Double) -> Float {
            var lo = 1.0
            var hi = 1_000_000.0
            for _ in 0..<60 {
                let mid = (lo * hi).squareRoot()
                if f(mid, bg) < target { lo = mid } else { hi = mid }
            }
            return Float((lo * hi).squareRoot())
        }

        var stretch = s.stretch
        var fitted: Float?
        switch Algorithm(rawValue: stretch.algorithm) ?? .stf {
        case .arcsinh:
            fitted = solve { k, x in asinh(k * x) / asinh(k) }
        case .logarithmic:
            fitted = solve { k, x in log(1 + k * x) / log(1 + k) }
        case .hyperbolic:
            stretch.p1 = Float(bg)
            fitted = solve { d, x in
                let sp = bg
                let span = max(1 - sp, sp)
                return min(1, max(0, asinh(d * (x - sp)) / asinh(d * span) * span + sp))
            }
        case .stf, .equalise, .none:
            fitted = nil
        }

        if let fitted {
            let offBaseline = preserving && stretch.p0Base > 1e-6 ? stretch.p0 / stretch.p0Base : 1
            stretch.p0Base = fitted
            stretch.p0 = min(1_000_000, max(1, fitted * offBaseline))
        }
        s.stretch = stretch
    }

    var p0: Float {
        get { active.stretch.p0 }
        set { editStretch { $0.p0 = newValue } }
    }
    var p1: Float {
        get { active.stretch.p1 }
        set { editStretch { $0.p1 = newValue } }
    }
    var blend: Float {
        get { active.stretch.blend }
        set { editStretch { $0.blend = newValue } }
    }
    var black: Float {
        get { active.stretch.black }
        set { editStretch { $0.black = newValue } }
    }
    /// Absolute midtone for green; the other channels keep their auto ratio so
    /// dragging it brightens without shifting colour.
    var midtone: Float {
        get { active.stretch.midtone }
        set { editStretch { $0.midtone = newValue } }
    }
    var saturation: Float {
        get { active.stretch.saturation }
        set { editStretch { $0.saturation = newValue } }
    }

    /// These act on whichever stage is selected, so a second Tone stage is
    /// genuinely a second one rather than another view of the first.
    var palette: Palette {
        get { Palette(rawValue: stage?.palette ?? "") ?? .natural }
        set {
            editStage {
                $0.palette = newValue.rawValue
                $0.mix = newValue.mix
            }
        }
    }
    /// Presets seed this; the sliders own it from then on.
    var mix: PaletteMix {
        get { stage?.mix ?? PaletteMix() }
        set { editStage { $0.mix = newValue } }
    }
    var zones: ZoneCurve {
        get { stage?.zones ?? ZoneCurve() }
        set { editStage { $0.zones = newValue } }
    }
    var zoneTable: [Float] { (stage?.zones ?? ZoneCurve()).table() }
    var tone: ToneParams {
        get { stage?.tone ?? ToneParams() }
        set { editStage { $0.tone = newValue } }
    }
    var detail: DetailParams {
        get { stage?.detail ?? active.detailStage?.detail ?? DetailParams() }
        set { editStage { $0.detail = newValue } }
    }

    var histogramRGB: [[Float]] { active.histogramRGB }

    /// What the shader is actually applying, read back off the slots so an
    /// export bakes in the picture on screen rather than a second derivation
    /// of it.
    var bakedStretch: (SIMD3<Float>, SIMD3<Float>) {
        guard let slot = active.renderer.ops.first(where: { $0.code == 3 }) else {
            return (.zero, SIMD3(repeating: 0.5))
        }
        return (slot.shadows, slot.midtone)
    }

    var bakedCalibration: (SIMD3<Float>, SIMD3<Float>)? {
        guard let slot = active.renderer.ops.first(where: { $0.code == 1 }) else { return nil }
        return (slot.calOffset, slot.calGain)
    }
    /// The renderer driving whichever picture the inspector is editing.
    var renderer: Renderer { active.renderer }
    var meta: FrameMeta? { master.meta }
    var source: String { master.path }

    @Published var linearMode = true
    @Published var displayOnly = true
    /// Unpinned, the two panels fold away and reappear on approach, so an
    /// untouched view is the whole window.
    @Published var panelsPinned = true
    @Published var bake = false
    @Published var split: SplitMode = .both
    @Published var holdingB = false

    @Published var colorReference: ColorReference = .starField {
        didSet {
            guard colorReference != oldValue, !restoring else { return }
            // The calibration in force stays applied until the new one lands,
            // so switching modes does not flash an uncalibrated frame and then
            // a second time when the measure returns.
            measureColour()
        }
    }
    @Published var colorCal: ColorCal?
    @Published var colorBusy = false
    @Published var narrowband = false
    /// The return code of the last measure: -1 no WCS, -2 catalogue too thin.
    @Published var colorFailure: Int32 = 0
    @Published var whiteReference: WhiteReference = .g2v {
        didSet {
            guard whiteReference != oldValue, colorReference == .catalogue, !restoring
            else { return }
            measureColour()
        }
    }
    @Published var cone = AcCone()
    @Published var solving = false
    @Published var masters: [URL] = []

    @Published var separating = false
    @Published var separationMessage: String?
    @Published var removerID = "starnet2"
    /// Kept in defaults rather than with the frame: it is a statement about how
    /// this machine runs the model, not about this picture.
    @Published var separationOptions = SeparationOptions.stored {
        didSet { SeparationOptions.stored = separationOptions }
    }

    /// True when the layers on disk were made with settings that are no longer
    /// the ones selected, so the button can offer a rerun instead of leaving a
    /// changed option looking like it did nothing.
    var separationStale: Bool {
        !source.isEmpty
            && StarSeparation.isStale(
                for: source, remover: removerID, options: separationOptions)
    }

    /// Twenty seconds of inference, so it runs once and caches beside the
    /// master. Off the main thread, and reporting failure rather than leaving
    /// the button looking like it worked.
    func separateStars(force: Bool = false) {
        guard !source.isEmpty, !separating else { return }
        let model = StarSeparation.remover(removerID)
        let options = separationOptions
        separating = true
        separationMessage =
            "Running \(model.name)"
            + (options.upsample
                ? " with 2× upsampling — a minute or so on a frame this size."
                : " — about ten seconds.")
        let path = source

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try StarSeparation.separate(
                    master: path, remover: model.id, options: options, force: force)
                DispatchQueue.main.async {
                    guard path == self.source else { return }
                    self.separating = false
                    self.separationMessage = "Starless and star layers written beside the master."
                    self.attachLayers(for: path)
                    // Straight into the split: separating and then having to go
                    // and find the layers yourself is a step with no purpose.
                    self.sharedOn.insert("Star separation")
                    self.activeLayer = .starless
                    self.push()
                }
            } catch {
                DispatchQueue.main.async {
                    self.separating = false
                    self.separationMessage = error.localizedDescription
                }
            }
        }
    }

    /// Builds a live state for each layer, or clears both when the files are
    /// not there. Nothing else may set `layers` — deriving them from whatever
    /// happens to be open is how opening a layer used to end the split it was
    /// part of.
    private func attachLayers(for path: String) {
        guard StarSeparation.exists(for: path) else {
            layers = nil
            starless = nil
            stars = nil
            sharedOn.remove("Star separation")
            return
        }
        layers = (StarSeparation.starlessURL(for: path), StarSeparation.starsURL(for: path))
        // The starless layer still has a sky, so an unlinked stretch neutralises
        // its cast the way it does on any frame. The star layer has no sky at
        // all — per-channel fitting there has nothing to fit to, and the three
        // midtones diverge until one channel runs away with the picture.
        starless = makeLayer(layers!.starless.path, layer: .starless)
        stars = makeLayer(layers!.stars.path, layer: .stars)
    }

    private func makeLayer(_ path: String, layer: Layer) -> LayerState? {
        // On the master's normalisation, not its own. A layer's brightest pixel
        // is nebula where the master's is a star, so left to derive its own
        // scale it lands several times brighter and every inherited number
        // overshoots — red saturating last, which is why it went blue.
        guard let f = try? LoadedFrame(url: URL(fileURLWithPath: path), scale: masterScale)
        else { return nil }

        let s = LayerState(template: Ops.template(for: layer))
        s.upload(f)
        let linked = layer == .stars
        var stretch = s.stretch
        stretch.linked = linked
        stretch.saturation = master.stretch.saturation
        let base = baseline(for: s).midtone
        stretch.midtone = linked ? (base.x + base.y + base.z) / 3 : base.y
        stretch.midtoneBase = stretch.midtone
        s.stretch = stretch
        if let saved = DevelopSettings.load(path), let stack = saved.stack, !stack.isEmpty {
            s.stack = stack
        }
        return s
    }
    @Published var viewport = Viewport() { didSet { scheduleSave() } }
    @Published var cropping = false
    /// Drawn and measured but not applied, so the crop can be read before it
    /// throws anything away.
    @Published var pendingCrop: SIMD4<Float>?
    /// Width over height the box is held to, or nil for freeform. Expressed in
    /// screen terms, so it is what you see rather than what the texture stores.
    @Published var cropRatio: Double? { didSet { reshapeCrop() } }
    @Published var cropPortrait = true { didSet { reshapeCrop() } }
    /// Last known pane shape, so a gesture can work out where in the frame the
    /// cursor is without the view having to tell the model its geometry twice.
    private var viewAspect: Float = 1.6
    @Published var savedAt: Date?
    @Published var orderError: String?

    var imageAspect: Float {
        guard let m = meta, m.height > 0 else { return 1 }
        let a = Float(m.width) / Float(m.height)
        return a.isFinite && a > 0 ? a : 1
    }

    var zoomLabel: String {
        viewport.isFit ? "Fit" : String(format: "%.0f%%", viewport.zoom * 100)
    }

    func pinch(_ factor: Float, at ndc: SIMD2<Float>, viewAspect aspect: Float) {
        viewAspect = aspect
        viewport.zoom(
            to: viewport.zoom * factor, anchor: ndc, imageAspect: imageAspect,
            viewAspect: aspect)
        viewport.clampPan(imageAspect: imageAspect, viewAspect: aspect)
    }

    func zoomBy(_ factor: Float) {
        pinch(factor, at: .zero, viewAspect: viewAspect)
    }

    /// `displacement` is how far the picture should move, in normalised device
    /// coordinates. Pan itself lives in texture space, so the gesture has to go
    /// through the same matrix the sampling does — otherwise a rotated or
    /// flipped frame moves the wrong way, and even an unrotated one moves at
    /// the wrong speed, because the aspect fit scales the axes differently.
    func drag(_ displacement: SIMD2<Float>, viewAspect aspect: Float) {
        viewAspect = aspect
        let m = viewport.matrix(imageAspect: imageAspect, viewAspect: aspect)
        viewport.pan -= m.x * displacement.x + m.y * displacement.y
        viewport.clampPan(imageAspect: imageAspect, viewAspect: viewAspect)
    }

    /// Orientation survives: it is a property of how the frame should be read,
    /// not of where you happened to be looking.
    /// Records a marquee without committing it. Both corners go through the same
    /// matrix the sampling does, so the rectangle is stored in the frame's own
    /// coordinates and lands where it was drawn whatever the rotation, flip or
    /// zoom happens to be.
    func proposeCrop(from a: SIMD2<Float>, to b: SIMD2<Float>, viewAspect aspect: Float) {
        viewAspect = aspect
        let first = viewport.texel(at: a, imageAspect: imageAspect, viewAspect: aspect)
        let second = viewport.texel(at: b, imageAspect: imageAspect, viewAspect: aspect)
        let x = SIMD2(min(first.x, second.x), max(first.x, second.x))
        let y = SIMD2(min(first.y, second.y), max(first.y, second.y))
        pendingCrop = SIMD4(
            min(max(x[0], 0), 1), min(max(y[0], 0), 1),
            min(max(x[1], 0), 1), min(max(y[1], 0), 1))
    }

    /// Pixels the crop would keep, at the master's own resolution rather than
    /// the half-res preview's — that is the number worth confirming against.
    var cropResolution: (w: Int, h: Int)? {
        guard let c = pendingCrop, let m = meta else { return nil }
        let full = SIMD2(Float(max(m.srcWidth, m.width)), Float(max(m.srcHeight, m.height)))
        return (Int((c.z - c.x) * full.x), Int((c.w - c.y) * full.y))
    }

    var cropIsUsable: Bool {
        guard let r = cropResolution else { return false }
        return r.w >= 32 && r.h >= 32
    }

    var cropPrintSummary: String? {
        cropResolution.map { PrintSize.describe(px: $0) }
    }

    /// The locked ratio in screen terms, turned the way the picture is.
    var effectiveCropRatio: Double? {
        cropRatio.map { cropPortrait ? 1 / $0 : $0 }
    }

    /// The same ratio in texture terms. A crop of texture size w by h displays
    /// with aspect `imageAspect * w/h`, and a quarter turn inverts that, so the
    /// number the box is stored against is not the number on the button.
    private var textureCropRatio: Float? {
        guard let screen = effectiveCropRatio else { return nil }
        let a = Double(max(imageAspect, 1e-4))
        let turned = viewport.quarterTurns % 2 == 1
        return Float(turned ? 1 / (screen * a) : screen / a)
    }

    /// Applies the chosen ratio to the box that is already there, rather than
    /// waiting for the next drag to notice.
    private func reshapeCrop() {
        guard cropping, let target = textureCropRatio, target > 0 else { return }

        guard let c = pendingCrop else {
            // Nothing drawn yet: offer the largest box of this shape, centred.
            var w: Float = 1
            var h: Float = 1
            if target > 1 { h = 1 / target } else { w = target }
            pendingCrop = SIMD4(0.5 - w / 2, 0.5 - h / 2, 0.5 + w / 2, 0.5 + h / 2)
            return
        }

        let centre = SIMD2((c.x + c.z) / 2, (c.y + c.w) / 2)
        var w = c.z - c.x
        var h = c.w - c.y
        // Only ever shrink, so the reshaped box stays inside the frame without
        // needing to be nudged back in.
        if w / h > target { w = h * target } else { h = w / target }
        pendingCrop = SIMD4(
            centre.x - w / 2, centre.y - h / 2, centre.x + w / 2, centre.y + h / 2)
    }

    func confirmCrop() {
        guard let c = pendingCrop, cropIsUsable else { return }
        viewport.crop = c
        viewport.pan = .zero
        viewport.zoom = 1
        pendingCrop = nil
        cropping = false
    }

    func cancelCrop() {
        pendingCrop = nil
        cropping = false
    }

    /// Forgets everything: the saved settings files as well as what is on
    /// screen, so the frame comes back exactly as it did the first time it was
    /// opened. Distinct from reverting, which only resets the live parameters
    /// and leaves the files to be written again on the next change.
    func resetEverything() {
        let target = source
        for path in ([master.path] + [starless?.path, stars?.path].compactMap { $0 })
        where !path.isEmpty {
            try? FileManager.default.removeItem(at: Masters.settingsURL(for: path))
        }

        restoring = true
        sharedOn = ["Master", "Background extraction"]
        colorReference = .starField
        whiteReference = .g2v
        colorCal = nil
        colorCalReference = nil
        resetStacks()
        viewport = Viewport()
        cropRatio = nil
        pendingCrop = nil
        activeLayer = .starless
        restoring = false

        savedAt = nil
        if !target.isEmpty { load(target) } else { revert() }
    }

    /// Back to the master as it came out of the stack — geometry and every
    /// operation. The file was never touched, so this is a matter of forgetting
    /// parameters rather than undoing anything.
    func resetToMaster() {
        clearCrop()
        viewport = Viewport()
        sharedOn.remove("Star separation")
        activeLayer = .starless
        resetStacks()
        revert()
    }

    /// Every stack back to the template for its kind of picture.
    private func resetStacks() {
        master.clear(template: Ops.template(for: nil))
        starless?.clear(template: Ops.template(for: .starless))
        stars?.clear(template: Ops.template(for: .stars))
        selection = .head("Master")
    }

    func clearCrop() {
        pendingCrop = nil
        viewport.crop = SIMD4(0, 0, 1, 1)
        viewport.pan = .zero
        viewport.zoom = 1
    }

    func resetView() {
        viewport.zoom = 1
        viewport.pan = .zero
    }

    var pipelineWarning: String? {
        Placement.warning(active.stack, paletteActive: paletteActive)
    }
    private var restoring = false
    private var saveTimer: Timer?
    private var histogramTimer: Timer?

    /// Names the preset the sliders currently sit on, or admits they have moved
    /// off one.
    static func paletteName(_ mix: PaletteMix, _ palette: String) -> String {
        if palette == Palette.natural.rawValue { return "Natural" }
        return Palette.allCases.first { $0 != .natural && $0.mix == mix }?.rawValue ?? "Custom"
    }
    var paletteName: String { Self.paletteName(mix, palette.rawValue) }
    private var colorStale = false
    /// Which mode produced `colorCal`, which is not always the selected mode —
    /// a measure can be in flight.
    @Published private(set) var colorCalReference: ColorReference?
    /// Calibration takes the linked toggle over while it is on. Remember what
    /// it was, or turning calibration off leaves a linked curve sitting on
    /// uncalibrated data — a different picture from the app's default.
    private var linkedBeforeCalibration: Bool?

    var paletteActive: Bool {
        active.stack.contains {
            $0.kind == "Narrowband palette" && $0.on && $0.palette != Palette.natural.rawValue
        }
    }
    var calibrationActive: Bool { calibrated(active) }

    /// One measurement, made on the master; each picture decides whether to wear
    /// it. Calibrating the nebulosity while leaving the stars alone is a real
    /// choice on this data — the extracted star layer is red-deficient, so the
    /// same gains that neutralise the sky push its stars cyan.
    private func calibrated(_ s: LayerState) -> Bool {
        s.stack.contains { $0.kind == "Colour calibration" && $0.on } && colorCal != nil
    }

    /// Off the main thread because this may plate-solve: when the frame has no
    /// WCS of its own it detects stars and matches triangles against the
    /// catalogue, which is seconds rather than milliseconds.
    func readCone(_ path: String) {
        guard !solving else { return }
        solving = true
        DispatchQueue.global(qos: .userInitiated).async {
            var c = AcCone()
            _ = path.withCString { ac_frame_cone($0, &c) }
            DispatchQueue.main.async {
                self.solving = false
                guard path == self.source else { return }
                self.cone = c
                if self.colorReference == .catalogue, self.colorCal == nil {
                    self.measureColour()
                }
            }
        }
    }

    /// Measured off the main thread: three background fits plus star photometry
    /// is a hundred milliseconds or so, which is long enough to stutter a drag.
    /// A request arriving mid-measure is coalesced into one rerun rather than
    /// queued, so dragging the tolerance slider settles instead of piling up.
    func measureColour() {
        guard !source.isEmpty else { return }
        if colorBusy {
            colorStale = true
            return
        }
        colorBusy = true
        let path = source
        let reference = colorReference
        let tolerance = sampleTolerance
        let white = whiteReference.index

        DispatchQueue.global(qos: .userInitiated).async {
            var out = AcColorCal()
            let ok = path.withCString { p in
                reference == .catalogue
                    ? ac_color_calibrate_catalog(p, white, tolerance, &out)
                    : ac_color_calibrate(p, reference.rawValue, tolerance, &out)
            }
            DispatchQueue.main.async { self.colorFailure = ok }
            DispatchQueue.main.async {
                self.colorBusy = false
                // The mode or the frame may have changed while this was in
                // flight; that request set colorStale and will rerun.
                if reference == self.colorReference, path == self.source {
                    let wasActive = self.calibrationActive
                    self.colorCal = (ok == 1 && out.ok == 1) ? ColorCal(out) : nil
                    self.colorCalReference = self.colorCal == nil ? nil : reference
                    // Only touch the stretch when the calibration is actually
                    // applied. Merely opening the panel must not move sliders.
                    if self.calibrationActive || wasActive {
                        self.applyBaseline()
                    } else {
                        self.push()
                    }
                }
                if self.colorStale {
                    self.colorStale = false
                    self.measureColour()
                }
            }
        }
    }

    private var colourState: String {
        if colorReference == .catalogue, colorCal == nil {
            return switch colorFailure {
            case -1: "frame has no plate solve"
            case -2: "catalogue does not cover this field"
            default: colorBusy ? "measuring…" : "not measured"
            }
        }
        if colorBusy { return "measuring…" }
        guard let c = colorCal, let measured = colorCalReference else { return "not measured" }
        switch measured {
        case .background:
            return "sky background · neutralised"
        case .starField:
            return c.starsUsed > 0
                ? "field stars · \(c.starsUsed) used"
                : "too few usable stars · sky only"
        case .catalogue:
            return "catalogue · \(c.matched) matched"
        }
    }

    /// Moves the stretch onto whichever baseline is now in force. Calibrated
    /// data is neutral and wants one curve over all three channels; an unlinked
    /// STF re-normalises each channel by its own noise and puts the cast
    /// straight back. Turning calibration off has to undo that, not leave it.
    ///
    /// The sliders are rescaled rather than reset — the baseline moves under
    /// them, but how far you had dragged away from it is your edit, and
    /// toggling calibration is not a request to throw it away.
    private func applyBaseline() {
        let s = active
        var stretch = s.stretch
        if calibrationActive {
            if linkedBeforeCalibration == nil { linkedBeforeCalibration = stretch.linked }
            stretch.linked = true
        } else if let previous = linkedBeforeCalibration {
            stretch.linked = previous
            linkedBeforeCalibration = nil
        }
        s.stretch = stretch

        let base = baseline(for: s).midtone.y
        let offBaseline = stretch.midtoneBase > 1e-6 ? stretch.midtone / stretch.midtoneBase : 1
        stretch.midtoneBase = base
        stretch.midtone = min(0.999, max(0.001, base * offBaseline))
        s.stretch = stretch
        autoFit(preserving: true)
        push()
    }

    /// Where the stretch starts from, before any slider moves it.
    ///
    /// A layer never gets its own fit. The method places the measured sky
    /// background at a quarter brightness, and a star layer has no sky — it is
    /// near zero everywhere with a few bright points, so a fresh fit collapses
    /// and the picture blows out. Both layers borrow the master's numbers, which
    /// is also the only choice under which the screen merge reconstructs the
    /// master it came from.
    private func baseline(for s: LayerState) -> (shadows: SIMD3<Float>, midtone: SIMD3<Float>) {
        if calibrated(s), let c = colorCal {
            return s.stretch.linked
                ? (SIMD3(repeating: c.linkedShadows), SIMD3(repeating: c.linkedMidtone))
                : (c.shadows, c.midtone)
        }
        return (
            master.meta?.shadows ?? .zero,
            master.meta?.midtone ?? SIMD3(repeating: 0.25)
        )
    }

    private func settings(_ s: LayerState) -> DevelopSettings {
        var d = DevelopSettings()
        d.stack = s.stack
        d.sampleTolerance = sampleTolerance
        d.colourReference = colorReference.rawValue
        d.white = whiteReference.rawValue
        d.rotation = viewport.rotation
        d.flipH = viewport.flipH
        d.flipV = viewport.flipV
        d.crop = viewport.crop
        d.separationOn = sharedOn.contains("Star separation")
        return d
    }

    /// Written on a short delay so dragging a slider does not write a file per
    /// frame, and atomically so a crash mid-drag cannot leave a half-file. Every
    /// state gets its own file, so a layer's edits survive independently of the
    /// master's.
    private func scheduleSave() {
        guard !restoring, !master.path.isEmpty else { return }
        saveTimer?.invalidate()
        let snapshots = ([master] + [starless, stars].compactMap { $0 })
            .filter { !$0.path.isEmpty }
            .map { ($0.path, settings($0)) }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
            Task { @MainActor in
                for (path, snapshot) in snapshots { snapshot.save(path) }
                self.savedAt = Date()
            }
        }
    }

    /// The half that belongs to the frame rather than to a layer.
    private func applyShared(_ d: DevelopSettings) {
        sampleTolerance = d.sampleTolerance
        colorReference = ColorReference(rawValue: d.colourReference) ?? .starField
        whiteReference = WhiteReference(rawValue: d.white) ?? .g2v
        if d.separationOn == true, layers != nil {
            sharedOn.insert("Star separation")
        } else {
            sharedOn.remove("Star separation")
        }
        viewport = Viewport(
            rotation: d.rotation, flipH: d.flipH, flipV: d.flipV, crop: d.crop)
    }

    var skyBalance: (before: String, after: String) {
        guard let c = colorCal else { return ("—", "—") }
        let s = c.skyBefore
        let total = max(s.x + s.y + s.z, 1e-9)
        return (
            String(
                format: "%.1f / %.1f / %.1f %%",
                100 * s.x / total, 100 * s.y / total, 100 * s.z / total),
            "33.3 / 33.3 / 33.3 %"
        )
    }
    @Published var sampleTolerance: Float = 2.0 {
        didSet {
            push()
            // Tolerance changes which tiles count as sky, so the fit has to be
            // redone for the readout to mean anything — and colour calibration
            // fits the same backgrounds.
            if !source.isEmpty, !restoring {
                measureGradient(source)
                if colorCal != nil { measureColour() }
            }
        }
    }
    @Published var gradientBefore: Float = 0
    @Published var gradientAfter: Float = 0

    @Published var dirty = false
    @Published var exportTarget: ExportTarget = .siril
    @Published var exportError: String?

    /// The as-stacked view. Still its own renderer for the merged pane, where
    /// the comparison really is a second picture; the single-frame split draws
    /// it as a branch in the same shader instead.
    let beforeRenderer = Renderer()

    /// The frame as it came out of the stack, as one stretch stage. This is what
    /// the shader shows on the left of the seam.
    var beforeSlot: OpSlot {
        beforeRenderer.ops.first ?? OpSlot.stf(
            shadows: master.meta?.shadows ?? .zero,
            midtone: master.meta?.midtone ?? SIMD3(repeating: 0.25))
    }

    var pairingWrong: Bool { algorithm.wantsLinear != linearMode }

    var skyLevels: String {
        guard let m = meta else { return "—" }
        let s = m.shadows
        let total = max(s.x + s.y + s.z, 1e-9)
        return String(
            format: "%.1f / %.1f / %.1f %%",
            100 * s.x / total, 100 * s.y / total, 100 * s.z / total)
    }

    /// The scale the master normalised to, so its layers can be put on the same
    /// one. Left at zero for a master, which then derives its own.
    private var masterScale: Float = 0

    /// Opens a master. Layers are never opened this way — they are attached to
    /// the master they came from, which is what stops a layer being taken for a
    /// frame and separated again into layers of a layer.
    func load(_ path: String) {
        guard !StarSeparation.isLayer(path),
            let f = try? LoadedFrame(url: URL(fileURLWithPath: path))
        else { return }

        restoring = true
        masterScale = f.meta.fullScale
        master.clear(template: Ops.template(for: nil))
        master.upload(f)
        var stretch = master.stretch
        stretch.midtone = f.meta.midtone.y
        stretch.midtoneBase = f.meta.midtone.y
        master.stretch = stretch

        beforeRenderer.upload(f)
        beforeRenderer.ops = [
            OpSlot.stf(shadows: f.meta.shadows, midtone: f.meta.midtone)
        ]

        colorCal = nil
        colorCalReference = nil
        linkedBeforeCalibration = nil
        colorFailure = 0
        separationMessage = nil
        sharedOn = ["Master", "Background extraction"]
        activeLayer = .starless
        viewport = Viewport()
        cone = AcCone()
        narrowband = f.meta.filter.withCString { ac_filter_is_narrowband($0) } == 1
        // A dual-band filter's passbands match no photometric system, and
        // forcing that sky neutral erases the Ha/OIII separation the data was
        // taken for. Sky-only neutralisation stays defensible; a white
        // reference does not.
        if narrowband { colorReference = .background }

        // Before the shared settings, which decide whether the split is entered.
        attachLayers(for: path)

        let saved = DevelopSettings.load(path)
        if let saved {
            if let stack = saved.stack, !stack.isEmpty { master.stack = stack }
            applyShared(saved)
        }
        selection = .head("Master")
        restoring = false

        savedAt = saved == nil ? nil : Masters.modified(Masters.settingsURL(for: path))
        measureGradient(path)
        readCone(path)
        push()
        computeHistogram()
        let wanted = ([master] + [starless, stars].compactMap { $0 })
            .contains { s in s.stack.contains { $0.kind == "Colour calibration" && $0.on } }
        if wanted || selectedName == "Colour calibration" {
            // A measurement, not a setting — re-fitted from the frame rather
            // than trusted from a file that may describe other pixels.
            measureColour()
        }
    }

    /// Measured by fitting the background model, not guessed from MAD.
    private func measureGradient(_ path: String) {
        var before: Float = 0
        var after: Float = 0
        path.withCString { p in
            before = ac_gradient_amplitude(p, 0, sampleTolerance)
            after = ac_gradient_amplitude(p, 1, sampleTolerance)
        }
        gradientBefore = before
        gradientAfter = after
    }

    /// Debounced: push() fires on every tick of a slider drag, and rebuilding
    /// this in line with it put a quarter of a million pixels of arithmetic
    /// between the drag and the frame.
    private func scheduleHistogram() {
        histogramTimer?.invalidate()
        histogramTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { _ in
            Task { @MainActor in self.computeHistogram() }
        }
    }

    /// Built by running the display pipeline the shader runs — calibration,
    /// palette, stretch, zones — over a sample of the frame. A histogram of the
    /// raw data would describe a picture nobody is looking at.
    private func computeHistogram() {
        let s = active
        guard let f = s.frame, let m = s.meta else { return }
        let n = m.width * m.height
        guard n > 0 else { return }

        // Walks the same slot list the shader walks, so a second Tone stage or
        // a second Zone balance shows up here too. Anything that needs a
        // neighbourhood is absent from both — a histogram of local contrast is
        // not a thing a histogram can show.
        let slots = s.renderer.ops
        let curves = s.zoneTables
        let pixels = f.pixels

        // One flat buffer rather than three nested arrays: the inner loop runs
        // a few hundred thousand times and Swift's bounds and copy-on-write
        // checks on [[Float]] dominate the arithmetic.
        var flat = [Float](repeating: 0, count: 768)
        var counted: Float = 0

        flat.withUnsafeMutableBufferPointer { bins in
            for i in stride(from: 0, to: n, by: 16) {
                var v = SIMD3<Float>(
                    Float(pixels[i * 4]), Float(pixels[i * 4 + 1]), Float(pixels[i * 4 + 2])
                ) / 65535
                v = Self.evaluate(v, slots: slots, zones: curves)
                for c in 0..<3 {
                    bins[c * 256 + min(255, max(0, Int(v[c] * 255)))] += 1
                }
                counted += 1
            }
        }

        let scale = max(counted, 1)
        objectWillChange.send()
        s.histogramRGB = (0..<3).map { c in
            Array(flat[(c * 256)..<(c * 256 + 256)]).map { $0 / scale }
        }

        var cdf = [Float](repeating: 0, count: 256)
        var acc: Float = 0
        for i in 0..<256 {
            acc += s.histogramRGB[1][i]
            cdf[i] = acc
        }
        s.renderer.setEqualisation(cdf)
    }

    /// The per-pixel half of the shader, in Swift. Kept next to the shader in
    /// behaviour rather than in code, which is a real duplication — but the
    /// alternative is a histogram of pixels nobody is looking at.
    private static func evaluate(
        _ input: SIMD3<Float>, slots: [OpSlot], zones: [[Float]]
    ) -> SIMD3<Float> {
        var v = input
        for slot in slots {
            switch slot.code {
            case 1:
                v = (v - slot.calOffset) * slot.calGain
            case 2:
                v = SIMD3(
                    simd_dot(slot.paletteR, v), simd_dot(slot.paletteG, v),
                    simd_dot(slot.paletteB, v))
            case 3:
                let algo = Algorithm(rawValue: slot.algorithm) ?? .stf
                for c in 0..<3 {
                    let sh = slot.shadows[c]
                    let x = max(0, min(1, (v[c] - sh) / max(1e-6, 1 - sh)))
                    v[c] = stretched(
                        x, algorithm: algo, midtone: slot.midtone[c], p0: slot.p0, p1: slot.p1)
                }
            case 4:
                let table = zones.indices.contains(Int(slot.lut)) ? zones[Int(slot.lut)] : nil
                if let table {
                    for c in 0..<3 {
                        v[c] = table[min(255, max(0, Int(v[c] * 255)))]
                    }
                }
            default:
                continue
            }
        }
        return simd_clamp(v, .zero, SIMD3(repeating: 1))
    }

    /// The transfer one channel is on, for drawing. Same path the shader takes,
    /// so the curve is the one being applied.
    func stretchCurve(_ channel: Int) -> [Float] {
        guard let slot = active.renderer.ops.first(where: { $0.code == 3 }) else {
            return (0..<256).map { Float($0) / 255 }
        }
        let algo = Algorithm(rawValue: slot.algorithm) ?? .stf
        let sh = slot.shadows[channel]
        let mid = slot.midtone[channel]
        return (0..<256).map { i in
            let v = Float(i) / 255
            let n = max(0, min(1, (v - sh) / max(1e-6, 1 - sh)))
            return Self.stretched(n, algorithm: algo, midtone: mid, p0: slot.p0, p1: slot.p1)
        }
    }

    private static func stretched(
        _ x: Float, algorithm: Algorithm, midtone: Float, p0: Float, p1: Float
    ) -> Float {
        switch algorithm {
        case .none, .equalise: return x
        case .stf: return Exporter.mtfPublic(midtone, x)
        case .arcsinh: return Float(asinh(Double(p0 * x)) / asinh(Double(p0)))
        case .logarithmic: return Float(log(Double(1 + p0 * x)) / log(Double(1 + p0)))
        case .hyperbolic:
            let sp = Double(p1)
            let span = max(1 - sp, sp)
            let v = asinh(Double(p0) * (Double(x) - sp)) / asinh(Double(p0) * span) * span + sp
            return Float(min(1, max(0, v)))
        }
    }

    /// Configures every picture on screen, not just the selected one. That is
    /// the whole point of holding both states: the unselected layer runs the
    /// same code with its own numbers, so it can neither fall behind nor run a
    /// hand-picked subset of the pipeline.
    private func push() {
        for s in liveStates { configure(s) }
        dirty = true
        scheduleHistogram()
        scheduleSave()
    }

    private func configure(_ s: LayerState) {
        let r = s.renderer
        let base = baseline(for: s)
        var zone: Int32 = 0

        r.ops = s.stack.compactMap { op -> OpSlot? in
            guard op.on else { return nil }
            let code = Ops.code(op.kind)
            // A Zone balance stage consumes a curve slot whether or not it is
            // switched on, or the indices would shift as stages are toggled.
            guard code != 0 else { return nil }

            var slot = OpSlot()
            slot.code = code
            switch op.kind {
            case "Colour calibration":
                guard let c = colorCal else { return nil }
                slot.calOffset = c.offset
                slot.calGain = c.gain
            case "Narrowband palette":
                let palette = Palette(rawValue: op.palette) ?? .natural
                guard palette != .natural else { return nil }
                let rows = op.mix.rows
                slot.paletteR = rows.0
                slot.paletteG = rows.1
                slot.paletteB = rows.2
            case "Screen stretch":
                slot.algorithm = op.algorithm
                slot.p0 = op.p0
                slot.p1 = op.p1
                slot.blend = op.blend
                slot.saturation = op.saturation
                var shadows = simd_clamp(
                    base.shadows + SIMD3(repeating: op.black), .zero, SIMD3(repeating: 0.99))
                let ratio = base.midtone.y > 1e-6 ? op.midtone / base.midtone.y : 1
                // Linked applies one curve to all three, so a genuinely coloured
                // target keeps its colour instead of being neutralised.
                var midtone = simd_clamp(
                    base.midtone * ratio, SIMD3(repeating: 0.001), SIMD3(repeating: 0.999))
                if op.linked {
                    shadows = SIMD3(repeating: (shadows.x + shadows.y + shadows.z) / 3)
                    midtone = SIMD3(repeating: op.midtone)
                }
                slot.shadows = shadows
                slot.midtone = midtone
            case "Zone balance":
                guard !op.zones.isIdentity else { return nil }
                slot.lut = s.zoneIndex(of: op.id)
                zone += 1
            case "Tone":
                guard !op.tone.isIdentity else { return nil }
                slot.exposure = op.tone.exposure
                slot.contrast = op.tone.contrast
                slot.toneHighlights = op.tone.highlights
                slot.toneShadows = op.tone.shadows
                slot.whites = op.tone.whites
                slot.blacks = op.tone.blacks
                slot.vibrance = op.tone.vibrance
                slot.scnr = op.tone.scnr
            default:
                return nil
            }
            return slot
        }

        r.setZones(s.zoneTables)
        r.detail = s.detailStage?.detail ?? DetailParams()
    }

    func revert() {
        let s = active
        let fitted = baseline(for: s).midtone.y
        editStretch {
            $0.algorithm = Algorithm.stf.rawValue
            $0.p0 = 10
            $0.p0Base = 10
            $0.p1 = 0.2
            $0.blend = 1
            $0.black = 0
            $0.saturation = 1
            $0.midtone = fitted
            $0.midtoneBase = fitted
        }
        dirty = false
    }
}

struct DevelopModule: View {
    @ObservedObject var model: DevelopModel
    @ObservedObject var stacker: StackModel
    @ObservedObject var sky: SkyCatalogue
    @Environment(\.tokens) private var t
    /// Which stage is under the cursor, so the rows that could accept it can
    /// say so while the drag is happening.
    @State private var dragging: UUID?
    @State private var hoveringLeft = false
    @State private var hoveringRight = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if model.panelsPinned {
                    sidebar.frame(width: 240, alignment: .leading).background(t.s1)
                    Divider().overlay(t.line)
                }
                canvas
                if model.panelsPinned {
                    Divider().overlay(t.line)
                    inspector.frame(width: 316, alignment: .leading).background(t.s1)
                }
            }
        }
        // Unpinned, the panels come back on approach and float over the picture
        // rather than taking width from it. Nothing is lost — the sliders work
        // the same — but an untouched view is the whole canvas.
        .overlay(alignment: .leading) {
            if !model.panelsPinned {
                floating(sidebar.frame(width: 240), edge: .leading, showing: hoveringLeft)
                    .onHover { hoveringLeft = $0 }
            }
        }
        .overlay(alignment: .trailing) {
            if !model.panelsPinned {
                floating(inspector.frame(width: 316), edge: .trailing, showing: hoveringRight)
                    .onHover { hoveringRight = $0 }
            }
        }
        .onAppear {
            model.masters = Masters.all(stacker.projectRoot)
            if model.meta == nil {
                // Whatever was just stacked, else the newest saved master —
                // reopening a project should not mean stacking it again.
                let out = stacker.outputPath
                if !out.isEmpty, FileManager.default.fileExists(atPath: out) {
                    model.load(out)
                } else if let saved = model.masters.first {
                    model.load(saved.path)
                }
            }
            if let lat = model.meta?.siteLat, lat != 0 { sky.latitude = Double(lat) }
            sky.open()
            if model.colorReference == .catalogue, model.colorCal == nil {
                model.measureColour()
            }
        }
        // A download that has just filled in this field is exactly when the
        // calibration should be retried — leaving the earlier "no catalogue"
        // result on screen makes a working download look like it did nothing.
        .onChange(of: sky.downloading) { _, busy in
            guard !busy, model.colorReference == .catalogue else { return }
            model.measureColour()
        }
        .onChange(of: sky.stats.stars) { _, stars in
            guard stars > 0, model.colorReference == .catalogue,
                model.colorCal == nil, model.colorFailure == -2
            else { return }
            model.measureColour()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                header("Operations")
                Spacer()
                addMenu
            }
            ForEach(model.rows) { row in
                stackRow(row)
            }

            if let why = model.orderError {
                Text(why)
                    .font(Face.secondary).foregroundStyle(t.q2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.md)
            } else if let warn = model.pipelineWarning {
                Text(warn)
                    .font(Face.secondary).foregroundStyle(t.q3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.md)
            }

            Spacer()

            Text("ORDER MATTERS")
                .font(Face.sectionHeader).tracking(Face.sectionTracking)
                .foregroundStyle(t.t3)
            Text("These run top to bottom, and rearranging them changes the result. Master, the split and the result are pinned; everything between them is yours to arrange, and a stage will only accept a position its maths survives. Add the same stage twice to push a value further than one pass can.")
                .font(Face.secondary).foregroundStyle(t.t3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metric.panelPad)
    }

    /// Every stage that could still be added, with the ones that cannot greyed
    /// and saying why — a refusal you can read beats one you have to discover.
    private var addMenu: some View {
        Menu {
            ForEach(Ops.addable(to: model.stack), id: \.kind.id) { entry in
                Button {
                    model.addStage(entry.kind.id)
                } label: {
                    Text(entry.refusal == nil ? entry.kind.id : "\(entry.kind.id) — \(entry.refusal!)")
                }
                .disabled(entry.refusal != nil)
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(t.t2)
                .frame(width: 18, height: 16)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .help("Add a stage. It lands at the last position its maths allows.")
    }

    @ViewBuilder
    private func stackRow(_ row: DevelopModel.Row) -> some View {
        let selected = model.selection == row.id
        let dropping = draggingTarget(row)

        Button { model.selection = row.id } label: {
            HStack(alignment: .top, spacing: Space.md) {
                // Master and the result are the frame's ends, not steps: there
                // is nothing to switch off, so they get alignment rather than a
                // checkbox that could only ever be ticked.
                if row.name == "Master" || row.id == .output {
                    Color.clear.frame(width: 14, height: 14)
                } else {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { row.on },
                            set: { on in
                                if case .stage(let id) = row.id {
                                    model.setStage(id, on: on)
                                } else {
                                    model.setHead(row.name, on: on)
                                }
                            })
                    )
                    .toggleStyle(.checkbox).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(Face.body)
                        .foregroundStyle(row.on || row.isSpine ? t.t1 : t.t3)
                    Text(row.state).font(Face.mono(10)).foregroundStyle(t.t4)
                }
                Spacer()
                if row.fixed {
                    Text("fixed").font(Face.mono(9)).foregroundStyle(t.t4)
                } else {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9))
                        .foregroundStyle(selected ? t.t2 : t.t4)
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? t.sel : (dropping ? t.s3 : .clear))
            .overlay(alignment: .top) {
                if dropping { Rectangle().fill(t.q5).frame(height: 1.5) }
            }
            // A clear background and a Spacer are both transparent to hit
            // testing, which left only the label clickable.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if case .stage(let id) = row.id {
                Button("Duplicate") { model.duplicateStage(id) }
                Button("Remove", role: .destructive) { model.removeStage(id) }
            }
        }
        .modifier(StageDrag(model: model, row: row, dragging: $dragging))
    }

    /// Whether this row is a position the stage being dragged could legally take.
    /// Shown during the gesture, so an illegal drop is visibly not offered
    /// rather than refused after the fact.
    private func draggingTarget(_ row: DevelopModel.Row) -> Bool {
        guard let id = dragging, case .stage(let target) = row.id, target != id,
            let index = model.stack.firstIndex(where: { $0.id == target })
        else { return false }
        return model.legalTargets(for: id).contains(index)
    }

    /// Orientation and zoom, next to the picture they act on. Rotation and flip
    /// persist with the frame; zoom and pan do not, because where you were
    /// looking last time is not an edit.
    private var viewControls: some View {
        HStack(spacing: Space.sm) {
            icon("rotate.left") { model.viewport.rotate(-1) }
            icon("rotate.right") { model.viewport.rotate(1) }
            icon("arrow.left.and.right.righttriangle.left.righttriangle.right") {
                model.viewport.flipH.toggle()
            }
            icon("arrow.up.and.down.righttriangle.up.righttriangle.down") {
                model.viewport.flipV.toggle()
            }

            Divider().frame(height: 12).overlay(t.line2)

            Button {
                if model.cropping { model.cancelCrop() } else { model.cropping = true }
            } label: {
                Image(systemName: "crop").font(.system(size: 11))
                    .foregroundStyle(model.cropping ? t.selT : t.t2)
                    .frame(width: 20, height: 18)
                    .background(model.cropping ? t.sel : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            }
            .buttonStyle(.plain)
            .help("Drag a rectangle over the picture to keep only that part.")

            if let r = model.cropResolution {
                Button("Crop to \(r.w) × \(r.h)") { model.confirmCrop() }
                    .buttonStyle(.plain).font(Face.mono(10))
                    .foregroundStyle(model.cropIsUsable ? t.q5 : t.t4)
                    .disabled(!model.cropIsUsable)
                    .help("Return")
                Button("Cancel") { model.cancelCrop() }
                    .buttonStyle(.plain).font(Face.mono(10)).foregroundStyle(t.t3)
                    .help("Escape")
            } else if model.viewport.isCropped {
                Button("Uncrop") { model.clearCrop() }
                    .buttonStyle(.plain).font(Face.mono(10)).foregroundStyle(t.q5)
            }

            Divider().frame(height: 12).overlay(t.line2)

            Button {
                model.panelsPinned.toggle()
            } label: {
                Image(
                    systemName: model.panelsPinned
                        ? "rectangle.inset.filled.and.person.filled"
                        : "rectangle.on.rectangle"
                )
                .font(.system(size: 10))
                .foregroundStyle(model.panelsPinned ? t.t2 : t.selT)
                .frame(width: 20, height: 18)
                .background(model.panelsPinned ? .clear : t.sel)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            }
            .buttonStyle(.plain)
            .help(
                model.panelsPinned
                    ? "Unpin the panels. They fold away and come back when you reach for them."
                    : "Pin the panels open again.")

            Divider().frame(height: 12).overlay(t.line2)

            icon("minus.magnifyingglass") { model.zoomBy(1 / 1.4) }
            Button(model.zoomLabel) { model.resetView() }
                .buttonStyle(.plain).font(Face.mono(10)).foregroundStyle(t.t2)
                .frame(width: 46)
                .help("Fit to the pane. Double-clicking the image does the same.")
            icon("plus.magnifyingglass") { model.zoomBy(1.4) }
        }
    }

    /// A strip at the edge to aim at, and the panel itself once the cursor is
    /// in it. Both live in the same hover region so the panel does not vanish
    /// the moment you reach for a slider.
    @ViewBuilder
    private func floating<V: View>(_ panel: V, edge: HorizontalAlignment, showing: Bool)
        -> some View
    {
        HStack(spacing: 0) {
            if edge == .trailing, !showing {
                grabStrip
            }
            if showing {
                panel
                    .background(t.s1)
                    .overlay(alignment: edge == .leading ? .trailing : .leading) {
                        Divider().overlay(t.line)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 0)
                    .transition(.move(edge: edge == .leading ? .leading : .trailing))
            }
            if edge == .leading, !showing {
                grabStrip
            }
        }
        .animation(.easeOut(duration: 0.12), value: showing)
    }

    private var grabStrip: some View {
        Rectangle()
            .fill(t.line.opacity(0.5))
            .frame(width: 3)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
    }

    private func icon(_ name: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: name).font(.system(size: 10)).foregroundStyle(t.t2)
                .frame(width: 18, height: 16)
        }
        .buttonStyle(.plain)
    }

    private var canvas: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                Segmented(
                    items: SplitMode.allCases.map(\.rawValue),
                    index: Binding(
                        get: { SplitMode.allCases.firstIndex(of: model.split) ?? 0 },
                        set: { model.split = SplitMode.allCases[$0] }))
                Text("B").font(Face.mono(10)).foregroundStyle(t.t3)
                    .padding(.horizontal, 4).frame(height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.swatch)
                            .stroke(t.line2, lineWidth: 0.5))
                Text("hold to flip").font(Face.secondary).foregroundStyle(t.t4)
                if model.separated {
                    Segmented(
                        items: DevelopModel.SplitLayout.allCases.map(\.rawValue),
                        index: Binding(
                            get: {
                                DevelopModel.SplitLayout.allCases.firstIndex(of: model.splitLayout)
                                    ?? 0
                            },
                            set: { model.splitLayout = DevelopModel.SplitLayout.allCases[$0] }))
                }
                Spacer()
                if model.source.isEmpty {
                    Text("Stack something first").font(Face.secondary).foregroundStyle(t.t3)
                } else {
                    viewControls
                }
            }
            .padding(.horizontal, Metric.panelPad)
            .frame(height: 26)
            .background(t.s1)

            if model.cropping {
                Divider().overlay(t.line)
                cropBar
            }

            DevelopCanvas(model: model, tokens: t)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(t.well)
    }

    /// Ratio presets and what the crop would print at, together — the shape you
    /// pick and the size it ends up being are the same decision.
    private var cropBar: some View {
        HStack(spacing: Space.md) {
            ForEach(PrintSize.ratios, id: \.name) { preset in
                Button { model.cropRatio = preset.value } label: {
                    Text(preset.name)
                        .font(Face.mono(10))
                        .foregroundStyle(model.cropRatio == preset.value ? t.selT : t.t3)
                        .padding(.horizontal, Space.sm).frame(height: 16)
                        .background(model.cropRatio == preset.value ? t.sel : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                }
                .buttonStyle(.plain)
            }

            if model.cropRatio != nil {
                Button {
                    model.cropPortrait.toggle()
                } label: {
                    Image(systemName: model.cropPortrait ? "rectangle.portrait" : "rectangle")
                        .font(.system(size: 10)).foregroundStyle(t.t2)
                        .frame(width: 18, height: 16)
                }
                .buttonStyle(.plain)
                .help("Portrait or landscape")
            }

            Spacer()

            if let summary = model.cropPrintSummary {
                Text(summary)
                    .font(Face.mono(10))
                    .foregroundStyle(model.cropIsUsable ? t.t2 : t.q2)
            } else {
                Text("Nothing selected").font(Face.mono(10)).foregroundStyle(t.t4)
            }
        }
        .padding(.horizontal, Metric.panelPad)
        .frame(height: 24)
        .background(t.s2)
    }

    /// Which picture the panels below are editing. Shown only while separated,
    /// because that is the only time the answer is not obvious.
    private var layerBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Segmented(
                items: DevelopModel.Layer.allCases.map(\.rawValue),
                index: Binding(
                    get: {
                        DevelopModel.Layer.allCases.firstIndex(of: model.activeLayer) ?? 0
                    },
                    set: { model.select(DevelopModel.Layer.allCases[$0]) }))

            // What each layer is running, side by side. Stages you switched on
            // against stages that reached the shader: when a control appears to
            // do nothing, those two numbers say which half is at fault.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(DevelopModel.Layer.allCases, id: \.rawValue) { layer in
                    HStack(alignment: .top, spacing: Space.sm) {
                        Text(layer.rawValue).font(Face.mono(9))
                            .foregroundStyle(model.activeLayer == layer ? t.q5 : t.t4)
                            .frame(width: 48, alignment: .leading)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.stagesOn(layer)).font(Face.mono(9))
                                .foregroundStyle(t.t3)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(model.pipelineSummary(layer)).font(Face.mono(9))
                                .foregroundStyle(t.t4)
                        }
                        Spacer()
                        Button("reset") { model.resetLayer(layer) }
                            .buttonStyle(.plain).font(Face.mono(9))
                            .foregroundStyle(t.t4)
                            .help("Put this layer back to its template. The other layer is untouched.")
                    }
                }
            }
            .padding(.top, Space.xs)

            Text(
                Ops.isSpine(model.selectedName)
                    ? "\(model.selectedName) sits above the split, so it belongs to the frame and both layers inherit it."
                    : "Every control below belongs to the \(model.activeLayer.rawValue.lowercased()) layer alone. The other keeps its own, and the merged pane is the two of them screened together."
            )
            .font(Face.secondary).foregroundStyle(t.t3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Space.xs)
        }
        .padding(Metric.panelPad)
        .background(t.s2)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            if model.separated {
                layerBar
                Divider().overlay(t.line)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(model.selectedName)

                    switch model.selectedName {
                    case "Master": masterPanel
                    case "Star separation": toolsSection
                    case "Screen stretch": stretchPanel
                    case "Background extraction": backgroundPanel
                    case "Colour calibration": colourPanel
                    case "Narrowband palette": palettePanel
                    case "Zone balance": zonePanel
                    case "Tone": tonePanel
                    case "Detail": detailPanel
                    case "Output": outputPanel
                    default: unimplemented
                    }

                    Spacer()
                }
                .padding(Metric.panelPad)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(t.line)
            histogramBar
        }
    }

    /// The transfer belonging to whichever operation is selected, drawn over
    /// the distribution it is acting on. Operations with no tonal curve of
    /// their own leave it empty rather than showing a meaningless diagonal.
    private var activeCurves: [(Color, [Float])] {
        switch model.selectedName {
        case "Screen stretch":
            return [
                (.red, model.stretchCurve(0)), (.green, model.stretchCurve(1)),
                (.blue, model.stretchCurve(2)),
            ]
        case "Zone balance":
            return [(t.q5, model.zoneTable)]
        case "Tone":
            return [(t.q5, model.tone.curve())]
        default:
            return []
        }
    }

    /// Pinned rather than living inside the stretch panel: it shows the output
    /// of the whole pipeline, so it is worth seeing while adjusting any part of
    /// it — and every operation now moves it.
    private var histogramBar: some View {
        VStack(spacing: 0) {
            // Frame before overlay: Canvas has no intrinsic size, so an overlay
            // applied first would lay out against nothing.
            Histogram(channels: model.histogramRGB, black: model.black, tokens: t)
                .frame(height: 88)
                .overlay { CurveView(curves: activeCurves, tokens: t) }
            HStack {
                Text("black").font(Face.mono(9)).foregroundStyle(t.t3)
                Spacer()
                Button(model.linked ? "R G B linked" : "R G B unlinked") {
                    model.linked.toggle()
                }
                .buttonStyle(.plain)
                .font(Face.mono(9))
                .foregroundStyle(model.linked ? t.q5 : t.t3)
                .help(
                    "Unlinked fits each channel separately and neutralises a colour cast. Linked applies one curve to all three, which a narrowband target needs.")
                Spacer()
                Text("white").font(Face.mono(9)).foregroundStyle(t.t3)
            }
            .padding(.horizontal, Space.sm)
            .frame(height: 18)
        }
        .padding(Space.sm)
        .background(t.s2)
    }

    /// Found on this machine rather than bundled, so the list says what is
    /// actually reachable instead of what the app knows about.
    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("External tools").padding(.top, Space.xl)

            ForEach(Tools.all) { tool in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tool.name).font(Face.body)
                            .foregroundStyle(tool.isReachable ? t.t1 : t.t4)
                        Text(tool.role.rawValue).font(Face.mono(9)).foregroundStyle(t.t4)
                    }
                    Spacer()
                    Text(status(tool)).font(Face.mono(9))
                        .foregroundStyle(tool.isReachable ? t.q5 : t.t4)
                }
                .frame(minHeight: 24)
            }

            if !Tools.sirilAvailable {
                note("Siril is not installed, so the tools it hosts cannot be reached even when their scripts are present.")
            }

            header("Star separation").padding(.top, Space.lg)

            HStack(spacing: Space.md) {
                Text("Model").font(Face.body).foregroundStyle(t.t2)
                Picker("", selection: $model.removerID) {
                    ForEach(StarSeparation.removers) { r in
                        Text(r.name).tag(r.id)
                    }
                }
                .labelsHidden().font(Face.body)
            }
            if StarSeparation.removers.count == 1 {
                note("One reachable backend. The wrapper around it is the part that generalises — prepare a stretched copy, infer, invert exactly — so a second model is a registry entry describing its argument spelling and whether it gets the plane order right.")
            }

            Toggle("2× upsampling", isOn: $model.separationOptions.upsample)
                .toggleStyle(.checkbox).font(Face.body).foregroundStyle(t.t2)
                .padding(.top, Space.sm)
            note("Measured on this stack: star removal is unchanged either way — 1.9% of star flux left behind against 2.0% — but the star layer captures 88.3% of it instead of 79.3%, and reconstruction error at stars falls by a third. It costs about four times the runtime. Worth it here because 3.67″/px is badly undersampled, which is the case this exists for.")

            if model.layers != nil {
                info("Layers", "cached beside the master")
                if let p = StarSeparation.provenance(for: model.source) {
                    info(
                        "Made with",
                        "\(StarSeparation.remover(p.remover).name)"
                            + (p.options.upsample ? " · 2× upsampled" : ""))
                }
                note("The model writes a starless image and an unscreened star layer — the proper inverse of a screen blend, so recombining them reconstructs the original rather than approximating it.")
            } else {
                note("Splits the master into stars and starless so each can be developed on its own terms. Cached beside the master, so it runs once.")
            }

            if model.separationStale {
                callout(
                    "These layers were made with different settings. The panes are showing the old ones until you separate again.",
                    t.q3)
            }

            HStack(spacing: Space.sm) {
                act(
                    model.layers == nil ? "Separate stars" : "Separate again",
                    primary: model.layers == nil || model.separationStale
                ) {
                    model.separateStars(force: model.layers != nil)
                }
            }
            .padding(.top, Space.md)
            .disabled(
                model.separating || model.source.isEmpty
                    || StarSeparation.isLayer(model.source)
                    || !StarSeparation.remover(model.removerID).isReachable)

            if let message = model.separationMessage {
                Text(message)
                    .font(Face.secondary)
                    .foregroundStyle(model.separating ? t.t3 : (model.layers == nil ? t.q2 : t.t3))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xs)
            }
        }
    }

    private func status(_ tool: ExternalTool) -> String {
        guard tool.path != nil else { return "not found" }
        return tool.isReachable ? "ready" : "needs Siril"
    }

    /// The source, and everything geometric that applies to it. Crop lives here
    /// rather than with a layer because it is a property of the frame: cropping
    /// the master crops whatever is derived from it, which is the only way the
    /// two layers can stay in register.
    private var masterPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The master, not whichever layer happens to be selected — this
            // panel is about the frame everything derives from.
            let shown = model.source
            if shown.isEmpty {
                Text("Nothing open. Stack something, or drop a master into the project.")
                    .font(Face.secondary).foregroundStyle(t.t3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.md)
            } else {
                Text(URL(fileURLWithPath: shown).lastPathComponent)
                    .font(Face.mono(10)).foregroundStyle(t.t1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.md)
                Text(Masters.describe(URL(fileURLWithPath: shown)))
                    .font(Face.secondary).foregroundStyle(t.t3)
            }

            if model.masters.count > 1 {
                Picker(
                    "",
                    selection: Binding(get: { model.source }, set: { model.load($0) })
                ) {
                    ForEach(model.masters, id: \.path) { m in
                        Text(m.lastPathComponent).tag(m.path)
                    }
                }
                .labelsHidden().font(Face.body).padding(.top, Space.sm)
            }

            header("Geometry").padding(.top, Space.lg)
            info("Rotation", "\(model.viewport.quarterTurns * 90)°")
            info(
                "Flipped",
                [model.viewport.flipH ? "H" : "", model.viewport.flipV ? "V" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " + ").ifEmpty("no"))
            info("Crop", model.viewport.isCropped ? cropSummary : "full frame")
            note("Rotation, flip and crop belong to the frame, so everything downstream — including both star layers — inherits them and stays in register.")

            HStack(spacing: Space.sm) {
                act("Reveal in Finder") {
                    guard !model.source.isEmpty else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([
                        URL(fileURLWithPath: model.source)
                    ])
                }
                if model.viewport.isCropped {
                    act("Uncrop") { model.clearCrop() }
                }
            }
            .padding(.top, Space.md)

            HStack(spacing: Space.sm) {
                act("Back to as stacked") { model.resetToMaster() }
                act("Reset everything") { confirmReset() }
            }
            .padding(.top, Space.sm)
            note("Back to as stacked forgets the geometry and every operation. Reset everything also deletes the saved settings, so the frame opens fresh next time. Neither touches the FITS.")
        }
    }

    /// Deleting saved settings is not undoable and the button sits beside one
    /// that is, so it asks.
    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset everything for this frame?"
        alert.informativeText =
            "Deletes the saved settings and returns every operation to its default. "
            + "The FITS itself is untouched, and the separated layers are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.resetEverything() }
    }

    private var cropSummary: String {
        guard let m = model.meta else { return "cropped" }
        let size = model.viewport.cropSize
        let full = SIMD2(Float(max(m.srcWidth, m.width)), Float(max(m.srcHeight, m.height)))
        return "\(Int(size.x * full.x)) × \(Int(size.y * full.y)) px"
    }

    private var editAndExport: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Edit").padding(.top, Space.xl)
            HStack(spacing: Space.sm) {
                act("Revert to as-stacked") { model.revert() }
            }
            info(
                "Edits",
                model.savedAt.map {
                    let f = DateFormatter()
                    f.dateFormat = "d MMM HH:mm:ss"
                    return "saved \(f.string(from: $0))"
                } ?? "not yet saved")
            note("Saved in the project under .astrocat/masters — the master as FITS, your edits as a .develop.json beside it. Every operation above is a parameter on the view; the file itself stays linear and untouched.")

            HStack {
                Text("EXPORT FOR").font(Face.sectionHeader)
                    .tracking(Face.sectionTracking).foregroundStyle(t.t3)
                Spacer()
                Picker("", selection: $model.exportTarget) {
                    ForEach(ExportTarget.allCases, id: \.rawValue) { e in
                        Text(e.rawValue).tag(e)
                    }
                }
                .labelsHidden().frame(width: 130).font(Face.body)
            }
            .padding(.top, Space.xl)

            info(
                "Stretch",
                model.exportTarget == .lightroom
                    ? "baked in" : "not applied — data stays linear")
            info(
                "Colour calibration",
                model.calibrationActive
                    ? (model.exportTarget == .lightroom ? "baked in" : "not applied")
                    : "off")
            note(model.exportTarget.reason)

            HStack(spacing: Space.sm) {
                act("Export…", primary: true) {
                    model.exportError = Exporter.run(
                        source: model.source,
                        target: model.exportTarget,
                        suggested: Exporter.suggestedName(
                            model.exportTarget, frames: 0,
                            exposure: model.meta?.exposure ?? 60, filter: "LP"),
                        stretch: model.bakedStretch,
                        calibration: model.bakedCalibration)
                }
                act("Advanced…") {}
            }
            .padding(.top, Space.md)
        }
    }

    private var stretchPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("ALGORITHM").font(Face.sectionHeader)
                        .tracking(Face.sectionTracking).foregroundStyle(t.t3)
                    Spacer()
                    Button("Reset to auto") { model.revert() }
                        .buttonStyle(.plain).font(Face.secondary).foregroundStyle(t.t2)
                }
                .padding(.top, Space.md)

                Picker("", selection: $model.algorithm) {
                    ForEach(Algorithm.allCases) { a in Text(a.label).tag(a) }
                }
                .labelsHidden().font(Face.body)
                note("auto-fit from median + MAD")

                HStack(spacing: Space.md) {
                    Text("Operates in").font(Face.body).foregroundStyle(t.t2)
                    Segmented(
                        items: ["Linear", "Non-linear"],
                        index: Binding(
                            get: { model.linearMode ? 0 : 1 },
                            set: { model.linearMode = $0 == 0 }))
                }
                .padding(.top, Space.md)

                if model.pairingWrong {
                    Text(
                        model.algorithm.wantsLinear
                            ? "\(model.algorithm.label) expects linear data. Applying it after another stretch will crush the highlights."
                            : "\(model.algorithm.label) expects data that has already been stretched. On linear data it will amplify noise."
                    )
                    .font(Face.secondary).foregroundStyle(t.q2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.md)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.panel)
                            .stroke(t.q2, lineWidth: 0.5))
                    .padding(.top, Space.md)
                } else {
                    note("Fitted on linear data. The stretch is a display parameter; the file keeps its linear values.")
                }

                Toggle("Display only", isOn: $model.displayOnly)
                    .toggleStyle(.checkbox).font(Face.body).foregroundStyle(t.t2)
                    .padding(.top, Space.md)

                stretchControls
        }
    }

    private var stretchControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            slider("Black point", $model.black, -0.01...0.05, "%+.5f")

            switch model.algorithm {
            case .stf:
                logSlider("Midtone", $model.midtone, 0.001, 0.6, "%.5f")
            case .arcsinh, .logarithmic:
                logSlider("Stretch", $model.p0, 1, 1_000_000, "%.0f")
            case .hyperbolic:
                logSlider("Stretch", $model.p0, 1, 1_000_000, "%.0f")
                logSlider("Symmetry point", $model.p1, 0.0002, 0.5, "%.4f")
            case .equalise:
                note("Built from this frame's own histogram — no parameter to set.")
            case .none:
                note("Linear data shown as-is. Expect a black frame.")
            }

            slider("Saturation", $model.saturation, 0.25...3, "%.2f×")

            if model.calibrationActive {
                note("Colour calibration is on, so this stretch runs linked over calibrated data. Unlinking would re-fit each channel to its own noise and put the cast back.")
            }
        }
    }

    private var backgroundPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            slider("Sample tolerance", $model.sampleTolerance, 0.5...5, "%.2f σ")
            note("How far above the background a tile may sit before extraction treats it as nebulosity and discards it. Changes the fit below, not the picture — extraction is applied when stacking.")
            info("Gradient before", String(format: "%.5f", model.gradientBefore))
            info("Gradient after", String(format: "%.5f", model.gradientAfter))
            info(
                "Removed by",
                model.gradientAfter > 0
                    ? String(format: "%.1f×", model.gradientBefore / model.gradientAfter)
                    : "—")
            info("Sky level R / G / B", model.skyLevels)
            note("Amplitude is measured on the fitted model, not sampled from the frame — the centre of the frame is nebula, which extraction is supposed to keep.")
        }
    }

    private var colourPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WHITE REFERENCE").font(Face.sectionHeader)
                .tracking(Face.sectionTracking).foregroundStyle(t.t3)
                .padding(.top, Space.md)

            Segmented(
                items: ColorReference.allCases.map(\.label),
                index: Binding(
                    get: { ColorReference.allCases.firstIndex(of: model.colorReference) ?? 1 },
                    set: { model.colorReference = ColorReference.allCases[$0] }))
                .padding(.top, Space.sm)
            note(model.colorReference.claim)

            if model.separated {
                note("Measured on the master — star photometry needs stars, and the starless layer has none. Whether a layer wears the correction is the checkbox, and it is per layer: these gains neutralise the sky, but the extracted star layer is short of red, so the same gains turn its stars cyan.")
            }

            if model.narrowband {
                callout(
                    "FILTER is \(model.meta?.filter ?? "narrowband"). A dual-band passband matches no photometric system, and forcing that sky neutral erases the Ha/OIII separation the data was taken for. Sky-only is the one defensible mode here.",
                    t.q2)
            }

            if model.colorReference == .catalogue {
                cataloguePanel
            }

            if let c = model.colorCal, model.colorCalReference == model.colorReference {
                if model.colorCalReference == .catalogue {
                    info("Stars matched", "\(c.matched) of \(c.starsFound)")
                    info(
                        "Colour range",
                        String(format: "%.2f mag in BP−RP", c.colourSpan))
                    info(
                        "Slope R / B",
                        String(format: "%+.3f / %+.3f per mag", c.slopeR, c.slopeB))
                    info(
                        "Field median vs white",
                        String(format: "%.2f  vs  %.2f", c.medianColour, c.white))
                    note(
                        abs(c.medianColour - c.white) < 0.15
                            ? "This field's average star is close to the chosen white, so the Stars mode above would land in nearly the same place. That is a fact about this field, not a rule."
                            : "This field's average star is well away from the chosen white, so Stars mode would give a materially different answer — this is where the catalogue earns its keep.")
                    if c.colourSpan < 0.25 {
                        callout(
                            "The matched stars span too little colour to fit a slope, so this fell back to a flat offset — the field-star answer restricted to catalogue matches. A wider field or a deeper catalogue would fix it.",
                            t.q2)
                    }
                } else if model.colorCalReference == .starField {
                    info("Stars found", "\(c.starsFound)")
                    info("Stars used", "\(c.starsUsed)")
                    info(
                        "R / G", String(format: "%.4f  ± %.4f", c.ratioR, c.scatterR))
                    info(
                        "B / G", String(format: "%.4f  ± %.4f", c.ratioB, c.scatterB))
                    if c.starsUsed == 0 {
                        callout(
                            "Too few usable stars — unsaturated, isolated and well above the noise. Falling back to sky neutralisation only.",
                            t.q2)
                    }
                }
                info(
                    "Gain R / G / B",
                    String(format: "%.3f / %.3f / %.3f", c.gain.x, c.gain.y, c.gain.z))
                info(
                    "Offset R / G / B",
                    String(format: "%.5f / %.5f / %.5f", c.offset.x, c.offset.y, c.offset.z))
                info("Sky before", model.skyBalance.before)
                info("Sky after", model.skyBalance.after)
                note("The correction is affine per channel — a gain from the star colours and an offset from the sky. A gain alone cannot make both neutral at once.")
                note(
                    model.colorBusy
                        ? "Re-measuring — the calibration above stays applied until the new one lands."
                        : String(
                            format: "Measured in %.0f ms · display only, the file stays linear.",
                            c.ms))
            } else if model.colorBusy {
                note("Measuring…")
            } else {
                note("Not measured yet.")
            }

            HStack(spacing: Space.sm) {
                act("Measure again") { model.measureColour() }
            }
            .padding(.top, Space.md)
            .disabled(model.colorBusy || model.colorReference == .catalogue)
        }
    }

    private var tonePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            note("Lightroom's tonal controls, in the shapes the Lighthouse script uses. Applied to luminance with the colour carried along, so a lift changes brightness without dragging hue.")

            header("Tone").padding(.top, Space.lg)
            toneSlider("Exposure", \.exposure, -2...2)
            toneSlider("Contrast", \.contrast, -1...1)
            toneSlider("Highlights", \.highlights, -1...1)
            toneSlider("Shadows", \.shadows, -1...1)
            toneSlider("Whites", \.whites, -1...1)
            toneSlider("Blacks", \.blacks, -1...1)
            note("Highlights and shadows act through smooth masks on the luminance before any adjustment, so a lift stays in the band it was aimed at instead of sliding as you drag.")

            header("Colour").padding(.top, Space.lg)
            note("Vibrance and SCNR are colour controls — they move the picture but not the curve below, which plots luminance in against luminance out.")
            toneSlider("Vibrance", \.vibrance, -1...1)
            note("Leans on whatever is least saturated already. On this data that is the blue the LP filter barely records, which is the half worth lifting.")
            toneSlider("SCNR", \.scnr, 0...1)
            note("Pulls green down to the average of red and blue. Green above that is almost never real on a deep sky frame — there are no green stars and no green nebulae, only the sensor's own cast.")

            HStack(spacing: Space.sm) {
                act("Neutral") { model.tone = ToneParams() }
            }
                .padding(.top, Space.md)
        }
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            note("Local contrast against a blurred copy — coarse for structure, fine for grain. Both act on luminance: sharpening chroma on a colour-sensor frame amplifies demosaic artefacts rather than detail.")

            slider(
                "Clarity",
                Binding(get: { model.detail.clarity }, set: { model.detail.clarity = $0 }),
                -1...1, "%+.2f")
            slider(
                "Clarity radius",
                Binding(get: { model.detail.radius }, set: { model.detail.radius = $0 }),
                1...40, "%.0f px")
            slider(
                "Texture",
                Binding(get: { model.detail.texture }, set: { model.detail.texture = $0 }),
                -1...1, "%+.2f")

            note("This is the one stage that has to look at a pixel's neighbours, so switching it on puts the view on a two-pass render — and it is why there can only be one of it. Everything else here can be added twice.")

            HStack(spacing: Space.sm) {
                act("Neutral") { model.detail = DetailParams() }
            }
            .padding(.top, Space.md)
        }
    }

    /// The end of the pipeline, mirroring Master at the start. No split, no
    /// comparison — the picture as it will leave the app.
    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            note(
                model.separated
                    ? "Both layers, screened back together. Everything above acts on one layer or the other; this is the only view of the result."
                    : "The frame with every stage above applied, at full resolution and without a comparison split.")

            if let m = model.meta {
                let size = model.viewport.cropSize
                let full = SIMD2(
                    Float(max(m.srcWidth, m.width)), Float(max(m.srcHeight, m.height)))
                info(
                    "Resolution",
                    "\(Int(size.x * full.x)) × \(Int(size.y * full.y)) px")
                info("Print", PrintSize.describe(px: (Int(size.x * full.x), Int(size.y * full.y))))
            }
            info("Stages", "\(model.stack.filter(\.on).count) of \(model.stack.count) on")

            editAndExport
        }
    }

    private func toneSlider(
        _ label: String, _ key: WritableKeyPath<ToneParams, Float>, _ range: ClosedRange<Float>
    ) -> some View {
        slider(
            label,
            Binding(get: { model.tone[keyPath: key] }, set: { model.tone[keyPath: key] = $0 }),
            range, "%+.2f")
    }

    private var zonePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            note("Each slider is the contrast the curve spends on that band of tones. The total is fixed, so lifting one zone visibly takes from the others — which is the point. Nothing here can invent detail, only decide where the range goes.")

            ForEach(Array(ZoneCurve.names.enumerated()), id: \.offset) { i, name in
                slider(
                    name,
                    Binding(
                        get: { model.zones.slopes[i] },
                        set: { model.zones.slopes[i] = $0 }),
                    0.1...4, "%.2f×")
            }

            HStack(spacing: Space.sm) {
                act("Flatten") { model.zones = ZoneCurve() }
                act("Lift nebulosity") {
                    model.zones = ZoneCurve(slopes: [0.5, 1.8, 1.6, 1.0, 0.4])
                }
                act("Tame stars") {
                    model.zones = ZoneCurve(slopes: [0.8, 1.4, 1.4, 1.1, 0.25])
                }
            }
            .padding(.top, Space.md)

            note("Because the curve is a running total of positive slopes it can never fold back on itself, so no setting here will posterise or invert. Its shape is drawn over the histogram below.")
        }
    }

    private var palettePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $model.palette) {
                ForEach(Palette.allCases, id: \.rawValue) { p in Text(p.rawValue).tag(p) }
            }
            .labelsHidden().font(Face.body).padding(.top, Space.md)
            note(model.palette.note)

            if model.palette != .natural {
                if !model.narrowband {
                    callout(
                        "FILTER is \(model.meta?.filter.isEmpty == false ? model.meta!.filter : "broadband"). No emission lines are separated here, so \"Ha\" below means the red channel and \"OIII\" the green and blue. The controls work; the names are borrowed.",
                        t.q2)
                }
                paletteSliders
            }
        }
    }

    private var paletteSliders: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Where each line lands").padding(.top, Space.lg)
            share("Red out", \.red)
            share("Green out", \.green)
            share("Blue out", \.blue)
            note("Each slider moves that output channel between the two source signals. All three at Ha gives a monochrome red image; spreading them is what makes a palette.")

            header("Sources").padding(.top, Space.lg)
            mixSlider(
                model.narrowband ? "OIII from G ↔ B" : "Second source, G ↔ B",
                \.oiiiBalance, 0...1, "%.2f")
            note("OIII straddles green and blue on a colour sensor and rarely splits evenly. Half and half is the least noisy starting point, not a measurement.")
            mixSlider(model.narrowband ? "Ha gain" : "Red gain", \.haGain, 0.25...4, "%.2f×")
            mixSlider(model.narrowband ? "OIII gain" : "Green-blue gain", \.oiiiGain, 0.25...4, "%.2f×")
            note("OIII is usually far weaker than Ha, so lifting it is the difference between a red picture and a two-colour one.")

            header("Resulting mix").padding(.top, Space.lg)
            let rows = model.mix.rows
            info("Red out", weights(rows.0))
            info("Green out", weights(rows.1))
            info("Blue out", weights(rows.2))
            note("Applied to linear channels before the stretch. A palette is a claim about which emission went where, so it belongs with the data rather than the display.")

            if model.palette == .sho {
                callout(
                    "SII is not present in this data at all. The red channel is a copy of Ha, so red and green carry the same signal.",
                    t.q2)
            }
        }
    }

    /// Ha at one end, OIII at the other, so the label says which way is which.
    private func share(_ label: String, _ key: WritableKeyPath<PaletteMix, Float>) -> some View {
        let value = Binding<Float>(
            get: { model.mix[keyPath: key] },
            set: { model.mix[keyPath: key] = $0 })
        return VStack(alignment: .leading, spacing: Space.xxs) {
            HStack {
                Text(label).font(Face.body).foregroundStyle(t.t2)
                Spacer()
                Text(
                    String(
                        format: "%.0f%% %@", value.wrappedValue * 100,
                        model.narrowband ? "Ha" : "R")
                )
                .font(Face.mono(11)).foregroundStyle(t.t1)
            }
            Slider(value: value, in: 0...1).controlSize(.small)
        }
        .padding(.vertical, Space.xs)
    }

    private func mixSlider(
        _ label: String, _ key: WritableKeyPath<PaletteMix, Float>,
        _ range: ClosedRange<Float>, _ fmt: String
    ) -> some View {
        slider(
            label,
            Binding(
                get: { model.mix[keyPath: key] },
                set: { model.mix[keyPath: key] = $0 }),
            range, fmt)
    }

    private func weights(_ v: SIMD3<Float>) -> String {
        String(format: "%.2f R  %.2f G  %.2f B", v.x, v.y, v.z)
    }

    private var cataloguePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                Text("White").font(Face.body).foregroundStyle(t.t2)
                Picker("", selection: $model.whiteReference) {
                    ForEach(WhiteReference.allCases, id: \.rawValue) { w in
                        Text(w.rawValue).tag(w)
                    }
                }
                .labelsHidden().font(Face.body)
            }
            .padding(.top, Space.md)
            note(model.whiteReference.note)

            header("Plate solve").padding(.top, Space.lg)
            if model.solving {
                note("Solving — detecting stars and matching them against the catalogue.")
            } else if model.cone.has_wcs == 1 {
                info(
                    "Field centre",
                    String(format: "%.4f°  %+.4f°", model.cone.ra, model.cone.dec))
                info("Scale", String(format: "%.3f ″/px", model.cone.scale_arcsec))
                info("Rotation", String(format: "%+.2f°", model.cone.rotation_deg))
                info("Search radius", String(format: "%.2f°", model.cone.radius_deg))
                if model.cone.solved == 1 {
                    info("Solved from", "\(model.cone.inliers) stars")
                    info("Residual", String(format: "%.2f px", model.cone.rms_px))
                    note("Fitted here, against the catalogue. The mount pointing and the optics constrain it to one small patch of sky, so this is a match rather than a blind search.")
                } else {
                    note("Read from the frame's own WCS — the Seestar plate-solves on device and writes the solution into its stack, so nothing had to be fitted.")
                }
            } else if sky.stats.stars == 0 {
                callout(
                    "This frame has no WCS of its own and there is no catalogue to solve against yet. Download it below and the solve will run automatically.",
                    t.q2)
            } else {
                callout(
                    "This frame has no WCS and could not be solved against the catalogue. Either the pointing in the header is far off, or too few stars were detected to match.",
                    t.q2)
            }

            header("Gaia DR3").padding(.top, Space.lg)
            catalogueStatus

            if sky.downloading {
                ProgressView(value: sky.stats.fraction)
                    .progressViewStyle(.linear)
                    .padding(.vertical, Space.sm)
                Text(sky.status).font(Face.mono(10)).foregroundStyle(t.t3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.sm) { act("Pause") { sky.cancel() } }
                    .padding(.top, Space.md)
            } else {
                HStack(spacing: Space.sm) {
                    act(
                        sky.stats.tilesDone > 0 ? "Resume download" : "Download catalogue",
                        primary: true
                    ) { sky.start() }
                    if sky.stats.stars > 0 {
                        act("Erase") { confirmErase() }
                    }
                }
                .padding(.top, Space.md)
                if !sky.status.isEmpty {
                    Text(sky.status).font(Face.mono(10)).foregroundStyle(t.t3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.xs)
                }
            }

            if model.colorFailure == -2 && !sky.downloading {
                callout(
                    "The catalogue holds nothing for this field yet. The download works outward tile by tile, so this field may simply not have been reached — resuming will get to it.",
                    t.q2)
            }
        }
    }

    /// Deleting the catalogue throws away a download measured in tens of
    /// minutes, and the button sits next to one you press often.
    private func confirmErase() {
        let alert = NSAlert()
        alert.messageText = "Erase the downloaded catalogue?"
        alert.informativeText =
            "\(SkyCatalogue.format(stars: sky.stats.stars)) stars, "
            + "\(SkyCatalogue.format(bytes: sky.stats.bytes)). "
            + "Downloading it again takes several minutes, and colour calibration "
            + "in Catalogue mode will stop working until it finishes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { sky.erase() }
    }

    private var catalogueStatus: some View {
        VStack(alignment: .leading, spacing: 0) {
            info(
                "Stars stored",
                sky.stats.stars > 0
                    ? "\(SkyCatalogue.format(stars: sky.stats.stars))  ·  \(SkyCatalogue.format(bytes: sky.stats.bytes))"
                    : "none yet")
            info("Tiles", "\(sky.stats.tilesDone) of \(sky.stats.tilesTotal)")
            info("Depth", String(format: "G < %.0f", sky.magLimit))
            info(
                "Sky covered",
                String(
                    format: "dec > %+.0f°  ·  %.0f%% of sphere",
                    sky.minDec, sky.stats.skyFraction * 100))
            note(
                String(
                    format:
                        "Scoped to what clears %.0f° altitude from latitude %.2f°, read from the frame's SITELAT. Everything further south never rises high enough to be worth the disk.",
                    sky.minAltitude, sky.latitude))
        }
    }

    private func callout(_ s: String, _ colour: Color) -> some View {
        Text(s)
            .font(Face.secondary).foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Space.md)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.panel).stroke(colour, lineWidth: 0.5))
            .padding(.top, Space.md)
    }

    /// Says what the operation would do and that it does not do it yet, rather
    /// than showing the stretch panel under someone else's heading.
    private var unimplemented: some View {
        let name = model.selectedName
        let what: String = {
            switch name {
            case "Colour calibration":
                return "Would measure star colours against a catalogue and correct the channel balance photometrically, instead of the display-only neutralisation the unlinked stretch performs. Needs plate solving and a star catalogue — neither is built."
            case "Curves":
                return "Would add an editable tone curve on top of the stretch, stored with the frame like every other parameter here."
            case "Noise reduction":
                return "Would smooth the background while protecting stars and edges. Worth doing after colour calibration, not before."
            default:
                return "Not implemented."
            }
        }()

        return VStack(alignment: .leading, spacing: Space.sm) {
            Text("Not implemented")
                .font(Face.body).foregroundStyle(t.q3)
            Text(what)
                .font(Face.secondary).foregroundStyle(t.t3)
                .fixedSize(horizontal: false, vertical: true)
            Text("The checkbox stays off until it does something.")
                .font(Face.secondary).foregroundStyle(t.t4)
        }
        .padding(.top, Space.md)
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(Face.body).foregroundStyle(t.t3)
            Spacer()
            Text(v).font(Face.mono(11)).foregroundStyle(t.t1)
        }
        .frame(height: 20)
    }

    private func header(_ s: String) -> some View {
        Text(s.uppercased()).font(Face.sectionHeader).tracking(Face.sectionTracking)
            .foregroundStyle(t.t3).padding(.bottom, Space.sm)
    }

    private func note(_ s: String) -> some View {
        Text(s).font(Face.secondary).foregroundStyle(t.t3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Space.xs)
    }

    /// Midtone and black point live across decades, so a linear track buries
    /// everything useful in its first few pixels.
    private func logSlider(
        _ label: String, _ value: Binding<Float>, _ lo: Float, _ hi: Float, _ fmt: String
    ) -> some View {
        let position = Binding<Float>(
            get: {
                let v = max(value.wrappedValue, lo)
                return log(v / lo) / log(hi / lo)
            },
            set: { t in value.wrappedValue = lo * pow(hi / lo, max(0, min(1, t))) })

        return VStack(alignment: .leading, spacing: Space.xxs) {
            HStack {
                Text(label).font(Face.body).foregroundStyle(t.t2)
                Spacer()
                Text(String(format: fmt, value.wrappedValue))
                    .font(Face.mono(11)).foregroundStyle(t.t1)
            }
            Slider(value: position, in: 0...1).controlSize(.small)
        }
        .padding(.vertical, Space.xs)
    }

    private func slider(
        _ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ fmt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack {
                Text(label).font(Face.body).foregroundStyle(t.t2)
                Spacer()
                Text(String(format: fmt, value.wrappedValue))
                    .font(Face.mono(11)).foregroundStyle(t.t1)
            }
            Slider(value: value, in: range).controlSize(.small)
        }
        .padding(.vertical, Space.xs)
    }

    private func act(_ label: String, primary: Bool = false, _ run: @escaping () -> Void)
        -> some View
    {
        Button(action: run) {
            Text(label).font(Face.body)
                .foregroundStyle(primary ? t.selT : t.t1)
                .padding(.horizontal, Space.md).frame(height: 20)
                .background(primary ? t.sel : t.s3)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .stroke(primary ? t.selLine : t.line2, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
    }
}

/// Before is the same texture with the stretch switched off, so the split shows
/// only what this module is doing.
struct DevelopCanvas: View {
    @ObservedObject var model: DevelopModel
    let tokens: Tokens
    @State private var divider: CGFloat = 0.5
    @State private var mergeDivider: CGFloat = 0.5
    @State private var cropDrag: CropDrag?
    @State private var cropStart: CGRect?

    /// What a drag on the crop box is doing. Decided once when the drag starts,
    /// so a fast gesture cannot switch from resizing to moving halfway through.
    private enum CropDrag {
        case create
        case move
        /// -1 for the low edge, 1 for the high, 0 for untouched.
        case resize(x: Int, y: Int)
    }

    /// Where the seam falls, in screen units. Below zero draws no comparison.
    private var splitFraction: Float {
        if model.holdingB { return 2 }
        switch model.split {
        case .before: return 2
        case .after: return -1
        case .both: return Float(divider)
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                tokens.img

                if model.selection == .output {
                    finalView
                }

                if model.separated, model.selection != .output {
                    separatedLayout
                }

                if !model.separated && model.selection != .output {
                    // One view, one draw. The as-stacked comparison is a branch
                    // inside the shader rather than a second Metal view overlaid
                    // and masked: two views have to agree on layout to line up,
                    // and when they disagree the seam is very visible as an
                    // effect and invisible as a cause.
                    MetalImageView(
                        renderer: model.renderer,
                        ops: model.renderer.ops,
                        before: model.beforeSlot,
                        splitX: splitFraction,
                        detail: model.renderer.detail,
                        zoneTables: model.active.zoneTables,
                        viewport: model.viewport,
                        onZoom: { model.pinch($0, at: $1, viewAspect: $2) },
                        onPan: { model.drag($0, viewAspect: $1) },
                        onReset: { model.resetView() })
                }

                if model.split == .both && !model.holdingB && !model.separated
                    && model.selection != .output
                {
                    Rectangle().fill(tokens.line3).frame(width: 1)
                        .offset(x: geo.size.width * divider)
                }

                if !model.separated && model.selection != .output {
                    Text("As stacked").font(Face.mono(10)).foregroundStyle(tokens.t2)
                        .padding(Space.md)
                    Text(
                        model.calibrationActive
                            ? "\(model.algorithm.label) · calibrated" : model.algorithm.label
                    )
                    .font(Face.mono(10)).foregroundStyle(tokens.t2)
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if model.cropping || model.pendingCrop != nil {
                    cropOverlay(geo.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        guard geo.size.width > 0, geo.size.height > 0 else { return }
                        guard model.cropping else {
                            divider = min(0.98, max(0.02, v.location.x / geo.size.width))
                            return
                        }
                        if cropDrag == nil {
                            cropStart = pendingRect(geo.size)
                            cropDrag = cropMode(at: v.startLocation, rect: cropStart)
                        }
                        let rect = cropRect(
                            v.startLocation, v.location, mode: cropDrag ?? .create,
                            start: cropStart)
                        model.proposeCrop(
                            from: ndc(CGPoint(x: rect.minX, y: rect.minY), in: geo.size),
                            to: ndc(CGPoint(x: rect.maxX, y: rect.maxY), in: geo.size),
                            viewAspect: Float(geo.size.width / geo.size.height))
                    }
                    .onEnded { _ in
                        cropDrag = nil
                        cropStart = nil
                    })
        }
        .focusable()
        .onKeyPress(.return) {
            guard model.pendingCrop != nil else { return .ignored }
            model.confirmCrop()
            return .handled
        }
        .onKeyPress(.escape) {
            guard model.cropping || model.pendingCrop != nil else { return .ignored }
            model.cancelCrop()
            return .handled
        }
        .onKeyPress(phases: [.down, .up]) { press in
            guard press.characters.lowercased() == "b" else { return .ignored }
            model.holdingB = press.phase == .down
            return .handled
        }
    }

    /// One layer, drawn from its own state. Both are live and both were
    /// configured by the last push, so neither pane depends on which one the
    /// inspector happens to be pointed at.
    @ViewBuilder
    private func layerView(_ layer: DevelopModel.Layer, selectable: Bool = false) -> some View {
        if let s = model.state(for: layer) {
            let r = s.renderer
            MetalImageView(
                renderer: r, ops: r.ops, detail: r.detail, zoneTables: s.zoneTables,
                viewport: model.viewport,
                onSelect: selectable ? { model.select(layer) } : nil)
        } else {
            tokens.img
        }
    }

    /// The result, and nothing else. Selecting Output is the one place the
    /// canvas shows a single picture with no comparison and no panes — the
    /// whole point of it is to look at the thing you have made.
    @ViewBuilder
    private var finalView: some View {
        ZStack(alignment: .topLeading) {
            if model.separated {
                mergedView
            } else {
                MetalImageView(
                    renderer: model.renderer,
                    ops: model.renderer.ops,
                    detail: model.renderer.detail,
                    zoneTables: model.active.zoneTables,
                    viewport: model.viewport,
                    onZoom: { model.pinch($0, at: $1, viewAspect: $2) },
                    onPan: { model.drag($0, viewAspect: $1) },
                    onReset: { model.resetView() })
            }
            Text("Output").font(Face.mono(10)).foregroundStyle(tokens.t2).padding(Space.md)
        }
    }

    /// StarNet's star layer is unscreened, so screen is exactly its inverse:
    /// `1-(1-a)(1-b)`. SwiftUI's blend mode is that formula, which makes the
    /// merge a compositing choice rather than another render pass — and black
    /// contributes nothing to a screen, so the letterbox and anything outside
    /// the crop compose correctly without being special-cased.
    private var mergedView: some View {
        ZStack {
            layerView(.starless)
            layerView(.stars).blendMode(.screen)
        }
    }

    /// Selecting a pane points the inspector at that layer's parameters. It is a
    /// change of address and nothing more — no file is opened, no value is
    /// copied, and the other pane does not move.
    private func layerPane(_ layer: DevelopModel.Layer) -> some View {
        let selected = model.activeLayer == layer
        return ZStack(alignment: .topLeading) {
            layerView(layer, selectable: true)
            HStack(spacing: Space.xs) {
                Text(layer.rawValue)
                    .font(Face.mono(10))
                    .foregroundStyle(selected ? tokens.selT : tokens.t3)
                if selected {
                    Text("editing").font(Face.mono(9)).foregroundStyle(tokens.t4)
                }
            }
            .padding(Space.sm)
        }
        .overlay(
            Rectangle().stroke(
                selected ? tokens.selLine : tokens.line, lineWidth: selected ? 1.5 : 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(layer) }
    }

    /// Before and after belong here and nowhere else in the split: comparing a
    /// single layer against the master is comparing two different pictures,
    /// while the merge is the thing that has a before.
    private var labelledMerge: some View {
        GeometryReader { geo in
            let showBefore = model.holdingB ? true : (model.split != .after)
            let showAfter = model.holdingB ? false : (model.split != .before)

            ZStack(alignment: .topLeading) {
                tokens.img
                if showAfter { mergedView }

                if showBefore {
                    MetalImageView(
                        renderer: model.beforeRenderer,
                        ops: model.beforeRenderer.ops,
                        viewport: model.viewport
                    )
                    .mask(alignment: .leading) {
                        Rectangle().frame(
                            width: model.split == .both && !model.holdingB
                                ? geo.size.width * mergeDivider : geo.size.width)
                    }
                    .allowsHitTesting(false)
                }

                if model.split == .both && !model.holdingB {
                    Rectangle().fill(tokens.line3).frame(width: 1)
                        .offset(x: geo.size.width * mergeDivider)
                }

                Text(showBefore && !showAfter ? "As stacked" : "Merged")
                    .font(Face.mono(10)).foregroundStyle(tokens.t2)
                    .padding(Space.sm)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture().onChanged { v in
                    mergeDivider = min(0.98, max(0.02, v.location.x / geo.size.width))
                })
        }
        .overlay(Rectangle().stroke(tokens.line, lineWidth: 0.5))
    }

    @ViewBuilder
    private var separatedLayout: some View {
        switch model.splitLayout {
        case .stacked:
            VStack(spacing: 1) {
                labelledMerge
                HStack(spacing: 1) {
                    layerPane(.starless)
                    layerPane(.stars)
                }
            }
        case .triptych:
            HStack(spacing: 1) {
                layerPane(.starless)
                labelledMerge
                layerPane(.stars)
            }
        }
    }

    /// SwiftUI's y runs down the view, the shader's runs up the picture.
    private func ndc(_ p: CGPoint, in size: CGSize) -> SIMD2<Float> {
        SIMD2(
            Float(p.x / max(size.width, 1)) * 2 - 1,
            1 - Float(p.y / max(size.height, 1)) * 2)
    }

    /// Projected back from the frame's coordinates each time it is drawn, so the
    /// box tracks the picture if it is rotated or zoomed while still pending.
    private func pendingRect(_ size: CGSize) -> CGRect? {
        guard let c = model.pendingCrop, size.width > 0, size.height > 0 else { return nil }
        let aspect = Float(size.width / size.height)
        let corners = [SIMD2(c.x, c.y), SIMD2(c.z, c.w)].map { texel in
            let n = model.viewport.ndc(
                of: texel, imageAspect: model.imageAspect, viewAspect: aspect)
            return CGPoint(
                x: CGFloat(n.x + 1) / 2 * size.width,
                y: CGFloat(1 - n.y) / 2 * size.height)
        }
        return CGRect(
            x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
            width: abs(corners[1].x - corners[0].x),
            height: abs(corners[1].y - corners[0].y))
    }

    /// Grab an edge to resize, the middle to move, anywhere else to start over.
    private func cropMode(at p: CGPoint, rect: CGRect?) -> CropDrag {
        guard let rect else { return .create }
        let grab: CGFloat = 14
        let x = abs(p.x - rect.minX) < grab ? -1 : (abs(p.x - rect.maxX) < grab ? 1 : 0)
        let y = abs(p.y - rect.minY) < grab ? -1 : (abs(p.y - rect.maxY) < grab ? 1 : 0)

        // Only count an edge if the pointer is alongside the box, not out past
        // its corner on the other axis.
        let alongX = p.y > rect.minY - grab && p.y < rect.maxY + grab
        let alongY = p.x > rect.minX - grab && p.x < rect.maxX + grab
        if (x != 0 && alongX) || (y != 0 && alongY) {
            return .resize(x: alongX ? x : 0, y: alongY ? y : 0)
        }
        return rect.contains(p) ? .move : .create
    }

    private func cropRect(
        _ from: CGPoint, _ to: CGPoint, mode: CropDrag, start: CGRect?
    ) -> CGRect {
        let dx = to.x - from.x
        let dy = to.y - from.y

        switch mode {
        case .create:
            let r = CGRect(
                x: min(from.x, to.x), y: min(from.y, to.y),
                width: abs(to.x - from.x), height: abs(to.y - from.y))
            return locked(r, anchor: from)
        case .move:
            guard let start else { return .zero }
            return start.offsetBy(dx: dx, dy: dy)
        case .resize(let ex, let ey):
            guard let start else { return .zero }
            var r = start
            if ex < 0 { r.origin.x += dx; r.size.width -= dx }
            if ex > 0 { r.size.width += dx }
            if ey < 0 { r.origin.y += dy; r.size.height -= dy }
            if ey > 0 { r.size.height += dy }
            // Dragging an edge past its opposite flips the rectangle rather
            // than collapsing it, which is what every other editor does.
            let flipped = CGRect(
                x: min(r.minX, r.maxX), y: min(r.minY, r.maxY),
                width: abs(r.width), height: abs(r.height))
            return locked(
                flipped,
                anchor: CGPoint(
                    x: ex < 0 ? flipped.maxX : flipped.minX,
                    y: ey < 0 ? flipped.maxY : flipped.minY))
        }
    }

    /// Holds a rectangle to the chosen ratio while keeping `anchor` still, so
    /// the corner you are not dragging stays where you put it.
    private func locked(_ rect: CGRect, anchor: CGPoint) -> CGRect {
        guard let ratio = model.effectiveCropRatio, rect.width > 0, rect.height > 0 else {
            return rect
        }
        var w = rect.width
        var h = rect.height
        // Whichever side was dragged further decides the size, so the box
        // follows the pointer rather than fighting it.
        if w / h > ratio { h = w / ratio } else { w = h * ratio }

        let x = abs(anchor.x - rect.minX) < 0.5 ? anchor.x : anchor.x - w
        let y = abs(anchor.y - rect.minY) < 0.5 ? anchor.y : anchor.y - h
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Dimming outside the box rather than drawing only its outline: what is
    /// about to be discarded is the part worth showing.
    private func cropOverlay(_ size: CGSize) -> some View {
        let rect = pendingRect(size)
        return ZStack(alignment: .topLeading) {
            if let rect {
                Canvas { ctx, full in
                    var outside = Path(CGRect(origin: .zero, size: full))
                    outside.addRect(rect)
                    ctx.fill(
                        outside, with: .color(.black.opacity(0.55)),
                        style: FillStyle(eoFill: true))
                    ctx.stroke(Path(rect), with: .color(tokens.selT), lineWidth: 1)
                    // Thirds, which is what the eye actually uses to place a
                    // subject in a frame.
                    for i in 1...2 {
                        let f = CGFloat(i) / 3
                        ctx.stroke(
                            Path {
                                $0.move(to: CGPoint(x: rect.minX + rect.width * f, y: rect.minY))
                                $0.addLine(
                                    to: CGPoint(x: rect.minX + rect.width * f, y: rect.maxY))
                                $0.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * f))
                                $0.addLine(
                                    to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * f))
                            },
                            with: .color(tokens.selT.opacity(0.25)), lineWidth: 0.5)
                    }

                    // Corner brackets rather than dots: they read as grabbable
                    // without covering the picture underneath.
                    let arm: CGFloat = 14
                    for (cx, sx) in [(rect.minX, 1.0), (rect.maxX, -1.0)] {
                        for (cy, sy) in [(rect.minY, 1.0), (rect.maxY, -1.0)] {
                            ctx.stroke(
                                Path {
                                    $0.move(to: CGPoint(x: cx + arm * sx, y: cy))
                                    $0.addLine(to: CGPoint(x: cx, y: cy))
                                    $0.addLine(to: CGPoint(x: cx, y: cy + arm * sy))
                                },
                                with: .color(tokens.selT), lineWidth: 2.5)
                        }
                    }
                }
                if let r = model.cropResolution {
                    Text("\(r.w) × \(r.h) px")
                        .font(Face.mono(10))
                        .foregroundStyle(model.cropIsUsable ? tokens.t1 : tokens.q2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(tokens.s1.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.swatch))
                        .offset(x: rect.minX, y: max(rect.minY - 20, 0))
                }
                Text("Drag inside to move · edges to resize · Return to crop")
                    .font(Face.mono(10)).foregroundStyle(tokens.t3)
                    .padding(Space.h1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else {
                Text("Drag a rectangle over the picture")
                    .font(Face.mono(10)).foregroundStyle(tokens.t2)
                    .padding(Space.h1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Three channels over each other, on the displayed values rather than the raw
/// ones, so what it shows is the picture on screen. Drawn as smoothed curves:
/// at 256 bins over a few hundred points a bar chart reads as a comb, and the
/// shape is the part worth seeing.
struct Histogram: View {
    let channels: [[Float]]
    let black: Float
    let tokens: Tokens

    /// A short moving average. Enough to settle the bin-to-bin noise without
    /// moving where the peak sits.
    private func smoothed(_ bins: [Float]) -> [Float] {
        guard bins.count > 4 else { return bins }
        let radius = 2
        return bins.indices.map { i in
            var sum: Float = 0
            var n: Float = 0
            for k in max(0, i - radius)...min(bins.count - 1, i + radius) {
                sum += bins[k]
                n += 1
            }
            return sum / n
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let curves = channels.map(smoothed)
            let peak = curves.flatMap { $0 }.max() ?? 1
            guard peak > 0 else { return }
            let colours: [Color] = [.red, .green, .blue]

            for (i, bins) in curves.enumerated() {
                let points = bins.enumerated().map { x, v -> CGPoint in
                    // Log scale: a linear histogram of astro data is one spike.
                    let h = CGFloat(log(1 + v / peak * 999) / log(1000)) * size.height
                    return CGPoint(
                        x: size.width * CGFloat(x) / CGFloat(bins.count - 1),
                        y: size.height - h)
                }

                var line = Path()
                line.addLines(points)

                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()

                ctx.fill(fill, with: .color(colours[i].opacity(0.14)))
                ctx.stroke(line, with: .color(colours[i].opacity(0.85)), lineWidth: 1)
            }

            if black > 0.001 {
                let x = size.width * CGFloat(black)
                ctx.stroke(
                    Path {
                        $0.move(to: CGPoint(x: x, y: 0))
                        $0.addLine(to: CGPoint(x: x, y: size.height))
                    },
                    with: .color(tokens.t3), lineWidth: 0.5)
            }
        }
    }
}

/// A transfer function drawn against the diagonal it departs from — the only
/// way to see at a glance which tones gained and which paid.
struct CurveView: View {
    let curves: [(Color, [Float])]
    let tokens: Tokens

    var body: some View {
        Canvas { ctx, size in
            ctx.stroke(
                Path {
                    $0.move(to: CGPoint(x: 0, y: size.height))
                    $0.addLine(to: CGPoint(x: size.width, y: 0))
                },
                with: .color(tokens.line2), lineWidth: 0.5)

            for (colour, values) in curves where values.count > 1 {
                var path = Path()
                path.addLines(
                    values.enumerated().map { i, v in
                        CGPoint(
                            x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                            y: size.height * (1 - CGFloat(min(max(v, 0), 1))))
                    })
                ctx.stroke(path, with: .color(colour), lineWidth: 1.4)
            }
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// Drag and drop, applied only to rows that can actually move — a pinned stage
/// should not offer a gesture that would be refused.
struct StageDrag: ViewModifier {
    let model: DevelopModel
    let row: DevelopModel.Row
    @Binding var dragging: UUID?

    func body(content: Content) -> some View {
        guard case .stage(let id) = row.id, !row.fixed else { return AnyView(content) }
        return AnyView(
            content
                .onDrag {
                    dragging = id
                    return NSItemProvider(object: id.uuidString as NSString)
                }
                .dropDestination(for: String.self) { items, _ in
                    dragging = nil
                    guard let dropped = items.first.flatMap(UUID.init(uuidString:)),
                        let index = model.stack.firstIndex(where: { $0.id == id })
                    else { return false }
                    return model.moveStage(dropped, to: index)
                } isTargeted: { over in
                    if !over, dragging == id { dragging = nil }
                }
        )
    }
}
