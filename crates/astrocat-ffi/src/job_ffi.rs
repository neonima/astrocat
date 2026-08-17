//! Background jobs. Progress is polled rather than delivered by callback, so
//! nothing Rust-side ever calls into Swift and there is no reentrancy to reason
//! about.

use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Instant;

use astrocat_core::stack::{self, Stage, StackOpts, StackResult};

pub const IDLE: i32 = 0;
pub const RUNNING: i32 = 1;
pub const DONE: i32 = 2;
pub const CANCELLED: i32 = 3;
pub const FAILED: i32 = 4;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct AcJob {
    pub state: i32,
    pub stage: i32,
    pub done: u32,
    pub total: u32,
    pub elapsed: f32,
    pub eta: f32,
    pub frames_used: u32,
    pub frames_failed: u32,
    pub noise: f32,
    pub gradient: f32,
    pub clipped_pct: f32,
    pub rotation_min: f32,
    pub rotation_max: f32,
    pub drift_px: f32,
    pub stars: u32,
    pub analyse_s: f32,
    pub register_s: f32,
    pub combine_s: f32,
}

#[derive(Default)]
struct Job {
    state: i32,
    stage: i32,
    done: u32,
    total: u32,
    started: Option<Instant>,
    elapsed: f32,
    message: String,
    result: Option<StackResult>,
}

static JOB: Mutex<Option<Job>> = Mutex::new(None);
static CANCEL: AtomicBool = AtomicBool::new(false);

thread_local! {
    static MSG: std::cell::RefCell<CString> =
        std::cell::RefCell::new(CString::new("").unwrap());
}

/// Starts a stack over `paths` (newline separated) writing to `out`.
///
/// # Safety
/// Both arguments must be valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn ac_stack_start(
    paths: *const c_char,
    out: *const c_char,
    sigma_low: f32,
    sigma_high: f32,
    remove_gradient: i32,
    full_resolution: i32,
    drizzle: u32,
) -> i32 {
    if paths.is_null() || out.is_null() {
        return 0;
    }
    {
        let guard = JOB.lock().unwrap();
        if guard.as_ref().map(|j| j.state) == Some(RUNNING) {
            return 0;
        }
    }

    let Ok(list) = CStr::from_ptr(paths).to_str() else {
        return 0;
    };
    let Ok(out_path) = CStr::from_ptr(out).to_str() else {
        return 0;
    };

    let files: Vec<PathBuf> = list
        .split('\n')
        .filter(|s| !s.trim().is_empty())
        .map(PathBuf::from)
        .collect();
    if files.is_empty() {
        return 0;
    }
    let out_path = PathBuf::from(out_path);
    let opts = StackOpts {
        sigma_low,
        sigma_high,
        passes: 1,
        remove_gradient: remove_gradient != 0,
        full_resolution: full_resolution != 0,
        drizzle,
        pixfrac: 0.7,
    };

    CANCEL.store(false, Ordering::SeqCst);
    *JOB.lock().unwrap() = Some(Job {
        state: RUNNING,
        total: files.len() as u32,
        started: Some(Instant::now()),
        ..Default::default()
    });

    std::thread::spawn(move || {
        let outcome = stack::run(&files, &out_path, &opts, |stage, done, total| {
            if CANCEL.load(Ordering::SeqCst) {
                return false;
            }
            if let Some(j) = JOB.lock().unwrap().as_mut() {
                j.stage = match stage {
                    Stage::Analyse => 0,
                    Stage::Register => 1,
                    Stage::Combine => 2,
                };
                j.done = done as u32;
                j.total = total as u32;
                j.elapsed = j.started.map(|s| s.elapsed().as_secs_f32()).unwrap_or(0.0);
            }
            true
        });

        if let Some(j) = JOB.lock().unwrap().as_mut() {
            j.elapsed = j.started.map(|s| s.elapsed().as_secs_f32()).unwrap_or(0.0);
            match outcome {
                Ok(r) if r.frames_used == 0 => {
                    j.state = FAILED;
                    j.message = "No frames could be registered".into();
                }
                Ok(r) => {
                    j.message = format!(
                        "{} frames combined, {} failed to register",
                        r.frames_used, r.frames_failed
                    );
                    j.result = Some(r);
                    j.state = DONE;
                }
                Err(_) => {
                    j.state = CANCELLED;
                    j.message = "Cancelled".into();
                }
            }
        }
    });

    1
}

#[no_mangle]
pub extern "C" fn ac_job_cancel() {
    CANCEL.store(true, Ordering::SeqCst);
}

