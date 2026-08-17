use crate::color::CatalogStar;
use crate::register::{self, RegisterOpts, Transform};
use crate::stars::Star;
use crate::wcs::Wcs;

#[derive(Debug, Clone, Copy)]
pub struct SolveOpts {
    pub max_stars: usize,
    pub min_inliers: usize,
    pub inlier_px: f32,
    /// How far the mount pointing may be from the true centre. Only used to
    /// keep catalogue stars that could plausibly be in frame.
    pub hint_slop_deg: f64,
}

impl Default for SolveOpts {
    fn default() -> Self {
        Self {
            max_stars: 300,
            min_inliers: 12,
            inlier_px: 3.0,
            hint_slop_deg: 1.5,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Solution {
    pub wcs: Wcs,
    pub inliers: usize,
    pub rms_px: f32,
    /// Whether the sky had to be mirrored to match. A similarity transform
    /// cannot reflect, so both handednesses are tried and the better kept.
    pub flipped: bool,
}

/// Catalogue stars as a synthetic field in the hint's pixel frame, brightest
/// first so the matcher's flux ordering means the same thing on both sides.
fn project(catalogue: &[CatalogStar], hint: &Wcs, slop_px: f64) -> Vec<Star> {
    let (w, h) = (hint.width as f64, hint.height as f64);
    let mut out = Vec::with_capacity(catalogue.len());

    for c in catalogue {
        let Some((x, y)) = hint.world_to_pixel(c.ra, c.dec) else {
            continue;
        };
        if x < -slop_px || y < -slop_px || x > w + slop_px || y > h + slop_px {
            continue;
        }
        out.push(Star {
            x: x as f32,
            y: y as f32,
            // Flux ordering is all the matcher uses this for, and magnitudes
            // are backwards, so invert them.
            flux: 10f32.powf(-0.4 * c.g),
            peak: 0.0,
            hfr: 1.0,
            eccentricity: 0.0,
            pixels: 1,
            saturated: false,
        });
    }
    out
}

/// Composes the fitted transform with the hint's own projection. Both are
/// linear about the same tangent point, so the result is another TAN WCS
/// rather than anything that needs the hint kept around.
fn compose(hint: &Wcs, t: &Transform, width: usize, height: usize) -> Option<Wcs> {
    let m = [
        [t.a as f64, -t.b as f64],
        [t.b as f64, t.a as f64],
    ];
    let cd = [
        [
            hint.cd[0][0] * m[0][0] + hint.cd[0][1] * m[1][0],
            hint.cd[0][0] * m[0][1] + hint.cd[0][1] * m[1][1],
        ],
        [
            hint.cd[1][0] * m[0][0] + hint.cd[1][1] * m[1][0],
            hint.cd[1][0] * m[0][1] + hint.cd[1][1] * m[1][1],
        ],
    ];

    // The new reference pixel is wherever the hint's reference pixel came from.
    let inverse = t.invert();
    let (cx, cy) = inverse.apply(
        (hint.crpix[0] - 1.0) as f32,
        (hint.crpix[1] - 1.0) as f32,
    );
    Wcs::from_cd(hint.crval, [cx as f64 + 1.0, cy as f64 + 1.0], cd, width, height)
}

/// Constrained plate solve: the mount pointing fixes the tangent point to
/// within a degree or so and the optics fix the scale, so this is a match
/// against one small patch of sky rather than a search over all of it.
pub fn solve(
    detected: &[Star],
    width: usize,
    height: usize,
    catalogue: &[CatalogStar],
    hint_ra: f64,
    hint_dec: f64,
    hint_scale_arcsec: f64,
    opts: &SolveOpts,
) -> Option<Solution> {
    if detected.len() < opts.min_inliers || catalogue.len() < opts.min_inliers {
        return None;
    }

    let scale_deg = hint_scale_arcsec / 3600.0;
    let slop_px = opts.hint_slop_deg / scale_deg.max(1e-9);
    let register_opts = RegisterOpts {
        max_stars: opts.max_stars,
        inlier_px: opts.inlier_px,
        min_inliers: opts.min_inliers,
        ..Default::default()
    };

    let mut best: Option<Solution> = None;

    for flipped in [false, true] {
        let hint = Wcs::tan(
            [hint_ra, hint_dec],
            [(width as f64 + 1.0) / 2.0, (height as f64 + 1.0) / 2.0],
            scale_deg,
            0.0,
            flipped,
            width,
            height,
        );

        let projected = project(catalogue, &hint, slop_px);
        if projected.len() < opts.min_inliers {
            continue;
        }

        let Some(m) = register::register(detected, &projected, &register_opts) else {
            continue;
        };
        // The optics fix the scale to a couple of percent; a fit that wants to
        // rescale by more than a quarter has matched noise.
        if !(0.75..1.35).contains(&m.transform.scale()) {
            continue;
        }
        let Some(wcs) = compose(&hint, &m.transform, width, height) else {
            continue;
        };

        let candidate = Solution {
            wcs,
            inliers: m.inliers,
            rms_px: m.rms,
            flipped,
        };
        if best.as_ref().is_none_or(|b| candidate.inliers > b.inliers) {
            best = Some(candidate);
        }
    }

    best.filter(|s| s.inliers >= opts.min_inliers)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn star(x: f32, y: f32, flux: f32) -> Star {
        Star {
            x,
            y,
            flux,
            peak: flux,
            hfr: 1.2,
            eccentricity: 0.0,
            pixels: 9,
            saturated: false,
        }
    }

    /// Builds a catalogue from a known WCS, then checks the solver recovers
    /// that WCS from the pixel positions alone plus a deliberately wrong hint.
    fn scenario(flipped: bool, offset_deg: f64) -> (Vec<Star>, Vec<CatalogStar>, Wcs) {
        let (w, h) = (1080usize, 1920usize);
        let truth = Wcs::tan(
            [314.8255, 44.5038],
            [w as f64 / 2.0, h as f64 / 2.0],
            7.348 / 3600.0,
            17.0,
            flipped,
            w,
            h,
        );

        let mut detected = Vec::new();
        let mut catalogue = Vec::new();
        let mut seed = 0xC0FF_EE01u32;
        let mut rand = move || {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (seed >> 16) as f32 / 65535.0
        };

        for k in 0..140 {
            let x = 40.0 + rand() * (w as f32 - 80.0);
            let y = 40.0 + rand() * (h as f32 - 80.0);
            let (ra, dec) = truth.pixel_to_world(x as f64, y as f64);
            detected.push(star(x, y, 1.0 / (1.0 + k as f32)));
            catalogue.push(CatalogStar {
                ra,
                dec,
                g: 8.0 + k as f32 * 0.02,
                bp: 8.4,
                rp: 7.6,
            });
        }

        // Pointing error, which is the whole reason the solve exists.
        let hint = Wcs::tan(
            [314.8255 + offset_deg, 44.5038 + offset_deg * 0.5],
            [w as f64 / 2.0, h as f64 / 2.0],
            7.348 / 3600.0,
            0.0,
            false,
            w,
            h,
        );
        (detected, catalogue, hint)
    }

    #[test]
    fn recovers_the_pointing_from_a_wrong_hint() {
        let (detected, catalogue, hint) = scenario(true, 0.4);
        let s = solve(
            &detected,
            1080,
            1920,
            &catalogue,
            hint.crval[0],
            hint.crval[1],
            7.348,
            &SolveOpts::default(),
        )
        .expect("solved");

        assert!(s.inliers >= 40, "only {} inliers", s.inliers);
        let (ra, dec) = s.wcs.centre();
        let truth = Wcs::tan(
            [314.8255, 44.5038],
            [540.0, 960.0],
            7.348 / 3600.0,
            17.0,
            true,
            1080,
            1920,
        );
        let (tra, tdec) = truth.centre();
        assert!((ra - tra).abs() < 0.01, "ra {ra} vs {tra}");
        assert!((dec - tdec).abs() < 0.01, "dec {dec} vs {tdec}");
        assert!((s.wcs.scale_arcsec() - 7.348).abs() < 0.05, "{}", s.wcs.scale_arcsec());
    }

    #[test]
    fn round_trips_every_catalogue_star_onto_its_pixel() {
        let (detected, catalogue, hint) = scenario(true, 0.4);
        let s = solve(
            &detected, 1080, 1920, &catalogue,
            hint.crval[0], hint.crval[1], 7.348, &SolveOpts::default(),
        )
        .expect("solved");

        let mut worst = 0.0f64;
        for (d, c) in detected.iter().zip(&catalogue) {
            let (x, y) = s.wcs.world_to_pixel(c.ra, c.dec).expect("in frame");
            worst = worst.max(((x - d.x as f64).powi(2) + (y - d.y as f64).powi(2)).sqrt());
        }
        assert!(worst < 1.0, "worst residual {worst} px");
    }

    #[test]
    fn finds_the_parity_it_was_not_given() {
        for flipped in [false, true] {
            let (detected, catalogue, hint) = scenario(flipped, 0.3);
            let s = solve(
                &detected, 1080, 1920, &catalogue,
                hint.crval[0], hint.crval[1], 7.348, &SolveOpts::default(),
            )
            .expect("solved");
            assert_eq!(s.flipped, flipped, "parity {flipped} not recovered");
        }
    }

    #[test]
    fn an_unrelated_field_does_not_solve() {
        let (detected, _, hint) = scenario(true, 0.3);
        // Catalogue from a completely different part of the sky.
        let elsewhere: Vec<CatalogStar> = (0..140)
            .map(|k| CatalogStar {
                ra: 120.0 + (k % 12) as f64 * 0.05,
                dec: -10.0 + (k / 12) as f64 * 0.05,
                g: 9.0,
                bp: 9.4,
                rp: 8.6,
            })
            .collect();
        assert!(solve(
            &detected, 1080, 1920, &elsewhere,
            hint.crval[0], hint.crval[1], 7.348, &SolveOpts::default(),
        )
        .is_none());
    }
}
