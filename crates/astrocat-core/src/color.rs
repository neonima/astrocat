use crate::background::{self, BackgroundOpts, Model};
use crate::debayer::Rgb;
use crate::stars::{self, DetectOpts, Star};
use crate::stretch::auto_stf_channels;
use crate::wcs::Wcs;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reference {
    /// Equalise the three sky backgrounds. Corrects the additive cast only —
    /// the sky is made neutral, star colours are left as the sensor recorded
    /// them.
    Background,
    /// Take the average field star as white. Corrects the multiplicative cast
    /// too, at the cost of assuming the mean colour of a few hundred field
    /// stars is neutral.
    StarField,
    /// Regress measured star colour against catalogue photometry and read the
    /// gains off a chosen white. Assumes nothing about this field.
    Catalogue,
}

#[derive(Debug, Clone, Copy)]
pub struct CatalogStar {
    pub ra: f64,
    pub dec: f64,
    pub g: f32,
    pub bp: f32,
    pub rp: f32,
}

impl CatalogStar {
    pub fn colour(&self) -> f32 {
        self.bp - self.rp
    }
}

pub struct CatalogueFit<'a> {
    pub wcs: &'a Wcs,
    pub stars: &'a [CatalogStar],
    /// `BP - RP` of the reference that should render neutral. G2V is 0.82.
    pub white: f32,
    /// The measurement runs at half resolution; catalogue positions come out
    /// of the WCS at full resolution.
    pub downsample: f64,
}

/// Gaia TAP returns CSV with a header row naming the columns, so read the
/// order from it rather than assuming one.
pub fn parse_gaia_csv(text: &str) -> Vec<CatalogStar> {
    let mut lines = text.lines();
    let Some(header) = lines.next() else {
        return Vec::new();
    };
    let cols: Vec<&str> = header.split(',').map(|s| s.trim()).collect();
    let at = |name: &str| cols.iter().position(|c| *c == name);
    let (Some(ra), Some(dec), Some(g), Some(bp), Some(rp)) = (
        at("ra"),
        at("dec"),
        at("phot_g_mean_mag"),
        at("phot_bp_mean_mag"),
        at("phot_rp_mean_mag"),
    ) else {
        return Vec::new();
    };
    let need = ra.max(dec).max(g).max(bp).max(rp);

    lines
        .filter_map(|line| {
            let f: Vec<&str> = line.split(',').collect();
            if f.len() <= need {
                return None;
            }
            Some(CatalogStar {
                ra: f[ra].trim().parse().ok()?,
                dec: f[dec].trim().parse().ok()?,
                g: f[g].trim().parse().ok()?,
                bp: f[bp].trim().parse().ok()?,
                rp: f[rp].trim().parse().ok()?,
            })
        })
        .collect()
}

#[derive(Debug, Clone, Copy)]
pub struct ColorOpts {
    pub reference: Reference,
    pub min_stars: usize,
    pub max_stars: usize,
    pub reject_sigma: f32,
    pub saturation: f32,
    pub tolerance: f32,
}

impl Default for ColorOpts {
    fn default() -> Self {
        Self {
            reference: Reference::StarField,
            min_stars: 30,
            max_stars: 800,
            reject_sigma: 2.5,
            saturation: 0.96,
            tolerance: 2.0,
        }
    }
}

/// The correction is affine per channel: `out = (in - offset) * gain`. Two free
/// parameters per channel satisfy the two constraints exactly — stars neutral
/// (multiplicative) and sky neutral (additive) — which a gain alone cannot.
#[derive(Debug, Clone, Copy)]
pub struct Calibration {
    pub offset: [f32; 3],
    pub gain: [f32; 3],
    pub sky_before: [f32; 3],
    /// Equal in all three channels by construction, so one number.
    pub sky_after: f32,
    /// Measured colour of the white reference: R/G, 1, B/G.
    pub ratio: [f32; 3],
    /// Spread of the per-star ratios. Wide scatter means the field average is
    /// not a reliable white.
    pub scatter: [f32; 3],
    pub stars_found: usize,
    pub stars_used: usize,
    /// Auto-stretch re-measured on the calibrated data. The stretch fitted to
    /// the uncalibrated frame no longer lands the background on target once the
    /// channels have moved.
    pub shadows: [f32; 3],
    pub midtone: [f32; 3],
    /// The same stretch fitted once over all three channels together. This is
    /// the one calibrated data wants: an unlinked STF normalises each channel
    /// by its own noise, which re-imposes a cast and undoes the calibration.
    pub linked_shadows: f32,
    pub linked_midtone: f32,
    /// Catalogue mode only. `slope` is d log10(ratio) / d(BP-RP); a slope near
    /// zero over a wide `colour_span` means the sensor barely separates colour.
    pub matched: usize,
    pub slope: [f32; 2],
    pub colour_span: f32,
    pub white: f32,
    /// Median `BP - RP` of the matched stars. Compared against `white` it says
    /// whether this field's average star is the white the field-star mode
    /// silently assumes it is.
    pub median_colour: f32,
}

