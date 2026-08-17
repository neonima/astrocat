import Foundation

/// Drives the Develop model through the real API and prints what each layer is
/// actually running.
///
/// The UI cannot be inspected from outside the app, and diagnosing a "this
/// control does nothing" report by reading the code has a bad record here. This
/// runs the same calls the buttons make and prints the slots that reached the
/// shader, which is the only thing that decides what appears on screen.
///
///     dist/AstroCat.app/Contents/MacOS/AstroCat --selftest <master.fit>
enum SelfTest {
    @MainActor
    static func run(_ path: String) -> Never {
        let m = DevelopModel()
        m.load(path)
        say("loaded", "\(URL(fileURLWithPath: path).lastPathComponent)")
        say("before pane slots", m.beforeRenderer.ops.map { describe($0) }.joined(separator: "  ")
            + (m.beforeRenderer.ops.isEmpty ? "(EMPTY — renders raw linear, i.e. black)" : ""))
        say("master meta stf", "shadows \(m.meta?.shadows.y ?? -1)  midtone \(m.meta?.midtone.y ?? -1)")
        say("after pane slots", m.master.renderer.ops.map { describe($0) }.joined(separator: "  "))
        say(
            "before == after slots",
            "\(m.beforeRenderer.ops.map { describe($0) } == m.master.renderer.ops.map { describe($0) })")
        comparePanes(m)
        compareSeam(m)
        say("master stack", m.master.stack.map(\.kind).joined(separator: " → "))

        m.setHead("Star separation", on: true)
        say("separated", "\(m.separated)")
        guard m.separated, let starless = m.starless, let stars = m.stars else {
            print("!! no layers cached beside this master; separate first")
            exit(1)
        }
        say("starless stack", starless.stack.map(\.kind).joined(separator: " → "))
        say("stars stack", stars.stack.map(\.kind).joined(separator: " → "))

        // Nothing has been touched yet. If a calibration stage is switched on
        // in a saved stack, it must already be applied by now — a stage that is
        // on but dormant is a lie, and it wakes up later looking like whatever
        // the user did next caused it.
        waitForColour(m)
        dump("after loading, before touching anything", m)

        m.select(.stars)
        say("selected", "\(m.activeLayer)  active is stars: \(m.active === stars)")

        // What the user does: put a colour calibration on the star layer.
        if let existing = stars.stack.first(where: { $0.kind == "Colour calibration" }) {
            m.setStage(existing.id, on: true)
        } else {
            m.addStage("Colour calibration")
        }
        // The measurement is async; the calibration cannot appear until it lands.
        waitForColour(m)
        dump("after calibrating STARS", m)

        // And the other thing that reportedly does nothing.
        let before = stars.renderer.ops.first { $0.code == 3 }?.midtone.y ?? -1
        m.midtone = min(0.999, max(0.001, m.midtone * 2))
        dump("after doubling the STARS midtone", m)
        let after = stars.renderer.ops.first { $0.code == 3 }?.midtone.y ?? -1
        say("stars stretch midtone", "\(before) → \(after)   changed: \(before != after)")

        let starlessMid = starless.renderer.ops.first { $0.code == 3 }?.midtone.y ?? -1
        say("starless stretch midtone", "\(starlessMid)  (must not have moved)")
        exit(0)
    }

    /// With the same pipeline on both sides, splitting must produce exactly the
    /// image that not splitting produces. That is the whole claim of a
    /// before/after divider, and comparing neighbouring columns cannot test it —
    /// on a star field, adjacent pixels differ for honest reasons.
    @MainActor
    private static func compareSeam(_ m: DevelopModel) {
        let w = 400
        let h = 300
        let r = m.master.renderer
        r.before = m.beforeSlot
        r.splitX = -1
        guard let whole = r.render(width: w, height: h) else { return }
        r.splitX = 0.5
        guard let split = r.render(width: w, height: h) else { return }
        r.splitX = -1

        var differing = 0
        var worst = 0
        for i in stride(from: 0, to: whole.count, by: 4) {
            for c in 0..<3 {
                let d = abs(Int(whole[i + c]) - Int(split[i + c]))
                if d > 2 { differing += 1 }
                worst = max(worst, d)
            }
        }
        say(
            "split vs unsplit",
            "\(differing) of \(whole.count / 4 * 3) samples differ, worst \(worst)/255")
    }

    /// Renders both panes at the same size and compares the pixels. Identical
    /// parameters are a claim about what appears on screen; this is the claim
    /// being checked rather than assumed.
    @MainActor
    private static func comparePanes(_ m: DevelopModel) {
        let w = 400
        let h = 300
        m.beforeRenderer.viewport = m.viewport
        m.master.renderer.viewport = m.viewport
        guard let before = m.beforeRenderer.render(width: w, height: h),
            let after = m.master.renderer.render(width: w, height: h)
        else {
            say("pane pixels", "could not render offscreen")
            return
        }
        var worst = 0
        var differing = 0
        for i in stride(from: 0, to: before.count, by: 4) {
            let d = max(
                abs(Int(before[i]) - Int(after[i])),
                max(
                    abs(Int(before[i + 1]) - Int(after[i + 1])),
                    abs(Int(before[i + 2]) - Int(after[i + 2]))))
            if d > 2 { differing += 1 }
            worst = max(worst, d)
        }
        let n = before.count / 4
        say("pane pixels", "\(differing) of \(n) differ by >2/255, worst \(worst)")
        say("before mean", "\(mean(before))")
        say("after  mean", "\(mean(after))")
    }

    private static func mean(_ px: [UInt8]) -> String {
        var sum = [0, 0, 0]
        for i in stride(from: 0, to: px.count, by: 4) {
            sum[0] += Int(px[i + 2])
            sum[1] += Int(px[i + 1])
            sum[2] += Int(px[i])
        }
        let n = px.count / 4
        return String(
            format: "%.1f / %.1f / %.1f",
            Double(sum[0]) / Double(n), Double(sum[1]) / Double(n), Double(sum[2]) / Double(n))
    }

    @MainActor
    private static func waitForColour(_ m: DevelopModel) {
        let deadline = Date().addingTimeInterval(20)
        while m.colorCal == nil, m.colorBusy || Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if !m.colorBusy, m.colorCal != nil { break }
        }
        // Settle the pushes the completion queued.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    @MainActor
    private static func dump(_ label: String, _ m: DevelopModel) {
        print("\n=== \(label) ===")
        print("  colorCal: \(m.colorCal == nil ? "nil" : "measured")   active: \(m.activeLayer)")
        for (name, state) in [("starless", m.starless), ("stars", m.stars)] {
            guard let state else { continue }
            let on = state.stack.filter(\.on).map(\.kind).joined(separator: ", ")
            print("  \(name.padding(toLength: 9, withPad: " ", startingAt: 0)) on: [\(on)]")
            print(
                "            slots: "
                    + state.renderer.ops.map { describe($0) }.joined(separator: "  "))
        }
    }

    private static func describe(_ s: OpSlot) -> String {
        switch s.code {
        case 1: return String(format: "cal(gain %.3f/%.3f/%.3f)", s.calGain.x, s.calGain.y, s.calGain.z)
        case 2: return "palette"
        case 3: return String(format: "stretch(mid %.5f)", s.midtone.y)
        case 4: return "zones(lut \(s.lut))"
        case 5: return "tone"
        default: return "op\(s.code)"
        }
    }

    private static func say(_ k: String, _ v: String) {
        print("\(k.padding(toLength: 22, withPad: " ", startingAt: 0)) \(v)")
    }
}
