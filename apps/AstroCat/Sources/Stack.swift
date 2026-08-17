import AppKit
import SwiftUI

enum RejectionAlgorithm: Int {
    case none = 0, sigmaClip = 1, winsorised = 2
}

enum ExportTarget: String, CaseIterable {
    case siril = "Siril"
    case pixinsight = "PixInsight"
    case lightroom = "Photoshop / Lightroom"

    var settings: String {
        switch self {
        case .siril: return "32-bit float FITS, linear, gradient left in"
        case .pixinsight: return "32-bit float FITS, linear, no normalisation"
        case .lightroom: return "16-bit TIFF, stretched, sRGB"
        }
    }

    var format: String { self == .lightroom ? "TIFF, 16-bit" : "FITS, BITPIX −32" }

    var rowOrder: String { self == .siril ? "bottom-up" : "top-down" }

    var data: String {
        self == .lightroom ? "stretch baked in, sRGB" : "linear, stretch not applied"
    }

    /// An AstroCat master carries no BIAS card — the pedestal is subtracted
    /// during stacking, and writing the card would invite a reader to subtract
    /// it a second time. The flag only bites when exporting a frame that came
    /// with one of its own.
    var pedestal: String {
        self == .siril ? "kept if the source has one" : "removed"
    }

    var reason: String {
        switch self {
        case .siril: return "Siril runs its own background extraction; leaving ours in fights it."
        case .pixinsight: return "PixInsight normalises during integration and prefers raw linear input."
        case .lightroom: return "Neither reads FITS or linear data, so the stretch has to be baked in."
        }
    }
}

@MainActor
final class StackModel: ObservableObject {
    @Published var sigmaLow: Float = 3
    @Published var sigmaHigh: Float = 3
    @Published var removeGradient = true
    @Published var keptOnly = true
    @Published var sixtyOnly = false
    @Published var sessionsUsed: Set<Int> = []
    @Published var target: ExportTarget = .siril
    @Published var job = AcJob()
    @Published var message = ""
    @Published var subNoise: Float = 0
    @Published var seestarNoise: Float = 0
    @Published var seestarFrames = 0
    @Published var seestarStars = 0
    @Published var subStars = 0
    @Published var worstCut: Float = 0
    @Published var rejection: RejectionAlgorithm = .sigmaClip
    @Published var viewMode = 0
    var filename: String { "NGC7000_\(job.frames_used)x60s_LP.fit" }
    @Published var passes = 1
    @Published var fullResolution = true
    @Published var overrideStrategy = false
    @Published var choice: StrategyChoice = .full
    @Published var drizzle = false
    @Published var referenceName = "auto (most stars)"

    @Published var subExptime: Float = 60
    @Published var outputPath = ""
    /// Where masters are written. Empty means the project is not open yet, and
    /// stacking falls back to a temp file rather than refusing.
    @Published var projectRoot = ""
    @Published var exportError: String?

    private var timer: Timer?
    private var seeded = false

    let beforeRenderer = Renderer()
    let afterRenderer = Renderer()
    private var beforeFrame: LoadedFrame?
    private var afterFrame: LoadedFrame?
    @Published var beforeStretch = StretchPair()
    @Published var afterStretch = StretchPair()
    @Published var hasBefore = false
    @Published var hasAfter = false

    private func load(_ path: String, into renderer: Renderer) -> (LoadedFrame, StretchPair)? {
        guard let f = try? LoadedFrame(url: URL(fileURLWithPath: path)) else { return nil }
        renderer.upload(f)
        return (f, StretchPair(shadows: f.meta.shadows, midtone: f.meta.midtone))
    }

    func loadBefore(_ path: String) {
        guard let (f, s) = load(path, into: beforeRenderer) else { return }
        beforeFrame = f
        beforeStretch = s
        hasBefore = true
    }

    func loadResult() {
        guard !outputPath.isEmpty, let (f, s) = load(outputPath, into: afterRenderer) else { return }
        afterFrame = f
        afterStretch = s
        hasAfter = true
    }

    /// Seeds the selection once, then leaves it under the user's control.
    func syncSessions(_ catalog: Catalog) {
        let known = Set(catalog.sessions.map(\.id))
        if sessionsUsed.isEmpty && !seeded {
            sessionsUsed = known
            seeded = true
        } else {
            sessionsUsed.formIntersection(known)
        }
    }

