use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::fits;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Light,
    Master,
    Unreadable,
}

#[derive(Debug, Clone)]
pub struct Scanned {
    pub path: PathBuf,
    pub kind: Kind,
    pub object: String,
    pub filter: String,
    pub exptime: f32,
    pub date_obs: String,
    /// Seconds since epoch-ish, derived from DATE-OBS. Only differences matter.
    pub second: i64,
    pub width: usize,
    pub height: usize,
    pub planes: usize,
    pub bytes: u64,
    pub reason: String,
}

impl Scanned {
    /// Header identity, not path — the same frame copied elsewhere is the same frame.
    pub fn identity(&self) -> String {
        format!("{}|{}|{:.1}", self.date_obs, self.object, self.exptime)
    }

    /// Observing night on a noon-to-noon rollover: a session that runs past
    /// midnight is one night, not two.
    pub fn night(&self) -> String {
        let (y, m, d, hh) = parse_date(&self.date_obs);
        if hh >= 12 {
            format!("{y:04}-{m:02}-{d:02}")
        } else {
            let (py, pm, pd) = previous_day(y, m, d);
            format!("{py:04}-{pm:02}-{pd:02}")
        }
    }

    pub fn group_key(&self) -> String {
        format!(
            "{}|{}|{}|{:.0}",
            self.object,
            self.night(),
            self.filter,
            self.exptime
        )
    }
}

fn parse_date(s: &str) -> (i32, u32, u32, u32) {
    let b = s.as_bytes();
    let num = |a: usize, n: usize| -> i64 {
        s.get(a..a + n)
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(0)
    };
    if b.len() < 13 {
        return (0, 1, 1, 0);
    }
    (
        num(0, 4) as i32,
        num(5, 2) as u32,
        num(8, 2) as u32,
        num(11, 2) as u32,
    )
}

fn days_in(y: i32, m: u32) -> u32 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        2 => 28,
        _ => 30,
    }
}

fn previous_day(y: i32, m: u32, d: u32) -> (i32, u32, u32) {
    if d > 1 {
        (y, m, d - 1)
    } else if m > 1 {
        (y, m - 1, days_in(y, m - 1))
    } else {
        (y - 1, 12, 31)
    }
}

/// Second resolution matters: 30-second subs collapse onto the same tick at
/// minute resolution, and the trace positions every frame by real clock time.
fn seconds(s: &str) -> i64 {
    let (y, m, d, hh) = parse_date(s);
    let field = |a: usize| -> i64 {
        s.get(a..a + 2)
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(0)
    };
    let days = y as i64 * 372 + m as i64 * 31 + d as i64;
    days * 86400 + hh as i64 * 3600 + field(14) * 60 + field(17)
}

pub fn scan_file(path: &Path) -> Scanned {
    let bytes = fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let mut out = Scanned {
        path: path.to_path_buf(),
        kind: Kind::Unreadable,
        object: String::new(),
        filter: String::new(),
        exptime: 0.0,
        date_obs: String::new(),
        second: 0,
        width: 0,
        height: 0,
        planes: 0,
        bytes,
        reason: String::new(),
    };

    let file = match fs::File::open(path) {
        Ok(f) => f,
        Err(e) => {
            out.reason = format!("cannot open: {e}");
            return out;
        }
    };
    let mut r = std::io::BufReader::new(file);
    let header = match fits::read_header(&mut r) {
        Ok(h) => h,
        Err(e) => {
            out.reason = format!("not a FITS header: {e}");
            return out;
        }
    };

    out.object = header.text("OBJECT").unwrap_or("").trim().to_string();
    out.filter = header.text("FILTER").unwrap_or("").trim().to_string();
    out.exptime = header.float("EXPTIME").unwrap_or(0.0) as f32;
    out.date_obs = header.text("DATE-OBS").unwrap_or("").trim().to_string();
    out.second = seconds(&out.date_obs);
    out.width = header.int("NAXIS1").unwrap_or(0).max(0) as usize;
    out.height = header.int("NAXIS2").unwrap_or(0).max(0) as usize;
    out.planes = if header.int("NAXIS").unwrap_or(2) >= 3 {
        header.int("NAXIS3").unwrap_or(1).max(1) as usize
    } else {
        1
    };

    // Classification is by header content only. The finished stack sits among
    // the lights with the same extension and a similar name.
    if header.int("STACKCNT").is_some() || out.planes == 3 {
        out.kind = Kind::Master;
        out.reason = match header.int("STACKCNT") {
            Some(n) => format!("STACKCNT = {n}, NAXIS3 = {}", out.planes),
            None => format!("NAXIS3 = {}, already colour", out.planes),
        };
    } else if out.width == 0 || out.height == 0 {
        out.reason = "no image dimensions".into();
    } else {
        out.kind = Kind::Light;
        out.reason = format!(
            "IMAGETYP = {}, single plane, BAYERPAT = {}",
            header.text("IMAGETYP").unwrap_or("?").trim(),
            header.text("BAYERPAT").unwrap_or("none").trim()
        );
    }

    out
}

