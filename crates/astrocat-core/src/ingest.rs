use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::catalog::{Kind, Scan};
use crate::{fits, stars, to_rgb_half, DetectOpts};

#[derive(Debug, Clone, Default, PartialEq)]
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

/// The columns, paired with the values that go in them, so the header and the
/// row are the same list rather than two lists kept in step by hand.
fn columns(f: &FrameRecord) -> Vec<(&'static str, String)> {
    vec![
        ("id", f.id.to_string()),
        ("path", f.path.display().to_string()),
        ("object", f.object.clone()),
        ("night", f.night.clone()),
        ("filter", f.filter.clone()),
        ("date_obs", f.date_obs.clone()),
        ("second", f.second.to_string()),
        ("exptime", f.exptime.to_string()),
        ("gain", f.gain.to_string()),
        ("ccd_temp", f.ccd_temp.to_string()),
        ("width", f.width.to_string()),
        ("height", f.height.to_string()),
        ("stars", f.stars.to_string()),
        ("hfr", f.hfr.to_string()),
        ("ecc", f.ecc.to_string()),
        ("background", f.background.to_string()),
        ("noise", f.noise.to_string()),
        ("quality", f.quality.to_string()),
        ("rejected", u8::from(f.rejected).to_string()),
        ("telescope", f.telescope.clone()),
        ("ra", f.ra.to_string()),
        ("dec", f.dec.to_string()),
        ("focal_len", f.focal_len.to_string()),
        ("pixel_size", f.pixel_size.to_string()),
        ("scale", f.scale.to_string()),
        ("has_wcs", u8::from(f.has_wcs).to_string()),
        ("trails", f.trails.to_string()),
    ]
}

pub fn catalog_dir(project: &Path) -> PathBuf {
    project.join(".astrocat")
}

pub fn save(project: &Path, frames: &[FrameRecord]) -> std::io::Result<()> {
    let dir = catalog_dir(project);
    fs::create_dir_all(&dir)?;
    let mut w = fs::File::create(dir.join("frames.tsv"))?;

    let header: Vec<&str> = columns(&FrameRecord::default())
        .into_iter()
        .map(|(name, _)| name)
        .collect();
    writeln!(w, "{}", header.join("\t"))?;

    for f in frames {
        let row: Vec<String> = columns(f).into_iter().map(|(_, value)| value).collect();
        writeln!(w, "{}", row.join("\t"))?;
    }
    Ok(())
}

