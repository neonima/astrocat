//! Catalog access over the C ABI. State is a single open project held behind a
//! mutex; strings are returned as pointers into that state and stay valid until
//! the next `ac_catalog_open`.

use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::sync::Mutex;

use astrocat_core::catalog;
use astrocat_core::ingest::{self, FrameRecord};

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct AcFrame {
    pub id: u32,
    pub session: u32,
    pub stars: u32,
    pub width: u32,
    pub height: u32,
    pub second: i64,
    pub hfr: f32,
    pub ecc: f32,
    pub background: f32,
    pub noise: f32,
    pub quality: f32,
    pub exptime: f32,
    pub gain: f32,
    pub ccd_temp: f32,
    pub rejected: i32,
    pub ra: f32,
    pub dec: f32,
    pub focal_len: f32,
    pub pixel_size: f32,
    pub scale: f32,
    pub has_wcs: i32,
    pub trails: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct AcSession {
    pub first: u32,
    pub count: u32,
    pub kept: u32,
    pub exptime: f32,
    pub start: i64,
    pub end: i64,
}

struct Session {
    night: CString,
    first: u32,
    count: u32,
    exptime: f32,
    start: i64,
    end: i64,
}

#[derive(Default)]
struct State {
    root: PathBuf,
    frames: Vec<FrameRecord>,
    sessions: Vec<Session>,
    strings: Vec<CString>,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

fn cs(s: &str) -> CString {
    CString::new(s).unwrap_or_else(|_| CString::new("").unwrap())
}

fn build_sessions(frames: &[FrameRecord]) -> Vec<Session> {
    let mut out: Vec<Session> = Vec::new();
    for (i, f) in frames.iter().enumerate() {
        let night = f.night.clone();
        match out.last_mut() {
            Some(s) if s.night.to_str().unwrap_or("") == night => {
                s.count += 1;
                s.end = f.second;
            }
            _ => out.push(Session {
                night: cs(&night),
                first: i as u32,
                count: 1,
                exptime: f.exptime,
                start: f.second,
                end: f.second,
            }),
        }
    }
    out
}

/// Returns the number of frames loaded, or -1 if the catalog is missing.
///
/// # Safety
/// `dir` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn ac_catalog_open(dir: *const c_char) -> i32 {
    if dir.is_null() {
        return -1;
    }
    let Ok(path) = CStr::from_ptr(dir).to_str() else {
        return -1;
    };
    let root = PathBuf::from(path);

    let Ok(mut frames) = ingest::load(&root) else {
        return -1;
    };
    frames.sort_by_key(|f| f.second);

    let mut strings = Vec::with_capacity(frames.len() * 5);
    for f in &frames {
        strings.push(cs(&f.path.to_string_lossy()));
        strings.push(cs(&f.date_obs));
        strings.push(cs(&f.object));
        strings.push(cs(&f.telescope));
        strings.push(cs(&f.filter));
    }

    let sessions = build_sessions(&frames);
    let n = frames.len() as i32;
    *STATE.lock().unwrap() = Some(State {
        root,
        frames,
        sessions,
        strings,
    });
    n
}

/// Scans a directory and ingests it into `.astrocat`, then opens it.
/// Blocking; the caller should run it off the main thread.
///
/// # Safety
/// `dir` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn ac_catalog_build(dir: *const c_char) -> i32 {
    if dir.is_null() {
        return -1;
    }
    let Ok(path) = CStr::from_ptr(dir).to_str() else {
        return -1;
    };
    let root = PathBuf::from(path);

    let Ok(scan) = catalog::scan_dir(&root) else {
        return -1;
    };
    let frames = ingest::ingest(&scan, |_, _| {});
    if ingest::save(&root, &frames).is_err() {
        return -1;
    }
    ac_catalog_open(dir)
}

fn with_state<T>(f: impl FnOnce(&State) -> T, fallback: T) -> T {
    match STATE.lock().unwrap().as_ref() {
        Some(s) => f(s),
        None => fallback,
    }
}

#[no_mangle]
pub extern "C" fn ac_frame_count() -> u32 {
    with_state(|s| s.frames.len() as u32, 0)
}

#[no_mangle]
pub extern "C" fn ac_session_count() -> u32 {
    with_state(|s| s.sessions.len() as u32, 0)
}

