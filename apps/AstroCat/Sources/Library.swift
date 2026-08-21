import AppKit
import SwiftUI

enum TraceMetric: String, CaseIterable {
    case stars = "Star count"
    case hfr = "Half-flux radius"
    case ecc = "Eccentricity"
    case sky = "Sky background"

    func value(_ f: Frame) -> Double {
        switch self {
        case .stars: return Double(f.stars)
        case .hfr: return Double(f.hfr)
        case .ecc: return Double(f.ecc)
        case .sky: return Double(f.background)
        }
    }
}

enum SheetFilter: String, CaseIterable {
    case all = "All", selection = "Selection", kept = "Kept", rejected = "Rejected"
}

enum LibraryView: String, CaseIterable {
    case trace = "Trace", metrics = "Metrics", rank = "Rank", grid = "Grid", frame = "Frame"
}

/// How big the contact sheet's cells are.
///
/// Cells follow the frame's own aspect rather than a fixed landscape box: these
/// subs are 2160 x 3840, so a landscape cell showed a centre crop of every one
/// of them, and the corners — where trailing and field rotation show first —
/// were never on screen at all.
enum SheetSize: String, CaseIterable {
    case small = "S", medium = "M", large = "L"

    var width: CGFloat {
        switch self {
        case .small: return 58
        case .medium: return 104
        case .large: return 168
        }
    }

    func height(_ aspect: CGFloat) -> CGFloat {
        // Bounded so an unusual sensor still lays out in rows.
        (width / max(min(aspect, 3), 0.33)).rounded()
    }

    /// Fixed tiers rather than the display size, so `.astrocat/thumbs` holds
    /// three sets and not one per layout the window has ever been.
    var thumb: Int {
        switch self {
        case .small: return 96
        case .medium: return 192
        case .large: return 384
        }
    }

    var showsMetrics: Bool { self != .small }
}

/// Shared so the sub-toolbar and the module resolve the same ordinal range.
/// Faults that weighting cannot repair — a soft or trailed frame stays soft or
/// trailed no matter how little it contributes. Judged against the session's
/// own median, so a poor night is not condemned wholesale.
@MainActor
func defects(_ frames: [Frame]) -> [Int: String] {
    guard frames.count > 10 else { return [:] }

    func median(_ v: [Float]) -> Float {
        let s = v.sorted()
        return s[s.count / 2]
    }
    func mad(_ v: [Float], _ m: Float) -> Float {
        median(v.map { abs($0 - m) }) * 1.4826
    }

    let hfrs = frames.map(\.hfr)
    let eccs = frames.map(\.ecc)
    let skies = frames.map(\.background)
    let stars = frames.map { Float($0.stars) }

    let mh = median(hfrs)
    let me = median(eccs)
    let ms = median(skies)
    let mstar = median(stars)
    let sh = mad(hfrs, mh)
    let se = mad(eccs, me)
    let ss = mad(skies, ms)

    var out: [Int: String] = [:]
    for f in frames {
        if f.hfr > mh + max(4 * sh, mh * 0.25) {
            out[f.id] = "out of focus"
        } else if se > 0, f.ecc > me + 5 * se {
            out[f.id] = "trailed"
        } else if ss > 0, f.background > ms + 6 * ss {
            out[f.id] = "sky flooded"
        } else if Float(f.stars) < mstar * 0.2 {
            out[f.id] = "lost the field"
        } else if f.stars > 0, Float(f.trails) / Float(f.stars) > 0.015 {
            // Streaks as a large share of all detections means the field itself
            // moved; a few among round stars is something crossing it.
            out[f.id] = "trailed — mount moved"
        } else if f.trails >= 4 {
            out[f.id] = "\(f.trails) satellite trails"
        } else if Float(f.stars) < mstar * 0.7 {
            out[f.id] = "lost stars"
        }
    }
    return out
}

struct FrameFilter {
    let name: String
    let matches: (Frame) -> Bool
}

