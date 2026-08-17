use crate::debayer::Rgb;

#[derive(Debug, Clone, Copy)]
pub struct Star {
    pub x: f32,
    pub y: f32,
    pub flux: f32,
    pub peak: f32,
    pub hfr: f32,
    pub eccentricity: f32,
    pub pixels: u32,
    pub saturated: bool,
}

#[derive(Debug, Clone)]
pub struct StarField {
    pub stars: Vec<Star>,
    pub background: f32,
    pub noise: f32,
}

impl StarField {
    pub fn median_hfr(&self) -> f32 {
        median_of(self.stars.iter().map(|s| s.hfr))
    }

    pub fn median_eccentricity(&self) -> f32 {
        median_of(self.stars.iter().map(|s| s.eccentricity))
    }

    /// Brightest unsaturated stars, for registration.
    pub fn brightest(&self, n: usize) -> Vec<Star> {
        let mut v: Vec<Star> = self.stars.iter().copied().filter(|s| !s.saturated).collect();
        v.sort_by(|a, b| b.flux.partial_cmp(&a.flux).unwrap_or(std::cmp::Ordering::Equal));
        v.truncate(n);
        v
    }
}

fn median_of(it: impl Iterator<Item = f32>) -> f32 {
    let mut v: Vec<f32> = it.collect();
    if v.is_empty() {
        return 0.0;
    }
    let k = v.len() / 2;
    v.select_nth_unstable_by(k, |a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    v[k]
}

#[derive(Debug, Clone, Copy)]
pub struct DetectOpts {
    pub sigma: f32,
    pub min_pixels: u32,
    pub max_pixels: u32,
    pub saturation: f32,
}

impl Default for DetectOpts {
    fn default() -> Self {
        Self {
            sigma: 5.0,
            min_pixels: 3,
            max_pixels: 5000,
            saturation: 0.95,
        }
    }
}

pub fn green(rgb: &Rgb) -> Vec<f32> {
    rgb.data.iter().skip(1).step_by(3).copied().collect()
}

pub fn detect(gray: &[f32], w: usize, h: usize, opts: &DetectOpts) -> StarField {
    let background = median_of(gray.iter().step_by(7).copied());
    let mut noise =
        median_of(gray.iter().step_by(7).map(|v| (v - background).abs())) * 1.4826;

    // A frame with no measurable noise (synthetic, or heavily denoised) would
    // otherwise collapse the threshold onto the background and swallow the
    // whole image as one blob. Fall back to a fraction of the dynamic range.
    let brightest = gray.iter().copied().fold(f32::MIN, f32::max);
    noise = noise.max((brightest - background).abs() * 1e-3).max(f32::MIN_POSITIVE);

    let threshold = background + opts.sigma * noise;

    let n = w * h;
    let mut visited = vec![false; n];
    let mut stars = Vec::new();
    let mut stack: Vec<usize> = Vec::new();
    let mut blob: Vec<(usize, f32)> = Vec::new();

    for seed in 0..n {
        if visited[seed] || gray[seed] < threshold {
            continue;
        }

        blob.clear();
        stack.clear();
        stack.push(seed);
        visited[seed] = true;

        while let Some(p) = stack.pop() {
            blob.push((p, gray[p] - background));
            let (x, y) = (p % w, p / w);
            for dy in -1isize..=1 {
                for dx in -1isize..=1 {
                    let (nx, ny) = (x as isize + dx, y as isize + dy);
                    if nx < 0 || ny < 0 || nx >= w as isize || ny >= h as isize {
                        continue;
                    }
                    let q = ny as usize * w + nx as usize;
                    if !visited[q] && gray[q] >= threshold {
                        visited[q] = true;
                        stack.push(q);
                    }
                }
            }
        }

        let count = blob.len() as u32;
        if count < opts.min_pixels || count > opts.max_pixels {
            continue;
        }

        let flux: f32 = blob.iter().map(|(_, v)| *v).sum();
        if flux <= 0.0 {
            continue;
        }

        let mut cx = 0.0;
        let mut cy = 0.0;
        let mut peak = 0.0f32;
        for (p, v) in &blob {
            cx += (p % w) as f32 * v;
            cy += (p / w) as f32 * v;
            peak = peak.max(gray[*p]);
        }
        cx /= flux;
        cy /= flux;

        let (mut ixx, mut iyy, mut ixy) = (0.0f32, 0.0f32, 0.0f32);
        for (p, v) in &blob {
            let dx = (p % w) as f32 - cx;
            let dy = (p / w) as f32 - cy;
            ixx += v * dx * dx;
            iyy += v * dy * dy;
            ixy += v * dx * dy;
        }
        ixx /= flux;
        iyy /= flux;
        ixy /= flux;

        // Eigenvalues of the 2x2 second-moment matrix give the major/minor axes.
        let tr = ixx + iyy;
        let det = (ixx - iyy) * (ixx - iyy) + 4.0 * ixy * ixy;
        let root = det.max(0.0).sqrt();
        let major = (tr + root) * 0.5;
        let minor = (tr - root) * 0.5;
        let eccentricity = if major > 1e-9 {
            (1.0 - (minor.max(0.0) / major)).max(0.0).sqrt()
        } else {
            0.0
        };

        let mut radial: Vec<(f32, f32)> = blob
            .iter()
            .map(|(p, v)| {
                let dx = (p % w) as f32 - cx;
                let dy = (p / w) as f32 - cy;
                ((dx * dx + dy * dy).sqrt(), *v)
            })
            .collect();
        radial.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));

        let mut acc = 0.0;
        let mut hfr = radial.last().map(|(r, _)| *r).unwrap_or(0.0);
        for (r, v) in &radial {
            acc += v;
            if acc >= flux * 0.5 {
                hfr = (*r).max(0.5);
                break;
            }
        }

        stars.push(Star {
            x: cx,
            y: cy,
            flux,
            peak,
            hfr,
            eccentricity,
            pixels: count,
            saturated: peak >= opts.saturation,
        });
    }

    StarField {
        stars,
        background,
        noise,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gaussian_field(w: usize, h: usize, spots: &[(f32, f32, f32, f32)]) -> Vec<f32> {
        let mut g = vec![0.01f32; w * h];
        let mut seed = 0x2545_F491u32;
        for v in g.iter_mut() {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            *v += ((seed >> 16) as f32 / 65535.0 - 0.5) * 0.002;
        }
        for (cx, cy, amp, sigma) in spots {
            for y in 0..h {
                for x in 0..w {
                    let dx = x as f32 - cx;
                    let dy = y as f32 - cy;
                    let r2 = dx * dx + dy * dy;
                    g[y * w + x] += amp * (-r2 / (2.0 * sigma * sigma)).exp();
                }
            }
        }
        g
    }

    #[test]
    fn finds_stars_at_the_right_positions() {
        let g = gaussian_field(64, 64, &[(20.0, 15.0, 1.0, 1.5), (44.0, 50.0, 0.6, 1.5)]);
        let f = detect(&g, 64, 64, &DetectOpts::default());
        assert_eq!(f.stars.len(), 2);

        let mut found: Vec<(f32, f32)> = f.stars.iter().map(|s| (s.x, s.y)).collect();
        found.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
        assert!((found[0].0 - 20.0).abs() < 0.2, "got {:?}", found[0]);
        assert!((found[0].1 - 15.0).abs() < 0.2, "got {:?}", found[0]);
        assert!((found[1].0 - 44.0).abs() < 0.2, "got {:?}", found[1]);
    }

    #[test]
    fn round_stars_have_low_eccentricity() {
        let g = gaussian_field(64, 64, &[(32.0, 32.0, 1.0, 2.0)]);
        let f = detect(&g, 64, 64, &DetectOpts::default());
        assert_eq!(f.stars.len(), 1);
        assert!(f.stars[0].eccentricity < 0.2, "got {}", f.stars[0].eccentricity);
    }

    #[test]
    fn wider_stars_have_larger_hfr() {
        let tight = detect(
            &gaussian_field(64, 64, &[(32.0, 32.0, 1.0, 1.2)]),
            64,
            64,
            &DetectOpts::default(),
        );
        let wide = detect(
            &gaussian_field(64, 64, &[(32.0, 32.0, 1.0, 3.0)]),
            64,
            64,
            &DetectOpts::default(),
        );
        assert!(
            wide.stars[0].hfr > tight.stars[0].hfr,
            "{} vs {}",
            wide.stars[0].hfr,
            tight.stars[0].hfr
        );
    }

    #[test]
    fn elongated_stars_are_flagged() {
        let mut g = vec![0.01f32; 64 * 64];
        for y in 0..64 {
            for x in 0..64 {
                let dx = (x as f32 - 32.0) / 5.0;
                let dy = (y as f32 - 32.0) / 1.2;
                g[y * 64 + x] += (-(dx * dx + dy * dy) / 2.0).exp();
            }
        }
        let f = detect(&g, 64, 64, &DetectOpts::default());
        assert_eq!(f.stars.len(), 1);
        assert!(f.stars[0].eccentricity > 0.85, "got {}", f.stars[0].eccentricity);
    }
}
