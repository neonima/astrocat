//! The all-sky catalogue store. One process-wide store, opened by path, driven
//! tile by tile from Swift so the HTTP and the progress reporting stay on the
//! platform's own networking rather than being reimplemented in Rust.

use std::ffi::{c_char, CStr};
use std::path::PathBuf;
use std::sync::Mutex;

use astrocat_core::skycat::{self, Store};

static STORE: Mutex<Option<Store>> = Mutex::new(None);

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct AcTile {
    pub ra0: f64,
    pub ra1: f64,
    pub dec0: f64,
    pub dec1: f64,
    pub index: u32,
    pub done: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct AcCatalogStats {
    pub min_dec: f64,
    pub sky_fraction: f64,
    pub stars: u64,
    pub bytes: u64,
    pub tiles_total: u32,
    pub tiles_done: u32,
    pub mag_limit: f32,
    pub open: i32,
}

/// # Safety
/// `dir` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn ac_sky_open(dir: *const c_char, min_dec: f64, mag_limit: f32) -> i32 {
    let Some(d) = (if dir.is_null() { None } else { CStr::from_ptr(dir).to_str().ok() }) else {
        return 0;
    };
    // Query cost is dominated by a fixed per-request scan, not by rows
    // returned, so tiles are as coarse as the row cap allows and the dense
    // patches of the galactic plane get split on demand.
    match Store::open(&PathBuf::from(d), min_dec, mag_limit, 20.0) {
        Ok(s) => {
            *STORE.lock().unwrap() = Some(s);
            1
        }
        Err(_) => 0,
    }
}

/// # Safety
/// `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn ac_sky_stats(out: *mut AcCatalogStats) -> i32 {
    if out.is_null() {
        return 0;
    }
    *out = AcCatalogStats::default();
    let guard = STORE.lock().unwrap();
    let Some(s) = guard.as_ref() else {
        return 0;
    };
    *out = AcCatalogStats {
        min_dec: s.min_dec,
        sky_fraction: skycat::sky_fraction(s.min_dec),
        stars: s.stars(),
        bytes: s.bytes(),
        tiles_total: s.tiles.len() as u32,
        tiles_done: (s.tiles.len() - s.pending()) as u32,
        mag_limit: s.mag_limit,
        open: 1,
    };
    1
}

/// Returns 1 and fills `out` with the next tile still to fetch, or 0 when the
/// catalogue is complete.
///
/// # Safety
/// `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn ac_sky_next_tile(from: u32, out: *mut AcTile) -> i32 {
    if out.is_null() {
        return 0;
    }
    *out = AcTile::default();
    let guard = STORE.lock().unwrap();
    let Some(s) = guard.as_ref() else {
        return 0;
    };
    let Some(i) = s.next_pending(from as usize) else {
        return 0;
    };
    let t = s.tiles[i];
    *out = AcTile {
        ra0: t.ra0,
        ra1: t.ra1,
        dec0: t.dec0,
        dec1: t.dec1,
        index: i as u32,
        done: 0,
    };
    1
}

/// Returns the number of rows stored, or -1 on failure.
///
/// # Safety
/// `csv` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn ac_sky_append(index: u32, csv: *const c_char, mag: f32) -> i32 {
    let Some(text) = (if csv.is_null() { None } else { CStr::from_ptr(csv).to_str().ok() }) else {
        return -1;
    };
    let mut guard = STORE.lock().unwrap();
    let Some(s) = guard.as_mut() else {
        return -1;
    };
    match s.append(index as usize, text, mag) {
        Ok(n) => n as i32,
        Err(_) => -1,
    }
}

#[no_mangle]
pub extern "C" fn ac_sky_split(index: u32) -> i32 {
    let mut guard = STORE.lock().unwrap();
    let Some(s) = guard.as_mut() else {
        return 0;
    };
    s.split(index as usize) as i32
}

#[no_mangle]
pub extern "C" fn ac_sky_flush() -> i32 {
    let guard = STORE.lock().unwrap();
    match guard.as_ref().map(|s| s.flush()) {
        Some(Ok(())) => 1,
        _ => 0,
    }
}

#[no_mangle]
pub extern "C" fn ac_sky_close() {
    *STORE.lock().unwrap() = None;
}

#[no_mangle]
pub extern "C" fn ac_sky_visible_min_dec(latitude: f64, min_altitude: f64) -> f64 {
    skycat::visible_min_dec(latitude, min_altitude)
}

#[no_mangle]
pub extern "C" fn ac_sky_fraction(min_dec: f64) -> f64 {
    skycat::sky_fraction(min_dec)
}

pub(crate) fn cone(ra: f64, dec: f64, radius: f64) -> Vec<astrocat_core::color::CatalogStar> {
    let guard = STORE.lock().unwrap();
    guard
        .as_ref()
        .and_then(|s| s.cone(ra, dec, radius).ok())
        .unwrap_or_default()
}
