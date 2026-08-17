import Foundation
import simd

/// One editable picture: its pixels, its renderer, and its own stack of stages.
///
/// A separated frame is two pictures, not one picture with a switch. Each gets a
/// complete stack because they want different treatment — and increasingly not
/// even the same *stages*: a star field has no sky whose cast wants neutralising
/// and no nebulosity to allocate contrast to, so offering it those by default
/// offers work that cannot help. Holding both live is also what makes selecting
/// a pane a change of address rather than a file load.
@MainActor
final class LayerState {
    /// One renderer each. A single renderer cannot drive two views — whichever
    /// drew last would set the uniforms for both.
    let renderer = Renderer()
    var path = ""
    var frame: LoadedFrame?
    var meta: FrameMeta?

    /// The stages, in the order they run.
    var stack: [OpInstance]

    var histogramRGB: [[Float]] = Array(
        repeating: Array(repeating: 0, count: 256), count: 3)

    init(template: [OpInstance]) {
        stack = template
    }

    /// The one stretch stage. Its parameters are the layer's tonal baseline, so
    /// they are reached directly rather than through whatever is selected.
    var stretch: OpInstance {
        get { stack.first { $0.isStretch } ?? OpInstance(kind: "Screen stretch") }
        set {
            guard let i = stack.firstIndex(where: { $0.isStretch }) else { return }
            stack[i] = newValue
        }
    }

    var hasStretch: Bool { stack.contains { $0.isStretch } }

    func index(of id: UUID) -> Int? { stack.firstIndex { $0.id == id } }

    /// Curves in stack order, one per Zone balance stage. A stage's slot carries
    /// its position in this list.
    var zoneTables: [[Float]] {
        stack.filter { $0.kind == "Zone balance" }.map { $0.zones.table() }
    }

    func zoneIndex(of id: UUID) -> Int32 {
        var n: Int32 = 0
        for op in stack {
            guard op.kind == "Zone balance" else { continue }
            if op.id == id { return n }
            n += 1
        }
        return 0
    }

    /// The single Detail stage, which drives the two-pass render.
    var detailStage: OpInstance? {
        stack.first { $0.kind == "Detail" && $0.on }
    }

    func upload(_ f: LoadedFrame) {
        frame = f
        meta = f.meta
        path = f.meta.path
        renderer.upload(f)
        renderer.setZones(zoneTables)
    }

    /// Back to the template for this kind of layer. Geometry is absent by
    /// design: crop and rotation belong to the frame, not to a layer.
    func clear(template: [OpInstance]) {
        stack = template
    }
}
