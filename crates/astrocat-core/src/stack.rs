use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;

use crate::background::{self, BackgroundOpts};
use crate::register::{prepare, register_to, RegisterOpts, Transform};
use crate::{fits, stars, to_rgb_half, DetectOpts, Rgb};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Analyse,
    Register,
    Combine,
}

#[derive(Debug, Clone, Copy)]
pub struct StackOpts {
    pub sigma_low: f32,
    pub sigma_high: f32,
    pub passes: u32,
    pub remove_gradient: bool,
    pub full_resolution: bool,
    /// Output scale for drizzle: 0 disables it, 1 keeps sensor scale, 2 doubles.
    pub drizzle: u32,
    pub pixfrac: f32,
}

impl Default for StackOpts {
    fn default() -> Self {
        Self {
            sigma_low: 3.0,
            sigma_high: 3.0,
            passes: 1,
            remove_gradient: true,
            full_resolution: true,
            drizzle: 0,
            pixfrac: 0.7,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct StackResult {
    pub width: usize,
    pub height: usize,
    pub frames_used: usize,
    pub frames_failed: usize,
    pub clipped_pct: f32,
    /// 10th percentile of per-tile MAD on green — never a global MAD, which
    /// measures nebulosity once noise drops below it.
    pub noise: f32,
    pub gradient: f32,
    pub integration_s: f32,
    pub rotation_min: f32,
    pub rotation_max: f32,
    pub drift_px: f32,
    pub stars: u32,
    pub analyse_s: f32,
    pub register_s: f32,
    pub combine_s: f32,
}

pub struct Cancelled;

/// Optimal stacking weight, w = (signal / noise)^2, divided by HFR^2 so a
/// blurred frame cannot dominate on SNR alone. Under these weights SNR adds in
/// quadrature, so a poor frame can never make the result worse — it simply
/// contributes little. That is why weighting, not culling, is the right tool
/// for varying transparency.
fn weight(field: &crate::stars::StarField) -> f32 {
    let mut fluxes: Vec<f32> = field.stars.iter().map(|s| s.flux).collect();
    if fluxes.is_empty() || field.noise <= 0.0 {
        return 0.0;
    }
    let k = fluxes.len() / 2;
    fluxes.select_nth_unstable_by(k, |a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let signal = fluxes[k] * (field.stars.len() as f32).sqrt();

    let snr = signal / field.noise;
    let hfr = field.median_hfr().max(0.25);
    (snr * snr) / (hfr * hfr)
}

fn load(path: &Path, full: bool) -> std::io::Result<Rgb> {
    let img = fits::read(path)?;
    let pedestal = img.pedestal();
    let mut rgb = if full {
        crate::debayer::to_rgb_full(&img)
    } else {
        to_rgb_half(&img)
    };
    let span = (65535.0 - pedestal).max(1.0);
    for v in rgb.data.iter_mut() {
        *v = (*v - pedestal) / span;
    }
    Ok(rgb)
}

/// Catmull-Rom cubic. Bilinear is a low-pass filter, and on data where a star
/// spans one or two pixels that blur is most of what softens the result.
fn sample(rgb: &Rgb, x: f32, y: f32, c: usize) -> Option<f32> {
    let (x1, y1) = (x.floor() as isize, y.floor() as isize);
    if x1 < 1 || y1 < 1 || x1 + 2 >= rgb.width as isize || y1 + 2 >= rgb.height as isize {
        return None;
    }
    let (fx, fy) = (x - x1 as f32, y - y1 as f32);
    let at = |xx: isize, yy: isize| rgb.data[(yy as usize * rgb.width + xx as usize) * 3 + c];

    let cubic = |a: f32, b: f32, cc: f32, d: f32, t: f32| -> f32 {
        let t2 = t * t;
        let t3 = t2 * t;
        0.5 * ((2.0 * b)
            + (-a + cc) * t
            + (2.0 * a - 5.0 * b + 4.0 * cc - d) * t2
            + (-a + 3.0 * b - 3.0 * cc + d) * t3)
    };

    let mut rows = [0f32; 4];
    for (i, row) in rows.iter_mut().enumerate() {
        let yy = y1 - 1 + i as isize;
        *row = cubic(at(x1 - 1, yy), at(x1, yy), at(x1 + 1, yy), at(x1 + 2, yy), fx);
    }
    Some(cubic(rows[0], rows[1], rows[2], rows[3], fy))
}

/// A raw Bayer frame with each sample's colour known, ready to drizzle. No
/// demosaic: interpolating before stacking is the thing drizzle exists to avoid.
struct Mosaic {
    data: Vec<f32>,
    width: usize,
    height: usize,
    quad: [usize; 4],
}

fn load_mosaic(path: &Path) -> std::io::Result<Mosaic> {
    let img = fits::read(path)?;
    let pedestal = img.pedestal();
    let span = (65535.0 - pedestal).max(1.0);
    let pattern = img.bayer_pattern().unwrap_or("GRBG").to_string();
    let p = pattern.as_bytes();
    let idx = |c: u8| match c {
        b'R' | b'r' => 0usize,
        b'B' | b'b' => 2,
        _ => 1,
    };

    Ok(Mosaic {
        data: img.data.iter().map(|v| (v - pedestal) / span).collect(),
        width: img.width,
        height: img.height,
        quad: [
            idx(*p.first().unwrap_or(&b'G')),
            idx(*p.get(1).unwrap_or(&b'R')),
            idx(*p.get(2).unwrap_or(&b'B')),
            idx(*p.get(3).unwrap_or(&b'G')),
        ],
    })
}

/// Drops one frame's samples onto the output grid. `pixfrac` shrinks each drop
/// below a full pixel, which is what lets sub-pixel dither resolve detail the
/// sensor never sampled directly.
#[allow(clippy::too_many_arguments)]
fn drizzle_frame(
    m: &Mosaic,
    t: &Transform,
    scale: f32,
    pixfrac: f32,
    bg: f32,
    gain: f32,
    ref_bg: f32,
    weight: f32,
    ow: usize,
    oh: usize,
    sum: &mut [f32],
    wsum: &mut [f32],
) {
    let half = (pixfrac * 0.5).clamp(0.05, 0.5);

    for y in 0..m.height {
        for x in 0..m.width {
            let v = m.data[y * m.width + x];
            let c = m.quad[(y % 2) * 2 + (x % 2)];
            let value = (v - bg) * gain + ref_bg;

            let (tx, ty) = t.apply(x as f32, y as f32);
            let (cx, cy) = (tx * scale, ty * scale);

            let (x0, x1) = (cx - half, cx + half);
            let (y0, y1) = (cy - half, cy + half);
            let (ix0, ix1) = (x0.floor() as isize, x1.floor() as isize);
            let (iy0, iy1) = (y0.floor() as isize, y1.floor() as isize);

            for oy in iy0..=iy1 {
                if oy < 0 || oy >= oh as isize {
                    continue;
                }
                let overlap_y = (y1.min(oy as f32 + 1.0) - y0.max(oy as f32)).max(0.0);
                if overlap_y <= 0.0 {
                    continue;
                }
                for ox in ix0..=ix1 {
                    if ox < 0 || ox >= ow as isize {
                        continue;
                    }
                    let overlap_x = (x1.min(ox as f32 + 1.0) - x0.max(ox as f32)).max(0.0);
                    if overlap_x <= 0.0 {
                        continue;
                    }
                    let a = overlap_x * overlap_y * weight;
                    let o = ((oy as usize * ow + ox as usize) * 3) + c;
                    sum[o] += value * a;
                    wsum[o] += a;
                }
            }
        }
    }
}

/// Decodes the next frames on a background thread while the caller resamples
/// the current one. Reading and resampling now cost about the same, so
/// overlapping them nearly halves the wall clock.
fn stream(
    accepted: &[(PathBuf, Transform, f32, f32, f32)],
    order: &[usize],
    full: bool,
) -> std::sync::mpsc::IntoIter<(usize, Rgb, usize)> {
    let (tx, rx) = std::sync::mpsc::sync_channel::<(usize, Rgb, usize)>(2);
    let jobs: Vec<(usize, PathBuf)> = order
        .iter()
        .map(|&i| (i, accepted[i].0.clone()))
        .collect();

    std::thread::spawn(move || {
        for (k, (i, path)) in jobs.into_iter().enumerate() {
            let Ok(rgb) = load(&path, full) else { continue };
            if tx.send((k, rgb, i)).is_err() {
                return;
            }
        }
    });

    rx.into_iter()
}

fn median(v: &mut Vec<f32>) -> f32 {
    if v.is_empty() {
        return 0.0;
    }
    let k = v.len() / 2;
    v.select_nth_unstable_by(k, |a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    v[k]
}

/// Quietest tiles only: below the noise floor a global MAD measures structure.
pub fn tile_noise(plane: &[f32], w: usize, h: usize) -> f32 {
    const T: usize = 32;
    let mut mads: Vec<f32> = Vec::new();
    for ty in (0..h.saturating_sub(T)).step_by(T) {
        for tx in (0..w.saturating_sub(T)).step_by(T) {
            let mut vals: Vec<f32> = Vec::with_capacity(T * T);
            for y in ty..ty + T {
                vals.extend_from_slice(&plane[y * w + tx..y * w + tx + T]);
            }
            let m = median(&mut vals.clone());
            let mut devs: Vec<f32> = vals.iter().map(|v| (v - m).abs()).collect();
            mads.push(median(&mut devs) * 1.4826);
        }
    }
    if mads.is_empty() {
        return 0.0;
    }
    mads.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    mads[mads.len() / 10]
}

/// Everything Siril and PixInsight need to plate-solve and calibrate: optics,
/// pointing, site, and the binning we applied. BAYERPAT is deliberately absent —
/// the output is already debayered and leaving it would make both re-demosaic.
fn provenance(
    src: Option<&fits::Header>,
    accepted: &[(PathBuf, Transform, f32, f32, f32)],
    opts: &StackOpts,
    width: usize,
) -> Vec<(String, String, String)> {
    let mut out: Vec<(String, String, String)> = Vec::new();
    let mut card = |k: &str, v: String, c: &str| out.push((k.into(), v, c.into()));

    card("CREATOR", "'AstroCat'".into(), "");
    card("STACKCNT", accepted.len().to_string(), "frames combined");
    card("ROWORDER", "'BOTTOM-UP'".into(), "FITS convention");

    let Some(h) = src else { return out };

    let text = |k: &str| h.text(k).map(|v| format!("'{}'", v.trim()));
    let num = |k: &str| h.float(k);

    if let Some(v) = text("OBJECT") { card("OBJECT", v, "target"); }
    if let Some(v) = text("TELESCOP") { card("TELESCOP", v, ""); }
    if let Some(v) = text("INSTRUME") { card("INSTRUME", v, ""); }
    if let Some(v) = text("FILTER") { card("FILTER", v, ""); }
    if let Some(v) = text("DATE-OBS") { card("DATE-OBS", v, "first frame"); }
    if let Some(v) = text("IMAGETYP") { card("IMAGETYP", v, ""); }

    if let Some(v) = num("FOCALLEN") { card("FOCALLEN", format!("{v}"), "mm"); }
    if let Some(v) = num("APERTURE") { card("APERTURE", format!("{v}"), ""); }
    if let Some(v) = num("GAIN") { card("GAIN", format!("{v}"), ""); }
    if let Some(v) = num("CCD-TEMP") { card("CCD-TEMP", format!("{v}"), "C"); }
    if let Some(v) = num("SITELAT") { card("SITELAT", format!("{v}"), "deg"); }
    if let Some(v) = num("SITELONG") { card("SITELONG", format!("{v}"), "deg"); }
    if let Some(v) = num("RA") { card("RA", format!("{v}"), "deg, mount pointing"); }
    if let Some(v) = num("DEC") { card("DEC", format!("{v}"), "deg, mount pointing"); }

    // We bin 2x2, so the effective pixel is twice the sensor pixel.
    let binning = (h.float("NAXIS1").unwrap_or(width as f64 * 2.0) / width.max(1) as f64)
        .round()
        .max(1.0);
    if let Some(px) = num("XPIXSZ") {
        card("XPIXSZ", format!("{:.4}", px * binning), "um, after binning");
        card("YPIXSZ", format!("{:.4}", px * binning), "um, after binning");
        if let Some(fl) = num("FOCALLEN") {
            if fl > 0.0 {
                card(
                    "SCALE",
                    format!("{:.4}", 206.265 * px * binning / fl),
                    "arcsec/pixel",
                );
            }
        }
    }
    card("XBINNING", format!("{binning:.0}"), "");
    card("YBINNING", format!("{binning:.0}"), "");

    let exp = num("EXPTIME").unwrap_or(0.0);
    card("EXPTIME", format!("{exp}"), "per frame, s");
    card("LIVETIME", format!("{}", exp * accepted.len() as f64), "total, s");
    card("TOTALEXP", format!("{}", exp * accepted.len() as f64), "total, s");
    // Deliberately no BIAS card: the pedestal is already gone from the data,
    // and a reader that honours it would subtract it a second time.
    if let Some(v) = num("BIAS") {
        card("HISTORY", format!("'pedestal {v} removed'"), "");
    }

    // Describe the path actually taken. A HISTORY card is the only record of
    // how a master was made, so one that guesses is worse than one that is
    // missing — it will be believed.
    card(
        "HISTORY",
        match (opts.drizzle, opts.full_resolution) {
            (d, _) if d > 1 => format!("'drizzle {d}x, pixfrac {:.2}'", opts.pixfrac),
            (_, true) => "'full-res GRBG bilinear demosaic'".into(),
            (_, false) => "'half-res GRBG bin, no interpolation'".into(),
        },
        "",
    );
    card("HISTORY", "'star-based similarity registration'".into(), "");
    card(
        "HISTORY",
        format!("'sigma clip {:.1}/{:.1}'", opts.sigma_low, opts.sigma_high),
        "",
    );
    if opts.remove_gradient {
        card("HISTORY", "'background gradient removed'".into(), "");
    }
    out
}

pub fn run(
    paths: &[PathBuf],
    out: &Path,
    opts: &StackOpts,
    mut progress: impl FnMut(Stage, usize, usize) -> bool + Send,
) -> Result<StackResult, Cancelled> {
    let detect = DetectOpts::default();
    let t_analyse = std::time::Instant::now();

    // Every frame is independent here, so fan out across the cores and keep the
    // caller's single-threaded progress callback behind a mutex.
    let threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .min(paths.len().max(1));
    let done = AtomicUsize::new(0);
    let cancel = AtomicBool::new(false);
    let progress = Mutex::new(&mut progress);

    let mut analysed: Vec<Option<(PathBuf, stars::StarField, usize, usize)>> =
        (0..paths.len()).map(|_| None).collect();

    // Hand out frames one at a time rather than in equal blocks: this machine
    // mixes performance and efficiency cores, and static chunks leave the fast
    // ones idle waiting for the slow ones.
    let next = AtomicUsize::new(0);
    let slots: Vec<Mutex<&mut Option<(PathBuf, stars::StarField, usize, usize)>>> =
        analysed.iter_mut().map(Mutex::new).collect();

    std::thread::scope(|scope| {
        for _ in 0..threads {
            let (paths, detect, done, cancel, progress, next, slots) =
                (paths, &detect, &done, &cancel, &progress, &next, &slots);
            scope.spawn(move || loop {
                if cancel.load(Ordering::Relaxed) {
                    return;
                }
                let i = next.fetch_add(1, Ordering::Relaxed);
                let Some(p) = paths.get(i) else { return };

                if let Ok(rgb) = load(p, opts.full_resolution) {
                    let gray: Vec<f32> =
                        stars::green(&rgb).iter().map(|v| v.clamp(0.0, 1.0)).collect();
                    let f = stars::detect(&gray, rgb.width, rgb.height, detect);
                    if let Ok(mut slot) = slots[i].lock() {
                        **slot = Some((p.clone(), f, rgb.width, rgb.height));
                    }
                }

                let n = done.fetch_add(1, Ordering::Relaxed) + 1;
                if let Ok(mut cb) = progress.lock() {
                    if !cb(Stage::Analyse, n, paths.len()) {
                        cancel.store(true, Ordering::Relaxed);
                    }
                }
            });
        }
    });
    drop(slots);

    if cancel.load(Ordering::Relaxed) {
        return Err(Cancelled);
    }

    let (mut w, mut h) = (0usize, 0usize);
    let mut fields = Vec::with_capacity(analysed.len());
    for a in analysed.into_iter().flatten() {
        w = a.2;
        h = a.3;
        fields.push((a.0, a.1));
    }
    if fields.is_empty() || w == 0 {
        return Ok(StackResult::default());
    }

    let analyse_s = t_analyse.elapsed().as_secs_f32();
    let t_register = std::time::Instant::now();

    let reference = fields
        .iter()
        .enumerate()
        .max_by_key(|(_, (_, f))| f.stars.len())
        .map(|(i, _)| i)
        .unwrap_or(0);
    let ref_stars = fields[reference].1.stars.clone();
    let ref_bg = fields[reference].1.background;
    let ref_noise = fields[reference].1.noise;

    let ropts = RegisterOpts::default();
    let Some(prepared) = prepare(&ref_stars, &ropts) else {
        return Ok(StackResult::default());
    };
    let mut solved: Vec<Option<Transform>> = (0..fields.len()).map(|_| None).collect();
    done.store(0, Ordering::Relaxed);
    let next = AtomicUsize::new(0);
    let rslots: Vec<Mutex<&mut Option<Transform>>> =
        solved.iter_mut().map(Mutex::new).collect();

    std::thread::scope(|scope| {
        for _ in 0..threads {
            let (fields, prepared, ropts, done, cancel, progress, next, rslots) =
                (&fields, &prepared, &ropts, &done, &cancel, &progress, &next, &rslots);
            scope.spawn(move || loop {
                if cancel.load(Ordering::Relaxed) {
                    return;
                }
                let i = next.fetch_add(1, Ordering::Relaxed);
                if i >= fields.len() {
                    return;
                }

                let t = if i == reference {
                    Some(Transform::IDENTITY)
                } else {
                    register_to(&fields[i].1.stars, prepared, ropts).map(|m| m.transform)
                };
                if let Ok(mut slot) = rslots[i].lock() {
                    **slot = t;
                }

                let n = done.fetch_add(1, Ordering::Relaxed) + 1;
                if let Ok(mut cb) = progress.lock() {
                    if !cb(Stage::Register, n, fields.len()) {
                        cancel.store(true, Ordering::Relaxed);
                    }
                }
            });
        }
    });
    drop(rslots);

    if cancel.load(Ordering::Relaxed) {
        return Err(Cancelled);
    }

    // (path, transform, background, noise, weight)
    let mut accepted: Vec<(PathBuf, Transform, f32, f32, f32)> = Vec::new();
    let mut failed = 0usize;
    let (mut rot_lo, mut rot_hi, mut drift) = (f32::MAX, f32::MIN, 0.0f32);

    for (i, (path, field)) in fields.iter().enumerate() {
        let Some(t) = solved[i] else {
            failed += 1;
            continue;
        };
        rot_lo = rot_lo.min(t.rotation_deg());
        rot_hi = rot_hi.max(t.rotation_deg());
        drift = drift.max((t.tx * t.tx + t.ty * t.ty).sqrt());
        accepted.push((path.clone(), t, field.background, field.noise, weight(field)));
    }
    if accepted.is_empty() {
        return Ok(StackResult::default());
    }

    let register_s = t_register.elapsed().as_secs_f32();
    let t_combine = std::time::Instant::now();

    // Two passes so rejection stays memory-bounded: running mean and variance,
    // then a re-read that clips against it.
    let n = w * h * 3;
    let mut mean = vec![0f32; n];
    let mut m2 = vec![0f32; n];
    let mut seen = vec![0f32; n];
    if opts.drizzle > 0 {
        let scale = opts.drizzle as f32;
        let (ow, oh) = ((w as f32 * scale) as usize, (h as f32 * scale) as usize);
        let on = ow * oh * 3;
        let mut sum = vec![0f32; on];
        let mut wsum = vec![0f32; on];

        let every: Vec<usize> = (0..accepted.len()).collect();
        let jobs: Vec<(usize, PathBuf)> =
            every.iter().map(|&i| (i, accepted[i].0.clone())).collect();
        let (tx, rx) = std::sync::mpsc::sync_channel::<(usize, Mosaic, usize)>(2);
        std::thread::spawn(move || {
            for (k, (i, path)) in jobs.into_iter().enumerate() {
                let Ok(m) = load_mosaic(&path) else { continue };
                if tx.send((k, m, i)).is_err() {
                    return;
                }
            }
        });

        for (k, mosaic, i) in rx {
            if !{
                let mut cb = progress.lock().unwrap();
                cb(Stage::Combine, k, accepted.len())
            } {
                return Err(Cancelled);
            }
            let (_, t, bg, noise, wt) = &accepted[i];
            drizzle_frame(
                &mosaic,
                t,
                scale,
                opts.pixfrac,
                *bg,
                ref_noise / noise.max(1e-9),
                ref_bg,
                *wt,
                ow,
                oh,
                &mut sum,
                &mut wsum,
            );
        }

        let mut planes = vec![vec![0f32; ow * oh]; 3];
        let mut empty = 0usize;
        for idx in 0..on {
            let v = if wsum[idx] > 1e-6 {
                sum[idx] / wsum[idx]
            } else {
                empty += 1;
                0.0
            };
            planes[idx % 3][idx / 3] = v;
        }

        let mut gradient = 0.0f32;
        if opts.remove_gradient {
            let bopts = BackgroundOpts::default();
            for plane in planes.iter_mut() {
                if let Some(model) = background::fit(plane, ow, oh, &bopts) {
                    background::subtract(plane, ow, oh, &model);
                }
            }
            if let Some(model) = background::fit(&planes[1], ow, oh, &bopts) {
                gradient = model.level.abs();
            }
        }

        let stars_found = stars::detect(&planes[1], ow, oh, &detect).stars.len() as u32;
        let reference_header = fits::read(&accepted[0].0).ok().map(|i| i.header);
        let extra = provenance(reference_header.as_ref(), &accepted, opts, ow);
        let _ = fits::write_f32(out, ow, oh, &planes, &extra);

        return Ok(StackResult {
            width: ow,
            height: oh,
            frames_used: accepted.len(),
            frames_failed: failed,
            clipped_pct: 100.0 * empty as f32 / on as f32,
            noise: tile_noise(&planes[1], ow, oh),
            gradient,
            integration_s: accepted.len() as f32,
            rotation_min: if rot_lo == f32::MAX { 0.0 } else { rot_lo },
            rotation_max: if rot_hi == f32::MIN { 0.0 } else { rot_hi },
            drift_px: drift,
            stars: stars_found,
            analyse_s,
            register_s,
            combine_s: t_combine.elapsed().as_secs_f32(),
        });
    }

    // The first pass only establishes a clip threshold, and a spread of frames
    // estimates it as well as all of them — so sample rather than read
    // everything twice.
    let sample_step = (accepted.len() / 60).max(1);
    let sampled: Vec<usize> = (0..accepted.len()).step_by(sample_step).collect();
    let total = sampled.len() + accepted.len();

    for (k, rgb, i) in stream(&accepted, &sampled, opts.full_resolution) {
        if !{
            let mut cb = progress.lock().unwrap();
            cb(Stage::Combine, k, total)
        } {
            return Err(Cancelled);
        }
        let (_, t, bg, noise, _) = &accepted[i];
        let inv = t.invert();
        let gain = ref_noise / noise.max(1e-9);

        // Split the output into horizontal bands. Each thread owns its own
        // slice of the accumulators, so there is nothing shared to guard.
        let rows_per = h.div_ceil(threads).max(1);
        let stride = rows_per * w * 3;
        std::thread::scope(|scope| {
            let mut mean_bands = mean.chunks_mut(stride);
            let mut m2_bands = m2.chunks_mut(stride);
            let mut seen_bands = seen.chunks_mut(stride);
            let mut base = 0usize;

            while let (Some(mb), Some(vb), Some(sb)) =
                (mean_bands.next(), m2_bands.next(), seen_bands.next())
            {
                let start = base;
                base += mb.len();
                let rgb = &rgb;
                scope.spawn(move || {
                    for i in 0..mb.len() {
                        let idx = start + i;
                        let (p, c) = (idx / 3, idx % 3);
                        let (sx, sy) = inv.apply((p % w) as f32, (p / w) as f32);
                        let Some(v) = sample(rgb, sx, sy, c) else { continue };
                        let v = (v - bg) * gain + ref_bg;
                        sb[i] += 1.0;
                        let d = v - mb[i];
                        mb[i] += d / sb[i];
                        vb[i] += d * (v - mb[i]);
                    }
                });
            }
        });
    }

    let mut sum = vec![0f32; n];
    let mut cnt = vec![0f32; n];
    let mut clipped = 0usize;

    let every: Vec<usize> = (0..accepted.len()).collect();
    for (k, rgb, i) in stream(&accepted, &every, opts.full_resolution) {
        if !{
            let mut cb = progress.lock().unwrap();
            cb(Stage::Combine, sampled.len() + k, total)
        } {
            return Err(Cancelled);
        }
        let (_, t, bg, noise, wt) = &accepted[i];
        let inv = t.invert();
        let gain = ref_noise / noise.max(1e-9);
        let rows_per = h.div_ceil(threads).max(1);
        let stride = rows_per * w * 3;
        let clip_count = AtomicUsize::new(0);

        std::thread::scope(|scope| {
            let mut sum_bands = sum.chunks_mut(stride);
            let mut cnt_bands = cnt.chunks_mut(stride);
            let mut base = 0usize;

            while let (Some(su), Some(cn)) = (sum_bands.next(), cnt_bands.next()) {
                let start = base;
                base += su.len();
                let (rgb, mean, m2, seen, clip_count) =
                    (&rgb, &mean, &m2, &seen, &clip_count);
                scope.spawn(move || {
                    let mut local = 0usize;
                    for i in 0..su.len() {
                        let idx = start + i;
                        let (p, c) = (idx / 3, idx % 3);
                        let (sx, sy) = inv.apply((p % w) as f32, (p / w) as f32);
                        let Some(v) = sample(rgb, sx, sy, c) else { continue };
                        let v = (v - bg) * gain + ref_bg;
                        let sigma = if seen[idx] > 1.0 {
                            (m2[idx] / (seen[idx] - 1.0)).max(0.0).sqrt()
                        } else {
                            0.0
                        };
                        let d = v - mean[idx];
                        if sigma > 0.0
                            && (d > opts.sigma_high * sigma || -d > opts.sigma_low * sigma)
                        {
                            local += 1;
                            continue;
                        }
                        su[i] += v * wt;
                        cn[i] += wt;
                    }
                    clip_count.fetch_add(local, Ordering::Relaxed);
                });
            }
        });
        clipped += clip_count.load(Ordering::Relaxed);
    }

    let mut planes = vec![vec![0f32; w * h]; 3];
    for idx in 0..n {
        planes[idx % 3][idx / 3] = if cnt[idx] > 0.0 {
            sum[idx] / cnt[idx]
        } else {
            mean[idx]
        };
    }

    let mut gradient = 0.0f32;
    if opts.remove_gradient {
        let bopts = BackgroundOpts::default();
        for plane in planes.iter_mut() {
            if let Some(model) = background::fit(plane, w, h, &bopts) {
                let (mut lo, mut hi) = (f64::MAX, f64::MIN);
                for i in 0..=16 {
                    for j in 0..=16 {
                        let v = model.eval(i as f64 / 8.0 - 1.0, j as f64 / 8.0 - 1.0);
                        lo = lo.min(v);
                        hi = hi.max(v);
                    }
                }
                gradient = gradient.max((hi - lo) as f32);
                background::subtract(plane, w, h, &model);
            }
        }
    }

    let combine_s = t_combine.elapsed().as_secs_f32();
    let stars = {
        let g: Vec<f32> = planes[1].iter().copied().collect();
        stars::detect(&g, w, h, &detect).stars.len() as u32
    };
    let integration: f32 = accepted.len() as f32;
    let reference_header = fits::read(&accepted[0].0).ok().map(|i| i.header);
    let extra = provenance(reference_header.as_ref(), &accepted, opts, w);
    let _ = fits::write_f32(out, w, h, &planes, &extra);

    Ok(StackResult {
        width: w,
        height: h,
        frames_used: accepted.len(),
        frames_failed: failed,
        clipped_pct: 100.0 * clipped as f32 / (n as f32 * accepted.len() as f32),
        noise: tile_noise(&planes[1], w, h),
        gradient,
        integration_s: integration,
        rotation_min: if rot_lo == f32::MAX { 0.0 } else { rot_lo },
        rotation_max: if rot_hi == f32::MIN { 0.0 } else { rot_hi },
        drift_px: drift,
        stars,
        analyse_s,
        register_s,
        combine_s,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn history(opts: &StackOpts, width: usize) -> Vec<String> {
        let header = fits::Header {
            cards: vec![
                ("NAXIS1".into(), fits::Value::Int(2160)),
                ("EXPTIME".into(), fits::Value::Float(60.0)),
            ],
            bytes: 0,
        };
        provenance(Some(&header), &[], opts, width)
            .into_iter()
            .filter(|(k, _, _)| k == "HISTORY")
            .map(|(_, v, _)| v)
            .collect()
    }

    /// A HISTORY card is the only record of how a master was made, so one that
    /// describes a path the stack did not take will simply be believed.
    #[test]
    fn history_records_the_path_actually_taken() {
        let full = StackOpts {
            full_resolution: true,
            drizzle: 0,
            ..Default::default()
        };
        let cards = history(&full, 2160);
        assert!(
            cards.iter().any(|c| c.contains("full-res")),
            "full resolution not recorded: {cards:?}"
        );
        assert!(
            !cards.iter().any(|c| c.contains("half-res")),
            "claimed half-res on the full-res path: {cards:?}"
        );

        let binned = StackOpts {
            full_resolution: false,
            drizzle: 0,
            ..Default::default()
        };
        let cards = history(&binned, 1080);
        assert!(
            cards.iter().any(|c| c.contains("half-res")),
            "binning not recorded: {cards:?}"
        );

        let drizzled = StackOpts {
            full_resolution: true,
            drizzle: 2,
            pixfrac: 0.7,
            ..Default::default()
        };
        let cards = history(&drizzled, 4320);
        assert!(
            cards.iter().any(|c| c.contains("drizzle 2x")),
            "drizzle not recorded: {cards:?}"
        );
    }
}
