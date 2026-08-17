import Foundation

/// External processing tools, found rather than bundled.
///
/// Only tools that are free to use are listed. Paid ones are deliberately
/// absent rather than detected and locked.
///
/// These fall into two kinds, and the difference decides how much work each one
/// is. StarNet2 and GraXpert are standalone binaries with documented flags —
/// hand them a file, read the result. The Siril script ecosystem are plugins
/// whose interface *is* Siril's Python API, so reaching those means driving
/// Siril headlessly rather than calling a binary.
struct ExternalTool: Identifiable {
    enum Role: String {
        case starRemoval = "Star removal"
        case background = "Background extraction"
        case denoise = "Noise reduction"
        case starReduction = "Star reduction"
        case sharpen = "Sharpening"
    }

    /// How the tool is reached, which is also how much of it is built.
    enum Host {
        /// Its own executable with documented arguments.
        case binary
        /// A script Siril hosts, reached through `siril-cli -s`.
        case siril
    }

    let id: String
    let name: String
    let role: Role
    let host: Host
    /// Probed in order; the first that exists wins unless overridden.
    let candidates: [String]
    let note: String

    var overrideKey: String { "tool.\(id).path" }

    /// A binary has to be executable; a Siril script only has to exist, because
    /// Siril is what runs it. Requiring both to be executable finds the tools
    /// that need launching and quietly misses the ones that need hosting.
    private func usable(_ candidate: String) -> Bool {
        switch host {
        case .binary: return FileManager.default.isExecutableFile(atPath: candidate)
        case .siril: return FileManager.default.fileExists(atPath: candidate)
        }
    }

    /// A user-set path beats discovery, so a tool installed somewhere unusual
    /// does not need the app changed to find it.
    var path: String? {
        if let custom = UserDefaults.standard.string(forKey: overrideKey), usable(custom) {
            return custom
        }
        return candidates.first(where: usable)
    }

    /// A Siril-hosted script is only reachable if Siril itself is there.
    var isReachable: Bool {
        guard path != nil else { return false }
        return host == .binary || Tools.sirilAvailable
    }

    var isAvailable: Bool { path != nil }
}

enum Tools {
    static let sirilCLI = "/Applications/Siril.app/Contents/MacOS/siril-cli"

    static let all: [ExternalTool] = [
        ExternalTool(
            id: "starnet2", name: "StarNet2", role: .starRemoval, host: .binary,
            candidates: [
                NSHomeDirectory() + "/poke/starnet2/starnet2",
                "/usr/local/bin/starnet2",
                NSHomeDirectory() + "/StarNet/starnet2",
            ],
            note:
                "Reads our 32-bit FITS directly and writes both layers — starless and an unscreened star layer, which is the proper inverse of a screen blend rather than a subtraction."),
        // Others are added here as they are wired, not as they are discovered.
        // Listing a tool AstroCat cannot actually drive is worse than omitting
        // it: it reads as a capability.
    ]

    static func tool(_ id: String) -> ExternalTool? { all.first { $0.id == id } }

    static var sirilAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: sirilCLI)
    }

    /// Runs a tool to completion, returning its combined output. Throws rather
    /// than returning a status, because a star removal that quietly did nothing
    /// looks exactly like one that worked until you inspect the pixels.
    @discardableResult
    static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 600
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: executable).deletingLastPathComponent()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        // A model that wedges would otherwise block this thread for ever, and
        // the caller is a background queue with no other way out.
        let expired = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expired)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let killed = expired.isCancelled == false && process.terminationReason == .uncaughtSignal
        expired.cancel()
        let output = String(decoding: data, as: UTF8.self)

        let name = URL(fileURLWithPath: executable).lastPathComponent
        if killed {
            throw NSError(
                domain: "AstroCat", code: 124,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(name) did not finish within \(Int(timeout))s and was stopped."
                ])
        }
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AstroCat", code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "\(name) failed: " + String(output.suffix(400))
                ])
        }
        return output
    }
}