    /// A stack costs minutes, so it lands in the project under a name that says
    /// what it is. Only an unopened project falls back to a temp file.
    private func destination(for frames: [Frame]) -> String {
        guard !projectRoot.isEmpty else {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("astrocat-stack.fit").path
        }
        // From the frames going in, not from the exposure picker — those can
        // disagree, and a name that misreports the integration is worse than no
        // name at all.
        var exposures = frames.map(\.exptime).sorted()
        let name = Masters.name(
            object: frames.first?.object ?? "",
            frames: frames.count,
            exposure: exposures.isEmpty ? subExptime : exposures[exposures.count / 2],
            filter: frames.first?.filter ?? "",
            night: String((frames.first?.date ?? "").prefix(10)))
        exposures.removeAll()
        return Masters.ensure(projectRoot).appendingPathComponent(name).path
    }

    func inputs(_ catalog: Catalog) -> [Frame] {
        catalog.frames.filter { f in
            guard sessionsUsed.contains(f.session) else { return false }
            if keptOnly && f.rejected { return false }
            if sixtyOnly && abs(f.exptime - 60) > 0.5 { return false }
            return true
        }
    }

    func start(_ frames: [Frame]) {
        guard !frames.isEmpty else { return }
        // The measurement decides unless the user has taken the wheel.
        if overrideStrategy {
            fullResolution = choice != .binned
            drizzle = choice == .drizzle
        } else if let s = Strategist.recommend(
            frames: frames, measuredDrift: job.state == 2 ? job.drift_px : nil)
        {
            fullResolution = s.fullResolution
            drizzle = s.drizzle > 0
        }
        let out = destination(for: frames)
        outputPath = out

        let list = frames.map(\.path).joined(separator: "\n")
        let ok = list.withCString { l in
            out.withCString { o in
                ac_stack_start(
                    l, o, sigmaLow, sigmaHigh, removeGradient ? 1 : 0,
                    fullResolution ? 1 : 0, drizzle ? 2 : 0)
            }
        }
        guard ok == 1 else { return }

        hasAfter = false
        if let first = frames.first {
            subNoise = first.path.withCString { ac_measure_noise($0) }
            subStars = Int(first.path.withCString { ac_measure_stars($0) })
            referenceName = "auto (most stars)"
            loadBefore(first.path)
        }
        poll()
    }

    func cancel() {
        ac_job_cancel()
    }

