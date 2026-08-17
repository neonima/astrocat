import simd

/// What part of the frame is on screen and which way up it is.
///
/// Deliberately separate from the develop operations: nothing here changes a
/// pixel value, only which pixels you are looking at. That is why it composes
/// into a single matrix handed to the vertex shader rather than joining the
/// operation list.
struct Viewport: Equatable, Codable {
    /// 1 fits the frame to the pane; 2 shows it at twice that.
    var zoom: Float = 1
    /// Offset in texture units, so 0.1 is a tenth of the frame regardless of
    /// how far in you are.
    var pan = SIMD2<Float>(repeating: 0)
    /// Quarter turns clockwise.
    var rotation = 0
    var flipH = false
    var flipV = false
    /// The kept region as x0, y0, x1, y1 in texture units. Held in the frame's
    /// own coordinates rather than the rotated view's, so turning the picture
    /// afterwards carries the crop with it instead of re-cutting the frame.
    var crop = SIMD4<Float>(0, 0, 1, 1)

    static let minZoom: Float = 0.1
    static let maxZoom: Float = 64

    var isFit: Bool { abs(zoom - 1) < 0.001 && pan == .zero }
    var isCropped: Bool { crop != SIMD4(0, 0, 1, 1) }
    var isIdentity: Bool { isFit && rotation == 0 && !flipH && !flipV && !isCropped }

    var cropSize: SIMD2<Float> {
        SIMD2(max(crop.z - crop.x, 0.01), max(crop.w - crop.y, 0.01))
    }

    var cropCentre: SIMD2<Float> {
        SIMD2((crop.x + crop.z) / 2, (crop.y + crop.w) / 2)
    }

    /// Ordered, clamped to the frame and never smaller than a sliver, so a
    /// backwards or off-edge drag still produces a usable rectangle.
    mutating func setCrop(_ a: SIMD2<Float>, _ b: SIMD2<Float>) {
        let x0 = min(a.x, b.x).clamped(), x1 = max(a.x, b.x).clamped()
        let y0 = min(a.y, b.y).clamped(), y1 = max(a.y, b.y).clamped()
        guard x1 - x0 > 0.02, y1 - y0 > 0.02 else { return }
        crop = SIMD4(x0, y0, x1, y1)
        pan = .zero
        zoom = 1
    }

    var quarterTurns: Int { ((rotation % 4) + 4) % 4 }

    mutating func rotate(_ turns: Int) {
        rotation = (((rotation + turns) % 4) + 4) % 4
    }

    /// Columns of the map from normalised device coordinates to texture
    /// coordinates, plus where the centre of the view lands. Everything about
    /// aspect, orientation and scale is resolved here so the shader only has to
    /// multiply.
    func matrix(imageAspect: Float, viewAspect: Float) -> (
        x: SIMD2<Float>, y: SIMD2<Float>, centre: SIMD2<Float>
    ) {
        let a = max(imageAspect, 1e-4)
        let v = max(viewAspect, 1e-4)
        // The crop is what has to fit the pane, and its shape is not the
        // frame's: a tall slice out of a wide frame is a tall picture.
        let size = cropSize
        let cropAspect = max(a * size.x / size.y, 1e-4)

        // A quarter turn swaps which side the fit is limited by.
        let turned = quarterTurns % 2 == 1
        let fit = min(v / (turned ? 1 : cropAspect), 1 / (turned ? cropAspect : 1))
        let scale = fit * min(max(zoom, Self.minZoom), Self.maxZoom)

        // ndc to viewport units, taking the height as 1.
        var m = simd_float2x2(SIMD2(v / 2, 0), SIMD2(0, 0.5))
        // Viewport units back to image units: the view transform is applied to
        // the sampling coordinate, so every step is the inverse of what the
        // picture appears to do.
        m = simd_float2x2(SIMD2(1 / scale, 0), SIMD2(0, 1 / scale)) * m

        let theta = -Float(quarterTurns) * .pi / 2
        let (s, c) = (sin(theta), cos(theta))
        m = simd_float2x2(SIMD2(c, s), SIMD2(-s, c)) * m
        m = simd_float2x2(SIMD2(flipH ? -1 : 1, 0), SIMD2(0, flipV ? -1 : 1)) * m
        // Crop-height units to texture units. Row 0 of the buffer is the bottom
        // of the frame, so v rises with ndc.y. Uncropped this is the old
        // diag(1/a, 1), since the crop height is then the frame height.
        m = simd_float2x2(SIMD2(size.y / a, 0), SIMD2(0, size.y)) * m

        return (m.columns.0, m.columns.1, cropCentre + pan)
    }

    /// The texture coordinate under a point given in normalised device
    /// coordinates.
    func texel(at ndc: SIMD2<Float>, imageAspect: Float, viewAspect: Float) -> SIMD2<Float> {
        let m = matrix(imageAspect: imageAspect, viewAspect: viewAspect)
        return m.x * ndc.x + m.y * ndc.y + m.centre
    }

    /// Where a texture coordinate lands on screen, in normalised device
    /// coordinates. The inverse of `texel(at:)`, so a rectangle held in the
    /// frame's coordinates can be drawn back over the picture after a rotation
    /// or a zoom has moved it.
    func ndc(of texel: SIMD2<Float>, imageAspect: Float, viewAspect: Float) -> SIMD2<Float> {
        let m = matrix(imageAspect: imageAspect, viewAspect: viewAspect)
        let d = texel - m.centre
        let det = m.x.x * m.y.y - m.y.x * m.x.y
        guard abs(det) > 1e-12 else { return .zero }
        return SIMD2(
            (m.y.y * d.x - m.y.x * d.y) / det,
            (-m.x.y * d.x + m.x.x * d.y) / det)
    }

    /// Zooms while holding whatever is under the cursor still, which is the
    /// difference between zoom that feels native and zoom that feels like a
    /// slider.
    mutating func zoom(
        to newZoom: Float, anchor ndc: SIMD2<Float>, imageAspect: Float, viewAspect: Float
    ) {
        let target = texel(at: ndc, imageAspect: imageAspect, viewAspect: viewAspect)
        zoom = min(max(newZoom, Self.minZoom), Self.maxZoom)
        let m = matrix(imageAspect: imageAspect, viewAspect: viewAspect)
        pan = target - (m.x * ndc.x + m.y * ndc.y) - cropCentre
    }

    /// Keeps the frame from being dragged entirely out of view. Once zoomed out
    /// far enough to see all of it there is nothing to pan to, so it recentres.
    mutating func clampPan(imageAspect: Float, viewAspect: Float) {
        let m = matrix(imageAspect: imageAspect, viewAspect: viewAspect)
        let half = SIMD2(abs(m.x.x) + abs(m.y.x), abs(m.x.y) + abs(m.y.y))
        // Bounded by the crop, not the frame: once cropped, the region outside
        // it is no longer somewhere you can pan to.
        let limit = cropSize / 2
        let slack = simd_max(limit - half, .zero)
        pan = simd_clamp(pan, -slack, slack)
    }
}

extension Float {
    func clamped() -> Float { min(max(self, 0), 1) }
}