/// # Safety
/// `out` must point to a valid `AcJob`.
#[no_mangle]
pub unsafe extern "C" fn ac_job(out: *mut AcJob) -> i32 {
    if out.is_null() {
        return 0;
    }
    let guard = JOB.lock().unwrap();
    let Some(j) = guard.as_ref() else {
        *out = AcJob::default();
        return 1;
    };

    let frac = if j.total > 0 {
        j.done as f32 / j.total as f32
    } else {
        0.0
    };
    let eta = if frac > 0.02 {
        j.elapsed / frac - j.elapsed
    } else {
        0.0
    };

    let r = j.result.clone().unwrap_or_default();
    *out = AcJob {
        state: j.state,
        stage: j.stage,
        done: j.done,
        total: j.total,
        elapsed: j.elapsed,
        eta,
        frames_used: r.frames_used as u32,
        frames_failed: r.frames_failed as u32,
        noise: r.noise,
        gradient: r.gradient,
        clipped_pct: r.clipped_pct,
        rotation_min: r.rotation_min,
        rotation_max: r.rotation_max,
        drift_px: r.drift_px,
        stars: r.stars,
        analyse_s: r.analyse_s,
        register_s: r.register_s,
        combine_s: r.combine_s,
    };
    1
}

#[no_mangle]
pub extern "C" fn ac_job_message() -> *const c_char {
    let text = JOB
        .lock()
        .unwrap()
        .as_ref()
        .map(|j| j.message.clone())
        .unwrap_or_default();
    MSG.with(|m| {
        *m.borrow_mut() = CString::new(text).unwrap_or_else(|_| CString::new("").unwrap());
        m.borrow().as_ptr()
    })
}

pub struct AcThumb {
    pixels: Vec<u8>,
    width: u32,
    height: u32,
}

fn cache_path(project: &str, source: &str, max_dim: u32) -> PathBuf {
    let name = PathBuf::from(source)
        .file_stem()
        .map(|s| s.to_string_lossy().replace(['/', ' '], "_"))
        .unwrap_or_else(|| "frame".into());
    PathBuf::from(project)
        .join(".astrocat")
        .join("thumbs")
        .join(max_dim.to_string())
        .join(format!("{name}.rgba"))
}

/// Cached variant: a decode reads a 17 MB frame, so the result is kept in
/// `.astrocat/thumbs` and reused on later launches.
///
/// # Safety
/// Both paths must be valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn ac_thumbnail_cached(
    project: *const c_char,
    path: *const c_char,
    max_dim: u32,
) -> *mut AcThumb {
    let (Some(proj), Some(src)) = (
        if project.is_null() { None } else { CStr::from_ptr(project).to_str().ok() },
        if path.is_null() { None } else { CStr::from_ptr(path).to_str().ok() },
    ) else {
        return ac_thumbnail(path, max_dim);
    };

    let cache = cache_path(proj, src, max_dim);
    if let Ok(bytes) = std::fs::read(&cache) {
        if bytes.len() > 8 {
            let w = u32::from_le_bytes(bytes[0..4].try_into().unwrap_or([0; 4]));
            let h = u32::from_le_bytes(bytes[4..8].try_into().unwrap_or([0; 4]));
            if w > 0 && h > 0 && bytes.len() == 8 + (w * h * 4) as usize {
                return Box::into_raw(Box::new(AcThumb {
                    pixels: bytes[8..].to_vec(),
                    width: w,
                    height: h,
                }));
            }
        }
    }

    let made = ac_thumbnail(path, max_dim);
    if made.is_null() {
        return made;
    }
    let t = &*made;
    if let Some(dir) = cache.parent() {
        if std::fs::create_dir_all(dir).is_ok() {
            let mut out = Vec::with_capacity(8 + t.pixels.len());
            out.extend_from_slice(&t.width.to_le_bytes());
            out.extend_from_slice(&t.height.to_le_bytes());
            out.extend_from_slice(&t.pixels);
            let _ = std::fs::write(&cache, out);
        }
    }
    made
}

