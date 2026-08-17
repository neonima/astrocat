import SwiftUI

private func span(_ frames: [Frame]) -> (Int64, Int64) {
    let lo = frames.map(\.second).min() ?? 0
    let hi = frames.map(\.second).max() ?? 1
    return (lo, max(hi, lo + 1))
}

/// Breaks longer than two minutes: slews, refocus, cloud stops.
private func gaps(_ frames: [Frame]) -> [(Int64, Int64)] {
    let s = frames.map(\.second).sorted()
    return zip(s, s.dropFirst()).compactMap { a, b in b - a > 120 ? (a, b - a) : nil }
}

struct SkyEvent {
    let label: String
    let start: Int64
    let end: Int64
}

/// Reads the star-count curve for the two things that actually happen to a
/// night: cloud passing through and recovering, and twilight ending it.
func skyEvents(_ frames: [Frame]) -> [SkyEvent] {
    let f = frames.sorted { $0.second < $1.second }
    guard f.count > 20 else { return [] }

    var counts = f.map { Double($0.stars) }
    let sorted = counts.sorted()
    let median = sorted[sorted.count / 2]
    guard median > 0 else { return [] }

    var events: [SkyEvent] = []
    var tailStart = f.count

    // Twilight: a decline at the end of the night that never comes back.
    var i = f.count - 1
    while i > 0 && counts[i] < median * 0.75 {
        i -= 1
    }
    if i < f.count - 5 {
        tailStart = i + 1
        events.append(
            SkyEvent(label: "astronomical twilight", start: f[tailStart].second, end: f.last!.second))
    }

    // Cloud: a dip below the run of the night that recovers before the tail.
    var j = 0
    while j < tailStart {
        if counts[j] < median * 0.8 {
            var k = j
            while k < tailStart && counts[k] < median * 0.8 { k += 1 }
            if k - j >= 3 {
                events.append(
                    SkyEvent(label: "thin cloud", start: f[j].second, end: f[k - 1].second))
            }
            j = k
        } else {
            j += 1
        }
    }
    counts.removeAll()

    // Merge same-label spans that touch, otherwise a broken run draws the
    // label on top of itself.
    var merged: [SkyEvent] = []
    for e in events.sorted(by: { $0.start < $1.start }) {
        if let last = merged.last, last.label == e.label, e.start <= last.end + 300 {
            merged[merged.count - 1] = SkyEvent(
                label: last.label, start: last.start, end: max(last.end, e.end))
        } else {
            merged.append(e)
        }
    }
    return merged
}

private func clock(_ second: Int64) -> String {
    let h = (second / 3600) % 24
    let m = (second / 60) % 60
    return String(format: "%02d:%02d", h, m)
}

struct TraceChart: View {
    let frames: [Frame]
    let selected: Set<Int>
    let cursor: Int
    let compact: Bool
    var metric: TraceMetric = .stars
    var excluded: Set<String> = []
    var onToggleEvent: ((String) -> Void)?
    let tokens: Tokens

    var body: some View {
        VStack(spacing: 0) {
            Canvas { ctx, size in
                guard !frames.isEmpty else { return }
                let (lo, hi) = span(frames)
                let w = size.width - 24
                let x = { (s: Int64) in 12 + Double(s - lo) / Double(hi - lo) * w }
                let vs = frames.map { metric.value($0) }
                let vmax = vs.max() ?? 1
                let vmin = min(0, vs.min() ?? 0)
                let range = max(vmax - vmin, 1e-9)

                for (start, dur) in gaps(frames) {
                    let r = CGRect(
                        x: x(start), y: 0, width: max(2, x(start + dur) - x(start)),
                        height: size.height)
                    ctx.fill(Path(r), with: .color(tokens.s2))
                    // Scoped to a layer: clip(to:) on the parent context is
                    // cumulative and would clip everything drawn afterwards.
                    ctx.drawLayer { band in
                        band.clip(to: Path(r))
                        var hatch = Path()
                        var p = r.minX - r.height
                        while p < r.maxX {
                            hatch.move(to: CGPoint(x: p, y: r.maxY))
                            hatch.addLine(to: CGPoint(x: p + r.height, y: r.minY))
                            p += 5
                        }
                        band.stroke(hatch, with: .color(tokens.line2), lineWidth: 0.5)
                    }
                }

                for f in frames {
                    let h = (metric.value(f) - vmin) / range * (size.height - 4)
                    let bar = CGRect(x: x(f.second) - 1, y: size.height - h, width: 2, height: h)
                    let on = selected.contains(f.id)
                    ctx.opacity = f.rejected ? 0.25 : (on ? 1.0 : 0.2)
                    ctx.fill(Path(bar), with: .color(tokens.quality(Double(f.quality))))
                }
                ctx.opacity = 1

                ctx.draw(
                    Text(String(format: "%.0f", vmax)).font(Face.mono(9))
                        .foregroundColor(tokens.t4),
                    at: CGPoint(x: size.width - 6, y: 4), anchor: .topTrailing)
                ctx.draw(
                    Text(metric.rawValue).font(Face.mono(9)).foregroundColor(tokens.t4),
                    at: CGPoint(x: size.width - 6, y: size.height - 4), anchor: .bottomTrailing)

                if frames.indices.contains(cursor) {
                    var line = Path()
                    let cx = x(frames[cursor].second)
                    line.move(to: CGPoint(x: cx, y: 0))
                    line.addLine(to: CGPoint(x: cx, y: size.height))
                    ctx.stroke(line, with: .color(tokens.t1), lineWidth: 1)
                }
            }
            .frame(height: compact ? 44 : 190)

            if !compact {
                axis.frame(height: 18)
                annotations.frame(height: 14)
            }
        }
    }

