import Foundation

struct Frame: Identifiable {
    var id: Int
    var session: Int
    var stars: Int
    var width: Int
    var height: Int
    var second: Int64
    var hfr: Float
    var ecc: Float
    var background: Float
    var noise: Float
    var quality: Float
    var exptime: Float
    var gain: Float
    var ccdTemp: Float
    var rejected: Bool
    var ra: Float
    var dec: Float
    var focalLen: Float
    var pixelSize: Float
    var scale: Float
    var hasWCS: Bool
    var trails: Int
    var telescope: String
    var filter: String
    var path: String
    var date: String
    var object: String
}

struct SessionInfo: Identifiable {
    var id: Int
    var night: String
    var first: Int
    var count: Int
    var kept: Int
    var exptime: Float
    var start: Int64
    var end: Int64
}

@MainActor
final class Catalog: ObservableObject {
    @Published private(set) var frames: [Frame] = []
    @Published private(set) var sessions: [SessionInfo] = []
    @Published var sessionIndex = 0
    @Published var error: String?
    @Published var dirty = false
    private(set) var root = ""

    var current: [Frame] {
        guard sessions.indices.contains(sessionIndex) else { return [] }
        let s = sessions[sessionIndex]
        return Array(frames[s.first..<(s.first + s.count)])
    }

    var keptCount: Int { current.filter { !$0.rejected }.count }
    var rejectedCount: Int { current.filter(\.rejected).count }

    func open(_ dir: String) {
        let n = dir.withCString { ac_catalog_open($0) }
        if n < 0 {
            error = "No catalog in \(dir)"
            frames = []
            sessions = []
            return
        }
        error = nil
        dirty = false
        root = dir
        reload()
    }

    func build(_ dir: String) {
        let n = dir.withCString { ac_catalog_build($0) }
        if n < 0 {
            error = "Could not ingest \(dir)"
            return
        }
        error = nil
        dirty = false
        root = dir
        reload()
    }

    private func reload() {
        var fs: [Frame] = []
        fs.reserveCapacity(Int(ac_frame_count()))
        for i in 0..<ac_frame_count() {
            var f = AcFrame()
            guard ac_frame(i, &f) == 1 else { continue }
            fs.append(
                Frame(
                    id: Int(f.id), session: Int(f.session), stars: Int(f.stars),
                    width: Int(f.width), height: Int(f.height), second: f.second,
                    hfr: f.hfr, ecc: f.ecc, background: f.background, noise: f.noise,
                    quality: f.quality, exptime: f.exptime, gain: f.gain,
                    ccdTemp: f.ccd_temp, rejected: f.rejected != 0,
                    ra: f.ra, dec: f.dec, focalLen: f.focal_len,
                    pixelSize: f.pixel_size, scale: f.scale, hasWCS: f.has_wcs != 0,
                    trails: Int(f.trails),
                    telescope: str(ac_frame_telescope(i)), filter: str(ac_frame_filter(i)),
                    path: str(ac_frame_path(i)), date: str(ac_frame_date(i)),
                    object: str(ac_frame_object(i))))
        }

        var ss: [SessionInfo] = []
        for i in 0..<ac_session_count() {
            var s = AcSession()
            guard ac_session(i, &s) == 1 else { continue }
            ss.append(
                SessionInfo(
                    id: Int(i), night: str(ac_session_night(i)), first: Int(s.first),
                    count: Int(s.count), kept: Int(s.kept), exptime: s.exptime,
                    start: s.start, end: s.end))
        }

        frames = fs
        sessions = ss
        // Open on the largest session, which is what you just shot.
        sessionIndex = ss.indices.max(by: { ss[$0].count < ss[$1].count }) ?? 0
    }

    private func str(_ p: UnsafePointer<CChar>?) -> String {
        guard let p else { return "" }
        return String(cString: p)
    }

    func setRejected(_ id: Int, _ rejected: Bool) {
        ac_set_rejected(UInt32(id), rejected ? 1 : 0)
        dirty = true
        if let i = frames.firstIndex(where: { $0.id == id }) {
            frames[i].rejected = rejected
        }
        refreshSessionCounts()
    }

    func cull(below threshold: Float) {
        _ = ac_cull_below(threshold)
        dirty = true
        for i in frames.indices {
            frames[i].rejected = frames[i].quality < threshold
        }
        refreshSessionCounts()
    }

    func save() {
        _ = ac_catalog_save()
        dirty = false
    }

    private func refreshSessionCounts() {
        for i in sessions.indices {
            let s = sessions[i]
            sessions[i].kept = frames[s.first..<(s.first + s.count)]
                .filter { !$0.rejected }.count
        }
    }
}