    private func poll() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] tm in
            Task { @MainActor in
                guard let self else { return }
                var j = AcJob()
                _ = ac_job(&j)
                self.job = j
                self.message = String(cString: ac_job_message())
                if j.state != 1 {
                    tm.invalidate()
                    if j.state == 2 { self.loadResult() }
                }
            }
        }
    }

    func measureSeestar(_ catalog: Catalog) {
        guard let dir = catalog.frames.first?.path else { return }
        let folder = (dir as NSString).deletingLastPathComponent
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        guard let master = candidates.first(where: { $0.hasPrefix("Stacked_") }) else { return }
        let path = folder + "/" + master
        seestarNoise = path.withCString { ac_measure_noise($0) }
        seestarStars = Int(path.withCString { ac_measure_stars($0) })
        // STACKCNT from the master's own header rather than a hardcoded count.
        if let hdr = path.withCString({ ac_header_text($0) }) {
            for line in String(cString: hdr).split(separator: "\n")
            where line.hasPrefix("STACKCNT") {
                seestarFrames =
                    Int(line.split(separator: "=")[1]
                        .split(separator: "/")[0]
                        .trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        subExptime = catalog.frames.first?.exptime ?? 60
    }
}

struct StackModule: View {
    @ObservedObject var model: StackModel
    @ObservedObject var catalog: Catalog
    @Environment(\.tokens) private var t

    private var frames: [Frame] { model.inputs(catalog) }

    private var allOn: Bool {
        !catalog.sessions.isEmpty
            && model.sessionsUsed.count == catalog.sessions.count
    }

    /// How many frames this night actually contributes under the live filters.
    private func usedCount(_ s: SessionInfo) -> Int {
        catalog.frames[s.first..<(s.first + s.count)].filter { f in
            if model.keptOnly && f.rejected { return false }
            if model.sixtyOnly && abs(f.exptime - 60) > 0.5 { return false }
            if f.quality < model.worstCut { return false }
            return true
        }.count
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 300, alignment: .leading).background(t.s1)
            Divider().overlay(t.line)
            centre
            Divider().overlay(t.line)
            inspector.frame(width: 316, alignment: .leading).background(t.s1)
        }
        .onAppear {
            model.projectRoot = catalog.root
            model.syncSessions(catalog)
            model.measureSeestar(catalog)
        }
        .onChange(of: catalog.root) { _, root in model.projectRoot = root }
        .onChange(of: catalog.sessions.count) { _, _ in model.syncSessions(catalog) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            nightsSection
            filtersSection
            referenceSection
            integrationSection
            Spacer()
        }
        .padding(Metric.panelPad)
    }

    private var nightsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                header("Nights")
                Spacer()
                Button(allOn ? "None" : "All") {
                    model.sessionsUsed = allOn ? [] : Set(catalog.sessions.map(\.id))
                }
                .buttonStyle(.plain)
                .font(Face.secondary)
                .foregroundStyle(t.t2)
            }

            ForEach(catalog.sessions) { s in
                let on = model.sessionsUsed.contains(s.id)
                let used = usedCount(s)
                Toggle(isOn: Binding(
                    get: { on },
                    set: { v in
                        if v { model.sessionsUsed.insert(s.id) }
                        else { model.sessionsUsed.remove(s.id) }
                    })
                ) {
                    HStack(spacing: Space.sm) {
                        Text(s.night)
                            .font(Face.body)
                            .foregroundStyle(on ? t.t1 : t.t3)
                        Spacer()
                        Text("\(used) of \(s.count)")
                            .font(Face.mono(11))
                            .foregroundStyle(on ? t.t2 : t.t4)
                        Text(String(format: "%.0fs", s.exptime))
                            .font(Face.mono(10))
                            .foregroundStyle(t.t4)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
                .toggleStyle(.checkbox)
                .frame(height: Metric.rowHeight)
            }

            Text(model.sessionsUsed.isEmpty
                ? "No nights selected — nothing will stack."
                : "\(model.sessionsUsed.count) of \(catalog.sessions.count) nights")
                .font(Face.secondary)
                .foregroundStyle(model.sessionsUsed.isEmpty ? t.q2 : t.t3)
                .padding(.top, Space.sm)
        }
    }

    private var filtersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Filters").padding(.top, Space.xl)
            HStack(spacing: Space.sm) {
                chip("Kept only", $model.keptOnly)
                chip("60 s only", $model.sixtyOnly)
            }
            HStack(spacing: Space.sm) {
                Text("Worst").font(Face.secondary).foregroundStyle(t.t3)
                Slider(value: $model.worstCut, in: 0...0.5).controlSize(.small)
                Text(String(format: "%.0f%% cut", model.worstCut * 100))
                    .font(Face.mono(11)).foregroundStyle(t.t2).frame(width: 60)
            }
            .padding(.top, Space.xs)
        }
    }

    private var referenceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Reference frame").padding(.top, Space.xl)
            Text(model.referenceName).font(Face.mono(11)).foregroundStyle(t.t2)
        }
    }

    private var integrationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Integration").padding(.top, Space.xl)
            let secs = frames.reduce(0.0) { $0 + Double($1.exptime) }
            Text(String(format: "%.1f h", secs / 3600))
                .font(Face.document).tracking(Face.documentTracking)
                .foregroundStyle(t.t1)
            Text("\(frames.count) frames selected")
                .font(Face.secondary).foregroundStyle(t.t3)
        }
    }

    private var centre: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                Segmented(
                    items: ["A / B split", "Result only", "vs previous stack"],
                    index: $model.viewMode)
                Spacer()
                Text("Identical stretch on both sides · sky levels matched")
                    .font(Face.secondary).foregroundStyle(t.t3)
            }
            .padding(.horizontal, Metric.panelPad)
            .frame(height: 26)
            .background(t.s1)

            ABSplit(model: model, tokens: t)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(t.line)
            comparison
        }
        .background(t.well)
    }

    private var comparison: some View {
        let ours = model.job.state == 2 ? model.job.noise : 0
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                cmpHead("Measured on identical tiles")
                cmpHead("This stack")
                cmpHead("Single sub")
                cmpHead("Seestar stack")
            }
            .frame(height: 20)
            cmpRow("Noise σ (10th pct tile MAD)", ours, model.subNoise, model.seestarNoise, exp: true)
            cmpRow(
                "Improvement vs single sub",
                ours > 0 ? model.subNoise / ours : 0, 1,
                model.seestarNoise > 0 ? model.subNoise / model.seestarNoise : 0, suffix: "×")
            cmpRow("Gradient peak-to-peak", model.job.gradient, 0, 0, exp: true)
            cmpIntRow("Star count", Int(model.job.stars), model.subStars, model.seestarStars)
            cmpRow(
                "Integration",
                Float(model.job.frames_used) * model.subExptime / 3600,
                model.subExptime / 3600,
                Float(model.seestarFrames) * model.subExptime / 3600, suffix: " h")
            cmpIntRow("Frames", Int(model.job.frames_used), 1, model.seestarFrames)

            Text("10th percentile of per-tile MAD, 32 × 32 tiles, identical normalised units. Absolute efficiency is not comparable across resamplers; the relative column is.")
                .font(Face.secondary).foregroundStyle(t.t4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Space.sm)
        }
        .padding(Metric.panelPad)
        .background(t.s0)
    }

    private func cmpHead(_ s: String) -> some View {
        Text(s.uppercased()).font(Face.sectionHeader).tracking(Face.sectionTracking)
            .foregroundStyle(t.t3)
            .frame(maxWidth: .infinity, alignment: s.isEmpty ? .leading : .trailing)
    }

    private func cmpIntRow(_ label: String, _ a: Int, _ b: Int, _ c: Int) -> some View {
        HStack(spacing: 0) {
            Text(label).font(Face.body).foregroundStyle(t.t2)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach([a, b, c].indices, id: \.self) { i in
                let v = [a, b, c][i]
                Text(v == 0 ? "—" : "\(v)")
                    .font(Face.mono(11))
                    .foregroundStyle(i == 2 ? (v > 0 ? t.q5 : t.t4) : t.t2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: 20)
    }

    private func cmpRow(
        _ label: String, _ a: Float, _ b: Float, _ c: Float,
        exp: Bool = false, suffix: String = ""
    ) -> some View {
        let fmt = { (v: Float) -> String in
            v == 0
                ? "—"
                : (exp ? String(format: "%.3e", v) : String(format: "%.2f", v) + suffix)
        }
        return HStack(spacing: 0) {
            Text(label).font(Face.body).foregroundStyle(t.t2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(fmt(a)).font(Face.mono(11)).foregroundStyle(t.t3)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(fmt(b)).font(Face.mono(11)).foregroundStyle(t.t2)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(fmt(c)).font(Face.mono(11)).foregroundStyle(c > 0 ? t.q5 : t.t4)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 20)
    }

    private var jobCard: some View {
        let j = model.job
        let border: Color =
            j.state == 3 ? t.q3 : (j.state == 4 ? t.q1 : t.line2)
        let title =
            ["Ready to stack", "Stacking", "Done", "Cancelled", "Failed during registration"][
                Int(j.state)]

        return VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).font(Face.title)
                .foregroundStyle(j.state == 4 ? t.q1 : t.t1)

            if j.state == 0 {
                Text("\(frames.count) frames · \(integrationLabel) integration · estimated \(estimate)")
                    .font(Face.secondary).foregroundStyle(t.t3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.message.isEmpty {
                Text(model.message).font(Face.secondary).foregroundStyle(t.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            stageRow("Analyse", "\(frames.count) frames", 0, j, j.analyse_s)
            stageRow("Register", "star-based, rotation", 1, j, j.register_s)
            stageRow(
                "Stack",
                j.state == 2
                    ? String(format: "%.2f%% of samples clipped", j.clipped_pct)
                    : "σ-clip \(String(format: "%.1f", model.sigmaLow)) / \(String(format: "%.1f", model.sigmaHigh))",
                2, j, j.combine_s)

            if j.state == 1 {
                action("Cancel") { model.cancel() }
            } else {
                action("Run stack", primary: true) { model.start(frames) }
                    .frame(maxWidth: .infinity)
            }

            note(
                j.state == 4
                    ? "Cancelling discards the partial result and keeps the cached analysis."
                    : "Nothing is written until the last stage finishes. Cancelling discards the partial result and keeps the cached analysis.")
        }
        .padding(Metric.panelPad)
        .background(t.s2)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel)
                .stroke(border, lineWidth: j.state >= 3 ? 1 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
    }

    /// Read from the catalog for the frames actually selected, rather than
    /// asserted — a project whose subs are solved should say so.
    private var solved: Int { frames.filter(\.hasWCS).count }

    /// What the next run will actually do — the recommendation unless the user
    /// has overridden it. Showing the last run's settings would be a lie.
    private var planned: (drizzle: Int, fullResolution: Bool) {
        if model.overrideStrategy {
            return (model.choice == .drizzle ? 2 : 0, model.choice != .binned)
        }
        guard
            let s = Strategist.recommend(
                frames: frames,
                measuredDrift: model.job.state == 2 ? model.job.drift_px : nil)
        else {
            return (0, model.fullResolution)
        }
        return (s.drizzle, s.fullResolution)
    }

    private var scaleLabel: String {
        guard let s = frames.first?.scale, s > 0 else { return "unknown" }
        return String(format: "%.2f ″/px", s)
    }

    private var registrationNote: String {
        guard !frames.isEmpty else { return "Select at least one night to stack." }
        if solved == frames.count {
            return "Every selected frame carries a plate solution, so alignment can use the WCS directly."
        }
        let scale = frames.first?.scale ?? 0
        let sampling =
            scale > 2.5
            ? " At \(String(format: "%.1f", scale))″/px the field is undersampled, so drizzle is worth trying."
            : ""
        _ = sampling
        return "Alignment is solved from stars; rotation is measured, never assumed. Per-frame optics and pointing are in Library." 
    }

    private var integrationLabel: String {
        let m = Int(frames.reduce(0.0) { $0 + Double($1.exptime) } / 60)
        return "\(m / 60) h \(m % 60) m"
    }

    /// From the measured rates: ~16 ms analyse, ~280 ms register, ~60 ms stack.
    private var estimate: String {
        let n = Double(frames.count)
        let secs = Int(n * 0.016 + n * 0.28 + n * 0.06)
        return secs >= 60 ? "\(secs / 60) m \(secs % 60) s" : "\(secs) s"
    }

    private func stageRow(
        _ name: String, _ detail: String, _ index: Int32, _ j: AcJob, _ secs: Float
    ) -> some View {
        let active = j.stage == index && j.state == 1
        let past = j.state == 2 || (j.state == 1 && j.stage > index)
        return VStack(spacing: 2) {
            HStack {
                Text(name).font(Face.body)
                    .foregroundStyle(active ? t.t1 : (past ? t.t2 : t.t3))
                Text(detail).font(Face.secondary).foregroundStyle(t.t4)
                Spacer()
                Text(secs > 0 ? String(format: "%.0f s", secs) : (active ? "…" : "—"))
                    .font(Face.mono(11)).foregroundStyle(t.t2)
            }
            if active || past {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(t.s3)
                        Rectangle().fill(past ? t.q5 : t.q4)
                            .frame(
                                width: geo.size.width
                                    * (past ? 1 : (j.total > 0 ? Double(j.done) / Double(j.total) : 0)))
                    }
                }
                .frame(height: 2)
            }
        }
        .frame(height: 22)
    }

    private func note(_ s: String) -> some View {
        Text(s).font(Face.secondary).foregroundStyle(t.t4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Space.xs)
    }

    private func stageBar(_ label: String, _ index: Int32, _ j: AcJob, _ secs: Float)
        -> some View
    {
        let active = j.stage == index && j.state == 1
        let past = j.state >= 2 || j.stage > index
        let frac: Double =
            past ? 1 : (active && j.total > 0 ? Double(j.done) / Double(j.total) : 0)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(Face.secondary)
                    .foregroundStyle(active ? t.t1 : t.t3)
                Spacer()
                Text(secs > 0 ? String(format: "%.0fs", secs) : (active ? "…" : "—"))
                    .font(Face.mono(10)).foregroundStyle(t.t3)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(t.s3)
                    Rectangle().fill(past ? t.q5 : t.q4)
                        .frame(width: geo.size.width * frac)
                }
            }
            .frame(height: 3)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header("Recipe").padding(.bottom, Space.md)

                header("Pixel rejection")
                note("Per-pixel across the selected frames — drops satellite trails and cosmic rays without discarding the frame. Frames themselves are kept or rejected in Library.")
                Segmented(
                    items: ["None", "σ-clip", "Winsorised"],
                    index: Binding(
                        get: { model.rejection.rawValue },
                        set: { model.rejection = RejectionAlgorithm(rawValue: $0) ?? .sigmaClip }))
                stepper("Low σ", $model.sigmaLow)
                stepper("High σ", $model.sigmaHigh)
                intStepper("Passes", $model.passes)

                header("Registration").padding(.top, Space.xl)
                info("Method", solved == frames.count && frames.count > 0 ? "WCS" : "Star-based")
                info("Drizzle", planned.drizzle > 0 ? "\(planned.drizzle)×" : "off")
                info("Scale", planned.fullResolution ? "full sensor" : "binned 2×2")
                if model.job.state == 2 {
                    info(
                        "Measured drift",
                        String(format: "%.1f px · %.2f° rotation",
                               model.job.drift_px,
                               model.job.rotation_max - model.job.rotation_min))
                }
                note(registrationNote)

                if let s = Strategist.recommend(
                    frames: frames,
                    measuredDrift: model.job.state == 2 ? model.job.drift_px : nil)
                {
                    header("Combine strategy").padding(.top, Space.xl)
                    HStack {
                        Text(s.label).font(Face.body).foregroundStyle(t.q5)
                        Spacer()
                        Text(s.sampling.rawValue)
                            .font(Face.mono(10)).foregroundStyle(t.t3)
                    }
                    .frame(height: 20)
                    note(s.reason)
                    if let c = s.caveat {
                        Text(c).font(Face.secondary).foregroundStyle(t.q3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Space.xs)
                    }
                    ForEach(Strategist.rejected(s), id: \.0) { name, why in
                        HStack(alignment: .top, spacing: Space.sm) {
                            Text(name).font(Face.secondary).foregroundStyle(t.t3)
                                .frame(width: 96, alignment: .leading)
                            Text(why).font(Face.secondary).foregroundStyle(t.t4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    }
                    Toggle("Choose it myself", isOn: $model.overrideStrategy)
                        .toggleStyle(.checkbox)
                        .font(Face.secondary)
                        .foregroundStyle(t.t2)
                        .padding(.top, Space.sm)

                    if model.overrideStrategy {
                        ForEach(StrategyChoice.allCases, id: \.rawValue) { c in
                            let on = model.choice == c
                            Button { model.choice = c } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text(c.rawValue).font(Face.body)
                                            .foregroundStyle(on ? t.selT : t.t1)
                                        Spacer()
                                        if c.matches(s) {
                                            Text("recommended")
                                                .font(Face.mono(9)).foregroundStyle(t.q5)
                                        }
                                    }
                                    Text(c.effect)
                                        .font(Face.secondary).foregroundStyle(t.t3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(Space.sm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(on ? t.sel : t.s2)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, Space.xs)
                        }

                        if !model.choice.matches(s) {
                            Text("Not what the data suggests — worth stacking both ways and comparing star count and noise in the table below.")
                                .font(Face.secondary).foregroundStyle(t.q3)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, Space.xs)
                        }
                    }
                }

                header("Output").padding(.top, Space.xl)
                info("Format", "FITS −32")
                info("Provenance", "HISTORY cards")

                header("Export for").padding(.top, Space.xl)
                Picker("", selection: $model.target) {
                    ForEach(ExportTarget.allCases, id: \.rawValue) { e in
                        Text(e.rawValue).tag(e)
                    }
                }
                .labelsHidden().font(Face.body)

                info("Format", model.target.format)
                info("Row order", model.target.rowOrder)
                info("Data", model.target.data)
                info("Pedestal", model.target.pedestal)
                info("Bayer", "none — already debayered")
                info("Filename", model.filename)
                note(model.target.reason)

                HStack(spacing: Space.sm) {
                    action("Export…") { export() }
                    action("Advanced…") {}
                }
                .padding(.top, Space.md)

                if let e = model.exportError {
                    Text(e).font(Face.secondary).foregroundStyle(t.q2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.xs)
                }

                jobCard.padding(.top, Space.xl)
                Spacer()
            }
            .padding(Metric.panelPad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func export() {
        model.exportError = Exporter.run(
            source: model.outputPath,
            target: model.target,
            suggested: Exporter.suggestedName(
                model.target, frames: Int(model.job.frames_used),
                exposure: model.subExptime, filter: catalog.sessions.first.map { _ in "LP" } ?? "LP"),
            stretch: (model.afterStretch.shadows, model.afterStretch.midtone))
    }

    private func header(_ s: String) -> some View {
        Text(s.uppercased()).font(Face.sectionHeader).tracking(Face.sectionTracking)
            .foregroundStyle(t.t3).padding(.bottom, Space.sm)
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(Face.body).foregroundStyle(t.t3)
            Spacer()
            Text(v).font(Face.mono(11)).foregroundStyle(t.t1)
        }
        .frame(height: 20)
    }

    private func stepper(_ label: String, _ value: Binding<Float>) -> some View {
        HStack {
            Text(label).font(Face.body).foregroundStyle(t.t3)
            Spacer()
            action("−") { value.wrappedValue = max(1, value.wrappedValue - 0.5) }
            Text(String(format: "%.1f", value.wrappedValue))
                .font(Face.mono(11)).foregroundStyle(t.t1).frame(width: 28)
            action("+") { value.wrappedValue = min(10, value.wrappedValue + 0.5) }
        }
        .frame(height: 22)
    }

    private func intStepper(_ label: String, _ value: Binding<Int>) -> some View {
        HStack {
            Text(label).font(Face.body).foregroundStyle(t.t3)
            Spacer()
            action("−") { value.wrappedValue = max(1, value.wrappedValue - 1) }
            Text("\(value.wrappedValue)")
                .font(Face.mono(11)).foregroundStyle(t.t1).frame(width: 28)
            action("+") { value.wrappedValue = min(5, value.wrappedValue + 1) }
        }
        .frame(height: 22)
    }

    private func chip(_ label: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(label).font(Face.secondary)
                .foregroundStyle(on.wrappedValue ? t.selT : t.t3)
                .padding(.horizontal, Space.md).frame(height: 20)
                .background(on.wrappedValue ? t.sel : t.s2)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .stroke(on.wrappedValue ? t.selLine : t.line2, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .padding(.bottom, Space.xs)
    }

    private func action(_ label: String, primary: Bool = false, _ run: @escaping () -> Void)
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

struct StretchPair {
    var shadows = SIMD3<Float>(repeating: 0)
    var midtone = SIMD3<Float>(repeating: 0.5)
}

struct ABSplit: View {
    @ObservedObject var model: StackModel
    let tokens: Tokens
    @State private var divider: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                tokens.img

                if model.hasAfter {
                    MetalImageView(
                        renderer: model.afterRenderer,
                        shadows: model.afterStretch.shadows,
                        midtone: model.afterStretch.midtone)
                }
                if model.hasBefore {
                    // Full-size render, masked — resizing the view would
                    // aspect-fit it to the half width and break alignment.
                    MetalImageView(
                        renderer: model.beforeRenderer,
                        shadows: model.beforeStretch.shadows,
                        midtone: model.beforeStretch.midtone)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geo.size.width * divider)
                        }
                }

                Rectangle().fill(tokens.line3).frame(width: 1)
                    .offset(x: geo.size.width * divider)

                Text("Single sub").font(Face.mono(10)).foregroundStyle(tokens.t2)
                    .padding(Space.md)
                Text(model.hasAfter ? "AstroCat stack" : "Not stacked yet")
                    .font(Face.mono(10)).foregroundStyle(tokens.t2)
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture().onChanged { v in
                    divider = min(0.98, max(0.02, v.location.x / geo.size.width))
                })
        }
    }
}
