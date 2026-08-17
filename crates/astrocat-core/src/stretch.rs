pub fn mtf(m: f32, x: f32) -> f32 {
    if x <= 0.0 {
        0.0
    } else if x >= 1.0 {
        1.0
    } else if (m - 0.5).abs() < 1e-6 {
        x
    } else {
        ((m - 1.0) * x) / (((2.0 * m - 1.0) * x) - m)
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Stf {
    pub shadows: f32,
    pub midtone: f32,
    pub median: f32,
    pub mad: f32,
}

fn median_strided(v: &[f32], stride: usize) -> f32 {
    let mut s: Vec<f32> = v.iter().step_by(stride.max(1)).copied().collect();
    if s.is_empty() {
        return 0.0;
    }
    let k = s.len() / 2;
    s.select_nth_unstable_by(k, |a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    s[k]
}

/// Input must be normalised to [0,1]. `midtone` is the analytic solution to
/// `mtf(midtone, median - shadows) == TARGET_BACKGROUND`.
pub fn auto_stf(v: &[f32], stride: usize) -> Stf {
    const TARGET_BACKGROUND: f32 = 0.25;
    const SHADOWS_CLIP_SIGMA: f32 = 2.8;

    let median = median_strided(v, stride);
    let devs: Vec<f32> = v
        .iter()
        .step_by(stride.max(1))
        .map(|x| (x - median).abs())
        .collect();
    // 1.4826 rescales MAD to a Gaussian-equivalent sigma.
    let mad = median_strided(&devs, 1) * 1.4826;

    let shadows = (median - SHADOWS_CLIP_SIGMA * mad).clamp(0.0, 1.0);
    let midtone = mtf(TARGET_BACKGROUND, (median - shadows).clamp(0.0, 1.0));

    Stf {
        shadows,
        midtone,
        median,
        mad,
    }
}

/// The midtone that puts `x` at the STF target, and the transform's own inverse
/// midtone.
///
/// Star-removal models are trained on stretched images. Handing one a linear
/// frame — median 0.0018 on this data, so every tile is effectively black — is
/// the difference between a clean starless layer and one full of holes: measured
/// on the 211-frame stack, 0.82% of green and 1.04% of blue clipped to zero on
/// linear input against 0.010% and 0.001% on stretched.
///
/// Shadows are deliberately **not** clipped. With no black point the MTF is its
/// own inverse at midtone `1 - m`, so stretch, infer, unstretch round-trips to
/// 0.002% worst-case relative error. Adding a shadow clip makes the inverse
/// ill-conditioned and costs 19% at the sky level, which is where all the
/// nebulosity is.
pub fn ml_midtone(median: f32) -> f32 {
    mtf(0.25, median.clamp(0.0, 1.0))
}

pub fn ml_inverse(midtone: f32) -> f32 {
    1.0 - midtone
}

/// Per-channel stretch over interleaved RGB. Unlinked, so a colour cast in the
/// sky background is neutralised rather than amplified.
pub fn auto_stf_channels(rgb: &[f32], stride: usize) -> [Stf; 3] {
    let step = 3 * stride.max(1);
    std::array::from_fn(|c| {
        let samples: Vec<f32> = rgb[c..].iter().step_by(step).copied().collect();
        auto_stf(&samples, 1)
    })
}

pub fn apply(stf: &Stf, x: f32) -> f32 {
    let denom = (1.0 - stf.shadows).max(1e-6);
    mtf(stf.midtone, ((x - stf.shadows) / denom).clamp(0.0, 1.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ml_prep_round_trips_at_astro_signal_levels() {
        // The sky sits near 0.002 and stars near 1.0 in the same frame, which is
        // exactly the range a naive inverse loses.
        let m = ml_midtone(0.0018);
        assert!((mtf(m, 0.0018) - 0.25).abs() < 1e-4, "median must land on target");
        for x in [1e-5, 0.0018, 0.01, 0.1, 0.5, 0.94, 1.0] {
            let back = mtf(ml_inverse(m), mtf(m, x));
            assert!(
                (back - x).abs() <= 1e-4 * x.max(1e-3),
                "round trip at {x}: got {back}"
            );
        }
    }

    #[test]
    fn mtf_is_identity_at_half() {
        for x in [0.0, 0.1, 0.5, 0.9, 1.0] {
            assert!((mtf(0.5, x) - x).abs() < 1e-6);
        }
    }

    #[test]
    fn mtf_is_monotonic_and_bounded() {
        let mut prev = -1.0;
        for i in 0..=100 {
            let y = mtf(0.05, i as f32 / 100.0);
            assert!((0.0..=1.0).contains(&y));
            assert!(y >= prev);
            prev = y;
        }
    }

    #[test]
    fn auto_stf_lands_background_on_target() {
        let v: Vec<f32> = (0..10_000)
            .map(|i| 0.008 + ((i % 21) as f32 - 10.0) * 0.0002)
            .collect();
        let stf = auto_stf(&v, 1);
        let displayed = apply(&stf, stf.median);
        assert!(
            (displayed - 0.25).abs() < 0.02,
            "background landed at {displayed}, expected ~0.25"
        );
    }

    #[test]
    fn auto_stf_brightens_dark_linear_data() {
        let v: Vec<f32> = (0..1000).map(|i| 0.005 + i as f32 * 1e-6).collect();
        let stf = auto_stf(&v, 1);
        assert!(stf.midtone < 0.5);
        assert!(apply(&stf, stf.median) > stf.median * 10.0);
    }
}
