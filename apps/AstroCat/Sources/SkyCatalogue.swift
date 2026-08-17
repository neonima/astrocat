import Foundation

/// Tiled all-sky download from the ESA Gaia archive. The store lives in Rust;
/// this drives it one tile at a time, because the platform's own networking is
/// better at resuming, cancelling and reporting progress than anything worth
/// writing again in Rust.
@MainActor
final class SkyCatalogue: ObservableObject {
    struct Stats {
        var tilesTotal = 0
        var tilesDone = 0
        var stars: UInt64 = 0
        var bytes: UInt64 = 0
        var minDec: Double = 0
        var skyFraction: Double = 1
        var magLimit: Float = 0
        var open = false

        var complete: Bool { open && tilesTotal > 0 && tilesDone >= tilesTotal }
        var fraction: Double {
            tilesTotal > 0 ? Double(tilesDone) / Double(tilesTotal) : 0
        }
    }

    @Published private(set) var stats = Stats()
    @Published private(set) var downloading = false
    @Published private(set) var status = ""
    @Published var latitude: Double = 45.6455
    @Published var minAltitude: Double = 20
    @Published var magLimit: Float = 13

    private var cancelled = false

    /// Asked for explicitly so truncation is detectable: a response holding
    /// exactly this many rows has to be assumed cut short and the tile split
    /// rather than trusted.
    private let rowCap = 200_000
    /// Enough to hide the archive's per-request latency, low enough to stay a
    /// polite guest on a shared public service.
    private let concurrency = 4
    private let session = URLSession(configuration: .default)

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AstroCat/catalog", isDirectory: true)
    }

    var minDec: Double { ac_sky_visible_min_dec(latitude, minAltitude) }

    func open() {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = dir.path.withCString { ac_sky_open($0, minDec, magLimit) }
        refresh()
    }

    func refresh() {
        var s = AcCatalogStats()
        guard ac_sky_stats(&s) == 1 else {
            stats = Stats()
            return
        }
        stats = Stats(
            tilesTotal: Int(s.tiles_total), tilesDone: Int(s.tiles_done),
            stars: s.stars, bytes: s.bytes, minDec: s.min_dec,
            skyFraction: s.sky_fraction, magLimit: s.mag_limit, open: s.open == 1)
    }

    func cancel() {
        cancelled = true
        status = "Stopping…"
    }

    func start() {
        guard !downloading else { return }
        open()
        cancelled = false
        downloading = true
        status = "Starting…"
        Task { await run() }
    }

    private func run() async {
        var from: UInt32 = 0
        var consecutiveFailures = 0
        var attempts: [UInt32: Int] = [:]

        while !cancelled {
            var tile = AcTile()
            if ac_sky_next_tile(from, &tile) != 1 {
                // Wrap once to pick up tiles skipped after a failure earlier in
                // the pass; if there is nothing pending from the top either,
                // the catalogue is complete.
                if from == 0 { break }
                from = 0
                continue
            }

            // Reserve a batch before fetching: the tiles are independent, and
            // the archive's per-request cost is high enough that waiting for
            // one at a time wastes most of the wall clock.
            var batch = [tile]
            var scan = tile.index + 1
            while batch.count < concurrency {
                var next = AcTile()
                guard ac_sky_next_tile(scan, &next) == 1 else { break }
                batch.append(next)
                scan = next.index + 1
            }

            let label = String(
                format: "RA %.0f–%.0f°  Dec %+.0f–%+.0f°",
                tile.ra0, tile.ra1, tile.dec0, tile.dec1)
            status =
                "\(stats.tilesDone + batch.count) of \(stats.tilesTotal) · \(label)"
                + (batch.count > 1 ? " +\(batch.count - 1) more" : "")

            do {
                let fetched = try await withThrowingTaskGroup(
                    of: (UInt32, String).self
                ) { group -> [(UInt32, String)] in
                    for t in batch {
                        group.addTask { [self] in (t.index, try await fetch(t)) }
                    }
                    var out: [(UInt32, String)] = []
                    for try await result in group { out.append(result) }
                    return out
                }

                for (index, csv) in fetched {
                    let rows = csv.withCString { ac_sky_append(index, $0, magLimit) }
                    if rows >= rowCap {
                        // Truncated: this patch of sky is denser than one
                        // request can carry, so ask for it in quarters instead.
                        _ = ac_sky_split(index)
                    }
                }
                consecutiveFailures = 0
                from = 0
            } catch {
                consecutiveFailures += 1
                let tried = (attempts[tile.index] ?? 0) + 1
                attempts[tile.index] = tried

                if tried >= 2 {
                    // Twice is enough to believe it is the tile, not the link.
                    // A smaller box is both cheaper for the archive and more
                    // likely to come back inside the timeout.
                    _ = ac_sky_split(tile.index)
                    _ = ac_sky_flush()
                }
                if consecutiveFailures >= 6 {
                    status = "Stopped: \(error.localizedDescription)"
                    break
                }
                from = tile.index + 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                refresh()
                continue
            }

            _ = ac_sky_flush()
            refresh()
        }

        _ = ac_sky_flush()
        refresh()
        downloading = false
        if cancelled {
            status = "Paused · \(stats.tilesDone) of \(stats.tilesTotal) tiles"
        } else if stats.complete {
            status = "Complete"
        }
    }

    private func fetch(_ tile: AcTile) async throws -> String {
        let adql = """
            SELECT ra,dec,phot_g_mean_mag,phot_bp_mean_mag,phot_rp_mean_mag \
            FROM gaiadr3.gaia_source \
            WHERE ra>=\(tile.ra0) AND ra<\(tile.ra1) \
            AND dec>=\(tile.dec0) AND dec<\(tile.dec1) \
            AND phot_g_mean_mag<\(magLimit) \
            AND phot_bp_mean_mag IS NOT NULL AND phot_rp_mean_mag IS NOT NULL
            """

        var components = URLComponents(
            string: "https://gea.esac.esa.int/tap-server/tap/sync")!
        components.queryItems = [
            URLQueryItem(name: "REQUEST", value: "doQuery"),
            URLQueryItem(name: "LANG", value: "ADQL"),
            URLQueryItem(name: "FORMAT", value: "csv"),
            URLQueryItem(name: "MAXREC", value: "\(rowCap)"),
            URLQueryItem(name: "QUERY", value: adql),
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 300
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(
                domain: "AstroCat", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Gaia archive returned an error"])
        }

        let text = String(decoding: data, as: UTF8.self)
        // The archive answers a failed query with 200 and a VOTABLE error
        // document. Parsing that as CSV yields zero rows, which would mark the
        // tile complete and lose that patch of sky silently.
        guard text.hasPrefix("ra,dec,") else {
            let reason =
                text.contains("timeout") ? "the query timed out" : "the archive rejected the query"
            throw NSError(
                domain: "AstroCat", code: 4,
                userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return text
    }

    func erase() {
        ac_sky_close()
        try? FileManager.default.removeItem(at: Self.directory)
        open()
        status = ""
    }

    static func format(bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    static func format(stars: UInt64) -> String {
        if stars >= 1_000_000 {
            return String(format: "%.1fM", Double(stars) / 1_000_000)
        }
        if stars >= 1_000 {
            return String(format: "%.0fk", Double(stars) / 1_000)
        }
        return "\(stars)"
    }
}