impl Calibration {
    pub fn identity() -> Self {
        Self {
            offset: [0.0; 3],
            gain: [1.0; 3],
            sky_before: [0.0; 3],
            sky_after: 0.0,
            ratio: [1.0; 3],
            scatter: [0.0; 3],
            stars_found: 0,
            stars_used: 0,
            shadows: [0.0; 3],
            midtone: [0.5; 3],
            linked_shadows: 0.0,
            linked_midtone: 0.5,
            matched: 0,
            slope: [0.0; 2],
            colour_span: 0.0,
            white: 0.0,
            median_colour: 0.0,
        }
    }

    pub fn value(&self, channel: usize, x: f32) -> f32 {
        (x - self.offset[channel]) * self.gain[channel]
    }
}

/// Photometric colour work is meaningless through a dual-band or narrowband
/// filter: the passbands match no catalogue band, and forcing the sky neutral
/// destroys the Ha/OIII separation the data exists to capture.
pub fn is_narrowband(filter: &str) -> bool {
    let f: String = filter
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect::<String>()
        .to_ascii_uppercase();
    [
        "HA", "HALPHA", "OIII", "O3", "SII", "S2", "NARROW", "DUAL", "DUO", "TRIBAND", "QUADBAND",
        "LEXTREME", "LENHANCE", "LULTIMATE", "ALPT", "NBZ", "NB",
    ]
    .iter()
    .any(|k| f.contains(k))
}

fn plane_into(rgb: &Rgb, channel: usize, out: &mut [f32]) {
    for (i, v) in out.iter_mut().enumerate() {
        *v = rgb.data[i * 3 + channel];
    }
}

/// Subtracts the model outright, unlike `background::subtract` which restores
/// the mean level. Photometry wants a zero-mean sky so an aperture sum is pure
/// star flux.
fn flatten(plane: &mut [f32], w: usize, h: usize, model: &Model) {
    let mut b = Vec::new();
    for y in 0..h {
        let ny = 2.0 * y as f64 / (h.max(2) - 1) as f64 - 1.0;
        for x in 0..w {
            let nx = 2.0 * x as f64 / (w.max(2) - 1) as f64 - 1.0;
            background::basis(nx, ny, model.degree, &mut b);
            plane[y * w + x] -= model.dot(&b) as f32;
        }
    }
}

