use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::catalog::{Kind, Scan};
use crate::{fits, stars, to_rgb_half, DetectOpts};

#[derive(Debug, Clone, Default)]
pub struct FrameRecord {
    pub id: u32,
    pub path: PathBuf,
    pub object: String,
    pub night: String,
    pub filter: String,
    pub date_obs: String,
    pub second: i64,
    pub exptime: f32,
    pub gain: f32,
    pub ccd_temp: f32,
    pub width: u32,
    pub height: u32,
    pub stars: u32,
    pub hfr: f32,
    pub ecc: f32,
    pub background: f32,
    pub noise: f32,
    /// Percentile rank of star count within its own session, in [0,1].
    pub quality: f32,
    pub rejected: bool,
    pub telescope: String,
    pub ra: f32,
    pub dec: f32,
    pub focal_len: f32,
    pub pixel_size: f32,
    /// arcsec per pixel at the sensor, from optics — not from a plate solve.
    pub scale: f32,
    /// Whether the frame carries a real plate solution. Seestar subs do not.
    pub has_wcs: bool,
    /// Elongated detections — satellites, planes, meteors. Counted rather than
    /// averaged: a median hides ten streaks among seven hundred stars.
    pub trails: u32,
}

pub fn measure(path: &Path) -> std::io::Result<FrameRecord> {
    let img = fits::read(path)?;
    // Absolute, because the app's working directory is not the project's.
    let path = &path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let pedestal = img.pedestal();
    let rgb = to_rgb_half(&img);
    let span = (65535.0 - pedestal).max(1.0);
    let gray: Vec<f32> = stars::green(&rgb)
        .iter()
        .map(|v| ((v - pedestal) / span).clamp(0.0, 1.0))
        .collect();

    let field = stars::detect(&gray, rgb.width, rgb.height, &DetectOpts::default());

    Ok(FrameRecord {
        path: path.to_path_buf(),
        object: img.header.text("OBJECT").unwrap_or("").trim().to_string(),
        filter: img.header.text("FILTER").unwrap_or("").trim().to_string(),
        date_obs: img.header.text("DATE-OBS").unwrap_or("").trim().to_string(),
        exptime: img.header.float("EXPTIME").unwrap_or(0.0) as f32,
        gain: img.header.float("GAIN").unwrap_or(0.0) as f32,
        ccd_temp: img.header.float("CCD-TEMP").unwrap_or(0.0) as f32,
        width: img.width as u32,
        height: img.height as u32,
        stars: field.stars.len() as u32,
        hfr: field.median_hfr(),
        ecc: field.median_eccentricity(),
        background: field.background,
        noise: field.noise,
        telescope: img.header.text("TELESCOP").unwrap_or("").trim().to_string(),
        ra: img.header.float("RA").unwrap_or(0.0) as f32,
        dec: img.header.float("DEC").unwrap_or(0.0) as f32,
        focal_len: img.header.float("FOCALLEN").unwrap_or(0.0) as f32,
        pixel_size: img.header.float("XPIXSZ").unwrap_or(0.0) as f32,
        scale: {
            let px = img.header.float("XPIXSZ").unwrap_or(0.0) as f32;
            let fl = img.header.float("FOCALLEN").unwrap_or(0.0) as f32;
            if fl > 0.0 { 206.265 * px / fl } else { 0.0 }
        },
        has_wcs: img.header.get("CRVAL1").is_some() && img.header.get("CD1_1").is_some(),
        trails: {
            let hfr = field.median_hfr().max(0.3);
            field
                .stars
                .iter()
                .filter(|s| s.eccentricity > 0.92 && s.hfr > hfr * 2.0 && s.pixels > 12)
                .count() as u32
        },
        ..Default::default()
    })
}

/// Rank within a session, so a night of poor transparency is judged against
/// itself rather than against a better night.
fn rank_within_sessions(frames: &mut [FrameRecord]) {
    let mut nights: Vec<String> = frames.iter().map(|f| f.night.clone()).collect();
    nights.sort();
    nights.dedup();

    for night in nights {
        let mut idx: Vec<usize> = (0..frames.len())
            .filter(|i| frames[*i].night == night)
            .collect();
        idx.sort_by_key(|i| frames[*i].stars);
        let n = idx.len().max(1) as f32;
        for (rank, i) in idx.iter().enumerate() {
            frames[*i].quality = if n > 1.0 {
                rank as f32 / (n - 1.0)
            } else {
                1.0
            };
        }
    }
}

pub fn ingest(scan: &Scan, mut progress: impl FnMut(usize, usize)) -> Vec<FrameRecord> {
    let todo: Vec<(&crate::catalog::Scanned, String)> = scan
        .groups
        .iter()
        .filter(|g| g.kind == Kind::Light)
        .flat_map(|g| g.frames.iter().map(|f| (f, g.night.clone())))
        .collect();

    let total = todo.len();
    let mut out: Vec<FrameRecord> = Vec::with_capacity(total);

    for (i, (s, night)) in todo.iter().enumerate() {
        progress(i, total);
        let Ok(mut rec) = measure(&s.path) else { continue };
        rec.id = out.len() as u32;
        rec.night = night.clone();
        rec.second = s.second;
        out.push(rec);
    }
    progress(total, total);

    out.sort_by_key(|f| f.second);
    for (i, f) in out.iter_mut().enumerate() {
        f.id = i as u32;
    }
    rank_within_sessions(&mut out);
    out
}

