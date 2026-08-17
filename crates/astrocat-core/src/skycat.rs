use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use crate::color::CatalogStar;

const MAGIC: &[u8; 16] = b"AstroCat sky v1\0";
/// Positions as micro-degrees: 3.6 mas, far finer than any pixel scale we will
/// see, and half the size of storing degrees as f64.
const MICRO: f64 = 1_000_000.0;
const RECORD: usize = 14;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Tile {
    pub ra0: f64,
    pub ra1: f64,
    pub dec0: f64,
    pub dec1: f64,
    pub offset: u64,
    pub count: u32,
    /// The limiting magnitude actually fetched, so a later deeper pass can tell
    /// which tiles it still has to ask for.
    pub mag: f32,
}

impl Tile {
    pub fn done(&self) -> bool {
        self.mag > 0.0
    }

    fn centre(&self) -> (f64, f64) {
        ((self.ra0 + self.ra1) / 2.0, (self.dec0 + self.dec1) / 2.0)
    }

    /// Conservative: the tile's corners against the cone, plus the cone centre
    /// falling inside the tile. Cheap and never rejects an overlapping tile.
    fn overlaps(&self, ra: f64, dec: f64, radius: f64) -> bool {
        if dec + radius < self.dec0 || dec - radius > self.dec1 {
            return false;
        }
        if ra >= self.ra0 && ra <= self.ra1 {
            return true;
        }
        let widen = radius / self.centre().1.to_radians().cos().abs().max(0.02);
        let lo = self.ra0 - widen;
        let hi = self.ra1 + widen;
        (ra >= lo && ra <= hi)
            || (ra + 360.0 >= lo && ra + 360.0 <= hi)
            || (ra - 360.0 >= lo && ra - 360.0 <= hi)
    }
}

pub struct Store {
    dir: PathBuf,
    pub tiles: Vec<Tile>,
    pub min_dec: f64,
    pub mag_limit: f32,
    data_len: u64,
}

fn angular_sep(ra1: f64, dec1: f64, ra2: f64, dec2: f64) -> f64 {
    let (r1, d1, r2, d2) = (
        ra1.to_radians(),
        dec1.to_radians(),
        ra2.to_radians(),
        dec2.to_radians(),
    );
    let c = d1.sin() * d2.sin() + d1.cos() * d2.cos() * (r1 - r2).cos();
    c.clamp(-1.0, 1.0).acos().to_degrees()
}

/// Bands of constant declination, each split into as many cells as its own
/// circumference needs. Not HEALPix, but a cone search only has to test a few
/// hundred rectangles and the inverse mapping stays obvious.
pub fn plan(min_dec: f64, cell_deg: f64) -> Vec<Tile> {
    let cell = cell_deg.clamp(2.0, 45.0);
    let start = min_dec.clamp(-90.0, 89.0);
    let bands = (((90.0 - start) / cell).ceil() as usize).max(1);
    let height = (90.0 - start) / bands as f64;

    let mut tiles = Vec::new();
    for b in 0..bands {
        let dec0 = start + b as f64 * height;
        let dec1 = dec0 + height;
        // Widen towards the pole, where a band of fixed RA width covers much
        // less sky than the same width at the equator.
        let shrink = dec0.abs().max(dec1.abs()).to_radians().cos().max(0.02);
        let n = (((360.0 * shrink) / cell).ceil() as usize).max(1);
        let width = 360.0 / n as f64;
        for i in 0..n {
            tiles.push(Tile {
                ra0: i as f64 * width,
                ra1: (i + 1) as f64 * width,
                dec0,
                dec1,
                offset: 0,
                count: 0,
                mag: 0.0,
            });
        }
    }
    tiles
}

impl Store {
    pub fn open(dir: &Path, min_dec: f64, mag_limit: f32, cell_deg: f64) -> std::io::Result<Store> {
        std::fs::create_dir_all(dir)?;
        let mut store = Store {
            dir: dir.to_path_buf(),
            tiles: Vec::new(),
            min_dec,
            mag_limit,
            data_len: 0,
        };

        if store.load_index().is_err() || store.tiles.is_empty() {
            store.tiles = plan(min_dec, cell_deg);
            store.min_dec = min_dec;
            store.mag_limit = mag_limit;
            store.data_len = std::fs::metadata(store.data_path()).map(|m| m.len()).unwrap_or(0);
        }
        Ok(store)
    }

    fn index_path(&self) -> PathBuf {
        self.dir.join("gaia.idx")
    }

    fn data_path(&self) -> PathBuf {
        self.dir.join("gaia.dat")
    }