fn median(v: &mut [f32]) -> f32 {
    if v.is_empty() {
        return 0.0;
    }
    let k = v.len() / 2;
    v.select_nth_unstable_by(k, |a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    v[k]
}

fn median_of(it: impl Iterator<Item = f32>) -> f32 {
    let mut v: Vec<f32> = it.collect();
    median(&mut v)
}

fn mad_of(it: impl Iterator<Item = f32>, centre: f32) -> f32 {
    median_of(it.map(|x| (x - centre).abs())) * 1.4826
}

/// Clips both ratios together so a star rejected on one is rejected on both and
/// `stars_used` stays a single honest count.
fn robust_pair(pairs: &mut Vec<(f32, f32)>, sigma: f32) -> ([f32; 2], [f32; 2]) {
    let mut cr = median_of(pairs.iter().map(|p| p.0));
    let mut cb = median_of(pairs.iter().map(|p| p.1));
    let mut sr = mad_of(pairs.iter().map(|p| p.0), cr);
    let mut sb = mad_of(pairs.iter().map(|p| p.1), cb);

    for _ in 0..3 {
        if sr <= 0.0 || sb <= 0.0 {
            break;
        }
        let before = pairs.len();
        pairs.retain(|p| (p.0 - cr).abs() <= sigma * sr && (p.1 - cb).abs() <= sigma * sb);
        if pairs.len() < 8 || pairs.len() == before {
            break;
        }
        cr = median_of(pairs.iter().map(|p| p.0));
        cb = median_of(pairs.iter().map(|p| p.1));
        sr = mad_of(pairs.iter().map(|p| p.0), cr);
        sb = mad_of(pairs.iter().map(|p| p.1), cb);
    }

    ([cr, cb], [sr, sb])
}

fn isolated(stars: &[Star], w: usize, h: usize) -> Vec<bool> {
    const CELL: usize = 24;
    let gw = w / CELL + 1;
    let gh = h / CELL + 1;
    let mut grid: Vec<Vec<u32>> = vec![Vec::new(); gw * gh];
    for (i, s) in stars.iter().enumerate() {
        let gx = (s.x as usize / CELL).min(gw - 1);
        let gy = (s.y as usize / CELL).min(gh - 1);
        grid[gy * gw + gx].push(i as u32);
    }

    stars
        .iter()
        .enumerate()
        .map(|(i, s)| {
            let reach = aperture(s) + 4.0;
            let gx = (s.x as usize / CELL).min(gw - 1) as isize;
            let gy = (s.y as usize / CELL).min(gh - 1) as isize;
            for dy in -1isize..=1 {
                for dx in -1isize..=1 {
                    let (cx, cy) = (gx + dx, gy + dy);
                    if cx < 0 || cy < 0 || cx >= gw as isize || cy >= gh as isize {
                        continue;
                    }
                    for &j in &grid[cy as usize * gw + cx as usize] {
                        if j as usize == i {
                            continue;
                        }
                        let o = &stars[j as usize];
                        let d = ((o.x - s.x).powi(2) + (o.y - s.y).powi(2)).sqrt();
                        if d < reach {
                            return false;
                        }
                    }
                }
            }
            true
        })
        .collect()
}

/// Generous and identical in all three channels. Aperture photometry does not
/// need a resolved star — it needs an aperture that holds all the flux and does
/// not move between channels.
fn aperture(s: &Star) -> f32 {
    (s.hfr * 3.0).clamp(3.0, 10.0)
}

#[derive(Debug, Clone, Copy)]
struct StarColour {
    x: f32,
    y: f32,
    r: f32,
    b: f32,
}

fn star_colours(
    rgb: &Rgb,
    models: &[Model],
    field: &stars::StarField,
    opts: &ColorOpts,
) -> Vec<StarColour> {
    let (w, h) = (rgb.width, rgb.height);
    let keep = isolated(&field.stars, w, h);

    let mut candidates: Vec<&Star> = field
        .stars
        .iter()
        .zip(&keep)
        .filter(|(s, iso)| {
            **iso
                && !s.saturated
                && s.pixels >= 5
                && s.peak >= field.background + 10.0 * field.noise
        })
        .map(|(s, _)| s)
        .collect();
    candidates.sort_by(|a, b| {
        b.flux
            .partial_cmp(&a.flux)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    candidates.truncate(opts.max_stars);

    let mut basis = Vec::new();
    let mut out = Vec::with_capacity(candidates.len());

    for s in candidates {
        let r = aperture(s);
        let x0 = (s.x - r).floor() as isize;
        let x1 = (s.x + r).ceil() as isize;
        let y0 = (s.y - r).floor() as isize;
        let y1 = (s.y + r).ceil() as isize;
        if x0 < 0 || y0 < 0 || x1 >= w as isize || y1 >= h as isize {
            continue;
        }

        let mut sum = [0.0f64; 3];
        let mut saturated = false;
        for y in y0..=y1 {
            let ny = 2.0 * y as f64 / (h - 1) as f64 - 1.0;
            for x in x0..=x1 {
                let dx = x as f32 - s.x;
                let dy = y as f32 - s.y;
                if dx * dx + dy * dy > r * r {
                    continue;
                }
                let nx = 2.0 * x as f64 / (w - 1) as f64 - 1.0;
                background::basis(nx, ny, models[0].degree, &mut basis);
                let i = y as usize * w + x as usize;
                for c in 0..3 {
                    let v = rgb.data[i * 3 + c];
                    // Checked per channel on the raw values: a star clipped in
                    // red but not green reads as neutral and would drag the
                    // white reference toward grey.
                    if v >= opts.saturation {
                        saturated = true;
                    }
                    sum[c] += (v as f64) - models[c].dot(&basis);
                }
            }
        }

        if saturated || sum.iter().any(|v| *v <= 0.0) {
            continue;
        }
        out.push(StarColour {
            x: s.x,
            y: s.y,
            r: (sum[0] / sum[1]) as f32,
            b: (sum[2] / sum[1]) as f32,
        });
    }

    out
}

/// Least squares with iterative clipping. Returns intercept, slope and the
/// residual sigma of the surviving points.
fn robust_line(points: &[(f32, f32)], sigma: f32) -> Option<(f32, f32, f32, usize)> {
    let mut keep: Vec<(f32, f32)> = points.to_vec();
    let mut best = None;

    for _ in 0..4 {
        let n = keep.len() as f64;
        if n < 8.0 {
            break;
        }
        let sx: f64 = keep.iter().map(|p| p.0 as f64).sum();
        let sy: f64 = keep.iter().map(|p| p.1 as f64).sum();
        let sxx: f64 = keep.iter().map(|p| (p.0 as f64) * (p.0 as f64)).sum();
        let sxy: f64 = keep.iter().map(|p| (p.0 as f64) * (p.1 as f64)).sum();
        let denom = n * sxx - sx * sx;
        if denom.abs() < 1e-12 {
            break;
        }
        let slope = (n * sxy - sx * sy) / denom;
        let intercept = (sy - slope * sx) / n;

        let residual = |p: &(f32, f32)| (p.1 as f64 - intercept - slope * p.0 as f64).abs() as f32;
        let mut devs: Vec<f32> = keep.iter().map(residual).collect();
        let spread = median(&mut devs) * 1.4826;
        best = Some((intercept as f32, slope as f32, spread, keep.len()));

        if spread <= 0.0 {
            break;
        }
        let before = keep.len();
        keep.retain(|p| residual(p) <= sigma * spread);
        if keep.len() == before || keep.len() < 8 {
            break;
        }
    }
    best
}

fn interquartile(values: &mut [f32]) -> f32 {
    if values.len() < 4 {
        return 0.0;
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    values[values.len() * 3 / 4] - values[values.len() / 4]
}

/// Pairs each measured star with a catalogue entry and regresses colour against
/// colour. The gains are the fit evaluated at the white reference — which is
/// what makes this independent of what the field happens to contain.
fn catalogue_ratios(
    colours: &[StarColour],
    fit: &CatalogueFit,
    opts: &ColorOpts,
) -> Option<([f32; 3], [f32; 3], [f32; 2], usize, f32, f32)> {
    const MATCH_PX: f32 = 3.0;

    let mut projected: Vec<(f32, f32, f32)> = Vec::with_capacity(fit.stars.len());
    for s in fit.stars {
        let Some((fx, fy)) = fit.wcs.world_to_pixel(s.ra, s.dec) else {
            continue;
        };
        let x = ((fx - 0.5) / fit.downsample) as f32;
        let y = ((fy - 0.5) / fit.downsample) as f32;
        // Extreme colours are where the linear fit is least trustworthy and
        // where Gaia's own BP/RP photometry degrades.
        let c = s.colour();
        if c.is_finite() && (-0.5..4.0).contains(&c) {
            projected.push((x, y, c));
        }
    }
    if projected.len() < opts.min_stars {
        return None;
    }

    let mut pairs: Vec<(f32, f32, f32)> = Vec::new();
    for m in colours {
        let mut best = (f32::MAX, 0.0f32);
        let mut second = f32::MAX;
        for (x, y, c) in &projected {
            let d = (x - m.x).powi(2) + (y - m.y).powi(2);
            if d < best.0 {
                second = best.0;
                best = (d, *c);
            } else if d < second {
                second = d;
            }
        }
        // A unique match only. Two catalogue stars inside the aperture means
        // the measured flux is a blend and the colour is meaningless.
        if best.0 <= MATCH_PX * MATCH_PX && second > (3.0 * MATCH_PX) * (3.0 * MATCH_PX) {
            pairs.push((best.1, m.r, m.b));
        }
    }
    if pairs.len() < opts.min_stars {
        return None;
    }

    let mut indices: Vec<f32> = pairs.iter().map(|p| p.0).collect();
    let span = interquartile(&mut indices);
    let median_colour = indices[indices.len() / 2];

    let logs = |pick: fn(&(f32, f32, f32)) -> f32| -> Vec<(f32, f32)> {
        pairs
            .iter()
            .filter(|p| pick(p) > 0.0)
            .map(|p| (p.0, pick(p).log10()))
            .collect()
    };
    let lr = logs(|p| p.1);
    let lb = logs(|p| p.2);

    // Too narrow a colour range and the slope is fitted to noise. Fall back to
    // a flat offset, which is the field-star answer restricted to matched stars.
    let flat = span < 0.25;
    let solve = |pts: &[(f32, f32)]| -> Option<(f32, f32, f32)> {
        if flat {
            let mut v: Vec<f32> = pts.iter().map(|p| p.1).collect();
            let m = median(&mut v);
            let s = mad_of(pts.iter().map(|p| p.1), m);
            Some((m, 0.0, s))
        } else {
            robust_line(pts, opts.reject_sigma).map(|(a, b, s, _)| (a, b, s))
        }
    };

    let (ar, br, sr) = solve(&lr)?;
    let (ab, bb, sb) = solve(&lb)?;

    let at_white = |a: f32, b: f32| 10f32.powf(a + b * fit.white);
    let ratio = [at_white(ar, br), 1.0, at_white(ab, bb)];
    // Convert the log-space residual into the same units the ratios are in, so
    // it reads the same way as the field-star scatter.
    let scatter = [
        ratio[0] * (10f32.powf(sr) - 1.0),
        0.0,
        ratio[2] * (10f32.powf(sb) - 1.0),
    ];

    Some((ratio, scatter, [br, bb], pairs.len(), span, median_colour))
}

pub fn measure(rgb: &Rgb, opts: &ColorOpts) -> Option<Calibration> {
    measure_with(rgb, opts, None)
}

pub fn measure_with(
    rgb: &Rgb,
    opts: &ColorOpts,
    catalogue: Option<CatalogueFit>,
) -> Option<Calibration> {
    let (w, h) = (rgb.width, rgb.height);
    let n = w * h;
    if n == 0 || rgb.data.len() < n * 3 {
        return None;
    }

    let bopts = BackgroundOpts {
        tolerance: opts.tolerance.clamp(0.5, 8.0),
        ..Default::default()
    };

    let mut plane = vec![0f32; n];
    let mut models: Vec<Model> = Vec::with_capacity(3);
    let mut sky = [0f32; 3];
    let mut flat_green = Vec::new();

    for c in 0..3 {
        plane_into(rgb, c, &mut plane);
        let model = background::fit(&plane, w, h, &bopts)?;
        sky[c] = model.level;
        if c == 1 {
            let mut g = plane.clone();
            flatten(&mut g, w, h, &model);
            flat_green = g;
        }
        models.push(model);
    }

    let mut ratio = [1.0f32; 3];
    let mut scatter = [0.0f32; 3];
    let mut stars_found = 0;
    let mut stars_used = 0;
    let mut matched = 0;
    let mut slope = [0.0f32; 2];
    let mut colour_span = 0.0f32;
    let mut median_colour = 0.0f32;
    let catalogue_white = catalogue.as_ref().map_or(0.0, |c| c.white);

    if opts.reference != Reference::Background {
        let field = stars::detect(
            &flat_green,
            w,
            h,
            &DetectOpts {
                sigma: 6.0,
                min_pixels: 5,
                saturation: opts.saturation,
                ..Default::default()
            },
        );
        stars_found = field.stars.len();
        let colours = star_colours(rgb, &models, &field, opts);

        match catalogue {
            // Asking for a catalogue calibration and being handed a field-star
            // one is the kind of substitution that reads as success. If the
            // catalogue cannot answer, say so rather than answering differently.
            _ if opts.reference == Reference::Catalogue => {
                let fit = catalogue?;
                let (r, s, b, n, span, med) = catalogue_ratios(&colours, &fit, opts)?;
                ratio = r;
                scatter = s;
                slope = b;
                matched = n;
                stars_used = n;
                colour_span = span;
                median_colour = med;
            }
            _ => {
                let mut pairs: Vec<(f32, f32)> =
                    colours.iter().map(|c| (c.r, c.b)).collect();
                if pairs.len() >= opts.min_stars {
                    let (centre, spread) = robust_pair(&mut pairs, opts.reject_sigma);
                    if centre[0] > 1e-4 && centre[1] > 1e-4 {
                        ratio = [centre[0], 1.0, centre[1]];
                        scatter = [spread[0], 0.0, spread[1]];
                        stars_used = pairs.len();
                    }
                }
            }
        }
    }

    // Gain is fixed by the star colours; normalising to a maximum of one means
    // the correction only ever attenuates, so nothing is pushed into clipping.
    let mut gain = [
        1.0 / ratio[0].max(1e-4),
        1.0,
        1.0 / ratio[2].max(1e-4),
    ];
    let peak = gain.iter().copied().fold(f32::MIN, f32::max);
    for g in gain.iter_mut() {
        *g /= peak.max(1e-6);
    }

    // With gain settled, the offsets are what is left to place all three
    // backgrounds on a common level. Anchoring on the lowest keeps every offset
    // non-negative, so no channel is lifted into invented signal.
    let level = (0..3)
        .map(|c| sky[c] * gain[c])
        .fold(f32::MAX, f32::min);
    let offset: [f32; 3] = std::array::from_fn(|c| sky[c] - level / gain[c].max(1e-6));

    let stride = (n / 300_000).max(1);
    let mut sample = Vec::with_capacity((n / stride + 1) * 3);
    for i in (0..n).step_by(stride) {
        for c in 0..3 {
            sample.push((rgb.data[i * 3 + c] - offset[c]) * gain[c]);
        }
    }
    let stf = auto_stf_channels(&sample, 1);
    let pooled = crate::stretch::auto_stf(&sample, 1);

    Some(Calibration {
        offset,
        gain,
        sky_before: sky,
        sky_after: level,
        ratio,
        scatter,
        stars_found,
        stars_used,
        shadows: std::array::from_fn(|c| stf[c].shadows),
        midtone: std::array::from_fn(|c| stf[c].midtone),
        linked_shadows: pooled.shadows,
        linked_midtone: pooled.midtone,
        matched,
        slope,
        colour_span,
        white: catalogue_white,
        median_colour,
    })
}

pub fn apply(rgb: &mut Rgb, cal: &Calibration) {
    for i in 0..rgb.pixels() {
        for c in 0..3 {
            rgb.data[i * 3 + c] = cal.value(c, rgb.data[i * 3 + c]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `sky` is added after `gain` scales the star flux, which is how a camera
    /// sees it: the sky offset is not subject to the channel response of the
    /// signal above it.
    fn synth(w: usize, h: usize, sky: [f32; 3], gain: [f32; 3], stars: usize) -> Rgb {
        let mut data = vec![0f32; w * h * 3];
        let mut seed = 0x9E37_79B9u32;
        let mut rand = move || {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (seed >> 16) as f32 / 65535.0
        };

        for i in 0..w * h {
            for c in 0..3 {
                data[i * 3 + c] = sky[c] + (rand() - 0.5) * 0.0006;
            }
        }

        let cols = (stars as f32).sqrt().ceil() as usize;
        let step = w / (cols + 1);
        for k in 0..stars {
            let cx = (step * (1 + k % cols)) as f32 + rand() * 2.0;
            let cy = (step * (1 + k / cols)) as f32 + rand() * 2.0;
            let amp = 0.05 + rand() * 0.35;
            let sigma = 1.4f32;
            let rad = 6isize;
            for dy in -rad..=rad {
                for dx in -rad..=rad {
                    let x = cx as isize + dx;
                    let y = cy as isize + dy;
                    if x < 0 || y < 0 || x >= w as isize || y >= h as isize {
                        continue;
                    }
                    let ddx = x as f32 - cx;
                    let ddy = y as f32 - cy;
                    let v = amp * (-(ddx * ddx + ddy * ddy) / (2.0 * sigma * sigma)).exp();
                    let i = y as usize * w + x as usize;
                    for c in 0..3 {
                        data[i * 3 + c] += v * gain[c];
                    }
                }
            }
        }

        Rgb {
            width: w,
            height: h,
            data,
        }
    }

    #[test]
    fn background_reference_neutralises_the_sky() {
        let rgb = synth(256, 256, [0.030, 0.020, 0.026], [1.0; 3], 40);
        let cal = measure(
            &rgb,
            &ColorOpts {
                reference: Reference::Background,
                ..Default::default()
            },
        )
        .expect("measure");

        assert_eq!(cal.gain, [1.0; 3]);
        for c in 0..3 {
            let after = cal.value(c, cal.sky_before[c]);
            assert!(
                (after - cal.sky_after).abs() < 1e-5,
                "channel {c} sky landed at {after}, expected {}",
                cal.sky_after
            );
            assert!(cal.offset[c] >= 0.0, "offset {c} is negative");
        }
    }

    #[test]
    fn star_reference_recovers_the_channel_gains() {
        let truth = [1.35f32, 1.0, 0.75];
        let rgb = synth(384, 384, [0.030, 0.020, 0.026], truth, 90);
        let cal = measure(&rgb, &ColorOpts::default()).expect("measure");

        assert!(cal.stars_used >= 30, "only {} stars used", cal.stars_used);
        for c in [0usize, 2] {
            let err = (cal.ratio[c] - truth[c]).abs() / truth[c];
            assert!(err < 0.05, "channel {c} ratio {} vs {}", cal.ratio[c], truth[c]);
        }

        // A neutral star must come out neutral: gain has to undo the response.
        let corrected: Vec<f32> = (0..3).map(|c| truth[c] * cal.gain[c]).collect();
        for c in [0usize, 2] {
            let err = (corrected[c] - corrected[1]).abs() / corrected[1];
            assert!(err < 0.05, "corrected star colour {corrected:?}");
        }
    }

    #[test]
    fn star_reference_also_neutralises_the_sky() {
        let rgb = synth(384, 384, [0.030, 0.020, 0.026], [1.35, 1.0, 0.75], 90);
        let cal = measure(&rgb, &ColorOpts::default()).expect("measure");
        for c in 0..3 {
            let after = cal.value(c, cal.sky_before[c]);
            assert!((after - cal.sky_after).abs() < 1e-5, "channel {c} at {after}");
        }
    }

    #[test]
    fn gain_never_amplifies() {
        let rgb = synth(384, 384, [0.030, 0.020, 0.026], [1.35, 1.0, 0.75], 90);
        let cal = measure(&rgb, &ColorOpts::default()).expect("measure");
        assert!(cal.gain.iter().all(|g| *g <= 1.0 + 1e-6), "{:?}", cal.gain);
        assert!(cal.gain.iter().any(|g| (*g - 1.0).abs() < 1e-6));
    }

    #[test]
    fn already_neutral_data_is_left_alone() {
        let rgb = synth(384, 384, [0.02; 3], [1.0; 3], 90);
        let cal = measure(&rgb, &ColorOpts::default()).expect("measure");
        for c in 0..3 {
            assert!((cal.gain[c] - 1.0).abs() < 0.04, "gain {:?}", cal.gain);
            assert!(cal.offset[c].abs() < 1e-3, "offset {:?}", cal.offset);
        }
    }

    #[test]
    fn the_linked_stretch_lands_the_calibrated_sky_on_target() {
        let rgb = synth(384, 384, [0.030, 0.020, 0.026], [1.35, 1.0, 0.75], 90);
        let cal = measure(&rgb, &ColorOpts::default()).expect("measure");
        let stf = crate::stretch::Stf {
            shadows: cal.linked_shadows,
            midtone: cal.linked_midtone,
            median: 0.0,
            mad: 0.0,
        };
        for c in 0..3 {
            let shown = crate::stretch::apply(&stf, cal.value(c, cal.sky_before[c]));
            assert!((shown - 0.25).abs() < 0.06, "channel {c} displayed at {shown}");
        }
    }

    /// A field whose stars obey a known colour law, placed through a known WCS,
    /// so the regression has a right answer to be checked against.
    fn synth_catalogue(
        half: usize,
        sky: [f32; 3],
        law: [(f32, f32); 2],
        count: usize,
    ) -> (Rgb, Wcs, Vec<CatalogStar>) {
        let full = half * 2;
        let wcs = Wcs::tan(
            [314.768, 45.733],
            [full as f64 / 2.0, full as f64 / 2.0],
            0.00102,
            1.16,
            true,
            full,
            full,
        );

        let mut data = vec![0f32; half * half * 3];
        let mut seed = 0x1234_5678u32;
        let mut rand = move || {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (seed >> 16) as f32 / 65535.0
        };
        for i in 0..half * half {
            for c in 0..3 {
                data[i * 3 + c] = sky[c] + (rand() - 0.5) * 0.0006;
            }
        }

        let cols = (count as f32).sqrt().ceil() as usize;
        let step = half / (cols + 2);
        let mut catalog = Vec::new();

        for k in 0..count {
            let hx = (step * (1 + k % cols)) as f32 + rand() * 2.0;
            let hy = (step * (1 + k / cols)) as f32 + rand() * 2.0;
            if hx as usize >= half - 12 || hy as usize >= half - 12 {
                continue;
            }
            let colour = 0.2 + 1.8 * (k as f32 / count as f32);
            let gain = [
                10f32.powf(law[0].0 + law[0].1 * colour),
                1.0,
                10f32.powf(law[1].0 + law[1].1 * colour),
            ];
            let amp = 0.06 + rand() * 0.3;

            for dy in -6isize..=6 {
                for dx in -6isize..=6 {
                    let (x, y) = (hx as isize + dx, hy as isize + dy);
                    if x < 0 || y < 0 || x >= half as isize || y >= half as isize {
                        continue;
                    }
                    let (ddx, ddy) = (x as f32 - hx, y as f32 - hy);
                    let v = amp * (-(ddx * ddx + ddy * ddy) / (2.0 * 1.4 * 1.4)).exp();
                    let i = y as usize * half + x as usize;
                    for c in 0..3 {
                        data[i * 3 + c] += v * gain[c];
                    }
                }
            }

            let (ra, dec) = wcs.pixel_to_world(hx as f64 * 2.0 + 0.5, hy as f64 * 2.0 + 0.5);
            catalog.push(CatalogStar {
                ra,
                dec,
                g: 12.0,
                bp: 12.0 + colour / 2.0,
                rp: 12.0 - colour / 2.0,
            });
        }

        (
            Rgb {
                width: half,
                height: half,
                data,
            },
            wcs,
            catalog,
        )
    }

    #[test]
    fn catalogue_reference_recovers_the_colour_law() {
        let law = [(-0.1f32, 0.25f32), (0.05, -0.15)];
        let (rgb, wcs, catalog) = synth_catalogue(384, [0.030, 0.020, 0.026], law, 121);
        let white = 0.82f32;

        let cal = measure_with(
            &rgb,
            &ColorOpts {
                reference: Reference::Catalogue,
                ..Default::default()
            },
            Some(CatalogueFit {
                wcs: &wcs,
                stars: &catalog,
                white,
                downsample: 2.0,
            }),
        )
        .expect("measure");

        assert!(cal.matched >= 30, "only {} matched", cal.matched);
        assert!(cal.colour_span > 0.5, "colour span {}", cal.colour_span);

        for (c, (a, b)) in [(0usize, law[0]), (2, law[1])] {
            let want = 10f32.powf(a + b * white);
            let err = (cal.ratio[c] - want).abs() / want;
            assert!(err < 0.05, "channel {c}: got {} want {want}", cal.ratio[c]);
        }
        assert!(
            (cal.slope[0] - law[0].1).abs() < 0.05,
            "slope {} vs {}",
            cal.slope[0],
            law[0].1
        );
    }

    /// The whole point of the catalogue mode: the answer must not depend on
    /// what colour the field happens to be made of.
    #[test]
    fn catalogue_reference_ignores_what_the_field_contains() {
        let law = [(-0.1f32, 0.25f32), (0.05, -0.15)];
        let mut ratios = Vec::new();

        for count in [121usize, 64] {
            let (rgb, wcs, mut catalog) = synth_catalogue(384, [0.03, 0.02, 0.026], law, 121);
            catalog.truncate(count.min(catalog.len()));
            let cal = measure_with(
                &rgb,
                &ColorOpts {
                    reference: Reference::Catalogue,
                    ..Default::default()
                },
                Some(CatalogueFit {
                    wcs: &wcs,
                    stars: &catalog,
                    white: 0.82,
                    downsample: 2.0,
                }),
            )
            .expect("measure");
            ratios.push(cal.ratio[0]);
        }

        // Truncating the catalogue keeps only the bluer half of the field, which
        // would move a field-average white but must not move this one.
        let drift = (ratios[0] - ratios[1]).abs() / ratios[0];
        assert!(drift < 0.03, "ratios drifted: {ratios:?}");
    }

    /// Answering a catalogue request with a field-star result would read as
    /// success while quietly measuring something else.
    #[test]
    fn catalogue_mode_fails_rather_than_falling_back() {
        let rgb = synth(384, 384, [0.030, 0.020, 0.026], [1.35, 1.0, 0.75], 90);
        let opts = ColorOpts {
            reference: Reference::Catalogue,
            ..Default::default()
        };
        assert!(measure_with(&rgb, &opts, None).is_none(), "no catalogue given");

        // A catalogue that matches nothing in this field must fail the same way.
        let wcs = Wcs::tan([10.0, 10.0], [192.0, 192.0], 0.001, 0.0, false, 768, 768);
        let elsewhere: Vec<CatalogStar> = (0..200)
            .map(|k| CatalogStar {
                ra: 200.0 + (k % 10) as f64 * 0.01,
                dec: -30.0 + (k / 10) as f64 * 0.01,
                g: 11.0,
                bp: 11.4,
                rp: 10.6,
            })
            .collect();
        assert!(
            measure_with(
                &rgb,
                &opts,
                Some(CatalogueFit {
                    wcs: &wcs,
                    stars: &elsewhere,
                    white: 0.82,
                    downsample: 2.0,
                }),
            )
            .is_none(),
            "catalogue covers a different part of the sky"
        );
    }

    #[test]
    fn narrowband_filters_are_recognised() {
        for f in ["Ha", "OIII", "L-eXtreme", "dual-band", "IDAS NBZ", "S II"] {
            assert!(is_narrowband(f), "{f} should be narrowband");
        }
        for f in ["", "LP", "IRCUT", "UV/IR cut", "Luminance", "Red"] {
            assert!(!is_narrowband(f), "{f} should be broadband");
        }
    }
}