/// Stretched RGBA8 thumbnail, box-filtered down from the half-res debayer.
/// Returns null on failure; release with `ac_thumb_free`.
///
/// # Safety
/// `path` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn ac_thumbnail(path: *const c_char, max_dim: u32) -> *mut AcThumb {
    use astrocat_core::{auto_stf_channels, stretch};

    let Some(p) = (if path.is_null() { None } else { CStr::from_ptr(path).to_str().ok() })
    else {
        return std::ptr::null_mut();
    };
    let Ok(img) = astrocat_core::fits::read(&PathBuf::from(p)) else {
        return std::ptr::null_mut();
    };

    let pedestal = img.pedestal();
    let bitpix = img.header.int("BITPIX").unwrap_or(16);
    let rgb = astrocat_core::to_rgb_half(&img);
    let full = if bitpix < 0 {
        rgb.data.iter().copied().fold(f32::MIN, f32::max).max(1.0)
    } else {
        65535.0
    };
    let span = (full - pedestal).max(1.0);
    let norm: Vec<f32> = rgb
        .data
        .iter()
        .map(|v| ((v - pedestal) / span).clamp(0.0, 1.0))
        .collect();
    let stf = auto_stf_channels(&norm, 7);

    let step = ((rgb.width.max(rgb.height) as f32 / max_dim.max(1) as f32).ceil() as usize).max(1);
    let (tw, th) = (rgb.width / step, rgb.height / step);
    if tw == 0 || th == 0 {
        return std::ptr::null_mut();
    }

    let mut pixels = vec![0u8; tw * th * 4];
    for y in 0..th {
        for x in 0..tw {
            let mut acc = [0f32; 3];
            let mut n = 0f32;
            for sy in 0..step {
                for sx in 0..step {
                    let (px, py) = (x * step + sx, y * step + sy);
                    if px >= rgb.width || py >= rgb.height {
                        continue;
                    }
                    let o = (py * rgb.width + px) * 3;
                    for c in 0..3 {
                        acc[c] += norm[o + c];
                    }
                    n += 1.0;
                }
            }
            // FITS row 0 is the bottom; image buffers start at the top.
            let o = ((th - 1 - y) * tw + x) * 4;
            for c in 0..3 {
                pixels[o + c] = (stretch::apply(&stf[c], acc[c] / n.max(1.0)) * 255.0) as u8;
            }
            pixels[o + 3] = 255;
        }
    }

    Box::into_raw(Box::new(AcThumb {
        pixels,
        width: tw as u32,
        height: th as u32,
    }))
}

/// # Safety
/// `t` must come from `ac_thumbnail`.
#[no_mangle]
pub unsafe extern "C" fn ac_thumb_pixels(t: *const AcThumb) -> *const u8 {
    if t.is_null() { std::ptr::null() } else { (*t).pixels.as_ptr() }
}

/// # Safety
/// `t` must come from `ac_thumbnail`.
#[no_mangle]
pub unsafe extern "C" fn ac_thumb_width(t: *const AcThumb) -> u32 {
    if t.is_null() { 0 } else { (*t).width }
}

/// # Safety
/// `t` must come from `ac_thumbnail`.
#[no_mangle]
pub unsafe extern "C" fn ac_thumb_height(t: *const AcThumb) -> u32 {
    if t.is_null() { 0 } else { (*t).height }
}

/// # Safety
/// `t` must come from `ac_thumbnail` and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn ac_thumb_free(t: *mut AcThumb) {
    if !t.is_null() {
        drop(Box::from_raw(t));
    }
}

/// Fits the background per channel and writes 6 polynomial coefficients plus a
/// level for each into `out` (21 floats). The shader evaluates and subtracts
/// them, so extraction previews live without touching the data.
///
/// # Safety
/// `path` must be valid; `out` must have room for 21 floats.
#[no_mangle]
pub unsafe extern "C" fn ac_background_model(
    path: *const c_char,
    tolerance: f32,
    out: *mut f32,
) -> i32 {
    use astrocat_core::background::{self, BackgroundOpts};

    if out.is_null() {
        return 0;
    }
    let Some(p) = (if path.is_null() { None } else { CStr::from_ptr(path).to_str().ok() })
    else {
        return 0;
    };
    let Ok(img) = astrocat_core::fits::read(&PathBuf::from(p)) else {
        return 0;
    };

    let pedestal = if img.pedestal() > 1.0 { 0.0 } else { img.pedestal() };
    let bitpix = img.header.int("BITPIX").unwrap_or(16);
    let mut rgb = astrocat_core::to_rgb_half(&img);
    let span = if bitpix < 0 { 1.0 } else { (65535.0 - pedestal).max(1.0) };
    for v in rgb.data.iter_mut() {
        *v = (*v - pedestal) / span;
    }

    let opts = BackgroundOpts {
        tolerance: tolerance.clamp(0.5, 8.0),
        ..Default::default()
    };
    let slots = std::slice::from_raw_parts_mut(out, 21);
    slots.fill(0.0);

    for c in 0..3 {
        let plane: Vec<f32> = rgb.data.iter().skip(c).step_by(3).copied().collect();
        let Some(m) = background::fit(&plane, rgb.width, rgb.height, &opts) else {
            continue;
        };
        for (i, k) in m.coeffs.iter().take(6).enumerate() {
            slots[c * 7 + i] = *k as f32;
        }
        slots[c * 7 + 6] = m.level;
    }
    1
}