/// Built from what the catalog actually contains, so a project with two filters
/// or three exposures grows the list on its own.
@MainActor
func availableFilters(_ catalog: Catalog) -> [FrameFilter] {
    var out: [FrameFilter] = []
    for e in Set(catalog.current.map { Int($0.exptime.rounded()) }).sorted() {
        out.append(FrameFilter(name: "\(e) s") { Int($0.exptime.rounded()) == e })
    }
    for f in Set(catalog.current.map(\.filter)).sorted() where !f.isEmpty {
        out.append(FrameFilter(name: f) { $0.filter == f })
    }
    if catalog.current.contains(where: \.hasWCS) {
        out.append(FrameFilter(name: "Solved") { $0.hasWCS })
    }
    if catalog.current.contains(where: { !$0.hasWCS }) {
        out.append(FrameFilter(name: "Unsolved") { !$0.hasWCS })
    }
    out.append(FrameFilter(name: "Kept") { !$0.rejected })
    out.append(FrameFilter(name: "Rejected") { $0.rejected })
    return out
}

@MainActor
func visibleFrames(_ catalog: Catalog, _ shell: ShellModel) -> [Frame] {
    var out = catalog.current

    if shell.excludeDefects {
        let bad = defects(catalog.current)
        out = out.filter { bad[$0.id] == nil }
    }

    if !shell.excludedEvents.isEmpty {
        let spans = skyEvents(catalog.current).filter { shell.excludedEvents.contains($0.label) }
        out = out.filter { f in !spans.contains { f.second >= $0.start && f.second <= $0.end } }
    }

    guard !shell.activeFilters.isEmpty else { return out }
    let active = availableFilters(catalog).filter { shell.activeFilters.contains($0.name) }
    return out.filter { f in active.allSatisfy { $0.matches(f) } }
}

@MainActor
func orderedFrames(_ catalog: Catalog, _ view: LibraryView) -> [Frame] {
    view == .rank ? catalog.current.sorted { $0.quality < $1.quality } : catalog.current
}

@MainActor
func orderedVisible(_ catalog: Catalog, _ shell: ShellModel) -> [Frame] {
    let v = visibleFrames(catalog, shell)
    return shell.libraryView == .rank ? v.sorted { $0.quality < $1.quality } : v
}

struct NamedSelection {
    let name: String
    let ids: [Int]
}

/// Derived from catalog metadata, not hardcoded — a project with two filters or
/// three exposures grows the list on its own.
@MainActor
func namedSelections(_ catalog: Catalog) -> [NamedSelection] {
    var out: [NamedSelection] = [
        NamedSelection(
            name: "Kept — all nights",
            ids: catalog.frames.filter { !$0.rejected }.map(\.id))
    ]

    for exp in Set(catalog.frames.map { Int($0.exptime.rounded()) }).sorted() {
        out.append(
            NamedSelection(
                name: "\(exp) s only",
                ids: catalog.frames.filter { Int($0.exptime.rounded()) == exp }.map(\.id)))
    }

    for f in Set(catalog.frames.map(\.filter)).sorted() where !f.isEmpty {
        out.append(
            NamedSelection(
                name: "Filter \(f)",
                ids: catalog.frames.filter { $0.filter == f }.map(\.id)))
    }

    let solved = catalog.frames.filter(\.hasWCS).map(\.id)
    if !solved.isEmpty {
        out.append(NamedSelection(name: "Plate solved", ids: solved))
    }

    out.append(
        NamedSelection(
            name: "Quality ≥ 0.60",
            ids: catalog.frames.filter { $0.quality >= 0.6 }.map(\.id)))
    return out
}

/// One selection across every view. A rank cut wins over the cursor range,
/// because that is what the "cut worst" control is for.
@MainActor
func librarySelection(_ catalog: Catalog, _ shell: ShellModel) -> Set<Int> {
    if let name = shell.namedSelection {
        return Set(namedSelections(catalog).first { $0.name == name }?.ids ?? [])
    }
    if shell.rankSelection > 0 {
        let worst = visibleFrames(catalog, shell).sorted { $0.quality < $1.quality }
            .prefix(shell.rankSelection)
        return Set(worst.map(\.id))
    }
    return selectionIds(
        orderedVisible(catalog, shell), cursor: shell.cursor, anchor: shell.anchor)
}

@MainActor
func selectionIds(_ ordered: [Frame], cursor: Int, anchor: Int?) -> Set<Int> {
    guard !ordered.isEmpty else { return [] }
    guard let a = anchor else {
        return ordered.indices.contains(cursor) ? [ordered[cursor].id] : []
    }
    let lo = max(0, min(a, cursor))
    let hi = min(ordered.count - 1, max(a, cursor))
    return Set(ordered[lo...hi].map(\.id))
}

