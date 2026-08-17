import MetalKit
import SwiftUI
import simd

/// Handles the gestures AppKit already knows about — pinch, precise scroll,
/// double click — rather than approximating them with SwiftUI drag handlers,
/// which cannot tell a trackpad from a mouse or read a magnification delta.
final class CanvasView: MTKView {
    /// Zoom multiplier and the cursor position in normalised device
    /// coordinates, so the caller can hold that point still.
    var onZoom: ((Float, SIMD2<Float>) -> Void)?
    var onPan: ((SIMD2<Float>, Float) -> Void)?
    var onReset: (() -> Void)?
    var onSelect: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    private func ndc(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return SIMD2(
            Float(p.x / bounds.width) * 2 - 1,
            Float(p.y / bounds.height) * 2 - 1)
    }

    override func magnify(with event: NSEvent) {
        onZoom?(Float(1 + event.magnification), ndc(event))
    }

    override func scrollWheel(with event: NSEvent) {
        // Matching Preview: two fingers pan, the same gesture with a modifier
        // zooms, and a mouse wheel — which has no second axis worth panning
        // with — zooms directly.
        let zooming =
            event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command)
            || !event.hasPreciseScrollingDeltas

        if zooming {
            onZoom?(Float(1 + event.scrollingDeltaY * 0.01), ndc(event))
            return
        }
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Reported as how far the content should move. The deltas already carry
        // the system's natural-scrolling setting, so no second inversion here.
        onPan?(
            SIMD2(
                Float(event.scrollingDeltaX / bounds.width) * 2,
                Float(-event.scrollingDeltaY / bounds.height) * 2),
            Float(bounds.width / bounds.height))
    }

    /// A single click has to be reported here rather than left to a SwiftUI
    /// gesture on the enclosing view. Overriding `mouseDown` at all makes this
    /// view swallow the event — an `onTapGesture` wrapped around a Metal view
    /// never fires, which is why clicking a layer pane to select it did nothing
    /// while the segmented control worked.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
        } else {
            onSelect?()
        }
        super.mouseDown(with: event)
    }
}

/// The pipeline is a stored property, not read off the renderer, so SwiftUI sees
/// the struct change and actually calls updateNSView. A change it cannot see is
/// a change it will not redraw for — the oldest bug in this project.
struct MetalImageView: NSViewRepresentable {
    let renderer: Renderer
    var ops: [OpSlot] = []
    var before = OpSlot()
    /// Below zero draws no comparison at all, which is the ordinary case.
    var splitX: Float = -1
    var detail = DetailParams()
    /// One 256-entry curve per Zone balance stage, in stack order.
    var zoneTables: [[Float]] = []
    var viewport = Viewport()
    /// Gestures report in view terms; only the owner knows what to do with
    /// them, so they are handed straight up.
    var onZoom: ((Float, SIMD2<Float>, Float) -> Void)?
    var onPan: ((SIMD2<Float>, Float) -> Void)?
    var onReset: (() -> Void)?
    var onSelect: (() -> Void)?

    func makeNSView(context: Context) -> MTKView {
        let view = CanvasView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.02, 0.02, 0.02, 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true

        view.onZoom = { [weak view] factor, at in
            guard let view, view.bounds.height > 0 else { return }
            onZoom?(factor, at, Float(view.bounds.width / view.bounds.height))
        }
        view.onPan = { onPan?($0, $1) }
        view.onReset = { onReset?() }
        view.onSelect = { onSelect?() }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        renderer.viewport = viewport
        renderer.detail = detail
        renderer.ops = ops
        renderer.before = before
        renderer.splitX = splitX
        if !zoneTables.isEmpty { renderer.setZones(zoneTables) }
        view.draw()
    }
}