/// Peak-to-peak of the fitted background model on green. `after` refits once the
/// model has been subtracted, so the pair shows what extraction actually removed.
///
/// # Safety
/// `path` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn ac_gradient_amplitude(
    path: *const c_char,
    after: i32,
    tolerance: f32,
) -> f32 {
    use astrocat_core::background::{self, BackgroundOpts};

    let Some(p) = (if path.is_null() { None } else { CStr::from_ptr(path).to_str().ok() })
    else {
        return 0.0;
    };
    let Ok(img) = astrocat_core::fits::read(&PathBuf::from(p)) else {
        return 0.0;
    };

    let pedestal = img.pedestal();
    let bitpix = img.header.int("BITPIX").unwrap_or(16);
    let mut rgb = astrocat_core::to_rgb_half(&img);
    let span = if bitpix < 0 { 1.0 } else { (65535.0 - pedestal).max(1.0) };
    for v in rgb.data.iter_mut() {
        *v = (*v - pedestal) / span;
    }
    let mut green: Vec<f32> = rgb.data.iter().skip(1).step_by(3).copied().collect();
    let (w, h) = (rgb.width, rgb.height);
    let opts = BackgroundOpts {
        tolerance: tolerance.clamp(0.5, 8.0),
        ..Default::default()
    };

    let amplitude = |plane: &[f32]| -> f32 {
        let Some(m) = background::fit(plane, w, h, &opts) else { return 0.0 };
        let (mut lo, mut hi) = (f64::MAX, f64::MIN);
        for i in 0..=16 {
            for j in 0..=16 {
                let v = m.eval(i as f64 / 8.0 - 1.0, j as f64 / 8.0 - 1.0);
                lo = lo.min(v);
                hi = hi.max(v);
            }
        }
        (hi - lo) as f32
    };

    if after == 0 {
        return amplitude(&green);
    }
    if let Some(m) = background::fit(&green, w, h, &opts) {
        background::subtract(&mut green, w, h, &m);
    }
    amplitude(&green)
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct AcColorCal {
    pub ok: i32,
    pub stars_found: u32,
    pub stars_used: u32,
    pub offset_r: f32,
    pub offset_g: f32,
    pub offset_b: f32,
    pub gain_r: f32,
    pub gain_g: f32,
    pub gain_b: f32,
    pub sky_r: f32,
    pub sky_g: f32,
    pub sky_b: f32,
    pub sky_after: f32,
    pub ratio_r: f32,
    pub ratio_b: f32,
    pub scatter_r: f32,
    pub scatter_b: f32,
    pub shadows_r: f32,
    pub shadows_g: f32,
    pub shadows_b: f32,
    pub midtone_r: f32,
    pub midtone_g: f32,
    pub midtone_b: f32,
    pub linked_shadows: f32,
    pub linked_midtone: f32,
    pub matched: u32,
    pub slope_r: f32,
    pub slope_b: f32,
    pub colour_span: f32,
    pub white: f32,
    pub median_colour: f32,
    pub ms: f32,
}

/// Solving means detecting stars and matching triangles, which is far too much
/// to repeat for every panel redraw. One frame's solution is kept.
static SOLVED: Mutex<Option<(String, astrocat_core::wcs::Wcs, usize, f32)>> = Mutex::new(None);

/// The frame's own WCS if it carries one, otherwise a constrained solve against
/// the local catalogue. The second value is the factor between WCS pixels and
/// the half-resolution measurement grid: a header solution describes the full
/// sensor, one we fit ourselves describes the grid we fitted it on.
fn frame_wcs(
    path: &str,
    img: &astrocat_core::fits::Image,
    rgb: &astrocat_core::Rgb,
) -> Option<(astrocat_core::wcs::Wcs, f64, bool, usize, f32)> {
    use astrocat_core::wcs::Wcs;

    if let Some(w) = Wcs::from_header(&img.header, img.width, img.height) {
        let downsample = img.width as f64 / rgb.width.max(1) as f64;
        return Some((w, downsample, false, 0, 0.0));
    }

    if let Some((cached, w, inliers, rms)) = SOLVED.lock().unwrap().as_ref() {
        if cached == path {
            return Some((w.clone(), 1.0, true, *inliers, *rms));
        }
    }

    let hint_ra = img.header.float("RA")?;
    let hint_dec = img.header.float("DEC")?;
    // Nominal focal length is good to a couple of percent, which the fitted
    // scale absorbs; it only has to be close enough to project with.
    let full_scale = img.header.float("SCALE").unwrap_or_else(|| {
        let px = img.header.float("XPIXSZ").unwrap_or(2.9);
        let fl = img.header.float("FOCALLEN").unwrap_or(160.0).max(1.0);
        206.265 * px / fl
    });

    let downsample = img.width as f64 / rgb.width.max(1) as f64;
    let scale = full_scale * downsample;
    let (w, h) = (rgb.width as f64, rgb.height as f64);
    let field = 0.5 * (w * w + h * h).sqrt() * scale / 3600.0;

    let opts = astrocat_core::solve::SolveOpts::default();
    let catalogue = crate::sky_ffi::cone(hint_ra, hint_dec, field + opts.hint_slop_deg);
    if catalogue.len() < 50 {
        return None;
    }

    let green = astrocat_core::stars::green(rgb);
    let field_stars = astrocat_core::stars::detect(
        &green,
        rgb.width,
        rgb.height,
        &astrocat_core::stars::DetectOpts::default(),
    );

    let s = astrocat_core::solve::solve(
        &field_stars.stars,
        rgb.width,
        rgb.height,
        &catalogue,
        hint_ra,
        hint_dec,
        scale,
        &opts,
    )?;

    *SOLVED.lock().unwrap() = Some((path.to_string(), s.wcs.clone(), s.inliers, s.rms_px));
    Some((s.wcs, 1.0, true, s.inliers, s.rms_px))
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct AcCone {
    pub ra: f64,
    pub dec: f64,
    pub radius_deg: f64,
    pub scale_arcsec: f64,
    pub rotation_deg: f64,
    pub has_wcs: i32,
    pub width: u32,
    pub height: u32,
    /// 1 when AstroCat fitted this rather than reading it from the header.
    pub solved: i32,
    pub inliers: u32,
    pub rms_px: f32,
}

/// The sky region a catalogue query has to cover for this frame, read from its
/// own WCS. Returns 0 when the frame carries no solution.
///
/// # Safety
/// `path` must be a valid NUL-terminated string and `out` a writable `AcCone`.
#[no_mangle]
pub unsafe extern "C" fn ac_frame_cone(path: *const c_char, out: *mut AcCone) -> i32 {
    if out.is_null() {
        return 0;
    }
    *out = AcCone::default();

    let Some(p) = (if path.is_null() { None } else { CStr::from_ptr(path).to_str().ok() }) else {
        return 0;
    };
    let Ok(img) = astrocat_core::fits::read(&PathBuf::from(p)) else {
        return 0;
    };
    let (rgb, _) = astrocat_core::debayer::to_display(&img);
    let Some((wcs, _, solved, inliers, rms)) = frame_wcs(p, &img, &rgb) else {
        return 0;
    };

    let (ra, dec) = wcs.centre();
    *out = AcCone {
        ra,
        dec,
        radius_deg: wcs.radius_deg(),
        scale_arcsec: wcs.scale_arcsec(),
        rotation_deg: wcs.rotation_deg(),
        has_wcs: 1,
        width: img.width as u32,
        height: img.height as u32,
        solved: solved as i32,
        inliers: inliers as u32,
        rms_px: rms,
    };
    1
}

/// Returns 1 on success, -1 when the frame has no WCS, -2 when the catalogue
/// file is missing or holds too few usable rows, 0 for anything else. The
/// distinction matters: they need different things from whoever is asking.
///
/// # Safety
/// Both paths must be valid NUL-terminated strings and `out` writable.
#[no_mangle]
pub unsafe extern "C" fn ac_color_calibrate_catalog(
    path: *const c_char,
    white: f32,
    tolerance: f32,
    out: *mut AcColorCal,
) -> i32 {
    use astrocat_core::color::{self, CatalogueFit, ColorOpts, Reference};

    if out.is_null() {
        return 0;
    }
    *out = AcColorCal::default();

    let started = Instant::now();
    let Some(p) = (if path.is_null() { None } else { CStr::from_ptr(path).to_str().ok() }) else {
        return 0;
    };

    let Ok(img) = astrocat_core::fits::read(&PathBuf::from(p)) else {
        return 0;
    };
    let (rgb, _) = astrocat_core::debayer::to_display(&img);
    let Some((wcs, downsample, _, _, _)) = frame_wcs(p, &img, &rgb) else {
        return -1;
    };

    let (ra, dec) = wcs.centre();
    let stars = crate::sky_ffi::cone(ra, dec, wcs.radius_deg());
    if stars.len() < 50 {
        return -2;
    }

    let opts = ColorOpts {
        reference: Reference::Catalogue,
        tolerance,
        ..Default::default()
    };

    let Some(cal) = color::measure_with(
        &rgb,
        &opts,
        Some(CatalogueFit {
            wcs: &wcs,
            stars: &stars,
            white,
            downsample,
        }),
    ) else {
        return 0;
    };

    write_calibration(out, &cal, started);
    1
}

fn write_calibration(
    out: *mut AcColorCal,
    c: &astrocat_core::color::Calibration,
    started: Instant,
) {
    unsafe {
        *out = AcColorCal {
            ok: 1,
            stars_found: c.stars_found as u32,
            stars_used: c.stars_used as u32,
            offset_r: c.offset[0],
            offset_g: c.offset[1],
            offset_b: c.offset[2],
            gain_r: c.gain[0],
            gain_g: c.gain[1],
            gain_b: c.gain[2],
            sky_r: c.sky_before[0],
            sky_g: c.sky_before[1],
            sky_b: c.sky_before[2],
            sky_after: c.sky_after,
            ratio_r: c.ratio[0],
            ratio_b: c.ratio[2],
            scatter_r: c.scatter[0],
            scatter_b: c.scatter[2],
            shadows_r: c.shadows[0],
            shadows_g: c.shadows[1],
            shadows_b: c.shadows[2],
            midtone_r: c.midtone[0],
            midtone_g: c.midtone[1],
            midtone_b: c.midtone[2],
            linked_shadows: c.linked_shadows,
            linked_midtone: c.linked_midtone,
            matched: c.matched as u32,
            slope_r: c.slope[0],
            slope_b: c.slope[1],
            colour_span: c.colour_span,
            white: c.white,
            median_colour: c.median_colour,
            ms: started.elapsed().as_secs_f32() * 1000.0,
        };
    }
}

/// `reference` is 0 for sky background, 1 for the average field star. Offsets
/// and gains come back in the same units as the texture `ac_load_fits` builds,
/// so the shader can apply them without rescaling.
///
/// # Safety
/// `path` must be a valid NUL-terminated string and `out` a writable `AcColorCal`.
#[no_mangle]
pub unsafe extern "C" fn ac_color_calibrate(
    path: *const c_char,
    reference: i32,
    tolerance: f32,
    out: *mut AcColorCal,
) -> i32 {
    use astrocat_core::color::{self, ColorOpts, Reference};

    if out.is_null() {
        return 0;
    }
    *out = AcColorCal::default();

    let started = Instant::now();
    let Some(p) = (if path.is_null() { None } else { CStr::from_ptr(path).to_str().ok() }) else {
        return 0;
    };
    let Ok(img) = astrocat_core::fits::read(&PathBuf::from(p)) else {
        return 0;
    };

    let (rgb, _) = astrocat_core::debayer::to_display(&img);
    let opts = ColorOpts {
        reference: if reference == 0 {
            Reference::Background
        } else {
            Reference::StarField
        },
        tolerance,
        ..Default::default()
    };

    let Some(c) = color::measure(&rgb, &opts) else {
        return 0;
    };

    write_calibration(out, &c, started);
    1
}

/// # Safety
/// `filter` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn ac_filter_is_narrowband(filter: *const c_char) -> i32 {
    if filter.is_null() {
        return 0;
    }
    match CStr::from_ptr(filter).to_str() {
        Ok(f) if astrocat_core::color::is_narrowband(f) => 1,
        _ => 0,
    }
}

/// Re-writes a master to `dst` with target-specific conventions. Row order and
/// the pedestal are the two things Siril and PixInsight disagree about.
///
/// # Safety
/// Both paths must be valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn ac_export_fits(
    src: *const c_char,
    dst: *const c_char,
    bottom_up: i32,
    keep_pedestal: i32,
) -> i32 {
    let (Some(s), Some(d)) = (
        if src.is_null() { None } else { CStr::from_ptr(src).to_str().ok() },
        if dst.is_null() { None } else { CStr::from_ptr(dst).to_str().ok() },
    ) else {
        return 0;
    };

    let Ok(img) = astrocat_core::fits::read(&PathBuf::from(s)) else {
        return 0;
    };
    let n = img.width * img.height;
    let planes: Vec<Vec<f32>> = (0..img.planes.max(1))
        .map(|c| {
            let mut p = img.data[c * n..(c + 1) * n].to_vec();
            if bottom_up == 0 {
                // Flip to top-down for readers that expect it.
                let w = img.width;
                let mut flipped = vec![0f32; n];
                for y in 0..img.height {
                    let src_row = (img.height - 1 - y) * w;
                    flipped[y * w..y * w + w].copy_from_slice(&p[src_row..src_row + w]);
                }
                p = flipped;
            }
            p
        })
        .collect();

    let mut extra: Vec<(String, String, String)> = img
        .header
        .cards
        .iter()
        .filter(|(k, _)| {
            !matches!(
                k.as_str(),
                "SIMPLE" | "BITPIX" | "NAXIS" | "NAXIS1" | "NAXIS2" | "NAXIS3"
                    | "BZERO" | "BSCALE" | "EXTEND" | "ROWORDER" | "BAYERPAT"
            )
        })
        .map(|(k, v)| {
            let text = match v {
                astrocat_core::Value::Str(s) => format!("'{s}'"),
                astrocat_core::Value::Int(i) => i.to_string(),
                astrocat_core::Value::Float(f) => format!("{f}"),
                astrocat_core::Value::Bool(b) => (if *b { "T" } else { "F" }).to_string(),
            };
            (k.clone(), text, String::new())
        })
        .collect();

    extra.push((
        "ROWORDER".into(),
        (if bottom_up != 0 { "'BOTTOM-UP'" } else { "'TOP-DOWN'" }).into(),
        String::new(),
    ));
    if keep_pedestal == 0 {
        extra.retain(|(k, _, _)| k != "BIAS");
    }

    i32::from(
        astrocat_core::fits::write_f32(&PathBuf::from(d), img.width, img.height, &planes, &extra)
            .is_ok(),
    )
}