struct LibraryModule: View {
    @ObservedObject var catalog: Catalog
    @ObservedObject var shell: ShellModel
    @ObservedObject var thumbs: ThumbnailStore
    @Environment(\.tokens) private var t

    /// Held here rather than in the shell: it owns a Metal texture and a 17 MB
    /// decode, and nothing outside the Library addresses it.
    @StateObject private var loupe = FrameLoupe()

    private var cursor: Int { shell.cursor }
    private var ordered: [Frame] { orderedVisible(catalog, shell) }
    private var selection: Set<Int> { librarySelection(catalog, shell) }
    @State private var sheetFilter: SheetFilter = .all
    @State private var sheetSize: SheetSize = .medium

    /// The cell shape, taken from the frames themselves. These are portrait
    /// subs; assuming landscape showed a centre crop of every one.
    private var cellAspect: CGFloat {
        guard let f = catalog.current.first, f.width > 0, f.height > 0 else { return 1.29 }
        return CGFloat(f.width) / CGFloat(f.height)
    }

    private var sheetFrames: [Frame] {
        switch sheetFilter {
        case .all: return ordered
        case .selection: return ordered.filter { selection.contains($0.id) }
        case .kept: return ordered.filter { !$0.rejected }
        case .rejected: return ordered.filter(\.rejected)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 240, alignment: .leading).background(t.s1)
            Divider().overlay(t.line)
            centre
            Divider().overlay(t.line)
            // The constant, not a repeat of its value: the preview sizes itself
            // against the same number and a drift between them would crop it.
            inspector.frame(width: Module.library.inspectorWidth, alignment: .leading)
                .background(t.s1)
        }
        .focusable()
        .onKeyPress { press in handleKey(press) }
        .onAppear { if thumbs.project.isEmpty { thumbs.project = catalog.root } }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:
            shell.rankSelection = 0
            shell.cutWorst = 0
            shell.namedSelection = nil
            if press.modifiers.contains(.shift), shell.anchor == nil { shell.anchor = shell.cursor }
            if !press.modifiers.contains(.shift) { shell.anchor = nil }
            shell.cursor = max(0, shell.cursor - 1)
            return .handled
        case .rightArrow:
            shell.rankSelection = 0
            shell.cutWorst = 0
            shell.namedSelection = nil
            if press.modifiers.contains(.shift), shell.anchor == nil { shell.anchor = shell.cursor }
            if !press.modifiers.contains(.shift) { shell.anchor = nil }
            shell.cursor = min(ordered.count - 1, shell.cursor + 1)
            return .handled
        default: break
        }
        switch press.characters.lowercased() {
        case "a": selection.forEach { catalog.setRejected($0, false) }; return .handled
        case "x": selection.forEach { catalog.setRejected($0, true) }; return .handled
        case "1": shell.libraryView = .trace; return .handled
        case "2": shell.libraryView = .metrics; return .handled
        case "3": shell.libraryView = .rank; return .handled
        case "4": shell.libraryView = .grid; return .handled
        case "5": shell.libraryView = .frame; return .handled
        default: return .ignored
        }
    }

    @ViewBuilder private var centre: some View {
        if shell.libraryView == .frame {
            VStack(spacing: 0) {
                traceHeader
                Divider().overlay(t.line)
                LoupePane(
                    loupe: loupe, catalog: catalog, shell: shell, thumbs: thumbs,
                    frames: ordered, selection: selection, aspect: cellAspect, tokens: t)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                traceHeader
                chart
                    .frame(height: shell.libraryView == .grid ? 44 : 222)
                    .background(t.s0)
                Divider().overlay(t.line)
                sheetHeader
                contactSheet
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(t.well)
        }
    }

    @ViewBuilder private var chart: some View {
        switch shell.libraryView {
        case .frame:
            EmptyView()
        case .trace, .grid:
            TraceChart(
                frames: catalog.current, selected: selection, cursor: cursor,
                compact: shell.libraryView == .grid, metric: shell.metric,
                excluded: shell.excludedEvents,
                onToggleEvent: { label in
                    if shell.excludedEvents.contains(label) {
                        shell.excludedEvents.remove(label)
                    } else {
                        shell.excludedEvents.insert(label)
                    }
                    shell.cursor = 0
                    shell.anchor = nil
                },
                tokens: t)
        case .metrics:
            MetricsPanels(frames: ordered, selected: selection, tokens: t)
        case .rank:
            RankChart(
                frames: ordered, selected: selection, cursor: cursor,
                threshold: shell.threshold, tokens: t)
        }
    }

    private var traceHeader: some View {
        let f = ordered
        let lo = f.map(\.second).min() ?? 0
        let hi = f.map(\.second).max() ?? 0
        let mins = (hi - lo) / 60
        return HStack {
            Text(
                "Night of \(catalog.sessions.indices.contains(catalog.sessionIndex) ? catalog.sessions[catalog.sessionIndex].night : "—") · \(hhmm(lo)) → \(hhmm(hi)) · \(mins / 60) h \(mins % 60) m · \(f.count) frames"
            )
            .font(Face.secondary).foregroundStyle(t.t2)
            Spacer()
            if let name = shell.namedSelection {
                Text("\(name) · \(selection.count) selected")
                    .font(Face.secondary).foregroundStyle(t.t2)
            } else if shell.rankSelection > 0 {
                Text("ranks 1–\(shell.rankSelection) · \(shell.rankSelection) selected, worst first")
                    .font(Face.secondary).foregroundStyle(t.t2)
            } else {
                Text("\(selection.count) selected")
                    .font(Face.secondary).foregroundStyle(t.t2)
            }
            if !shell.activeFilters.isEmpty {
                Text("filtered from \(catalog.current.count)")
                    .font(Face.secondary).foregroundStyle(t.q3)
            }
            Text("\(catalog.rejectedCount) rejected · \(catalog.keptCount) kept")
                .font(Face.secondary).foregroundStyle(t.t3)
        }
        .padding(.horizontal, Metric.panelPad)
        .frame(height: 22)
    }

    private func hhmm(_ s: Int64) -> String {
        String(format: "%02d:%02d", (s / 3600) % 24, (s / 60) % 60)
    }

    private var sheetHeader: some View {
        HStack(spacing: Space.md) {
            Text("CONTACT SHEET").font(Face.sectionHeader)
                .tracking(Face.sectionTracking).foregroundStyle(t.t3)
            Segmented(
                items: ["All \(ordered.count)", "Selection", "Kept", "Rejected"],
                index: Binding(
                    get: { SheetFilter.allCases.firstIndex(of: sheetFilter) ?? 0 },
                    set: { sheetFilter = SheetFilter.allCases[$0] }))
            Spacer()
            Text("Colour = quality rank within this session")
                .font(Face.secondary).foregroundStyle(t.t3)
            HStack(spacing: 0) {
                ForEach([t.q1, t.q2, t.q3, t.q4, t.q5], id: \.self) { c in
                    Rectangle().fill(c).frame(width: 14, height: 6)
                }
            }
            Text("worst → best").font(Face.mono(10)).foregroundStyle(t.t3)
            Segmented(
                items: SheetSize.allCases.map(\.rawValue),
                index: Binding(
                    get: { SheetSize.allCases.firstIndex(of: sheetSize) ?? 0 },
                    set: { sheetSize = SheetSize.allCases[$0] }),
                padding: Space.sm)
        }
        .padding(.horizontal, Metric.panelPad)
        .frame(height: 24)
        .background(t.s1)
    }

    private var contactSheet: some View {
        ScrollView {
            // Adaptive rather than a fixed column count: the 21 columns that
            // filled the pane at 62 px leave three quarters of it empty at 168.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: sheetSize.width), spacing: Metric.frameGap)],
                spacing: Metric.frameGap
            ) {
                ForEach(Array(sheetFrames.enumerated()), id: \.element.id) { i, f in
                    FrameCell(
                        frame: f, index: i + 1, selected: selection.contains(f.id),
                        size: sheetSize, aspect: cellAspect, thumbs: thumbs, tokens: t
                    )
                    // Without an explicit shape only the opaque parts of the
                    // cell take a tap, so clicks land unreliably.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        // Straight to the frame at full resolution. Judging a
                        // sub from a thumbnail is what that view is there to
                        // stop.
                        shell.cursor = ordered.firstIndex { $0.id == f.id } ?? i
                        shell.anchor = nil
                        shell.libraryView = .frame
                    }
                    .onTapGesture {
                        // Touching a frame hands control back to the cursor;
                        // a rank cut would otherwise swallow every selection.
                        shell.rankSelection = 0
                        shell.cutWorst = 0
                        shell.namedSelection = nil
                        if NSEvent.modifierFlags.contains(.shift) {
                            if shell.anchor == nil { shell.anchor = shell.cursor }
                        } else {
                            shell.anchor = nil
                        }
                        shell.cursor = ordered.firstIndex { $0.id == f.id } ?? i
                    }
                }
            }
            .padding(Metric.panelPad)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Sessions")
            ForEach(catalog.sessions) { s in
                Button {
                    catalog.sessionIndex = s.id
                    shell.cursor = 0
                    shell.anchor = nil
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.night).font(Face.body)
                                .foregroundStyle(s.id == catalog.sessionIndex ? t.selT : t.t1)
                            Text(spec(s)).font(Face.mono(10)).foregroundStyle(t.t3)
                        }
                        Spacer()
                        Text("\(s.count)").font(Face.mono(11)).foregroundStyle(t.t2)
                    }
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                    .background(s.id == catalog.sessionIndex ? t.sel : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                }
                .buttonStyle(.plain)
            }

            sectionHeader("Filters").padding(.top, Space.xl)
            let cols = [GridItem(.adaptive(minimum: 62), spacing: Space.xs)]
            LazyVGrid(columns: cols, alignment: .leading, spacing: Space.xs) {
                ForEach(availableFilters(catalog), id: \.name) { f in
                    let on = shell.activeFilters.contains(f.name)
                    let n = catalog.current.filter(f.matches).count
                    Button {
                        if on { shell.activeFilters.remove(f.name) }
                        else { shell.activeFilters.insert(f.name) }
                        shell.cursor = 0
                        shell.anchor = nil
                        shell.rankSelection = 0
                        shell.cutWorst = 0
                    } label: {
                        HStack(spacing: 3) {
                            Text(f.name).font(Face.secondary)
                                .foregroundStyle(on ? t.selT : t.t2)
                            Text("\(n)").font(Face.mono(9))
                                .foregroundStyle(on ? t.selT : t.t4)
                        }
                        .padding(.horizontal, Space.sm)
                        .frame(height: 18)
                        .background(on ? t.sel : t.s2)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control)
                                .stroke(on ? t.selLine : t.line2, lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                    }
                    .buttonStyle(.plain)
                }
            }
            let bad = defects(catalog.current).count
            Toggle(isOn: $shell.excludeDefects) {
                HStack(spacing: Space.xs) {
                    Text("Hide faulty frames").font(Face.secondary)
                        .foregroundStyle(shell.excludeDefects ? t.t1 : t.t2)
                    Text("\(bad)").font(Face.mono(9))
                        .foregroundStyle(bad > 0 ? t.q2 : t.t4)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.top, Space.sm)
            .help("Hides them from view only — use Reject faulty to keep them out of a stack")

            if bad > 0 {
                Button("Reject faulty (\(bad))") {
                    // Hiding is a view state; Stack consumes kept/rejected, so
                    // the exclusion has to be committed to carry across.
                    for (id, _) in defects(catalog.current) {
                        catalog.setRejected(id, true)
                    }
                }
                .buttonStyle(.plain)
                .font(Face.secondary)
                .foregroundStyle(t.q2)
                .padding(.horizontal, Space.sm)
                .frame(height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .stroke(t.q2.opacity(0.5), lineWidth: 0.5))
                .padding(.top, Space.xs)
            }

            if catalog.rejectedCount > 0 {
                Button("Clear \(catalog.rejectedCount) rejections") {
                    // Works on the whole session, not the selection: a rejected
                    // frame may be hidden, and then nothing could reach it.
                    for f in catalog.current where f.rejected {
                        catalog.setRejected(f.id, false)
                    }
                }
                .buttonStyle(.plain)
                .font(Face.secondary)
                .foregroundStyle(t.t2)
                .padding(.horizontal, Space.sm)
                .frame(height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .stroke(t.line2, lineWidth: 0.5))
                .padding(.top, Space.xs)
            }

            if !shell.activeFilters.isEmpty {
                Button("Clear filters") { shell.activeFilters = [] }
                    .buttonStyle(.plain).font(Face.secondary).foregroundStyle(t.t3)
                    .padding(.top, Space.xs)
            }

            sectionHeader("Saved selections").padding(.top, Space.xl)
            ForEach(namedSelections(catalog), id: \.name) { sel in
                let on = shell.namedSelection == sel.name
                Button {
                    shell.rankSelection = 0
                    shell.cutWorst = 0
                    shell.anchor = nil
                    shell.namedSelection = on ? nil : sel.name
                } label: {
                    HStack {
                        Text(sel.name).font(Face.body)
                            .foregroundStyle(on ? t.selT : t.t2)
                        Spacer()
                        Text("\(sel.ids.count)").font(Face.mono(11))
                            .foregroundStyle(on ? t.selT : t.t3)
                    }
                    .padding(.horizontal, Space.sm)
                    .frame(height: 22)
                    .background(on ? t.sel : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                }
                .buttonStyle(.plain)
            }

            sectionHeader("Masters").padding(.top, Space.xl)
            ForEach(masters, id: \.self) { m in
                Text(m).font(Face.body).foregroundStyle(t.t3)
                    .padding(.horizontal, Space.sm)
                    .frame(height: 22)
            }

            if let e = catalog.error {
                Text(e).font(Face.secondary).foregroundStyle(t.q2).padding(.top, Space.lg)
            }
            Spacer()
        }
        .padding(Metric.panelPad)
    }

    private func spec(_ s: SessionInfo) -> String {
        String(format: "LP · %.0f s · %@→%@", s.exptime, clockOf(s.start), clockOf(s.end))
    }

    private func clockOf(_ sec: Int64) -> String {
        String(format: "%02d:%02d", (sec / 3600) % 24, (sec / 60) % 60)
    }

    private var masters: [String] {
        var out: [String] = []
        if !catalog.frames.isEmpty {
            out.append("Seestar on-device")
        }
        return out
    }

    /// With a range selected there is no single cursor frame worth showing, so
    /// the best of the set stands in for it.
    private var previewFrame: Frame? {
        let sel = selection
        if sel.count > 1 {
            return catalog.current.filter { sel.contains($0.id) }
                .max { $0.quality < $1.quality }
        }
        return ordered.indices.contains(cursor) ? ordered[cursor] : nil
    }

    private var inspector: some View {
        let f = previewFrame

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let f {
                    HStack {
                        Text("FRAME \((ordered.firstIndex { $0.id == f.id } ?? 0) + 1)")
                            .font(Face.sectionHeader).tracking(Face.sectionTracking)
                            .foregroundStyle(t.t3)
                        Spacer()
                        Text(hhmm(f.second)).font(Face.mono(11)).foregroundStyle(t.t3)
                    }
                    .padding(.bottom, Space.sm)
                }

                preview(f)

                if let f {
                    sectionHeader("Measured").padding(.top, Space.xl)
                    value("Star count", "\(f.stars)", color: t.quality(Double(f.quality)))
                    value("HFR", String(format: "%.2f", f.hfr))
                    value("Eccentricity", String(format: "%.3f", f.ecc))
                    value("Sky background", String(format: "%.5f", f.background))
                    value("Noise σ", String(format: "%.3e", f.noise))
                    value(
                        "Trails", f.trails == 0 ? "none" : "\(f.trails)",
                        color: f.trails >= 4 ? t.q2 : t.t1)
                    value("Quality", String(format: "%.5f", f.quality))

                    sectionHeader("Frame").padding(.top, Space.xl)
                    value("Object", f.object)
                    value("Date-obs", String(f.date.prefix(19)))
                    value("Exposure", String(format: "%.0f s", f.exptime))
                    value("Gain", String(format: "%.0f", f.gain))
                    value("Sensor", String(format: "%.2f °C", f.ccdTemp))
                    value("Index", "\(cursor + 1) of \(ordered.count)")
                    value("Status", f.rejected ? "Rejected" : "Kept",
                          color: f.rejected ? t.q1 : t.t1)
                    if let d = defects(catalog.current)[f.id] {
                        value("Fault", d, color: t.q2)
                    }

                    sectionHeader("Optics").padding(.top, Space.xl)
                    value("Telescope", f.telescope)
                    value("Filter", f.filter)
                    value("Focal length", String(format: "%.0f mm", f.focalLen))
                    value("Pixel size", String(format: "%.2f µm", f.pixelSize))
                    value("Scale", String(format: "%.2f ″/px", f.scale))
                    value(
                        "Field",
                        String(
                            format: "%.2f° × %.2f°",
                            Float(f.width) * f.scale / 3600,
                            Float(f.height) * f.scale / 3600))

                    sectionHeader("Pointing").padding(.top, Space.xl)
                    value("RA", String(format: "%.4f°", f.ra))
                    value("Dec", String(format: "%.4f°", f.dec))
                    value(
                        "Plate solution", f.hasWCS ? "WCS present" : "none — mount pointing",
                        color: f.hasWCS ? t.q5 : t.q3)
                }
                Spacer()
            }
            .padding(Metric.panelPad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The selected frame, whole, at its own shape and as large as the pane
    /// allows — this is the picture, not a decoration on a list of numbers, and
    /// it is what tells you a sub is wrong before any of the numbers do.
    ///
    /// Sized from the frame itself: a fixed landscape box cropped these
    /// portrait subs to their middle tenth.
    @ViewBuilder private func preview(_ f: Frame?) -> some View {
        let available = Module.library.inspectorWidth - Metric.panelPad * 2
        let aspect = f.map { $0.width > 0 && $0.height > 0
            ? CGFloat($0.width) / CGFloat($0.height) : cellAspect } ?? cellAspect
        // Capped so the measurements below stay within a short scroll.
        let height = min(available / aspect, 460)
        let width = height * aspect

        ZStack(alignment: .bottomLeading) {
            Thumbnail(
                path: f?.path ?? "", size: 480, mode: .fit, store: thumbs, placeholder: t.img)
                .frame(width: width, height: height)

            if selection.count > 1 {
                Text("best of \(selection.count) selected")
                    .font(Face.mono(9)).foregroundStyle(t.t2)
                    .padding(4)
                    .background(t.well.opacity(0.75))
            }
            if let f, f.rejected {
                Text("REJECTED").font(Face.mono(9, .medium))
                    .foregroundStyle(t.selT)
                    .padding(.horizontal, 4).frame(height: 14)
                    .background(t.q1.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: width, height: height)
        .background(t.img)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel)
                .stroke(f?.rejected == true ? t.q1 : t.line, lineWidth: 0.5))
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // The thumbnail is still a thumbnail — half-res and box-filtered down,
        // so a 1–2 px star is a smudge in it. Clicking goes to the frame at its
        // own resolution, which is the only place focus can actually be judged.
        .onTapGesture { if f != nil { shell.libraryView = .frame } }
        .help("Open at full resolution")
    }

    private func sectionHeader(_ s: String) -> some View {
        Text(s.uppercased())
            .font(Face.sectionHeader)
            .tracking(Face.sectionTracking)
            .foregroundStyle(t.t3)
            .padding(.bottom, Space.sm)
    }

    private func value(_ k: String, _ v: String, color: Color? = nil) -> some View {
        HStack {
            Text(k).font(Face.body).foregroundStyle(t.t3)
            Spacer()
            Text(v).font(Face.mono(11)).foregroundStyle(color ?? t.t1)
        }
        .frame(height: 20)
    }
}

