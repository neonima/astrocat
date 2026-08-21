import Foundation

// The same check as scripts/settings-check, but on the app's real settings
// types rather than fixtures — including the v1 develop files already on disk,
// whose white reference and palette were stored as the picker's labels. Built
// against the app's own sources so it exercises the shipping types, not copies
// of them.

var failures = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("  ok   \(name)")
    } else {
        print("  FAIL \(name)")
        failures += 1
    }
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("astrocat-develop-check", isDirectory: true)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
let master = scratch.appendingPathComponent("master.fit").path

func write(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object)
    try! data.write(to: Masters.settingsURL(for: master))
}

// A file exactly as a build before this change wrote one: no version, the two
// picker labels stored as values, and none of the fields added since.
let v1: [String: Any] = [
    "algorithm": 1, "p0": 10, "p1": 0.2, "blend": 1, "black": 0,
    "midtone": 0.0020978276, "midtoneBase": 0.0020978276, "linked": true,
    "linearMode": true, "displayOnly": true, "sampleTolerance": 5,
    "colourOn": true, "colourReference": 2,
    "white": "A0V (Vega)",
    "paletteOn": true, "palette": "SHO (synthetic SII)",
    "mix": ["red": 1, "green": 0, "blue": 0, "oiiiBalance": 0.5, "haGain": 1, "oiiiGain": 1],
    "zonesOn": false, "zones": ["slopes": [1, 1, 1, 1, 1]],
    "toneOn": false,
    "tone": [
        "exposure": 0, "contrast": 0, "highlights": 0, "shadows": 0,
        "whites": 0, "blacks": 0, "vibrance": 0, "scnr": 0,
    ],
    "detail": ["clarity": 0, "texture": 0],
    "rotation": 2, "flipH": false, "flipV": false,
    "crop": [0.102896005, 0.16477004, 0.971275, 0.89746404],
    "separationOn": true,
]

print("develop settings")

write(v1)
let loaded = DevelopSettings.load(master)
check("a v1 file still loads", loaded != nil)
check("the crop survives", loaded?.crop == SIMD4<Float>(0.102896005, 0.16477004, 0.971275, 0.89746404))
check("the orientation survives", loaded?.rotation == 2)
check("the stretch survives", loaded?.midtone == 0.0020978276 && loaded?.linked == true)
check("the colour mode survives", loaded?.colourOn == true && loaded?.colourReference == 2)
check("the separation switch survives", loaded?.separationOn == true)

// The three ways a v1 file used to be lost.
check("the white reference is migrated off its label", loaded?.white == WhiteReference.a0v.rawValue)
check("the palette is migrated off its label", loaded?.palette == Palette.sho.rawValue)
check("both still resolve to a case", WhiteReference(rawValue: loaded?.white ?? "") == .a0v)
check("and the palette does too", Palette(rawValue: loaded?.palette ?? "") == .sho)

// Fields this build has and v1 did not: saturation at the top level, radius
// inside a nested struct, and a switch whose default is not `false`.
check("a field added since takes its default", loaded?.saturation == 1.15)
check("one added inside a nested struct too", loaded?.detail.radius == 10)
check("a stretch switch absent from the file reads as on", loaded?.stretchOn == true)

var edited = loaded!
edited.saturation = 1.4
edited.tone.contrast = 0.3
edited.save(master)
let reloaded = DevelopSettings.load(master)
check("a save round trips", reloaded == edited)

let rewritten =
    (try? Data(contentsOf: Masters.settingsURL(for: master)))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
check("the rewritten file carries the version", (rewritten?[Settings.versionKey] as? Int) == 2)
check("and is not migrated a second time", DevelopSettings.load(master)?.palette == "sho")

// One field corrupted should cost that field, not the session's work.
var damaged = v1
damaged["midtone"] = "not a number"
write(damaged)
let salvaged = DevelopSettings.load(master)
check("a corrupt field falls back to its default", salvaged?.midtone == DevelopSettings().midtone)
check("and the rest of the edits survive it", salvaged?.crop == loaded?.crop)

// The layer files are the same type, so a layer's edits ride on the same
// guarantee as the master's.
check("an empty file is refused rather than half-read", {
    try! Data().write(to: Masters.settingsURL(for: master))
    return DevelopSettings.load(master) == nil
}())
check("a missing file is nil", DevelopSettings.load(scratch.appendingPathComponent("nope.fit").path) == nil)