/// How a star-removal pass is run, independent of which model runs it.
struct SeparationOptions: Equatable, Codable {
    /// 2x upsampling before inference. Measured on the 211-frame stack: star
    /// *removal* is unchanged — 1.9% of star flux left behind against 2.0% —
    /// but the star *layer* captures 88.3% of it instead of 79.3%, and the
    /// reconstruction error at stars falls 35% with the 99.99th percentile
    /// halved. It costs 3.7x the runtime. On by default because this data is
    /// badly undersampled at 3.67"/px, which is the case the flag exists for.
    var upsample = true
    /// Tile stride. Smaller means more overlap and fewer seams, and slower.
    var stride = 256

    static let key = "separation.options"

    static var stored: SeparationOptions {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                let v = try? JSONDecoder().decode(SeparationOptions.self, from: d)
            else { return SeparationOptions() }
            return v
        }
        set {
            guard let d = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(d, forKey: key)
        }
    }
}

/// A star-removal backend: how to invoke it, and which of its quirks the shared
/// wrapper has to undo afterwards.
///
/// The wrapper is the valuable part and it is the same for every model — prepare
/// a stretched copy, infer, invert exactly. What differs between tools is the
/// argument spelling and whether they get the plane order right, so that is all
/// this carries.
struct StarRemover: Identifiable {
    let id: String
    let name: String
    /// Key into `Tools.all`, which owns discovery and the path override.
    let tool: String
    /// StarNet2 reads RGB and writes BGR. Measured rather than documented: the
    /// master's red median comes back as the layer's blue. A backend that gets
    /// this right must not be "corrected".
    let swapsRedBlue: Bool
    /// Whether the model expects a stretched frame. Every star-removal model so
    /// far does; the flag exists so a linear-native one would not be silently
    /// handed the wrong thing.
    let wantsStretchedInput: Bool
    let arguments: (String, String, String, SeparationOptions) -> [String]

    var isReachable: Bool { Tools.tool(self.tool)?.isReachable == true }
}

/// Star separation. Both layers are cached beside the master, so half a minute
/// of inference happens once rather than on every launch.
enum StarSeparation {
    static let removers: [StarRemover] = [
        StarRemover(
            id: "starnet2", name: "StarNet2", tool: "starnet2",
            swapsRedBlue: true, wantsStretchedInput: true
        ) { input, starless, stars, opts in
            var args = [
                "--input", input, "--output", starless, "--unscreen", stars,
                "--stride", String(opts.stride),
            ]
            if opts.upsample { args.append("--upsample") }
            return args
        }
    ]

    static func remover(_ id: String) -> StarRemover {
        removers.first { $0.id == id } ?? removers[0]
    }
}

extension StarSeparation {
    /// Layers live beside the masters directory, not inside it. They are FITS of
    /// the same size and shape, so anything globbing the masters folder would
    /// take them for masters — which is exactly what happened: a layer became
    /// selectable, got loaded as the frame, and was then separated again into
    /// layers of a layer.
    static func directory(for master: String) -> URL {
        URL(fileURLWithPath: master)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("layers", isDirectory: true)
    }

    /// FITS rather than TIFF: StarNet2 writes 32-bit float when asked for it,
    /// so both layers come back linear and at full precision. A 16-bit TIFF
    /// would force a stretch on the way in and an inverse on the way out, and
    /// the shadows — where all the nebulosity is — would not survive it.
    private static func layerURL(_ master: String, _ suffix: String) -> URL {
        let stem = URL(fileURLWithPath: master).deletingPathExtension().lastPathComponent
        return directory(for: master).appendingPathComponent("\(stem).\(suffix).fit")
    }

    static func starlessURL(for master: String) -> URL { layerURL(master, "starless") }

    static func starsURL(for master: String) -> URL { layerURL(master, "stars") }

    /// Separating a layer produces layers of a layer, which is never wanted and
    /// quietly wrecks the frame you thought you were working on.
    static func isLayer(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.contains(".starless.") || name.contains(".stars.")
    }

