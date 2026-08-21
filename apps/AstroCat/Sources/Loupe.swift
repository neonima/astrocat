import SwiftUI
import simd

/// One sub, at its own resolution, on the display path the rest of the app
/// uses.
///
/// The contact sheet cannot answer the question this exists for. Its thumbnails
/// come from `to_rgb_half` and are then box-filtered down again, and at 3.67″/px
/// a star is one or two pixels — so by the time a frame is 62 px wide, a soft
/// star and a sharp one are the same grey smudge. Deciding a frame is out of
/// focus is deciding it on pixels, which means loading the frame.
@MainActor
final class FrameLoupe: ObservableObject {
    let renderer = Renderer()

    @Published private(set) var path = ""
    @Published private(set) var meta: FrameMeta?
    @Published private(set) var loading = false
    @Published var viewport = Viewport()
    /// A request, not a state: only the view knows how tall the pane is, so it
    /// resolves this and clears it.
    @Published var isActualPixels = false

    /// Arrowing through a night starts a load per frame and they finish out of
    /// order. Only the newest may display, or the pane settles on whichever
    /// frame happened to decode last.
    private var generation = 0
    private var viewAspect: Float = 1.6

    var imageAspect: Float {
        guard let m = meta, m.height > 0 else { return 1 }
        let a = Float(m.width) / Float(m.height)
        return a.isFinite && a > 0 ? a : 1
    }

    var ready: Bool { meta != nil }

    var zoomLabel: String {
        viewport.isFit ? "Fit" : String(format: "%.0f%%", viewport.zoom * 100)
    }

    func show(_ path: String) {
        guard path != self.path, !path.isEmpty else { return }
        self.path = path
        // Keeping the old frame up would be worse than an empty pane: it looks
        // exactly like the new frame, and the whole task is telling frames
        // apart.
        meta = nil
        loading = true
        viewport = Viewport()

        generation += 1
        let mine = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = try? LoadedFrame(url: URL(fileURLWithPath: path))
            DispatchQueue.main.async {
                guard mine == self.generation else { return }
                self.loading = false
                guard let loaded else { return }
                self.renderer.upload(loaded)
                self.renderer.shadows = loaded.meta.shadows
                self.renderer.midtone = loaded.meta.midtone
                self.renderer.algorithm = Algorithm.stf.rawValue
                self.renderer.saturation = 1
                self.renderer.blend = 1
                self.renderer.ops = [3]
                self.meta = loaded.meta
                // The pixels are in the texture now; a 66 MB buffer per frame
                // is not worth holding to redo an upload that will not happen.
            }
        }
    }

    /// Reloads whatever is open. Used when the pane appears with a frame
    /// already set, which `show` would otherwise treat as no change.
    func reshow(_ path: String) {
        guard !path.isEmpty else { return }
        if path == self.path && meta != nil { return }
        self.path = ""
        show(path)
    }

    func pinch(_ factor: Float, at ndc: SIMD2<Float>, viewAspect aspect: Float) {
        viewAspect = aspect
        viewport.zoom(
            to: viewport.zoom * factor, anchor: ndc, imageAspect: imageAspect, viewAspect: aspect)
        viewport.clampPan(imageAspect: imageAspect, viewAspect: aspect)
    }

    func drag(_ displacement: SIMD2<Float>, viewAspect aspect: Float) {
        viewAspect = aspect
        let m = viewport.matrix(imageAspect: imageAspect, viewAspect: aspect)
        viewport.pan -= m.x * displacement.x + m.y * displacement.y
        viewport.clampPan(imageAspect: imageAspect, viewAspect: aspect)
    }

    func zoomBy(_ factor: Float) {
        pinch(factor, at: .zero, viewAspect: viewAspect)
    }

    func fit() {
        viewport.zoom = 1
        viewport.pan = .zero
    }

    /// One texture pixel per drawable pixel — where star shape actually becomes
    /// readable, and the reason this view exists. `zoom` is a multiple of the
    /// fit, so what 1:1 costs depends on how big the pane is.
    func actualPixels(paneHeight: CGFloat, scale: CGFloat) {
        guard let m = meta, m.height > 0, paneHeight > 0 else { return }
        let drawable = Float(paneHeight * scale)
        viewport.zoom = min(max(Float(m.height) / drawable, Viewport.minZoom), Viewport.maxZoom)
        viewport.clampPan(imageAspect: imageAspect, viewAspect: viewAspect)
    }
}

