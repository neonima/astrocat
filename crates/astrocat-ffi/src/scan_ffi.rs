//! Scan and project-summary access. Held separately from the open catalog so
//! Home and Import can inspect folders without disturbing Library.

use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use astrocat_core::catalog::{self, Kind, Scan};
use astrocat_core::ingest;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct AcScanStats {
    pub files: u32,
    pub lights: u32,
    pub masters: u32,
    pub sessions: u32,
    pub groups: u32,
    pub unreadable: u32,
    pub bytes: i64,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct AcGroup {
    pub kind: i32,
    pub frames: u32,
    pub fresh: u32,
    pub present: u32,
    pub exptime: f32,
    pub bytes: i64,
    pub span: i64,
    pub gaps: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct AcProject {
    pub exists: i32,
    pub sessions: u32,
    pub frames: u32,
    pub kept: u32,
    pub bytes: i64,
    pub last_night: i64,
}

#[derive(Default)]
struct ScanState {
    scan: Option<Scan>,
    fresh: Vec<u32>,
    present: Vec<u32>,
    strings: Vec<CString>,
}

static SCAN: Mutex<Option<ScanState>> = Mutex::new(None);

thread_local! {
    static SCRATCH: std::cell::RefCell<CString> =
        std::cell::RefCell::new(CString::new("").unwrap());
}

fn cs(s: &str) -> CString {
    CString::new(s).unwrap_or_else(|_| CString::new("").unwrap())
}

fn scratch(s: &str) -> *const c_char {
    SCRATCH.with(|c| {
        *c.borrow_mut() = cs(s);
        c.borrow().as_ptr()
    })
}

fn path_arg(p: *const c_char) -> Option<PathBuf> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok().map(PathBuf::from)
}

/// Scans `dir` and compares against the catalog already held in `project`,
/// so the caller can show what is new versus already present.
///
/// # Safety
/// Both arguments must be valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn ac_scan(dir: *const c_char, project: *const c_char) -> i32 {
    let Some(root) = path_arg(dir) else { return -1 };
    let Ok(scan) = catalog::scan_dir(&root) else {
        return -1;
    };

    let known: Vec<String> = path_arg(project)
        .and_then(|p| ingest::load(&p).ok())
        .map(|f| {
            f.iter()
                .map(|r| format!("{}|{}|{:.1}", r.date_obs, r.object, r.exptime))
                .collect()
        })
        .unwrap_or_default();

    let mut fresh = Vec::new();
    let mut present = Vec::new();
    let mut strings = Vec::new();

    for g in &scan.groups {
        let p = g
            .frames
            .iter()
            .filter(|f| known.contains(&f.identity()))
            .count() as u32;
        present.push(p);
        fresh.push(g.frames.len() as u32 - p);

        let name = if g.kind == Kind::Master {
            format!("Master stack · {}", g.object)
        } else {
            format!("{} · {}", g.object, g.night)
        };
        let spec = if g.kind == Kind::Master {
            "NAXIS3=3".to_string()
        } else {
            format!("{} {:.0}s", g.filter, g.exptime)
        };
        strings.push(cs(&name));
        strings.push(cs(&spec));
        strings.push(cs(g.frames.first().map(|f| f.reason.as_str()).unwrap_or("")));
    }

    let n = scan.groups.len() as i32;
    *SCAN.lock().unwrap() = Some(ScanState {
        scan: Some(scan),
        fresh,
        present,
        strings,
    });
    n
}

fn with_scan<T>(f: impl FnOnce(&ScanState, &Scan) -> T, fallback: T) -> T {
    let g = SCAN.lock().unwrap();
    match g.as_ref().and_then(|s| s.scan.as_ref().map(|sc| (s, sc))) {
        Some((s, sc)) => f(s, sc),
        None => fallback,
    }
}

/// # Safety
/// `out` must point to a valid `AcScanStats`.
#[no_mangle]
pub unsafe extern "C" fn ac_scan_stats(out: *mut AcScanStats) -> i32 {
    if out.is_null() {
        return 0;
    }
    with_scan(
        |_, sc| {
            *out = AcScanStats {
                files: sc.files_seen() as u32,
                lights: sc.lights() as u32,
                masters: sc.masters() as u32,
                sessions: sc.sessions() as u32,
                groups: sc.groups.len() as u32,
                unreadable: sc.unreadable.len() as u32,
                bytes: sc.bytes() as i64,
            };
            1
        },
        0,
    )
}

