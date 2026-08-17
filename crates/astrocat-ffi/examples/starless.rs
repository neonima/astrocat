//! End-to-end star separation through the same FFI the app calls, so the
//! numbers in CLAUDE.md come from the shipped path rather than a prototype.
//!
//! cargo run --release --example starless -- <master> <starnet2-binary>

use std::ffi::CString;
use std::path::PathBuf;
use std::process::Command;

use astrocat_ffi::job_ffi::{ac_fits_prestretch, ac_fits_swap_rb, ac_fits_unstretch, AcMlPrep};

fn c(s: &str) -> CString {
    CString::new(s).expect("path has no interior NUL")
}

fn report(label: &str, path: &PathBuf) {
    let img = astrocat_core::fits::read(path).expect("readable FITS");
    let n = img.width * img.height;
    println!("{label}");
    for ch in 0..img.planes.min(3) {
        let plane = &img.data[ch * n..(ch + 1) * n];
        let mut sorted: Vec<f32> = plane.to_vec();
        let k = sorted.len() / 2;
        sorted.select_nth_unstable_by(k, |a, b| a.partial_cmp(b).unwrap());
        let zeros = plane.iter().filter(|v| **v <= 0.0).count();
        println!(
            "   ch{ch}: med={:.6} min={:.6} max={:.6}  <=0: {zeros} ({:.4}%)",
            sorted[k],
            plane.iter().copied().fold(f32::MAX, f32::min),
            plane.iter().copied().fold(f32::MIN, f32::max),
            100.0 * zeros as f64 / n as f64
        );
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let master = args.next().expect("usage: starless <master> <starnet2>");
    let binary = args.next().expect("usage: starless <master> <starnet2>");

    // Absolute, because Tools.run puts the child's working directory next to the
    // binary and a relative path would resolve against that instead.
    let master = std::fs::canonicalize(&master)
        .expect("master exists")
        .to_string_lossy()
        .into_owned();
    // Its own directory: the masters folder is globbed for masters, so anything
    // dropped beside the frame becomes selectable in the app.
    let dir = PathBuf::from(&master).parent().unwrap().join("starless-check");
    std::fs::create_dir_all(&dir).expect("writable output directory");
    let prepared = dir.join("prepared.starnet.fit");
    let starless = dir.join("out.starless.fit");
    let stars = dir.join("out.stars.fit");

    let mut prep = AcMlPrep::default();
    let ok = unsafe { ac_fits_prestretch(c(&master).as_ptr(), c(prepared.to_str().unwrap()).as_ptr(), &mut prep) };
    assert_eq!(ok, 1, "prestretch failed");
    println!(
        "prep        midtone {:.6} / {:.6} / {:.6}   scale {:.4}",
        prep.midtone[0], prep.midtone[1], prep.midtone[2], prep.scale
    );

    let status = Command::new(&binary)
        .current_dir(PathBuf::from(&binary).parent().unwrap())
        .args([
            "--input",
            prepared.to_str().unwrap(),
            "--output",
            starless.to_str().unwrap(),
            "--unscreen",
            stars.to_str().unwrap(),
            "--quiet",
        ])
        .status()
        .expect("starnet2 runs");
    assert!(status.success(), "starnet2 failed");

    for layer in [&starless, &stars] {
        let p = c(layer.to_str().unwrap());
        assert_eq!(unsafe { ac_fits_swap_rb(p.as_ptr()) }, 1, "swap failed");
        assert_eq!(unsafe { ac_fits_unstretch(p.as_ptr(), &prep) }, 1, "unstretch failed");
    }
    let _ = std::fs::remove_file(&prepared);

    report("master", &PathBuf::from(&master));
    report("starless", &starless);
    report("stars", &stars);

    // The screen blend is the inverse of the unscreen, so this is the check that
    // the whole round trip preserved the frame rather than merely looked right.
    let m = astrocat_core::fits::read(&PathBuf::from(&master)).unwrap();
    let a = astrocat_core::fits::read(&starless).unwrap();
    let b = astrocat_core::fits::read(&stars).unwrap();
    let n = m.width * m.height;
    println!("merge vs master");
    for ch in 0..3 {
        let (mp, ap, bp) = (
            &m.data[ch * n..(ch + 1) * n],
            &a.data[ch * n..(ch + 1) * n],
            &b.data[ch * n..(ch + 1) * n],
        );
        let mut worst = 0f32;
        let mut sum = 0f64;
        for i in 0..n {
            let merged = 1.0 - (1.0 - ap[i]) * (1.0 - bp[i]);
            let e = (merged - mp[i]).abs();
            worst = worst.max(e);
            sum += e as f64;
        }
        println!("   ch{ch}: mean abs err={:.3e}  worst={:.4}", sum / n as f64, worst);
    }
}