    fn load_index(&mut self) -> std::io::Result<()> {
        let mut buf = Vec::new();
        File::open(self.index_path())?.read_to_end(&mut buf)?;
        if buf.len() < 32 || &buf[..16] != MAGIC {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "not an AstroCat sky index",
            ));
        }
        self.min_dec = f64::from_le_bytes(buf[16..24].try_into().unwrap());
        self.mag_limit = f32::from_le_bytes(buf[24..28].try_into().unwrap());
        let count = u32::from_le_bytes(buf[28..32].try_into().unwrap()) as usize;

        let mut tiles = Vec::with_capacity(count);
        for i in 0..count {
            let o = 32 + i * 48;
            if o + 48 > buf.len() {
                break;
            }
            let f = |k: usize| f64::from_le_bytes(buf[o + k..o + k + 8].try_into().unwrap());
            tiles.push(Tile {
                ra0: f(0),
                ra1: f(8),
                dec0: f(16),
                dec1: f(24),
                offset: u64::from_le_bytes(buf[o + 32..o + 40].try_into().unwrap()),
                count: u32::from_le_bytes(buf[o + 40..o + 44].try_into().unwrap()),
                mag: f32::from_le_bytes(buf[o + 44..o + 48].try_into().unwrap()),
            });
        }
        self.tiles = tiles;
        self.data_len = std::fs::metadata(self.data_path()).map(|m| m.len()).unwrap_or(0);
        Ok(())
    }

    pub fn flush(&self) -> std::io::Result<()> {
        let mut out = BufWriter::new(File::create(self.index_path())?);
        out.write_all(MAGIC)?;
        out.write_all(&self.min_dec.to_le_bytes())?;
        out.write_all(&self.mag_limit.to_le_bytes())?;
        out.write_all(&(self.tiles.len() as u32).to_le_bytes())?;
        for t in &self.tiles {
            for v in [t.ra0, t.ra1, t.dec0, t.dec1] {
                out.write_all(&v.to_le_bytes())?;
            }
            out.write_all(&t.offset.to_le_bytes())?;
            out.write_all(&t.count.to_le_bytes())?;
            out.write_all(&t.mag.to_le_bytes())?;
        }
        out.flush()
    }

    /// Splits a tile whose response came back at the server's row cap into four,
    /// so a dense patch of the galactic plane is fetched in pieces rather than
    /// silently truncated.
    pub fn split(&mut self, index: usize) -> usize {
        let Some(t) = self.tiles.get(index).copied() else {
            return 0;
        };
        let (rm, dm) = ((t.ra0 + t.ra1) / 2.0, (t.dec0 + t.dec1) / 2.0);
        let children = [
            (t.ra0, rm, t.dec0, dm),
            (rm, t.ra1, t.dec0, dm),
            (t.ra0, rm, dm, t.dec1),
            (rm, t.ra1, dm, t.dec1),
        ];
        // Mark the parent done so the plan does not offer it again; its children
        // carry the actual rows.
        self.tiles[index].mag = -1.0;
        self.tiles[index].count = 0;
        for (ra0, ra1, dec0, dec1) in children {
            self.tiles.push(Tile {
                ra0,
                ra1,
                dec0,
                dec1,
                offset: 0,
                count: 0,
                mag: 0.0,
            });
        }
        4
    }

    pub fn next_pending(&self, from: usize) -> Option<usize> {
        self.tiles
            .iter()
            .enumerate()
            .skip(from)
            .find(|(_, t)| t.mag == 0.0)
            .map(|(i, _)| i)
    }

    pub fn pending(&self) -> usize {
        self.tiles.iter().filter(|t| t.mag == 0.0).count()
    }

    pub fn stars(&self) -> u64 {
        self.tiles.iter().map(|t| t.count as u64).sum()
    }

    pub fn bytes(&self) -> u64 {
        self.data_len
    }

    pub fn append(&mut self, index: usize, csv: &str, mag: f32) -> std::io::Result<usize> {
        let stars = crate::color::parse_gaia_csv(csv);
        let mut packed = Vec::with_capacity(stars.len() * RECORD);
        for s in &stars {
            let ra = (s.ra.rem_euclid(360.0) * MICRO) as i32;
            let dec = (s.dec.clamp(-90.0, 90.0) * MICRO) as i32;
            packed.extend_from_slice(&ra.to_le_bytes());
            packed.extend_from_slice(&dec.to_le_bytes());
            for m in [s.g, s.bp, s.rp] {
                packed.extend_from_slice(&((m * 100.0).clamp(-32000.0, 32000.0) as i16).to_le_bytes());
            }
        }

        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.data_path())?;
        let offset = file.seek(SeekFrom::End(0))?;
        file.write_all(&packed)?;

        self.data_len = offset + packed.len() as u64;
        if let Some(t) = self.tiles.get_mut(index) {
            t.offset = offset;
            t.count = stars.len() as u32;
            t.mag = mag;
        }
        Ok(stars.len())
    }

    pub fn cone(&self, ra: f64, dec: f64, radius: f64) -> std::io::Result<Vec<CatalogStar>> {
        let mut file = File::open(self.data_path())?;
        let mut out = Vec::new();
        let mut buf = Vec::new();

        for t in self.tiles.iter().filter(|t| t.count > 0 && t.overlaps(ra, dec, radius)) {
            buf.resize(t.count as usize * RECORD, 0);
            file.seek(SeekFrom::Start(t.offset))?;
            if file.read_exact(&mut buf).is_err() {
                continue;
            }
            for r in buf.chunks_exact(RECORD) {
                let sra = i32::from_le_bytes(r[0..4].try_into().unwrap()) as f64 / MICRO;
                let sdec = i32::from_le_bytes(r[4..8].try_into().unwrap()) as f64 / MICRO;
                if angular_sep(ra, dec, sra, sdec) > radius {
                    continue;
                }
                let m = |k: usize| i16::from_le_bytes(r[k..k + 2].try_into().unwrap()) as f32 / 100.0;
                out.push(CatalogStar {
                    ra: sra,
                    dec: sdec,
                    g: m(8),
                    bp: m(10),
                    rp: m(12),
                });
            }
        }
        Ok(out)
    }
}

