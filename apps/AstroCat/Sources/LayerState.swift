import Foundation
import simd

/// One editable picture: its pixels, its renderer, and every parameter that
/// acts on it.
///
/// A separated frame is two pictures, not one picture with a switch. Each gets
/// a complete parameter set because they want opposite treatment — the starless
/// layer is stretched hard for faint nebulosity, the star layer needs a curve
/// that does not bloat what it has. Holding both live is also what makes
/// selecting a pane a change of address rather than a file load: the state is
/// already there and already rendered, so switching moves nothing.
@MainActor
final class LayerState {
    /// One renderer each. A single renderer cannot drive two views — whichever
    /// drew last would set the uniforms for both.
    let renderer = Renderer()
    var path = ""
    var frame: LoadedFrame?
    var meta: FrameMeta?

    var algorithm: Algorithm = .stf
    var p0: Float = 10
    var p1: Float = 0.2
    var blend: Float = 1
    var black: Float = 0
    var midtone: Float = 0.25
    var linked = false
    var saturation: Float = 1.15
    var linearMode = true
    var displayOnly = true
    /// The auto-fitted values the sliders are expressed against, so a change of
    /// baseline rescales the tuning instead of discarding it.
    var midtoneBase: Float = 0.25
    var p0Base: Float = 10

    var palette: Palette = .natural
    var mix = PaletteMix()
    var zones = ZoneCurve() {
        didSet {
            zoneTable = zones.table()
            renderer.setZones(zoneTable)
        }
    }
    private(set) var zoneTable: [Float] = ZoneCurve().table()
    var tone = ToneParams()
    var detail = DetailParams()

    /// Operations switched on for this picture alone. The spine above the split
    /// is not in here — it belongs to the master.
    var enabled: Set<String> = ["Screen stretch"]

    var histogramRGB: [[Float]] = Array(
        repeating: Array(repeating: 0, count: 256), count: 3)

    init(linked: Bool = false) {
        self.linked = linked
    }

    func upload(_ f: LoadedFrame) {
        frame = f
        meta = f.meta
        path = f.meta.path
        renderer.upload(f)
        renderer.setZones(zoneTable)
    }

    /// Everything except the pixels back to its default. Geometry is absent by
    /// design: crop and rotation belong to the frame, not to a layer.
    func clear() {
        algorithm = .stf
        p0 = 10
        p0Base = 10
        p1 = 0.2
        blend = 1
        black = 0
        saturation = 1.15
        linearMode = true
        displayOnly = true
        palette = .natural
        mix = PaletteMix()
        zones = ZoneCurve()
        tone = ToneParams()
        detail = DetailParams()
        enabled = ["Screen stretch"]
    }
}