/// The header line is the schema. Reading by column name rather than by
/// position is what lets a later release add, drop or reorder a column without
/// shifting every value in every catalogue already on disk one place along —
/// which would land a rejection flag in a star count and lose a night of
/// culling without saying so. A column this build does not know is ignored; one
/// the file does not carry takes its default.
pub fn load(project: &Path) -> std::io::Result<Vec<FrameRecord>> {
    let text = fs::read_to_string(catalog_dir(project).join("frames.tsv"))?;
    let mut lines = text.lines();
    let Some(header) = lines.next() else {
        return Ok(Vec::new());
    };
    let index: BTreeMap<&str, usize> = header
        .split('\t')
        .map(str::trim)
        .zip(0..)
        .collect();

    let mut out = Vec::new();
    for line in lines.filter(|l| !l.trim().is_empty()) {
        let cells: Vec<&str> = line.split('\t').collect();
        let at = |name: &str| -> &str {
            index
                .get(name)
                .and_then(|i| cells.get(*i))
                .copied()
                .unwrap_or("")
        };
        out.push(FrameRecord {
            id: at("id").parse().unwrap_or(0),
            path: PathBuf::from(at("path")),
            object: at("object").into(),
            night: at("night").into(),
            filter: at("filter").into(),
            date_obs: at("date_obs").into(),
            second: at("second").parse().unwrap_or(0),
            exptime: at("exptime").parse().unwrap_or(0.0),
            gain: at("gain").parse().unwrap_or(0.0),
            ccd_temp: at("ccd_temp").parse().unwrap_or(0.0),
            width: at("width").parse().unwrap_or(0),
            height: at("height").parse().unwrap_or(0),
            stars: at("stars").parse().unwrap_or(0),
            hfr: at("hfr").parse().unwrap_or(0.0),
            ecc: at("ecc").parse().unwrap_or(0.0),
            background: at("background").parse().unwrap_or(0.0),
            noise: at("noise").parse().unwrap_or(0.0),
            quality: at("quality").parse().unwrap_or(0.0),
            rejected: at("rejected") == "1",
            telescope: at("telescope").into(),
            ra: at("ra").parse().unwrap_or(0.0),
            dec: at("dec").parse().unwrap_or(0.0),
            focal_len: at("focal_len").parse().unwrap_or(0.0),
            pixel_size: at("pixel_size").parse().unwrap_or(0.0),
            scale: at("scale").parse().unwrap_or(0.0),
            has_wcs: at("has_wcs") == "1",
            trails: at("trails").parse().unwrap_or(0),
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

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(name);
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(catalog_dir(&dir)).unwrap();
        dir
    }

    /// Every field distinct, so a column written under the wrong header changes
    /// the record it comes back as.
    fn distinct() -> FrameRecord {
        FrameRecord {
            id: 1,
            path: PathBuf::from("/x/y.fit"),
            object: "NGC 7000".into(),
            night: "2026-08-14".into(),
            filter: "LP".into(),
            date_obs: "2026-08-14T23:06:42".into(),
            second: 12345,
            exptime: 30.5,
            gain: 80.0,
            ccd_temp: -9.25,
            width: 3840,
            height: 2160,
            stars: 885,
            hfr: 0.63,
            ecc: 0.41,
            background: 0.0018,
            noise: 6.4e-5,
            quality: 0.75,
            rejected: true,
            telescope: "Seestar S30".into(),
            ra: 314.8088,
            dec: 44.5387,
            focal_len: 250.0,
            pixel_size: 2.9,
            scale: 3.674,
            has_wcs: true,
            trails: 3,
        }
    }

    #[test]
    fn every_column_round_trips() {
        let dir = scratch("astrocat-ingest-columns");
        save(&dir, &[distinct()]).unwrap();
        assert_eq!(load(&dir).unwrap(), vec![distinct()]);
    }

    fn write_tsv(dir: &Path, header: &str, row: &str) {
        fs::write(
            catalog_dir(dir).join("frames.tsv"),
            format!("{header}\n{row}\n"),
        )
        .unwrap();
    }

    #[test]
    fn columns_are_read_by_name_not_position() {
        let dir = scratch("astrocat-ingest-reordered");
        write_tsv(
            &dir,
            "rejected\tstars\tid\tobject\tquality",
            "1\t885\t7\tNGC 7000\t0.75",
        );
        let back = load(&dir).unwrap();
        assert_eq!(back[0].id, 7);
        assert_eq!(back[0].stars, 885);
        assert_eq!(back[0].object, "NGC 7000");
        assert!(back[0].rejected);
    }

    #[test]
    fn a_column_the_file_lacks_takes_its_default() {
        let dir = scratch("astrocat-ingest-missing");
        write_tsv(&dir, "id\tstars\trejected", "3\t885\t1");
        let back = load(&dir).unwrap();
        assert_eq!(back[0].trails, 0);
        assert_eq!(back[0].stars, 885);
        assert!(back[0].rejected);
    }

    #[test]
    fn a_column_this_build_does_not_know_is_ignored() {
        let dir = scratch("astrocat-ingest-unknown");
        write_tsv(&dir, "id\tsnr\tstars\trejected", "3\t42.0\t885\t1");
        let back = load(&dir).unwrap();
        assert_eq!(back[0].stars, 885);
        assert!(back[0].rejected);
    }
}