/// Declinations that clear `min_altitude` at culmination from this latitude.
/// Everything further south never rises high enough to be worth catalogue space.
pub fn visible_min_dec(latitude: f64, min_altitude: f64) -> f64 {
    (latitude - 90.0 + min_altitude).clamp(-90.0, 60.0)
}

/// Fraction of the celestial sphere above `min_dec`, for showing what the
/// horizon cut actually saves.
pub fn sky_fraction(min_dec: f64) -> f64 {
    (1.0 - min_dec.to_radians().sin()) / 2.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plan_covers_every_visible_declination() {
        let tiles = plan(-24.35, 10.0);
        assert!(!tiles.is_empty());
        assert!((tiles.iter().map(|t| t.dec0).fold(f64::MAX, f64::min) - -24.35).abs() < 1e-9);
        assert!((tiles.iter().map(|t| t.dec1).fold(f64::MIN, f64::max) - 90.0).abs() < 1e-9);

        // Every RA is covered within each band.
        for dec in [-20.0, 0.0, 45.0, 80.0] {
            for ra in [0.0, 90.0, 180.0, 359.9] {
                assert!(
                    tiles
                        .iter()
                        .any(|t| ra >= t.ra0 && ra < t.ra1 && dec >= t.dec0 && dec < t.dec1),
                    "gap at {ra} {dec}"
                );
            }
        }
    }

    #[test]
    fn polar_bands_use_fewer_cells_than_the_equator() {
        let tiles = plan(-24.0, 10.0);
        let at = |d: f64| tiles.iter().filter(|t| d >= t.dec0 && d < t.dec1).count();
        assert!(at(0.0) > at(80.0), "{} vs {}", at(0.0), at(80.0));
    }

    #[test]
    fn the_horizon_cut_matches_the_site() {
        // Northern France: nothing below about -24 clears 20 degrees altitude.
        let d = visible_min_dec(45.6455, 20.0);
        assert!((d - -24.3545).abs() < 1e-3, "{d}");
        assert!((sky_fraction(d) - 0.706).abs() < 0.01, "{}", sky_fraction(d));
    }

    #[test]
    fn a_round_trip_through_the_store_keeps_the_stars() {
        let dir = std::env::temp_dir().join(format!("astrocat-skycat-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut store = Store::open(&dir, -24.0, 13.0, 10.0).expect("open");

        let index = store.next_pending(0).expect("a pending tile");
        let t = store.tiles[index];
        let (ra, dec) = t.centre();
        let csv = format!(
            "ra,dec,phot_g_mean_mag,phot_bp_mean_mag,phot_rp_mean_mag\n\
             {ra},{dec},11.5,12.0,10.8\n\
             {},{},9.25,9.5,8.9\n",
            ra + 0.01,
            dec + 0.01
        );
        assert_eq!(store.append(index, &csv, 13.0).expect("append"), 2);
        store.flush().expect("flush");

        let reopened = Store::open(&dir, -24.0, 13.0, 10.0).expect("reopen");
        assert_eq!(reopened.stars(), 2);
        let found = reopened.cone(ra, dec, 0.5).expect("cone");
        assert_eq!(found.len(), 2, "{found:?}");
        assert!((found[0].ra - ra).abs() < 1e-5);
        assert!((found[0].g - 11.5).abs() < 0.01);
        assert!((found[0].colour() - 1.2).abs() < 0.02);

        // A cone somewhere else must not pick them up.
        let far = reopened.cone((ra + 180.0) % 360.0, -dec, 0.5).expect("cone");
        assert!(far.is_empty(), "{far:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn splitting_replaces_a_tile_with_four_children() {
        let dir = std::env::temp_dir().join(format!("astrocat-split-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut store = Store::open(&dir, -24.0, 13.0, 10.0).expect("open");
        let before = store.tiles.len();
        let pending = store.pending();

        let t = store.tiles[0];
        assert_eq!(store.split(0), 4);
        assert_eq!(store.tiles.len(), before + 4);
        // The parent stops being offered, and the four children take its place.
        assert_eq!(store.pending(), pending - 1 + 4);

        let kids = &store.tiles[before..];
        assert!(kids.iter().all(|k| k.dec0 >= t.dec0 && k.dec1 <= t.dec1));
        assert!(kids.iter().all(|k| k.ra0 >= t.ra0 && k.ra1 <= t.ra1));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