/// # Safety
/// `out` must point to a valid `AcFrame`.
#[no_mangle]
pub unsafe extern "C" fn ac_frame(index: u32, out: *mut AcFrame) -> i32 {
    if out.is_null() {
        return 0;
    }
    with_state(
        |s| {
            let Some(f) = s.frames.get(index as usize) else {
                return 0;
            };
            let session = s
                .sessions
                .iter()
                .position(|x| index >= x.first && index < x.first + x.count)
                .unwrap_or(0) as u32;
            *out = AcFrame {
                id: f.id,
                session,
                stars: f.stars,
                width: f.width,
                height: f.height,
                second: f.second,
                hfr: f.hfr,
                ecc: f.ecc,
                background: f.background,
                noise: f.noise,
                quality: f.quality,
                exptime: f.exptime,
                gain: f.gain,
                ccd_temp: f.ccd_temp,
                rejected: i32::from(f.rejected),
                ra: f.ra,
                dec: f.dec,
                focal_len: f.focal_len,
                pixel_size: f.pixel_size,
                scale: f.scale,
                has_wcs: i32::from(f.has_wcs),
                trails: f.trails,
            };
            1
        },
        0,
    )
}

/// # Safety
/// `out` must point to a valid `AcSession`.
#[no_mangle]
pub unsafe extern "C" fn ac_session(index: u32, out: *mut AcSession) -> i32 {
    if out.is_null() {
        return 0;
    }
    with_state(
        |s| {
            let Some(x) = s.sessions.get(index as usize) else {
                return 0;
            };
            let kept = s.frames[x.first as usize..(x.first + x.count) as usize]
                .iter()
                .filter(|f| !f.rejected)
                .count() as u32;
            *out = AcSession {
                first: x.first,
                count: x.count,
                kept,
                exptime: x.exptime,
                start: x.start,
                end: x.end,
            };
            1
        },
        0,
    )
}

fn string_at(index: u32, offset: usize) -> *const c_char {
    with_state(
        |s| {
            s.strings
                .get(index as usize * 5 + offset)
                .map(|c| c.as_ptr())
                .unwrap_or(std::ptr::null())
        },
        std::ptr::null(),
    )
}

#[no_mangle]
pub extern "C" fn ac_frame_path(index: u32) -> *const c_char {
    string_at(index, 0)
}

#[no_mangle]
pub extern "C" fn ac_frame_date(index: u32) -> *const c_char {
    string_at(index, 1)
}

#[no_mangle]
pub extern "C" fn ac_frame_object(index: u32) -> *const c_char {
    string_at(index, 2)
}

#[no_mangle]
pub extern "C" fn ac_frame_telescope(index: u32) -> *const c_char {
    string_at(index, 3)
}

#[no_mangle]
pub extern "C" fn ac_frame_filter(index: u32) -> *const c_char {
    string_at(index, 4)
}

#[no_mangle]
pub extern "C" fn ac_session_night(index: u32) -> *const c_char {
    with_state(
        |s| {
            s.sessions
                .get(index as usize)
                .map(|x| x.night.as_ptr())
                .unwrap_or(std::ptr::null())
        },
        std::ptr::null(),
    )
}

#[no_mangle]
pub extern "C" fn ac_set_rejected(index: u32, rejected: i32) {
    if let Some(s) = STATE.lock().unwrap().as_mut() {
        if let Some(f) = s.frames.get_mut(index as usize) {
            f.rejected = rejected != 0;
        }
    }
}

/// Rejects every frame whose quality rank falls below `threshold`.
/// Returns how many are now rejected.
#[no_mangle]
pub extern "C" fn ac_cull_below(threshold: f32) -> u32 {
    let mut state = STATE.lock().unwrap();
    let Some(s) = state.as_mut() else { return 0 };
    for f in s.frames.iter_mut() {
        f.rejected = f.quality < threshold;
    }
    s.frames.iter().filter(|f| f.rejected).count() as u32
}

#[no_mangle]
pub extern "C" fn ac_catalog_save() -> i32 {
    let state = STATE.lock().unwrap();
    let Some(s) = state.as_ref() else { return 0 };
    i32::from(ingest::save(&s.root, &s.frames).is_ok())
}