struct FrameCell: View {
    let frame: Frame
    var index = 0
    let selected: Bool
    var size: SheetSize = .small
    var aspect: CGFloat = 1.29
    @ObservedObject var thumbs: ThumbnailStore
    let tokens: Tokens

    var body: some View {
        let q = tokens.quality(Double(frame.quality))
        ZStack(alignment: .topLeading) {
            Thumbnail(path: frame.path, size: size.thumb, store: thumbs, placeholder: tokens.s2)

            // Scrim so the values stay legible over whatever the sky is doing.
            LinearGradient(
                colors: [tokens.well.opacity(0.15), tokens.well.opacity(0.8)],
                startPoint: .top, endPoint: .bottom)

            Text("\(index)")
                .font(Face.mono(8))
                .foregroundStyle(tokens.t3)
                .padding(.leading, 3)
                .padding(.top, 2)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if size.showsMetrics {
                    Text("\(frame.stars)")
                        .font(Face.mono(11, .medium))
                        .foregroundStyle(frame.rejected ? tokens.t3 : q)
                    Text(String(format: "%.2f", frame.hfr))
                        .font(Face.mono(9))
                        .foregroundStyle(tokens.t2)
                }
                Rectangle().fill(q).frame(height: 2)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: size.width, height: size.height(aspect))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.swatch)
                .stroke(selected ? tokens.selLine : tokens.line, lineWidth: selected ? 1 : 0.5))
        .overlay(alignment: .topTrailing) {
            if frame.rejected {
                Text("×").font(Face.mono(11)).foregroundStyle(tokens.q1).padding(2)
            }
        }
        .opacity(frame.rejected ? 0.42 : 1)
        .clipShape(RoundedRectangle(cornerRadius: Radius.swatch))
    }
}