/// What a star-removal pass has to be handed and then undone by. Per channel,
/// because neutralising the cast before inference makes the frame look more like
/// what the model was trained on, and the inverse restores it exactly.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct AcMlPrep {
    pub midtone: [f32; 3],
    /// What the plane values were divided by, so the inverse can undo it.
    pub scale: f32,
}

unsafe fn cstr(p: *const c_char) -> Option<&'static str> {
    if p.is_null() {
        None
    } else {
        CStr::from_ptr(p).to_str().ok()
    }
}

fn read_planes(path: &str) -> Option<(astrocat_core::fits::Image, Vec<Vec<f32>>)> {
    let img = astrocat_core::fits::read(&PathBuf::from(path)).ok()?;
    if img.planes != 3 {
        return None;
    }
    let n = img.width * img.height;
    let planes = (0..3).map(|c| img.data[c * n..(c + 1) * n].to_vec()).collect();
    Some((img, planes))
}

fn median_of(v: &[f32], stride: usize) -> f32 {
    let mut s: Vec<f32> = v.iter().step_by(stride.max(1)).copied().collect();
    if s.is_empty() {
        return 0.0;
    }
    let k = s.len() / 2;
    s.select_nth_unstable_by(k, |a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    s[k]
}

/// Writes a stretched copy of `src` for a model that expects non-linear input,
/// and records what it takes to undo it. See `stretch::ml_midtone` for why the
/// linear frame cannot simply be handed over as-is.
///
/// # Safety
/// `src` and `dst` must be valid NUL-terminated strings and `out` writable.
#[no_mangle]
pub unsafe extern "C" fn ac_fits_prestretch(
    src: *const c_char,
    dst: *const c_char,
    out: *mut AcMlPrep,
) -> i32 {
    let (Some(s), Some(d)) = (cstr(src), cstr(dst)) else {
        return 0;
    };
    if out.is_null() {
        return 0;
    }
    let Some((img, mut planes)) = read_planes(s) else {
        return 0;
    };

    let brightest = planes
        .iter()
        .flat_map(|p| p.iter().copied())
        .fold(f32::MIN, f32::max);
    let scale = if brightest > 1.0 { brightest } else { 1.0 };

    let mut prep = AcMlPrep {
        midtone: [0.5; 3],
        scale,
    };
    for (c, plane) in planes.iter_mut().enumerate() {
        for v in plane.iter_mut() {
            *v = (*v / scale).clamp(0.0, 1.0);
        }
        let m = astrocat_core::stretch::ml_midtone(median_of(plane, 7));
        prep.midtone[c] = m;
        for v in plane.iter_mut() {
            *v = astrocat_core::mtf(m, *v);
        }
    }
    *out = prep;

    let extra = vec![(
        "HISTORY".into(),
        "'AstroCat: stretched for star removal, MTF per channel'".into(),
        String::new(),
    )];
    i32::from(
        astrocat_core::fits::write_f32(
            &PathBuf::from(d),
            img.width,
            img.height,
            &planes,
            &extra,
        )
        .is_ok(),
    )
}

/// Inverts `ac_fits_prestretch` in place, returning a layer to linear. Must run
/// after any channel reordering, or the per-channel midtones land on the wrong
/// planes.
///
/// # Safety
/// `path` must be a valid NUL-terminated string and `prep` a valid pointer.
#[no_mangle]
pub unsafe extern "C" fn ac_fits_unstretch(path: *const c_char, prep: *const AcMlPrep) -> i32 {
    let Some(p) = cstr(path) else { return 0 };
    if prep.is_null() {
        return 0;
    }
    let prep = *prep;
    let Some((img, mut planes)) = read_planes(p) else {
        return 0;
    };

    for (c, plane) in planes.iter_mut().enumerate() {
        let inverse = astrocat_core::stretch::ml_inverse(prep.midtone[c]);
        for v in plane.iter_mut() {
            *v = astrocat_core::mtf(inverse, (*v).clamp(0.0, 1.0)) * prep.scale;
        }
    }

    let extra = vec![(
        "HISTORY".into(),
        "'AstroCat: unstretched back to linear after star removal'".into(),
        String::new(),
    )];
    i32::from(
        astrocat_core::fits::write_f32(
            &PathBuf::from(p),
            img.width,
            img.height,
            &planes,
            &extra,
        )
        .is_ok(),
    )
}

/// Swaps the red and blue planes of a three-plane FITS, in place.
///
/// StarNet2 writes its FITS output in BGR plane order while reading RGB, so a
/// layer comes back with red and blue exchanged. Correcting the file rather
/// than the reader means Siril and PixInsight see it right too.
///
/// # Safety
/// `path` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn ac_fits_swap_rb(path: *const c_char) -> i32 {
    let Some(p) = (if path.is_null() { None } else { CStr::from_ptr(path).to_str().ok() }) else {
        return 0;
    };
    let target = PathBuf::from(p);
    let Ok(img) = astrocat_core::fits::read(&target) else {
        return 0;
    };
    if img.planes != 3 {
        return 0;
    }

    let n = img.width * img.height;
    let planes: Vec<Vec<f32>> = [2usize, 1, 0]
        .iter()
        .map(|c| img.data[c * n..(c + 1) * n].to_vec())
        .collect();

    let extra: Vec<(String, String, String)> = vec![(
        "HISTORY".into(),
        "'AstroCat: R and B planes swapped, StarNet2 writes BGR'".into(),
        String::new(),
    )];
    i32::from(
        astrocat_core::fits::write_f32(&target, img.width, img.height, &planes, &extra).is_ok(),
    )
}

