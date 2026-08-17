//! Drives the exact FFI sequence the app uses, so a failure here is a failure
//! in the C ABI path rather than in the science underneath it.
use std::ffi::CString;

use astrocat_ffi::job_ffi::{ac_color_calibrate_catalog, ac_frame_cone, AcColorCal, AcCone};
use astrocat_ffi::sky_ffi::{ac_sky_open, ac_sky_stats, AcCatalogStats};

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = CString::new(args.next().expect("usage: ffi_catalog <catalog dir> <frame>")).unwrap();
    let frame = CString::new(args.next().expect("frame path")).unwrap();
    let white: f32 = args.next().and_then(|v| v.parse().ok()).unwrap_or(0.82);

    unsafe {
        println!("ac_sky_open -> {}", ac_sky_open(dir.as_ptr(), -24.3545, 13.0));

        let mut stats = AcCatalogStats::default();
        println!("ac_sky_stats -> {}", ac_sky_stats(&mut stats));
        println!(
            "  tiles {}/{}  stars {}  bytes {}  min_dec {:.3}",
            stats.tiles_done, stats.tiles_total, stats.stars, stats.bytes, stats.min_dec
        );

        let mut cone = AcCone::default();
        println!("ac_frame_cone -> {}", ac_frame_cone(frame.as_ptr(), &mut cone));
        println!(
            "  wcs {} centre {:.4} {:+.4} radius {:.3}",
            cone.has_wcs, cone.ra, cone.dec, cone.radius_deg
        );

        let mut cal = AcColorCal::default();
        let rc = ac_color_calibrate_catalog(frame.as_ptr(), white, 2.0, &mut cal);
        println!("white {white:.2} -> rc {rc}");
        if rc == 1 {
            println!(
                "  matched {}  R/G {:.4}  B/G {:.4}  gain {:.3}/{:.3}/{:.3}  span {:.2}",
                cal.matched, cal.ratio_r, cal.ratio_b, cal.gain_r, cal.gain_g, cal.gain_b,
                cal.colour_span
            );
            println!(
                "  slope R {:+.4}  B {:+.4} per BP-RP   median colour {:.3} vs white {:.2}",
                cal.slope_r, cal.slope_b, cal.median_colour, cal.white
            );
        }
    }
}
