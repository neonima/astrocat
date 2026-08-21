import Foundation

// Exercises Settings.swift against the shapes a real settings file takes, so
// the guarantee "an update does not lose edits" is checked rather than
// asserted. Kept out of Sources/ because it has its own entry point; run it
// with scripts/check-settings.sh.

var failures = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("  ok   \(name)")
    } else {
        print("  FAIL \(name)")
        failures += 1
    }
}

func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

struct Nested: Codable, Equatable {
    var a: Float = 1
    var b: Float = 2
    /// Stands in for a field added by a later release.
    var added: Float = 7
}

struct Fixture: Migratable, Equatable {
    var scale: Float = 0.5
    var count: Int = 3
    var flag: Bool = false
    var name: String = "natural"
    var nested = Nested()
    var box = SIMD4<Float>(0, 0, 1, 1)
    /// Stands in for a field added by a later release.
    var added: Int = 42

    static let version = 2

    static func migrate(_ object: inout [String: Any], to version: Int) {
        switch version {
        case 2: Settings.respell(&object, "name", ["Natural": "natural", "HOO": "hoo"])
        default: break
        }
    }
}

// A file written by an earlier build: no version, no `added` anywhere, and the
// palette still spelled the way the picker used to label it.
let old: [String: Any] = [
    "scale": 0.25, "count": 9, "flag": true, "name": "HOO",
    "nested": ["a": 11, "b": 22],
    "box": [0.1, 0.2, 0.9, 0.8],
]

print("settings")

let loaded = Settings.decode(Fixture.self, from: json(old))
check("an old file still decodes", loaded != nil)
check("edits survive", loaded?.scale == 0.25 && loaded?.count == 9 && loaded?.flag == true)
check("a new field takes its default", loaded?.added == 42)
check("a new field in a nested struct takes its default", loaded?.nested.added == 7)
check("nested edits survive", loaded?.nested.a == 11 && loaded?.nested.b == 22)
check("arrays survive", loaded?.box == SIMD4<Float>(0.1, 0.2, 0.9, 0.8))
check("a migration respells a value", loaded?.name == "hoo")

var future = old
future[Settings.versionKey] = 99
check(
    "a file from a newer build is not migrated backwards",
    Settings.decode(Fixture.self, from: json(future))?.name == "HOO")

var current = old
current[Settings.versionKey] = 2
check(
    "a current file is not migrated again",
    Settings.decode(Fixture.self, from: json(current))?.name == "HOO")

var removed = old
removed["retired"] = "a field this build no longer has"
check("a removed field is ignored", Settings.decode(Fixture.self, from: json(removed))?.count == 9)

var wrongType = old
wrongType["count"] = "nine"
let salvaged = Settings.decode(Fixture.self, from: json(wrongType))
check("a field whose type changed falls back to its default", salvaged?.count == 3)
check("and the rest of the file still loads", salvaged?.scale == 0.25 && salvaged?.flag == true)

var wrongNested = old
wrongNested["nested"] = ["a": "eleven", "b": 22]
let salvagedNested = Settings.decode(Fixture.self, from: json(wrongNested))
check("a nested field whose type changed falls back", salvagedNested?.nested.a == 1)
check("and its siblings survive", salvagedNested?.nested.b == 22)

var wrongArray = old
wrongArray["box"] = [0.1, "two", 0.9, 0.8]
check(
    "a malformed array falls back whole",
    Settings.decode(Fixture.self, from: json(wrongArray))?.box == SIMD4<Float>(0, 0, 1, 1))

var deep = old
deep["scale"] = "quarter"
deep["nested"] = ["a": "eleven"]
let salvagedBoth = Settings.decode(Fixture.self, from: json(deep))
check(
    "several bad fields are each repaired",
    salvagedBoth?.scale == 0.5 && salvagedBoth?.nested.a == 1 && salvagedBoth?.count == 9)

var edited = Fixture()
edited.scale = 0.75
edited.nested.b = 5
let round = Settings.encode(edited).flatMap { Settings.decode(Fixture.self, from: $0) }
check("a round trip is lossless", round == edited)

let stamped =
    Settings.encode(edited)
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
check("what it writes carries the version", (stamped?[Settings.versionKey] as? Int) == 2)

// Writing over a file a newer build left behind. What this build does not know
// about has to still be there when that build comes back.
var newer = old
newer[Settings.versionKey] = 3
newer["dither"] = 0.4
newer["nested"] = ["a": 11, "b": 22, "gamma": 2.2]
let overwritten =
    Settings.encode(Fixture(), carrying: json(newer))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
check("a field only a newer build knows survives being written over", overwritten?["dither"] as? Double == 0.4)
check(
    "one nested inside a struct survives too",
    (overwritten?["nested"] as? [String: Any])?["gamma"] as? Double == 2.2)
check("this build's own values still win", overwritten?["count"] as? Int == 3)
check(
    "and the nested ones do",
    (overwritten?["nested"] as? [String: Any])?["a"] as? Double == 1)

// The respell has to be safe on a value it has already migrated, because that
// is what an old build writing back a newer file leaves behind.
var twice = old
twice["name"] = "hoo"
check(
    "a migration run a second time leaves the value alone",
    Settings.decode(Fixture.self, from: json(twice))?.name == "hoo")

check("garbage is refused rather than half-read", Settings.decode(Fixture.self, from: Data()) == nil)
check(
    "a JSON array is refused",
    Settings.decode(Fixture.self, from: "[1,2]".data(using: .utf8)!) == nil)

// The trap the whole file exists to close: what stock Codable does with the
// same input.
struct Stock: Codable {
    var scale: Float = 0.5
    var added: Int = 42
}
check(
    "stock Codable would have thrown on the same file",
    (try? JSONDecoder().decode(Stock.self, from: json(["scale": 0.25]))) == nil)

print(failures == 0 ? "settings: all checks passed" : "settings: \(failures) failed")
exit(failures == 0 ? 0 : 1)
