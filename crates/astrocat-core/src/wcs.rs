use crate::fits::Header;

const D2R: f64 = std::f64::consts::PI / 180.0;

/// Gnomonic (TAN) world coordinate system, with SIP distortion when the header
/// carries it. Pixel coordinates are 0-based with row 0 at the bottom, matching
/// how the reader stores the array; FITS itself is 1-based, hence the CRPIX
/// offsets below.
#[derive(Debug, Clone)]
pub struct Wcs {
    pub crval: [f64; 2],
    pub crpix: [f64; 2],
    pub cd: [[f64; 2]; 2],
    inv: [[f64; 2]; 2],
    a: Vec<(i32, i32, f64)>,
    b: Vec<(i32, i32, f64)>,
    ap: Vec<(i32, i32, f64)>,
    bp: Vec<(i32, i32, f64)>,
    pub width: usize,
    pub height: usize,
}

fn poly(terms: &[(i32, i32, f64)], u: f64, v: f64) -> f64 {
    terms
        .iter()
        .map(|(p, q, c)| c * u.powi(*p) * v.powi(*q))
        .sum()
}

impl Wcs {
    pub fn from_header(h: &Header, width: usize, height: usize) -> Option<Wcs> {
        if !h.text("CTYPE1").unwrap_or("").contains("TAN") {
            return None;
        }
        let crval = [h.float("CRVAL1")?, h.float("CRVAL2")?];
        let crpix = [h.float("CRPIX1")?, h.float("CRPIX2")?];
        let cd = [
            [h.float("CD1_1")?, h.float("CD1_2")?],
            [h.float("CD2_1")?, h.float("CD2_2")?],
        ];

        let det = cd[0][0] * cd[1][1] - cd[0][1] * cd[1][0];
        if det.abs() < 1e-20 {
            return None;
        }
        let inv = [
            [cd[1][1] / det, -cd[0][1] / det],
            [-cd[1][0] / det, cd[0][0] / det],
        ];

        let sip = |prefix: &str, order: &str| -> Vec<(i32, i32, f64)> {
            let n = h.int(order).unwrap_or(0).clamp(0, 8) as i32;
            let mut out = Vec::new();
            for p in 0..=n {
                for q in 0..=(n - p) {
                    match h.float(&format!("{prefix}_{p}_{q}")) {
                        Some(c) if c != 0.0 => out.push((p, q, c)),
                        _ => {}
                    }
                }
            }
            out
        };

        Some(Wcs {
            crval,
            crpix,
            cd,
            inv,
            a: sip("A", "A_ORDER"),
            b: sip("B", "B_ORDER"),
            ap: sip("AP", "AP_ORDER"),
            bp: sip("BP", "BP_ORDER"),
            width,
            height,
        })
    }

    /// Undistorted tangent-plane WCS, for tests and for a solver that has just
    /// fitted a rotation and scale.
    pub fn tan(
        crval: [f64; 2],
        crpix: [f64; 2],
        scale_deg: f64,
        rotation_deg: f64,
        parity: bool,
        width: usize,
        height: usize,
    ) -> Wcs {
        let (s, c) = (rotation_deg * D2R).sin_cos();
        let flip = if parity { -1.0 } else { 1.0 };
        let cd = [
            [flip * scale_deg * c, -scale_deg * s],
            [flip * scale_deg * s, scale_deg * c],
        ];
        let det = cd[0][0] * cd[1][1] - cd[0][1] * cd[1][0];
        let inv = [
            [cd[1][1] / det, -cd[0][1] / det],
            [-cd[1][0] / det, cd[0][0] / det],
        ];
        Wcs {
            crval,
            crpix,
            cd,
            inv,
            a: Vec::new(),
            b: Vec::new(),
            ap: Vec::new(),
            bp: Vec::new(),
            width,
            height,
        }
    }

    /// For a solver that has fitted an arbitrary linear term rather than a
    /// scale and a rotation.
    pub fn from_cd(
        crval: [f64; 2],
        crpix: [f64; 2],
        cd: [[f64; 2]; 2],
        width: usize,
        height: usize,
    ) -> Option<Wcs> {
        let det = cd[0][0] * cd[1][1] - cd[0][1] * cd[1][0];
        if det.abs() < 1e-20 {
            return None;
        }
        Some(Wcs {
            crval,
            crpix,
            cd,
            inv: [
                [cd[1][1] / det, -cd[0][1] / det],
                [-cd[1][0] / det, cd[0][0] / det],
            ],
            a: Vec::new(),
            b: Vec::new(),
            ap: Vec::new(),
            bp: Vec::new(),
            width,
            height,
        })
    }

