//! All `AcBuf` pointers must come from `ac_load_fits` and must not be used
//! after `ac_buf_free`.

pub mod catalog_ffi;
pub mod job_ffi;
pub mod scan_ffi;
pub mod sky_ffi;

use std::cell::RefCell;
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::time::Instant;

use astrocat_core::{auto_stf_channels, fits};

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct AcInfo {
    pub width: u32,
    pub height: u32,
    pub src_width: u32,
    pub src_height: u32,
    pub planes: u32,
    pub shadows_r: f32,
    pub shadows_g: f32,
    pub shadows_b: f32,
    pub midtone_r: f32,
    pub midtone_g: f32,
    pub midtone_b: f32,
    pub median: f32,
    pub mad: f32,
    pub pedestal: f32,
    pub exposure: f32,
    pub gain: f32,
    pub ccd_temp: f32,
    pub load_ms: f32,
    pub site_lat: f32,
    pub site_long: f32,
    /// The normalisation used, so a derived frame can be put on the same scale.
    pub full_scale: f32,
}

impl Default for AcInfo {
    fn default() -> Self {
        Self {
            width: 0,
            height: 0,
            src_width: 0,
            src_height: 0,
            planes: 0,
            shadows_r: 0.0,
            shadows_g: 0.0,
            shadows_b: 0.0,
            midtone_r: 0.5,
            midtone_g: 0.5,
            midtone_b: 0.5,
            median: 0.0,
            mad: 0.0,
            pedestal: 0.0,
            exposure: 0.0,
            gain: 0.0,
            ccd_temp: 0.0,
            load_ms: 0.0,
            site_lat: 0.0,
            site_long: 0.0,
            full_scale: 0.0,
        }
    }
}

pub struct AcBuf {
    pixels: Vec<u16>,
    object: CString,
    date_obs: CString,
    bayer: CString,
    telescope: CString,
    filter: CString,
}

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(empty_cstring());
}

fn empty_cstring() -> CString {
    CString::new("").expect("empty string is valid")
}

fn set_error(msg: &str) {
    LAST_ERROR.with(|e| {
        *e.borrow_mut() = CString::new(msg).unwrap_or_else(|_| empty_cstring());
    });
}

fn cstring(s: &str) -> CString {
    CString::new(s).unwrap_or_else(|_| empty_cstring())
}

#[no_mangle]
pub extern "C" fn ac_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

/// Returns null on failure; see `ac_last_error`. Release with `ac_buf_free`.
#[no_mangle]
pub unsafe extern "C" fn ac_load_fits(path: *const c_char, out: *mut AcInfo) -> *mut AcBuf {
    ac_load_fits_scaled(path, 0.0, out)
}

/// `scale` above zero forces the normalisation instead of using this frame's
/// own maximum.
///
/// # Safety
/// `path` must be a valid NUL-terminated string and `out` writable.
#[no_mangle]
pub unsafe extern "C" fn ac_load_fits_scaled(
    path: *const c_char,
    scale: f32,
    out: *mut AcInfo,
) -> *mut AcBuf {
    if path.is_null() || out.is_null() {
        set_error("null argument");
        return std::ptr::null_mut();
    }

    let started = Instant::now();

    let path = match CStr::from_ptr(path).to_str() {
        Ok(p) => PathBuf::from(p),
        Err(_) => {
            set_error("path is not valid UTF-8");
            return std::ptr::null_mut();
        }
    };

    let img = match fits::read(&path) {
        Ok(i) => i,
        Err(e) => {
            set_error(&format!("{}: {e}", path.display()));
            return std::ptr::null_mut();
        }
    };

    let (rgb, pedestal, full_scale) = astrocat_core::debayer::to_display_scaled(&img, scale);
    let normalised = &rgb.data;
    let stf = auto_stf_channels(normalised, 7);

    let mut pixels = vec![0u16; rgb.pixels() * 4];
    for (i, chunk) in normalised.chunks_exact(3).enumerate() {
        let o = i * 4;
        pixels[o] = (chunk[0] * 65535.0) as u16;
        pixels[o + 1] = (chunk[1] * 65535.0) as u16;
        pixels[o + 2] = (chunk[2] * 65535.0) as u16;
        pixels[o + 3] = u16::MAX;
    }

    *out = AcInfo {
        width: rgb.width as u32,
        height: rgb.height as u32,
        src_width: img.width as u32,
        src_height: img.height as u32,
        planes: img.planes as u32,
        shadows_r: stf[0].shadows,
        shadows_g: stf[1].shadows,
        shadows_b: stf[2].shadows,
        midtone_r: stf[0].midtone,
        midtone_g: stf[1].midtone,
        midtone_b: stf[2].midtone,
        median: stf[1].median,
        mad: stf[1].mad,
        pedestal,
        exposure: img.header.float("EXPTIME").unwrap_or(0.0) as f32,
        gain: img.header.float("GAIN").unwrap_or(0.0) as f32,
        ccd_temp: img.header.float("CCD-TEMP").unwrap_or(0.0) as f32,
        load_ms: started.elapsed().as_secs_f32() * 1000.0,
        site_lat: img.header.float("SITELAT").unwrap_or(0.0) as f32,
        site_long: img.header.float("SITELONG").unwrap_or(0.0) as f32,
        full_scale,
    };

    Box::into_raw(Box::new(AcBuf {
        pixels,
        object: cstring(img.header.text("OBJECT").unwrap_or("").trim()),
        date_obs: cstring(img.header.text("DATE-OBS").unwrap_or("").trim()),
        bayer: cstring(img.bayer_pattern().unwrap_or("")),
        telescope: cstring(img.header.text("TELESCOP").unwrap_or("").trim()),
        filter: cstring(img.header.text("FILTER").unwrap_or("").trim()),
    }))
}

#[no_mangle]
pub unsafe extern "C" fn ac_buf_pixels(buf: *const AcBuf) -> *const u16 {
    if buf.is_null() {
        return std::ptr::null();
    }
    (*buf).pixels.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn ac_buf_len(buf: *const AcBuf) -> usize {
    if buf.is_null() {
        return 0;
    }
    (*buf).pixels.len()
}

macro_rules! text_accessor {
    ($name:ident, $field:ident) => {
        #[no_mangle]
        pub unsafe extern "C" fn $name(buf: *const AcBuf) -> *const c_char {
            if buf.is_null() {
                return std::ptr::null();
            }
            (*buf).$field.as_ptr()
        }
    };
}

text_accessor!(ac_buf_object, object);
text_accessor!(ac_buf_date_obs, date_obs);
text_accessor!(ac_buf_bayer, bayer);
text_accessor!(ac_buf_telescope, telescope);
text_accessor!(ac_buf_filter, filter);

#[no_mangle]
pub unsafe extern "C" fn ac_buf_free(buf: *mut AcBuf) {
    if !buf.is_null() {
        drop(Box::from_raw(buf));
    }
}