/// Star count of an existing FITS, for the comparison table.
///
/// # Safety
/// `path` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn ac_measure_stars(path: *const c_char) -> u32 {
    let Some(p) = (if path.is_null() { None } else { CStr::from_ptr(path).to_str().ok() })
    else {
        return 0;
    };
    let Ok(img) = astrocat_core::fits::read(&PathBuf::from(p)) else {
        return 0;
    };
    let pedestal = img.pedestal();
    let bitpix = img.header.int("BITPIX").unwrap_or(16);
    let mut rgb = astrocat_core::to_rgb_half(&img);
    let span = if bitpix < 0 { 1.0 } else { (65535.0 - pedestal).max(1.0) };
    for v in rgb.data.iter_mut() {
        *v = (*v - pedestal) / span;
    }
    let g: Vec<f32> = rgb.data.iter().skip(1).step_by(3).copied().collect();
    astrocat_core::stars::detect(&g, rgb.width, rgb.height, &astrocat_core::DetectOpts::default())
        .stars
        .len() as u32
}

/// Measures an existing FITS the same way a stack result is measured, so the
/// comparison table holds like against like.
///
/// # Safety
/// `path` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn ac_measure_noise(path: *const c_char) -> f32 {
    let Some(p) = (if path.is_null() {
        None
    } else {
        CStr::from_ptr(path).to_str().ok()
    }) else {
        return 0.0;
    };
    let Ok(img) = astrocat_core::fits::read(&PathBuf::from(p)) else {
        return 0.0;
    };
    let pedestal = img.pedestal();
    let bitpix = img.header.int("BITPIX").unwrap_or(16);
    let mut rgb = astrocat_core::to_rgb_half(&img);
    let span = if bitpix < 0 { 1.0 } else { (65535.0 - pedestal).max(1.0) };
    for v in rgb.data.iter_mut() {
        *v = (*v - pedestal) / span;
    }
    let green: Vec<f32> = rgb.data.iter().skip(1).step_by(3).copied().collect();
    stack::tile_noise(&green, rgb.width, rgb.height)
}
