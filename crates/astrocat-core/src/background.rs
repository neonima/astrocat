#[derive(Debug, Clone, Copy)]
pub struct BackgroundOpts {
    pub tile: usize,
    pub degree: usize,
    /// Reject a tile whose clipped median sits this many sigma above the global
    /// one — those hold nebulosity, not sky.
    pub tolerance: f32,
    pub refits: usize,
}

impl Default for BackgroundOpts {
    fn default() -> Self {
        Self {
            tile: 48,
            degree: 2,
            tolerance: 2.0,
            refits: 2,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Model {
    pub coeffs: Vec<f64>,
    pub degree: usize,
    pub samples: usize,
    pub level: f32,
}

pub(crate) fn basis(x: f64, y: f64, degree: usize, out: &mut Vec<f64>) {
    out.clear();
    for total in 0..=degree {
        for i in 0..=total {
            out.push(x.powi(i as i32) * y.powi((total - i) as i32));
        }
    }
}

pub fn terms(degree: usize) -> usize {
    (degree + 1) * (degree + 2) / 2
}

impl Model {
    /// `x`, `y` normalised to [-1, 1].
    pub fn eval(&self, x: f64, y: f64) -> f64 {
        let mut b = Vec::new();
        basis(x, y, self.degree, &mut b);
        self.dot(&b)
    }

    /// For callers evaluating several models at the same point: build the basis
    /// once and reuse it, instead of re-allocating inside `eval` per channel.
    pub fn dot(&self, b: &[f64]) -> f64 {
        b.iter().zip(&self.coeffs).map(|(v, c)| v * c).sum()
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

/// Sigma-clipped median of a tile, which removes stars before they can drag
/// the sample upward.
fn clipped_median(vals: &mut Vec<f32>) -> Option<(f32, f32)> {
    if vals.len() < 8 {
        return None;
    }
    let mut med = median(vals);
    let mut sigma = 0.0;
    for _ in 0..3 {
        let mut devs: Vec<f32> = vals.iter().map(|v| (v - med).abs()).collect();
        sigma = median(&mut devs) * 1.4826;
        if sigma <= 0.0 {
            break;
        }
        vals.retain(|v| (v - med).abs() <= 3.0 * sigma);
        if vals.len() < 8 {
            return None;
        }
        med = median(vals);
    }
    Some((med, sigma))
}

fn solve(mut a: Vec<Vec<f64>>, mut b: Vec<f64>) -> Option<Vec<f64>> {
    let n = b.len();
    for col in 0..n {
        let (mut piv, mut best) = (col, a[col][col].abs());
        for r in (col + 1)..n {
            if a[r][col].abs() > best {
                best = a[r][col].abs();
                piv = r;
            }
        }
        if best < 1e-12 {
            return None;
        }
        a.swap(col, piv);
        b.swap(col, piv);

        for r in (col + 1)..n {
            let f = a[r][col] / a[col][col];
            if f == 0.0 {
                continue;
            }
            for c in col..n {
                a[r][c] -= f * a[col][c];
            }
            b[r] -= f * b[col];
        }
    }

    let mut x = vec![0.0; n];
    for i in (0..n).rev() {
        let mut s = b[i];
        for j in (i + 1)..n {
            s -= a[i][j] * x[j];
        }
        x[i] = s / a[i][i];
    }
    Some(x)
}

fn fit_coeffs(samples: &[(f64, f64, f64)], degree: usize) -> Option<Vec<f64>> {
    let m = terms(degree);
    if samples.len() < m * 2 {
        return None;
    }

    let mut ata = vec![vec![0.0f64; m]; m];
    let mut atb = vec![0.0f64; m];
    let mut b = Vec::with_capacity(m);

    for (x, y, v) in samples {
        basis(*x, *y, degree, &mut b);
        for i in 0..m {
            atb[i] += b[i] * v;
            for j in 0..m {
                ata[i][j] += b[i] * b[j];
            }
        }
    }
    solve(ata, atb)
}

pub fn fit(plane: &[f32], w: usize, h: usize, opts: &BackgroundOpts) -> Option<Model> {
    let t = opts.tile.min(w.min(h) / 12).max(8);
    let mut tiles: Vec<(f64, f64, f64)> = Vec::new();

    for ty in (0..=h.saturating_sub(t)).step_by(t) {
        for tx in (0..=w.saturating_sub(t)).step_by(t) {
            let mut vals: Vec<f32> = Vec::with_capacity(t * t);
            for y in ty..(ty + t) {
                vals.extend_from_slice(&plane[y * w + tx..y * w + tx + t]);
            }
            if let Some((med, _)) = clipped_median(&mut vals) {
                let cx = (tx + t / 2) as f64;
                let cy = (ty + t / 2) as f64;
                tiles.push((
                    2.0 * cx / (w - 1) as f64 - 1.0,
                    2.0 * cy / (h - 1) as f64 - 1.0,
                    med as f64,
                ));
            }
        }
    }

    if tiles.len() < terms(opts.degree) * 2 {
        return None;
    }

    // Reject on residuals from a preliminary fit, never on raw brightness:
    // the bright end of a strong gradient is signal to be modelled, not an
    // outlier to be discarded. One-sided, because nebulosity only adds light.
    let mut kept = tiles;
    let mut coeffs = fit_coeffs(&kept, opts.degree)?;

    for _ in 0..opts.refits.max(1) {
        let model = Model {
            coeffs: coeffs.clone(),
            degree: opts.degree,
            samples: kept.len(),
            level: 0.0,
        };
        let resid: Vec<f64> = kept
            .iter()
            .map(|(x, y, v)| v - model.eval(*x, *y))
            .collect();
        let mut ares: Vec<f32> = resid.iter().map(|r| r.abs() as f32).collect();
        let rs = (median(&mut ares) * 1.4826) as f64;
        if rs <= 0.0 {
            break;
        }

        let next: Vec<(f64, f64, f64)> = kept
            .iter()
            .zip(&resid)
            .filter(|(_, r)| **r <= opts.tolerance as f64 * rs)
            .map(|(t, _)| *t)
            .collect();

        if next.len() == kept.len() || next.len() < terms(opts.degree) * 2 {
            break;
        }
        kept = next;
        coeffs = fit_coeffs(&kept, opts.degree)?;
    }

    let model = Model {
        coeffs,
        degree: opts.degree,
        samples: kept.len(),
        level: 0.0,
    };
    let mean: f64 = kept.iter().map(|(x, y, _)| model.eval(*x, *y)).sum::<f64>()
        / kept.len().max(1) as f64;

    Some(Model {
        level: mean as f32,
        ..model
    })
}

/// Subtracts the gradient and restores the mean sky level, so the result stays
/// positive and comparable to the input.
pub fn subtract(plane: &mut [f32], w: usize, h: usize, model: &Model) {
    for y in 0..h {
        let ny = 2.0 * y as f64 / (h - 1) as f64 - 1.0;
        for x in 0..w {
            let nx = 2.0 * x as f64 / (w - 1) as f64 - 1.0;
            plane[y * w + x] -= model.eval(nx, ny) as f32 - model.level;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn noisy(w: usize, h: usize, f: impl Fn(f32, f32) -> f32) -> Vec<f32> {
        let mut seed = 0x9E37_79B9u32;
        (0..w * h)
            .map(|i| {
                seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                let n = ((seed >> 16) as f32 / 65535.0 - 0.5) * 0.0008;
                f((i % w) as f32, (i / w) as f32) + n
            })
            .collect()
    }

    fn spread(plane: &[f32], w: usize, h: usize) -> f32 {
        let corner = |x: usize, y: usize| {
            let mut v: Vec<f32> = (y..y + 40)
                .flat_map(|yy| (x..x + 40).map(move |xx| (xx, yy)))
                .map(|(xx, yy)| plane[yy * w + xx])
                .collect();
            median(&mut v)
        };
        // The centre must be included: a radially symmetric gradient has
        // identical values at all four corners.
        let v = [
            corner(4, 4),
            corner(w - 44, 4),
            corner(4, h - 44),
            corner(w - 44, h - 44),
            corner(w / 2 - 20, h / 2 - 20),
        ];
        v.iter().cloned().fold(f32::MIN, f32::max) - v.iter().cloned().fold(f32::MAX, f32::min)
    }

    #[test]
    fn flattens_a_linear_gradient() {
        let (w, h) = (256, 256);
        let mut p = noisy(w, h, |x, y| 0.01 + x * 2e-5 + y * 1e-5);
        let before = spread(&p, w, h);
        let m = fit(&p, w, h, &BackgroundOpts::default()).expect("fit");
        subtract(&mut p, w, h, &m);
        let after = spread(&p, w, h);
        assert!(after < before * 0.1, "before {before} after {after}");
    }

    #[test]
    fn flattens_a_curved_gradient() {
        let (w, h) = (256, 256);
        let mut p = noisy(w, h, |x, y| {
            let (dx, dy) = ((x - 128.0) / 128.0, (y - 128.0) / 128.0);
            0.01 + 0.004 * (dx * dx + dy * dy)
        });
        let before = spread(&p, w, h);
        let m = fit(&p, w, h, &BackgroundOpts::default()).expect("fit");
        subtract(&mut p, w, h, &m);
        assert!(spread(&p, w, h) < before * 0.15);
    }

    #[test]
    fn stars_do_not_drag_the_fit() {
        let (w, h) = (256, 256);
        let mut clean = noisy(w, h, |x, _| 0.01 + x * 2e-5);
        let mut starry = clean.clone();
        let mut seed = 12345u32;
        for _ in 0..400 {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let i = (seed >> 8) as usize % (w * h);
            starry[i] += 0.5;
        }

        let a = fit(&clean, w, h, &BackgroundOpts::default()).expect("fit");
        let b = fit(&starry, w, h, &BackgroundOpts::default()).expect("fit");
        subtract(&mut clean, w, h, &a);
        subtract(&mut starry, w, h, &b);

        for (i, j) in [(0usize, 0usize), (255, 0), (0, 255), (255, 255)] {
            let d = (a.eval(i as f64 / 128.0 - 1.0, j as f64 / 128.0 - 1.0)
                - b.eval(i as f64 / 128.0 - 1.0, j as f64 / 128.0 - 1.0))
            .abs();
            assert!(d < 5e-4, "corner ({i},{j}) differs by {d}");
        }
    }

    #[test]
    fn preserves_the_sky_level() {
        let (w, h) = (128, 128);
        let mut p = noisy(w, h, |x, y| 0.02 + x * 1e-5 + y * 1e-5);
        let mut before: Vec<f32> = p.clone();
        let m0 = median(&mut before);
        let m = fit(&p, w, h, &BackgroundOpts::default()).expect("fit");
        subtract(&mut p, w, h, &m);
        let m1 = median(&mut p.clone());
        assert!((m1 - m0).abs() < 1e-3, "{m0} -> {m1}");
    }
}