const HEADER: &str = "id\tpath\tobject\tnight\tfilter\tdate_obs\tsecond\texptime\tgain\tccd_temp\twidth\theight\tstars\thfr\tecc\tbackground\tnoise\tquality\trejected\ttelescope\tra\tdec\tfocal_len\tpixel_size\tscale\thas_wcs\ttrails";

pub fn catalog_dir(project: &Path) -> PathBuf {
    project.join(".astrocat")
}

pub fn save(project: &Path, frames: &[FrameRecord]) -> std::io::Result<()> {
    let dir = catalog_dir(project);
    fs::create_dir_all(&dir)?;
    let mut w = fs::File::create(dir.join("frames.tsv"))?;
    writeln!(w, "{HEADER}")?;
    for f in frames {
        writeln!(
            w,
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            f.id,
            f.path.display(),
            f.object,
            f.night,
            f.filter,
            f.date_obs,
            f.second,
            f.exptime,
            f.gain,
            f.ccd_temp,
            f.width,
            f.height,
            f.stars,
            f.hfr,
            f.ecc,
            f.background,
            f.noise,
            f.quality,
            u8::from(f.rejected),
            f.telescope,
            f.ra,
            f.dec,
            f.focal_len,
            f.pixel_size,
            f.scale,
            u8::from(f.has_wcs),
            f.trails
        )?;
    }
    Ok(())
}

pub fn load(project: &Path) -> std::io::Result<Vec<FrameRecord>> {
    let text = fs::read_to_string(catalog_dir(project).join("frames.tsv"))?;
    let mut out = Vec::new();
    for line in text.lines().skip(1) {
        let c: Vec<&str> = line.split('\t').collect();
        if c.len() < 19 {
            continue;
        }
        // Older catalogs stop at column 19; treat the rest as absent.
        let at = |i: usize| c.get(i).copied().unwrap_or("");
        out.push(FrameRecord {
            id: c[0].parse().unwrap_or(0),
            path: PathBuf::from(c[1]),
            object: c[2].into(),
            night: c[3].into(),
            filter: c[4].into(),
            date_obs: c[5].into(),
            second: c[6].parse().unwrap_or(0),
            exptime: c[7].parse().unwrap_or(0.0),
            gain: c[8].parse().unwrap_or(0.0),
            ccd_temp: c[9].parse().unwrap_or(0.0),
            width: c[10].parse().unwrap_or(0),
            height: c[11].parse().unwrap_or(0),
            stars: c[12].parse().unwrap_or(0),
            hfr: c[13].parse().unwrap_or(0.0),
            ecc: c[14].parse().unwrap_or(0.0),
            background: c[15].parse().unwrap_or(0.0),
            noise: c[16].parse().unwrap_or(0.0),
            quality: c[17].parse().unwrap_or(0.0),
            rejected: c[18] == "1",
            telescope: at(19).to_string(),
            ra: at(20).parse().unwrap_or(0.0),
            dec: at(21).parse().unwrap_or(0.0),
            focal_len: at(22).parse().unwrap_or(0.0),
            pixel_size: at(23).parse().unwrap_or(0.0),
            scale: at(24).parse().unwrap_or(0.0),
            has_wcs: at(25) == "1",
            trails: at(26).parse().unwrap_or(0),
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(night: &str, stars: u32) -> FrameRecord {
        FrameRecord {
            night: night.into(),
            stars,
            ..Default::default()
        }
    }

    #[test]
    fn quality_is_ranked_within_each_session() {
        let mut f = vec![
            rec("a", 100),
            rec("a", 900),
            rec("a", 500),
            rec("b", 10),
            rec("b", 20),
        ];
        rank_within_sessions(&mut f);
        assert_eq!(f[0].quality, 0.0);
        assert_eq!(f[1].quality, 1.0);
        assert_eq!(f[2].quality, 0.5);
        // A weak night is still ranked against itself, not against night "a".
        assert_eq!(f[3].quality, 0.0);
        assert_eq!(f[4].quality, 1.0);
    }

    #[test]
    fn round_trips_through_disk() {
        let dir = std::env::temp_dir().join("astrocat-ingest-test");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let frames = vec![FrameRecord {
            id: 0,
            path: PathBuf::from("/x/y.fit"),
            object: "NGC 7000".into(),
            night: "2026-08-14".into(),
            filter: "LP".into(),
            date_obs: "2026-08-14T23:06:42".into(),
            second: 12345,
            exptime: 60.0,
            stars: 885,
            hfr: 0.63,
            quality: 0.75,
            rejected: true,
            ..Default::default()
        }];
        save(&dir, &frames).unwrap();
        let back = load(&dir).unwrap();

        assert_eq!(back.len(), 1);
        assert_eq!(back[0].object, "NGC 7000");
        assert_eq!(back[0].stars, 885);
        assert_eq!(back[0].night, "2026-08-14");
        assert!(back[0].rejected);
        assert!((back[0].quality - 0.75).abs() < 1e-6);
    }
}