    pub fn world_to_pixel(&self, ra: f64, dec: f64) -> Option<(f64, f64)> {
        let (a0, d0) = (self.crval[0] * D2R, self.crval[1] * D2R);
        let (a, d) = (ra * D2R, dec * D2R);
        let da = a - a0;

        let cosc = d0.sin() * d.sin() + d0.cos() * d.cos() * da.cos();
        // Behind the tangent point: the projection diverges, and any answer
        // would be a reflection of the real position.
        if cosc <= 1e-6 {
            return None;
        }

        let xi = d.cos() * da.sin() / cosc / D2R;
        let eta = (d0.cos() * d.sin() - d0.sin() * d.cos() * da.cos()) / cosc / D2R;

        let u = self.inv[0][0] * xi + self.inv[0][1] * eta;
        let v = self.inv[1][0] * xi + self.inv[1][1] * eta;
        Some((
            u + poly(&self.ap, u, v) + self.crpix[0] - 1.0,
            v + poly(&self.bp, u, v) + self.crpix[1] - 1.0,
        ))
    }

    pub fn pixel_to_world(&self, x: f64, y: f64) -> (f64, f64) {
        let u = x + 1.0 - self.crpix[0];
        let v = y + 1.0 - self.crpix[1];
        let du = u + poly(&self.a, u, v);
        let dv = v + poly(&self.b, u, v);

        let xi = (self.cd[0][0] * du + self.cd[0][1] * dv) * D2R;
        let eta = (self.cd[1][0] * du + self.cd[1][1] * dv) * D2R;

        let (a0, d0) = (self.crval[0] * D2R, self.crval[1] * D2R);
        let rho = (xi * xi + eta * eta).sqrt();
        if rho < 1e-14 {
            return (self.crval[0], self.crval[1]);
        }
        let c = rho.atan();
        let dec = (c.cos() * d0.sin() + eta * c.sin() * d0.cos() / rho).asin();
        let ra = a0
            + (xi * c.sin()).atan2(rho * d0.cos() * c.cos() - eta * d0.sin() * c.sin());

        (ra.rem_euclid(2.0 * std::f64::consts::PI) / D2R, dec / D2R)
    }

    pub fn centre(&self) -> (f64, f64) {
        self.pixel_to_world((self.width as f64 - 1.0) / 2.0, (self.height as f64 - 1.0) / 2.0)
    }

    pub fn scale_arcsec(&self) -> f64 {
        let det = self.cd[0][0] * self.cd[1][1] - self.cd[0][1] * self.cd[1][0];
        det.abs().sqrt() * 3600.0
    }

    pub fn rotation_deg(&self) -> f64 {
        self.cd[1][0].atan2(self.cd[1][1]) / D2R
    }

    /// Half the diagonal plus a margin, which is what a cone search needs to
    /// cover the corners of a rectangular frame.
    pub fn radius_deg(&self) -> f64 {
        let (w, h) = (self.width as f64, self.height as f64);
        0.5 * (w * w + h * h).sqrt() * self.scale_arcsec() / 3600.0 * 1.05
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Wcs {
        Wcs::tan([314.768, 45.733], [1096.0, 715.5], 0.00102, 1.16, true, 2160, 3840)
    }

    #[test]
    fn pixel_and_world_round_trip() {
        let w = sample();
        for (x, y) in [(0.0, 0.0), (1080.0, 1920.0), (2159.0, 3839.0), (400.0, 3000.0)] {
            let (ra, dec) = w.pixel_to_world(x, y);
            let (bx, by) = w.world_to_pixel(ra, dec).expect("in front of the tangent point");
            assert!((bx - x).abs() < 1e-6, "x {x} -> {bx}");
            assert!((by - y).abs() < 1e-6, "y {y} -> {by}");
        }
    }

    #[test]
    fn scale_and_radius_are_sane() {
        let w = sample();
        assert!((w.scale_arcsec() - 3.672).abs() < 0.01, "{}", w.scale_arcsec());
        // 2160x3840 at 3.67 arcsec/px is about 2.2 x 3.9 degrees.
        assert!((w.radius_deg() - 2.35).abs() < 0.1, "{}", w.radius_deg());
    }

    #[test]
    fn the_centre_is_near_the_reference_point() {
        let w = sample();
        let (ra, dec) = w.centre();
        assert!((ra - 314.768).abs() < 2.0, "{ra}");
        assert!((dec - 45.733).abs() < 2.0, "{dec}");
    }

    #[test]
    fn sip_terms_shift_the_position() {
        let mut w = sample();
        w.ap = vec![(2, 0, -3.5e-7)];
        let plain = sample();
        let (ra, dec) = plain.pixel_to_world(2000.0, 2000.0);
        let a = plain.world_to_pixel(ra, dec).unwrap();
        let b = w.world_to_pixel(ra, dec).unwrap();
        assert!((a.0 - b.0).abs() > 0.1, "SIP made no difference: {a:?} {b:?}");
    }

    #[test]
    fn behind_the_tangent_point_has_no_pixel() {
        let w = sample();
        assert!(w.world_to_pixel(314.768, 45.733 - 120.0).is_none());
    }
}