/// The centre pane of the Library's Frame view: one frame large, the run it
/// belongs to underneath.
struct LoupePane: View {
    @ObservedObject var loupe: FrameLoupe
    @ObservedObject var catalog: Catalog
    @ObservedObject var shell: ShellModel
    @ObservedObject var thumbs: ThumbnailStore
    let frames: [Frame]
    let selection: Set<Int>
    let aspect: CGFloat
    let tokens: Tokens

    private var current: Frame? {
        frames.indices.contains(shell.cursor) ? frames[shell.cursor] : nil
    }

    /// Judged against the session's own median, which is the only comparison
    /// that means anything — a night of poor seeing is soft throughout and
    /// that is not the same as one frame having drifted out of focus.
    private var medianHFR: Float {
        let v = frames.map(\.hfr).sorted()
        return v.isEmpty ? 0 : v[v.count / 2]
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            canvas
            Divider().overlay(tokens.line)
            filmstrip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.well)
        // Keyed on the path, not the cursor: changing session or filters moves
        // which frame the cursor names without moving the cursor, and keying on
        // the index leaves the previous frame on screen under the new one's
        // measurements.
        .onAppear { if let f = current { loupe.reshow(f.path) } }
        .onChange(of: current?.path) { _, path in if let path { loupe.show(path) } }
    }

    private var headerBar: some View {
        HStack(spacing: Space.md) {
            if let f = current {
                Text("FRAME \(shell.cursor + 1) OF \(frames.count)")
                    .font(Face.sectionHeader).tracking(Face.sectionTracking)
                    .foregroundStyle(tokens.t3)
                Text(URL(fileURLWithPath: f.path).lastPathComponent)
                    .font(Face.mono(10)).foregroundStyle(tokens.t2)
                    .lineLimit(1).truncationMode(.middle)

                focusBadge(f)

                if f.rejected {
                    tag("REJECTED — out of the stack", tokens.q1)
                }
            } else {
                Text("No frame").font(Face.secondary).foregroundStyle(tokens.t3)
            }

            Spacer()

            // The point of looking closely is deciding, so the decision is here
            // rather than back in a panel you have to go and find.
            if let f = current {
                Button {
                    catalog.setRejected(f.id, !f.rejected)
                } label: {
                    HStack(spacing: Space.xs) {
                        Text(f.rejected ? "Keep" : "Reject")
                        Text(f.rejected ? "A" : "X").font(Face.mono(9))
                            .padding(.horizontal, 3).frame(height: 13)
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.swatch)
                                    .stroke(tokens.line2, lineWidth: 0.5))
                    }
                    .font(Face.body)
                    .foregroundStyle(f.rejected ? tokens.q5 : tokens.q1)
                    .padding(.horizontal, Space.sm)
                    .frame(height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control)
                            .stroke((f.rejected ? tokens.q5 : tokens.q1).opacity(0.5),
                                    lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            if loupe.loading {
                Text("loading full resolution…")
                    .font(Face.mono(10)).foregroundStyle(tokens.t3)
            }
            Text(loupe.zoomLabel).font(Face.mono(11)).foregroundStyle(tokens.t2)
                .frame(width: 46, alignment: .trailing)
            button("Fit") { loupe.fit() }
            button("1:1") { loupe.isActualPixels = true }
            button("−") { loupe.zoomBy(1 / 1.4) }
            button("+") { loupe.zoomBy(1.4) }
        }
        .padding(.horizontal, Metric.panelPad)
        .frame(height: 26)
        .background(tokens.s1)
    }

    /// The number that decides the question this view is open for, next to what
    /// it should be measured against.
    @ViewBuilder private func focusBadge(_ f: Frame) -> some View {
        let m = medianHFR
        let delta = m > 0 ? (f.hfr - m) / m : 0
        let colour: Color = delta > 0.25 ? tokens.q1 : (delta > 0.1 ? tokens.q2 : tokens.t2)
        HStack(spacing: Space.xs) {
            Text(String(format: "HFR %.2f", f.hfr)).font(Face.mono(11)).foregroundStyle(colour)
            Text(String(format: "%@%.0f%% vs median %.2f", delta >= 0 ? "+" : "", delta * 100, m))
                .font(Face.mono(10)).foregroundStyle(tokens.t3)
            Text(String(format: "ecc %.2f", f.ecc)).font(Face.mono(10))
                .foregroundStyle(f.ecc > 0.85 ? tokens.q2 : tokens.t3)
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                tokens.img
                if loupe.ready {
                    MetalImageView(
                        renderer: loupe.renderer,
                        shadows: loupe.renderer.shadows,
                        midtone: loupe.renderer.midtone,
                        algorithm: Algorithm.stf.rawValue,
                        p0: 10, p1: 0.2, blend: 1, saturation: 1,
                        ops: [3],
                        viewport: loupe.viewport,
                        onZoom: { loupe.pinch($0, at: $1, viewAspect: $2) },
                        onPan: { loupe.drag($0, viewAspect: $1) },
                        onReset: { loupe.fit() })
                } else if let f = current {
                    // The cached thumbnail while the frame decodes, so arrowing
                    // through a night stays a sequence of pictures rather than a
                    // sequence of empty panes.
                    Thumbnail(path: f.path, size: 480, store: thumbs, placeholder: tokens.img)
                        .opacity(0.55)
                }

                if let f = current, f.rejected {
                    Rectangle().stroke(tokens.q1, lineWidth: 2).allowsHitTesting(false)
                }
            }
            // Resolved here because 1:1 depends on how tall the pane is, which
            // the model has no way to know.
            .onChange(of: loupe.isActualPixels) { _, want in
                guard want else { return }
                loupe.isActualPixels = false
                loupe.actualPixels(
                    paneHeight: geo.size.height,
                    scale: NSScreen.main?.backingScaleFactor ?? 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Metric.frameGap) {
                    ForEach(Array(frames.enumerated()), id: \.element.id) { i, f in
                        FrameCell(
                            frame: f, index: i + 1, selected: selection.contains(f.id),
                            size: .small, aspect: aspect, thumbs: thumbs, tokens: tokens
                        )
                        .id(f.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            shell.rankSelection = 0
                            shell.cutWorst = 0
                            shell.namedSelection = nil
                            shell.anchor = nil
                            shell.cursor = i
                        }
                    }
                }
                .padding(.horizontal, Metric.panelPad)
                .padding(.vertical, Space.sm)
            }
            .onChange(of: shell.cursor) { _, _ in
                guard let f = current else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(f.id, anchor: .center) }
            }
        }
        .frame(height: SheetSize.small.height(aspect) + Space.sm * 2)
        .background(tokens.s1)
    }

    private func tag(_ text: String, _ colour: Color) -> some View {
        Text(text).font(Face.mono(9)).foregroundStyle(colour)
            .padding(.horizontal, 4).frame(height: 14)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.swatch)
                    .stroke(colour.opacity(0.6), lineWidth: 0.5))
    }

    private func button(_ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(label).font(Face.mono(10)).foregroundStyle(tokens.t2)
                .frame(width: 26, height: 18)
                .background(tokens.s2)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .stroke(tokens.line2, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
    }
}