    private var axis: some View {
        GeometryReader { geo in
            let (lo, hi) = span(frames)
            ZStack(alignment: .topLeading) {
                ForEach(0..<5) { i in
                    let f = Double(i) / 4
                    Text(clock(lo + Int64(Double(hi - lo) * f)))
                        .font(Face.mono(10))
                        .foregroundStyle(tokens.t3)
                        .offset(x: 12 + (geo.size.width - 24) * f - (i == 4 ? 28 : 0))
                }
            }
        }
    }

    private var annotations: some View {
        GeometryReader { geo in
            let (lo, hi) = span(frames)
            let w = geo.size.width - 24
            let at = { (s: Int64) in 12 + Double(s - lo) / Double(hi - lo) * w }

            ZStack(alignment: .topLeading) {
                let events = skyEvents(frames)

                // A gap inside an event span is already explained by it; drawing
                // both collides in a 14pt row.
                ForEach(Array(gaps(frames).enumerated()), id: \.offset) { _, g in
                    let inside = events.contains { g.0 >= $0.start - 120 && g.0 <= $0.end }
                    if !inside {
                        Text("\(g.1 / 60) min gap")
                            .font(Face.mono(9))
                            .foregroundStyle(tokens.t4)
                            .fixedSize()
                            .offset(x: max(0, min(w - 46, at(g.0) - 20)))
                    }
                }

                ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                    let width = max(52, at(e.end) - at(e.start))
                    let off = e.label != "" && excluded.contains(e.label)
                    Button { onToggleEvent?(e.label) } label: {
                        Text(e.label)
                            .font(Face.mono(9))
                            .foregroundStyle(off ? tokens.q1 : tokens.t3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: width, height: 12)
                            .background(off ? tokens.s3 : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.swatch)
                                    .stroke(off ? tokens.q1 : tokens.line2, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(off ? "Excluded — click to include" : "Click to exclude these frames")
                    .offset(x: at(e.start))
                }
            }
        }
    }
}

struct MetricsPanels: View {
    let frames: [Frame]
    let selected: Set<Int>
    let tokens: Tokens

    private let heights: [CGFloat] = [58, 42, 36, 36]

    var body: some View {
        VStack(spacing: 6) {
            panel(0, "stars") { Double($0.stars) }
            panel(1, "hfr") { Double($0.hfr) }
            panel(2, "ecc") { Double($0.ecc) }
            panel(3, "sky") { Double($0.background) }
        }
        .padding(.bottom, 32)
    }

    private func panel(
        _ i: Int, _ label: String, _ value: @escaping (Frame) -> Double
    ) -> some View {
        Canvas { ctx, size in
            guard !frames.isEmpty else { return }
            let (lo, hi) = span(frames)
            let w = size.width - 24
            let vs = frames.map(value)
            let vmax = vs.max() ?? 1
            let vmin = vs.min() ?? 0
            let range = max(vmax - vmin, 1e-9)

            ctx.draw(
                Text(label).font(Face.mono(10)).foregroundColor(tokens.t3),
                at: CGPoint(x: 14, y: 6), anchor: .topLeading)

            for f in frames {
                let x = 12 + Double(f.second - lo) / Double(hi - lo) * w
                let h = (value(f) - vmin) / range * (size.height - 10)
                ctx.opacity = f.rejected ? 0.25 : (selected.contains(f.id) ? 1.0 : 0.3)
                ctx.fill(
                    Path(CGRect(x: x - 1, y: size.height - h, width: 2, height: h)),
                    with: .color(tokens.quality(Double(f.quality))))
            }
        }
        .frame(height: heights[i])
        .background(tokens.s1)
    }
}

struct RankChart: View {
    let frames: [Frame]
    let selected: Set<Int>
    let cursor: Int
    let threshold: Float
    let tokens: Tokens

    var body: some View {
        VStack(spacing: 0) {
            Canvas { ctx, size in
                guard !frames.isEmpty else { return }
                let w = size.width - 24
                let step = w / Double(frames.count)
                let maxStars = Double(frames.map(\.stars).max() ?? 1)

                for (i, f) in frames.enumerated() {
                    let h = Double(f.stars) / maxStars * (size.height - 4)
                    let x = 12 + Double(i) * step
                    ctx.opacity = f.rejected ? 0.25 : (selected.contains(f.id) ? 1.0 : 0.3)
                    ctx.fill(
                        Path(CGRect(x: x, y: size.height - h, width: max(1, step - 0.5), height: h)),
                        with: .color(tokens.quality(Double(f.quality))))
                }
                ctx.opacity = 1

                let cut = frames.firstIndex { $0.quality >= threshold } ?? frames.count
                var dash = Path()
                let dx = 12 + Double(cut) * step
                dash.move(to: CGPoint(x: dx, y: 0))
                dash.addLine(to: CGPoint(x: dx, y: size.height))
                ctx.stroke(
                    dash, with: .color(tokens.q2),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .frame(height: 190)

            HStack {
                Text("worst first").font(Face.mono(10)).foregroundStyle(tokens.t3)
                Spacer()
                Text("best").font(Face.mono(10)).foregroundStyle(tokens.t3)
            }
            .padding(.horizontal, 12)
            .frame(height: 18)

            Spacer().frame(height: 14)
        }
    }
}