    static func exists(for master: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: starlessURL(for: master).path)
            && fm.fileExists(atPath: starsURL(for: master).path)
    }

    /// What produced the layers on disk. Recorded so changing an option that
    /// changes the pixels does not silently leave the old ones in place.
    private struct Provenance: Codable, Equatable {
        var remover: String
        var options: SeparationOptions
    }

    private static func provenanceURL(_ master: String) -> URL {
        let stem = URL(fileURLWithPath: master).deletingPathExtension().lastPathComponent
        return directory(for: master).appendingPathComponent("\(stem).separation.json")
    }

    /// Nil when nothing has been separated, otherwise how it was made — so the
    /// panel can offer a rerun rather than pretend the setting took effect.
    static func provenance(for master: String) -> (remover: String, options: SeparationOptions)? {
        guard exists(for: master),
            let d = try? Data(contentsOf: provenanceURL(master)),
            let p = try? JSONDecoder().decode(Provenance.self, from: d)
        else { return nil }
        return (p.remover, p.options)
    }

    static func isStale(for master: String, remover: String, options: SeparationOptions) -> Bool {
        guard exists(for: master) else { return false }
        guard let p = provenance(for: master) else { return true }
        return p.remover != remover || p.options != options
    }

    /// Returns the two layer paths, running the model only when they are
    /// missing or were made with different settings.
    static func separate(
        master: String, remover id: String = "starnet2",
        options: SeparationOptions = SeparationOptions(), force: Bool = false
    ) throws -> (starless: URL, stars: URL) {
        guard !isLayer(master) else {
            throw NSError(
                domain: "AstroCat", code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "This is already a separated layer. Go back to the master to separate it."
                ])
        }

        let starless = starlessURL(for: master)
        let stars = starsURL(for: master)
        let model = remover(id)
        if !force, exists(for: master),
            !isStale(for: master, remover: id, options: options)
        {
            return (starless, stars)
        }
        try? FileManager.default.createDirectory(
            at: directory(for: master), withIntermediateDirectories: true)

        guard let tool = Tools.tool(model.tool), let binary = tool.path else {
            throw NSError(
                domain: "AstroCat", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(model.name) was not found. Set its path in the tools list, or install it."
                ])
        }

        // The model reads float FITS as-is, and our master is linear with a
        // median around 0.0018 — every tile is effectively black to something
        // trained on stretched images. Measured on the 211-frame stack, handing
        // it the linear frame clips 0.82% of green and 1.04% of blue to zero,
        // which is what the black speckles in the starless layer were; the same
        // frame stretched first clips none at all. So stretch, infer, then
        // invert exactly.
        let prepared = directory(for: master).appendingPathComponent("prepared.starnet.fit")
        var prep = AcMlPrep()
        var input = master
        if model.wantsStretchedInput {
            let ok = master.withCString { src in
                prepared.path.withCString { dst in ac_fits_prestretch(src, dst, &prep) }
            }
            guard ok == 1 else {
                throw NSError(
                    domain: "AstroCat", code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not prepare the master for star removal: "
                            + String(cString: ac_last_error())
                    ])
            }
            input = prepared.path
        }
        defer { try? FileManager.default.removeItem(at: prepared) }

        // Upsampling quadruples the working resolution, so the wait is minutes
        // rather than seconds on a large frame.
        try Tools.run(
            binary,
            model.arguments(input, starless.path, stars.path, options),
            timeout: options.upsample ? 1800 : 600)

        guard exists(for: master) else {
            throw NSError(
                domain: "AstroCat", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(model.name) reported success but wrote no layers."
                ])
        }

        for layer in [starless, stars] {
            // Measured against the master: its red median reappears as the
            // layer's blue. StarNet2 reads RGB and writes its planes in BGR.
            // This has to precede the inverse, whose midtones are per channel.
            if model.swapsRedBlue {
                _ = layer.path.withCString { ac_fits_swap_rb($0) }
            }
            if model.wantsStretchedInput {
                _ = layer.path.withCString { ac_fits_unstretch($0, &prep) }
            }
        }

        if let d = try? JSONEncoder().encode(Provenance(remover: id, options: options)) {
            try? d.write(to: provenanceURL(master), options: .atomic)
        }
        return (starless, stars)
    }
}