#[derive(Debug, Clone)]
pub struct Group {
    pub key: String,
    pub object: String,
    pub night: String,
    pub filter: String,
    pub exptime: f32,
    pub kind: Kind,
    pub frames: Vec<Scanned>,
}

impl Group {
    pub fn bytes(&self) -> u64 {
        self.frames.iter().map(|f| f.bytes).sum()
    }

    /// Wall-clock span of the group in seconds.
    pub fn span(&self) -> i64 {
        let lo = self.frames.iter().map(|f| f.second).min().unwrap_or(0);
        let hi = self.frames.iter().map(|f| f.second).max().unwrap_or(0);
        hi - lo
    }

    /// Breaks longer than `threshold` seconds — slews, refocus, cloud stops.
    pub fn gaps(&self, threshold: i64) -> Vec<(i64, i64)> {
        let mut m: Vec<i64> = self.frames.iter().map(|f| f.second).collect();
        m.sort_unstable();
        m.windows(2)
            .filter(|w| w[1] - w[0] > threshold)
            .map(|w| (w[0], w[1] - w[0]))
            .collect()
    }
}

#[derive(Debug, Clone, Default)]
pub struct Scan {
    pub root: PathBuf,
    pub groups: Vec<Group>,
    pub unreadable: Vec<Scanned>,
}

impl Scan {
    pub fn files_seen(&self) -> usize {
        self.groups.iter().map(|g| g.frames.len()).sum::<usize>() + self.unreadable.len()
    }

    pub fn lights(&self) -> usize {
        self.groups
            .iter()
            .filter(|g| g.kind == Kind::Light)
            .map(|g| g.frames.len())
            .sum()
    }

    pub fn masters(&self) -> usize {
        self.groups
            .iter()
            .filter(|g| g.kind == Kind::Master)
            .map(|g| g.frames.len())
            .sum()
    }

    pub fn sessions(&self) -> usize {
        self.groups.iter().filter(|g| g.kind == Kind::Light).count()
    }

    pub fn bytes(&self) -> u64 {
        self.groups.iter().map(|g| g.bytes()).sum()
    }

    pub fn exposures(&self) -> Vec<f32> {
        let mut v: Vec<f32> = self
            .groups
            .iter()
            .filter(|g| g.kind == Kind::Light)
            .map(|g| g.exptime)
            .collect();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        v.dedup();
        v
    }
}

