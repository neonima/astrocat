import Foundation
import simd

struct FrameMeta {
    var path = ""
    var width = 0
    var height = 0
    var srcWidth = 0
    var srcHeight = 0
    var planes = 0
    var shadows = SIMD3<Float>(repeating: 0)
    var midtone = SIMD3<Float>(repeating: 0.5)
    var median: Float = 0
    var mad: Float = 0
    var pedestal: Float = 0
    var exposure: Float = 0
    var gain: Float = 0
    var ccdTemp: Float = 0
    var loadMs: Float = 0
    var siteLat: Float = 0
    var fullScale: Float = 0
    var siteLong: Float = 0
    var object = ""
    var dateObs = ""
    var bayer = ""
    var telescope = ""
    var filter = ""
}

final class LoadedFrame {
    let meta: FrameMeta
    let pixels: UnsafePointer<UInt16>
    private let handle: OpaquePointer

    /// `scale` above zero forces the normalisation, so a frame derived from
    /// another can be put on the same scale as it.
    init(url: URL, scale: Float = 0) throws {
        var info = AcInfo()
        guard let handle = url.path.withCString({ ac_load_fits_scaled($0, scale, &info) }) else {
            throw NSError(
                domain: "AstroCat", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(cString: ac_last_error())])
        }
        guard let pixels = ac_buf_pixels(handle) else {
            ac_buf_free(handle)
            throw NSError(
                domain: "AstroCat", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "empty pixel buffer"])
        }

        self.handle = handle
        self.pixels = pixels

        var m = FrameMeta()
        m.path = url.path
        m.width = Int(info.width)
        m.height = Int(info.height)
        m.srcWidth = Int(info.src_width)
        m.srcHeight = Int(info.src_height)
        m.planes = Int(info.planes)
        m.shadows = SIMD3(info.shadows_r, info.shadows_g, info.shadows_b)
        m.midtone = SIMD3(info.midtone_r, info.midtone_g, info.midtone_b)
        m.median = info.median
        m.mad = info.mad
        m.pedestal = info.pedestal
        m.exposure = info.exposure
        m.gain = info.gain
        m.ccdTemp = info.ccd_temp
        m.loadMs = info.load_ms
        m.siteLat = info.site_lat
        m.fullScale = info.full_scale
        m.siteLong = info.site_long
        m.object = String(cString: ac_buf_object(handle))
        m.dateObs = String(cString: ac_buf_date_obs(handle))
        m.bayer = String(cString: ac_buf_bayer(handle))
        m.telescope = String(cString: ac_buf_telescope(handle))
        m.filter = String(cString: ac_buf_filter(handle))
        self.meta = m
    }

    deinit {
        ac_buf_free(handle)
    }
}