/// # Safety
/// `out` must point to a valid `AcGroup`.
#[no_mangle]
pub unsafe extern "C" fn ac_scan_group(index: u32, out: *mut AcGroup) -> i32 {
    if out.is_null() {
        return 0;
    }
    with_scan(
        |st, sc| {
            let Some(g) = sc.groups.get(index as usize) else {
                return 0;
            };
            *out = AcGroup {
                kind: i32::from(g.kind == Kind::Master),
                frames: g.frames.len() as u32,
                fresh: st.fresh.get(index as usize).copied().unwrap_or(0),
                present: st.present.get(index as usize).copied().unwrap_or(0),
                exptime: g.exptime,
                bytes: g.bytes() as i64,
                span: g.span(),
                gaps: g.gaps(120).len() as u32,
            };
            1
        },
        0,
    )
}

fn group_string(index: u32, offset: usize) -> *const c_char {
    with_scan(
        |st, _| {
            st.strings
                .get(index as usize * 3 + offset)
                .map(|c| c.as_ptr())
                .unwrap_or(std::ptr::null())
        },
        std::ptr::null(),
    )
}

#[no_mangle]
pub extern "C" fn ac_group_name(index: u32) -> *const c_char {
    group_string(index, 0)
}

#[no_mangle]
pub extern "C" fn ac_group_spec(index: u32) -> *const c_char {
    group_string(index, 1)
}

#[no_mangle]
pub extern "C" fn ac_group_reason(index: u32) -> *const c_char {
    group_string(index, 2)
}

#[no_mangle]
pub extern "C" fn ac_group_file(group: u32, frame: u32) -> *const c_char {
    let path = with_scan(
        |_, sc| {
            sc.groups
                .get(group as usize)
                .and_then(|g| g.frames.get(frame as usize))
                .map(|f| f.path.to_string_lossy().into_owned())
        },
        None,
    );
    match path {
        Some(p) => scratch(&p),
        None => std::ptr::null(),
    }
}

/// Raw 80-column header cards, newline separated — the evidence pane shows
/// these verbatim rather than a parsed summary.
///
/// # Safety
/// `path` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn ac_header_text(path: *const c_char) -> *const c_char {
    let Some(p) = path_arg(path) else {
        return std::ptr::null();
    };
    let Ok(file) = std::fs::File::open(&p) else {
        return std::ptr::null();
    };

    use std::io::Read;
    let mut r = std::io::BufReader::new(file);
    let mut out = String::new();
    let mut block = [0u8; 2880];

    'outer: for _ in 0..16 {
        if r.read_exact(&mut block).is_err() {
            break;
        }
        for card in block.chunks_exact(80) {
            let line = String::from_utf8_lossy(card);
            let trimmed = line.trim_end();
            if trimmed.starts_with("END") {
                out.push_str("END\n");
                break 'outer;
            }
            if !trimmed.is_empty() {
                out.push_str(trimmed);
                out.push('\n');
            }
        }
    }
    scratch(&out)
}

/// Summary of a project on disk, without opening it as the active catalog.
///
/// # Safety
/// `dir` must be valid; `out` must point to a valid `AcProject`.
#[no_mangle]
pub unsafe extern "C" fn ac_project_summary(dir: *const c_char, out: *mut AcProject) -> i32 {
    if out.is_null() {
        return 0;
    }
    let Some(root) = path_arg(dir) else { return 0 };

    let mut p = AcProject {
        exists: i32::from(Path::new(&root).exists()),
        ..Default::default()
    };

    if let Ok(frames) = ingest::load(&root) {
        let mut nights: Vec<&str> = frames.iter().map(|f| f.night.as_str()).collect();
        nights.sort_unstable();
        nights.dedup();
        p.sessions = nights.len() as u32;
        p.frames = frames.len() as u32;
        p.kept = frames.iter().filter(|f| !f.rejected).count() as u32;
        p.last_night = frames.iter().map(|f| f.second).max().unwrap_or(0);
        p.bytes = frames
            .iter()
            .filter_map(|f| std::fs::metadata(&f.path).ok())
            .map(|m| m.len() as i64)
            .sum();
    }

    *out = p;
    1
}