pub fn scan_dir(root: &Path) -> std::io::Result<Scan> {
    let root = &root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let mut files: Vec<PathBuf> = Vec::new();
    collect(root, &mut files)?;
    files.sort();

    let mut buckets: BTreeMap<String, Group> = BTreeMap::new();
    let mut unreadable = Vec::new();

    for path in files {
        let s = scan_file(&path);
        if s.kind == Kind::Unreadable {
            unreadable.push(s);
            continue;
        }
        let key = if s.kind == Kind::Master {
            format!("master|{}", s.object)
        } else {
            s.group_key()
        };
        buckets
            .entry(key.clone())
            .or_insert_with(|| Group {
                key,
                object: s.object.clone(),
                night: s.night(),
                filter: s.filter.clone(),
                exptime: s.exptime,
                kind: s.kind,
                frames: Vec::new(),
            })
            .frames
            .push(s);
    }

    let mut groups: Vec<Group> = buckets.into_values().collect();
    for g in groups.iter_mut() {
        g.frames.sort_by_key(|f| f.second);
    }
    groups.sort_by(|a, b| {
        (a.kind == Kind::Master)
            .cmp(&(b.kind == Kind::Master))
            .then(b.night.cmp(&a.night))
    });

    Ok(Scan {
        root: root.to_path_buf(),
        groups,
        unreadable,
    })
}

fn collect(dir: &Path, out: &mut Vec<PathBuf>) -> std::io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let p = entry?.path();
        if p.is_dir() {
            collect(&p, out)?;
        } else if matches!(
            p.extension().and_then(|e| e.to_str()).map(str::to_lowercase).as_deref(),
            Some("fit") | Some("fits") | Some("fts")
        ) {
            out.push(p);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(date: &str, object: &str, exp: f32) -> Scanned {
        Scanned {
            path: PathBuf::new(),
            kind: Kind::Light,
            object: object.into(),
            filter: "LP".into(),
            exptime: exp,
            date_obs: date.into(),
            second: seconds(date),
            width: 2160,
            height: 3840,
            planes: 1,
            bytes: 0,
            reason: String::new(),
        }
    }

    #[test]
    fn night_rolls_over_at_noon_not_midnight() {
        assert_eq!(s("2026-08-14T23:06:42", "X", 60.0).night(), "2026-08-14");
        assert_eq!(s("2026-08-15T03:48:00", "X", 60.0).night(), "2026-08-14");
        assert_eq!(s("2026-08-15T12:00:00", "X", 60.0).night(), "2026-08-15");
        assert_eq!(s("2026-08-15T11:59:00", "X", 60.0).night(), "2026-08-14");
    }

    #[test]
    fn night_rollover_crosses_month_and_year() {
        assert_eq!(s("2026-09-01T02:00:00", "X", 60.0).night(), "2026-08-31");
        assert_eq!(s("2026-01-01T02:00:00", "X", 60.0).night(), "2025-12-31");
        assert_eq!(s("2028-03-01T02:00:00", "X", 60.0).night(), "2028-02-29");
    }

    #[test]
    fn identity_ignores_path() {
        let a = s("2026-08-14T23:06:42", "NGC 7000", 60.0);
        let mut b = a.clone();
        b.path = PathBuf::from("/somewhere/else.fit");
        assert_eq!(a.identity(), b.identity());
    }

    #[test]
    fn different_exposures_are_different_groups() {
        let a = s("2026-08-14T23:06:42", "NGC 7000", 60.0);
        let b = s("2026-08-14T23:07:42", "NGC 7000", 30.0);
        assert_ne!(a.group_key(), b.group_key());
    }

    #[test]
    fn gaps_report_breaks_over_threshold() {
        let g = Group {
            key: String::new(),
            object: "X".into(),
            night: "2026-08-14".into(),
            filter: "LP".into(),
            exptime: 60.0,
            kind: Kind::Light,
            frames: vec![
                s("2026-08-14T23:00:00", "X", 60.0),
                s("2026-08-14T23:01:00", "X", 60.0),
                s("2026-08-14T23:06:00", "X", 60.0),
            ],
        };
        let gaps = g.gaps(120);
        assert_eq!(gaps.len(), 1);
        assert_eq!(gaps[0].1, 300);
    }
}