print("\nstack settings")

var stack = StackSettings()
stack.sigmaLow = 2.5
stack.rejection = .winsorised
stack.passes = 3
stack.keptOnly = false
stack.worstCut = 0.2
stack.overrideStrategy = true
stack.choice = .drizzle
stack.target = .pixinsight
stack.nights = ["2026-07-29", "2026-08-14"]

let stackRound = Settings.encode(stack).flatMap { Settings.decode(StackSettings.self, from: $0) }
check("a stack setup round trips", stackRound == stack)

// Nothing has ever written one of these, so there is no v1 to migrate — the
// guarantee that matters is the one that starts now.
let sparse = try! JSONSerialization.data(withJSONObject: [
    "sigmaLow": 2.5, "target": "pixinsight",
])
let filled = Settings.decode(StackSettings.self, from: sparse)
check("a partial file fills the rest in", filled?.sigmaHigh == 3 && filled?.passes == 1)
check("and keeps what it had", filled?.sigmaLow == 2.5 && filled?.target == .pixinsight)

// An enum case dropped by a later release, read back by a build that still has
// it — and the reverse, which is what actually bites.
let gone = try! JSONSerialization.data(withJSONObject: [
    "choice": "quadrupled", "target": "png", "passes": 4,
])
let recovered = Settings.decode(StackSettings.self, from: gone)
check("an enum case this build lacks falls back to its default", recovered?.choice == .full)
check("without taking the rest of the setup with it", recovered?.target == .png && recovered?.passes == 4)

check(
    "the export target is stored as a name, not its label",
    ExportTarget.pixinsight.rawValue == "pixinsight" && ExportTarget.pixinsight.label == "PixInsight")
check(
    "and so is the strategy",
    StrategyChoice.drizzle.rawValue == "drizzle" && StrategyChoice.drizzle.label == "Drizzle 2×")

// Through the model, so what is checked is the wiring rather than the struct:
// opening a project reads its file, and changing a control writes one.
@MainActor
func throughTheModel(_ saved: StackSettings) {
    let project = scratch.appendingPathComponent("project", isDirectory: true)
    let url = StackSettings.url(project.path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Settings.encode(saved)!.write(to: url)

    let model = StackModel()
    model.projectRoot = project.path
    check("opening a project restores its stack setup", model.settings == saved)

    model.settings.passes = 7
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    let written = (try? Data(contentsOf: url)).flatMap {
        Settings.decode(StackSettings.self, from: $0)
    }
    check("changing a control writes it back", written?.passes == 7)
    check(
        "without disturbing the rest",
        written?.choice == .drizzle && written?.nights == saved.nights)

    let untouched = StackModel()
    untouched.projectRoot = scratch.appendingPathComponent("empty").path
    check("a project with no file gets the defaults", untouched.settings == StackSettings())
}
MainActor.assumeIsolated { throughTheModel(stack) }

// Given a real master, reports what its settings file actually restores to —
// the same "run it before forming a theory" the selftest exists for, on a copy
// so nothing on disk is touched.
if let real = CommandLine.arguments.dropFirst().first {
    let copy = scratch.appendingPathComponent("real.fit").path
    if let data = try? Data(contentsOf: Masters.settingsURL(for: real)) {
        try? data.write(to: Masters.settingsURL(for: copy))
        if let s = DevelopSettings.load(copy) {
            print(
                """
                \n\(real)
                  white \(s.white)  palette \(s.palette) (on: \(s.paletteOn))
                  stretch \(s.stretchOn)  colour \(s.colourOn)/\(s.colourReference)  \
                separation \(s.separationOn)
                  midtone \(s.midtone)  saturation \(s.saturation)  tolerance \(s.sampleTolerance)
                  crop \(s.crop)  rotation \(s.rotation)  detail radius \(s.detail.radius)
                """)
        } else {
            print("\n\(real): unreadable")
            failures += 1
        }
    } else {
        print("\n\(real): no settings file")
    }
}

try? FileManager.default.removeItem(at: scratch)

print(failures == 0 ? "app settings: all checks passed" : "app settings: \(failures) failed")
exit(failures == 0 ? 0 : 1)
