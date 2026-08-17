use std::collections::HashMap;

use crate::stars::Star;

/// Similarity transform: rotation, uniform scale and translation.
/// `x' = a*x - b*y + tx`, `y' = b*x + a*y + ty`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Transform {
    pub a: f32,
    pub b: f32,
    pub tx: f32,
    pub ty: f32,
}

impl Transform {
    pub const IDENTITY: Transform = Transform {
        a: 1.0,
        b: 0.0,
        tx: 0.0,
        ty: 0.0,
    };

    pub fn apply(&self, x: f32, y: f32) -> (f32, f32) {
        (
            self.a * x - self.b * y + self.tx,
            self.b * x + self.a * y + self.ty,
        )
    }

    pub fn rotation_deg(&self) -> f32 {
        self.b.atan2(self.a).to_degrees()
    }

    pub fn scale(&self) -> f32 {
        (self.a * self.a + self.b * self.b).sqrt()
    }

    pub fn invert(&self) -> Transform {
        let det = self.a * self.a + self.b * self.b;
        let (ia, ib) = (self.a / det, -self.b / det);
        Transform {
            a: ia,
            b: ib,
            tx: -(ia * self.tx - ib * self.ty),
            ty: -(ib * self.tx + ia * self.ty),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Match {
    pub transform: Transform,
    pub inliers: usize,
    pub rms: f32,
}

#[derive(Debug, Clone, Copy)]
pub struct RegisterOpts {
    pub max_stars: usize,
    pub triangle_stars: usize,
    pub invariant_tol: f32,
    pub inlier_px: f32,
    pub min_inliers: usize,
}

impl Default for RegisterOpts {
    fn default() -> Self {
        Self {
            max_stars: 300,
            triangle_stars: 30,
            invariant_tol: 0.01,
            inlier_px: 2.0,
            min_inliers: 12,
        }
    }
}

/// Vertices ordered by opposite-side length, so two similar triangles put
/// corresponding vertices in the same slots regardless of rotation or scale.
struct Tri {
    v: [usize; 3],
    inv: (f32, f32),
}

fn triangles(pts: &[(f32, f32)], top: usize) -> Vec<Tri> {
    let n = pts.len().min(top);
    let mut out = Vec::new();

    for i in 0..n {
        for j in (i + 1)..n {
            for k in (j + 1)..n {
                let d = |p: (f32, f32), q: (f32, f32)| {
                    ((p.0 - q.0).powi(2) + (p.1 - q.1).powi(2)).sqrt()
                };
                // side[m] is opposite vertex m
                let mut side = [
                    (d(pts[j], pts[k]), i),
                    (d(pts[i], pts[k]), j),
                    (d(pts[i], pts[j]), k),
                ];
                side.sort_by(|x, y| x.0.partial_cmp(&y.0).unwrap_or(std::cmp::Ordering::Equal));

                let (s0, s1, s2) = (side[0].0, side[1].0, side[2].0);
                if s2 < 12.0 || s0 / s2 < 0.15 {
                    continue;
                }

                out.push(Tri {
                    v: [side[0].1, side[1].1, side[2].1],
                    inv: (s1 / s2, s0 / s2),
                });
            }
        }
    }

    out
}

fn similarity_from(pairs: &[((f32, f32), (f32, f32))]) -> Option<Transform> {
    let n = pairs.len() as f32;
    if n < 2.0 {
        return None;
    }

    let (mut px, mut py, mut qx, mut qy) = (0.0, 0.0, 0.0, 0.0);
    for ((sx, sy), (dx, dy)) in pairs {
        px += sx;
        py += sy;
        qx += dx;
        qy += dy;
    }
    px /= n;
    py /= n;
    qx /= n;
    qy /= n;

    let (mut num_a, mut num_b, mut den) = (0.0f32, 0.0f32, 0.0f32);
    for ((sx, sy), (dx, dy)) in pairs {
        let (ux, uy) = (sx - px, sy - py);
        let (vx, vy) = (dx - qx, dy - qy);
        num_a += ux * vx + uy * vy;
        num_b += ux * vy - uy * vx;
        den += ux * ux + uy * uy;
    }
    if den < 1e-9 {
        return None;
    }

    let a = num_a / den;
    let b = num_b / den;
    Some(Transform {
        a,
        b,
        tx: qx - (a * px - b * py),
        ty: qy - (b * px + a * py),
    })
}

struct Grid {
    cell: f32,
    map: HashMap<(i32, i32), Vec<usize>>,
}

impl Grid {
    fn build(pts: &[(f32, f32)], cell: f32) -> Grid {
        let mut map: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
        for (i, (x, y)) in pts.iter().enumerate() {
            map.entry(((x / cell) as i32, (y / cell) as i32))
                .or_default()
                .push(i);
        }
        Grid { cell, map }
    }

    fn nearest_within(&self, pts: &[(f32, f32)], x: f32, y: f32, r: f32) -> Option<f32> {
        let (cx, cy) = ((x / self.cell) as i32, (y / self.cell) as i32);
        let mut best = f32::MAX;
        for dy in -1..=1 {
            for dx in -1..=1 {
                if let Some(bucket) = self.map.get(&(cx + dx, cy + dy)) {
                    for &i in bucket {
                        let d = (pts[i].0 - x).powi(2) + (pts[i].1 - y).powi(2);
                        if d < best {
                            best = d;
                        }
                    }
                }
            }
        }
        let d = best.sqrt();
        (d <= r).then_some(d)
    }
}

fn score(
    t: &Transform,
    src: &[(f32, f32)],
    dst: &[(f32, f32)],
    grid: &Grid,
    tol: f32,
) -> (usize, f32) {
    let mut inliers = 0;
    let mut sum_sq = 0.0;
    for (x, y) in src {
        let (px, py) = t.apply(*x, *y);
        if let Some(d) = grid.nearest_within(dst, px, py, tol) {
            inliers += 1;
            sum_sq += d * d;
        }
    }
    let rms = if inliers > 0 {
        (sum_sq / inliers as f32).sqrt()
    } else {
        f32::MAX
    };
    (inliers, rms)
}

fn points(stars: &[Star], max: usize) -> Vec<(f32, f32)> {
    let mut v: Vec<&Star> = stars.iter().filter(|s| !s.saturated).collect();
    v.sort_by(|a, b| b.flux.partial_cmp(&a.flux).unwrap_or(std::cmp::Ordering::Equal));
    v.truncate(max);
    v.iter().map(|s| (s.x, s.y)).collect()
}

/// The reference side of a registration, prepared once. Rebuilding its
/// triangles, hash buckets and grid per frame was most of the per-frame cost.
pub struct Reference {
    points: Vec<(f32, f32)>,
    triangles: Vec<Tri>,
    buckets: HashMap<(i32, i32), Vec<usize>>,
    grid: Grid,
}

pub fn prepare(dst: &[Star], opts: &RegisterOpts) -> Option<Reference> {
    let dp = points(dst, opts.max_stars);
    if dp.len() < 3 {
        return None;
    }
    let dt = triangles(&dp, opts.triangle_stars);
    if dt.is_empty() {
        return None;
    }

    let tol = opts.invariant_tol;
    let mut buckets: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
    for (i, t) in dt.iter().enumerate() {
        buckets
            .entry(((t.inv.0 / tol) as i32, (t.inv.1 / tol) as i32))
            .or_default()
            .push(i);
    }

    let grid = Grid::build(&dp, opts.inlier_px.max(4.0) * 4.0);
    Some(Reference {
        points: dp,
        triangles: dt,
        buckets,
        grid,
    })
}

/// Fit the transform taking `src` star positions onto `dst`.
pub fn register(src: &[Star], dst: &[Star], opts: &RegisterOpts) -> Option<Match> {
    let reference = prepare(dst, opts)?;
    register_to(src, &reference, opts)
}

pub fn register_to(src: &[Star], reference: &Reference, opts: &RegisterOpts) -> Option<Match> {
    let sp = points(src, opts.max_stars);
    if sp.len() < 3 {
        return None;
    }
    let st = triangles(&sp, opts.triangle_stars);
    if st.is_empty() {
        return None;
    }

    let dp = &reference.points;
    let dt = &reference.triangles;
    let buckets = &reference.buckets;
    let grid = &reference.grid;
    let tol = opts.invariant_tol;
    let mut best: Option<Match> = None;
    // Once a transform explains most of the field, further candidates cannot
    // beat it by enough to be worth scoring — and scoring is the whole cost.
    let good_enough = (sp.len() as f32 * 0.6) as usize;
    let mut scored = 0usize;

    'search: for s in &st {
        let key = ((s.inv.0 / tol) as i32, (s.inv.1 / tol) as i32);
        for ddx in -1..=1 {
            for ddy in -1..=1 {
                let Some(cands) = buckets.get(&(key.0 + ddx, key.1 + ddy)) else {
                    continue;
                };
                for &ci in cands {
                    let d = &dt[ci];
                    if (d.inv.0 - s.inv.0).abs() > tol || (d.inv.1 - s.inv.1).abs() > tol {
                        continue;
                    }

                    let pairs: Vec<((f32, f32), (f32, f32))> = (0..3)
                        .map(|m| (sp[s.v[m]], dp[d.v[m]]))
                        .collect();
                    let Some(t) = similarity_from(&pairs) else {
                        continue;
                    };
                    if !(0.8..1.25).contains(&t.scale()) {
                        continue;
                    }

                    let (inliers, rms) = score(&t, &sp, dp, grid, opts.inlier_px);
                    scored += 1;
                    if inliers >= opts.min_inliers
                        && best.as_ref().is_none_or(|b| {
                            inliers > b.inliers || (inliers == b.inliers && rms < b.rms)
                        })
                    {
                        best = Some(Match {
                            transform: t,
                            inliers,
                            rms,
                        });
                    }
                    if best.as_ref().is_some_and(|b| b.inliers >= good_enough)
                        || scored > 400
                    {
                        break 'search;
                    }
                }
            }
        }
    }

    // Refit on every inlier so the final transform is not driven by three stars.
    let m = best?;
    let mut pairs = Vec::new();
    for (x, y) in &sp {
        let (px, py) = m.transform.apply(*x, *y);
        let mut nearest = None;
        let mut bd = opts.inlier_px;
        for (i, (dx, dy)) in dp.iter().enumerate() {
            let d = ((dx - px).powi(2) + (dy - py).powi(2)).sqrt();
            if d < bd {
                bd = d;
                nearest = Some(i);
            }
        }
        if let Some(i) = nearest {
            pairs.push(((*x, *y), dp[i]));
        }
    }

    let refined = similarity_from(&pairs).unwrap_or(m.transform);
    let (inliers, rms) = score(&refined, &sp, dp, grid, opts.inlier_px);
    Some(Match {
        transform: refined,
        inliers,
        rms,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn star(x: f32, y: f32, flux: f32) -> Star {
        Star {
            x,
            y,
            flux,
            peak: 0.5,
            hfr: 1.0,
            eccentricity: 0.1,
            pixels: 9,
            saturated: false,
        }
    }

    fn field(seed: u32, n: usize) -> Vec<Star> {
        let mut s = seed;
        let mut next = || {
            s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (s >> 8) as f32 / 16_777_216.0
        };
        (0..n)
            .map(|_| star(next() * 1000.0, next() * 1000.0, next() * 100.0 + 1.0))
            .collect()
    }

    fn transformed(src: &[Star], t: &Transform) -> Vec<Star> {
        src.iter()
            .map(|s| {
                let (x, y) = t.apply(s.x, s.y);
                star(x, y, s.flux)
            })
            .collect()
    }

    #[test]
    fn recovers_translation_and_rotation() {
        let src = field(7, 120);
        let ang: f32 = 3.5f32.to_radians();
        let truth = Transform {
            a: ang.cos(),
            b: ang.sin(),
            tx: 24.0,
            ty: -11.0,
        };
        let dst = transformed(&src, &truth);

        let m = register(&src, &dst, &RegisterOpts::default()).expect("should register");
        assert!(m.inliers > 100, "inliers {}", m.inliers);
        assert!(m.rms < 0.05, "rms {}", m.rms);
        assert!((m.transform.rotation_deg() - 3.5).abs() < 0.05);
        assert!((m.transform.tx - 24.0).abs() < 0.5);
        assert!((m.transform.ty + 11.0).abs() < 0.5);
    }

    #[test]
    fn survives_missing_and_spurious_stars() {
        let src = field(11, 140);
        let ang: f32 = -1.2f32.to_radians();
        let truth = Transform {
            a: ang.cos(),
            b: ang.sin(),
            tx: -40.0,
            ty: 33.0,
        };
        let mut dst = transformed(&src, &truth);
        dst.truncate(100);
        dst.extend(field(999, 25));

        let m = register(&src, &dst, &RegisterOpts::default()).expect("should register");
        assert!(m.inliers > 60, "inliers {}", m.inliers);
        assert!((m.transform.rotation_deg() + 1.2).abs() < 0.1);
    }

    #[test]
    fn inverse_round_trips() {
        let ang: f32 = 12.0f32.to_radians();
        let t = Transform {
            a: ang.cos() * 1.02,
            b: ang.sin() * 1.02,
            tx: 5.0,
            ty: -7.0,
        };
        let inv = t.invert();
        let (x, y) = t.apply(100.0, 200.0);
        let (rx, ry) = inv.apply(x, y);
        assert!((rx - 100.0).abs() < 1e-2, "{rx}");
        assert!((ry - 200.0).abs() < 1e-2, "{ry}");
    }

    #[test]
    fn unrelated_fields_do_not_match() {
        let a = field(1, 120);
        let b = field(2, 120);
        let m = register(&a, &b, &RegisterOpts::default());
        assert!(
            m.as_ref().is_none_or(|m| m.inliers < 20),
            "spurious match {:?}",
            m
        );
    }
}
