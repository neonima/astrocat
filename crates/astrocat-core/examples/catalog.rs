use std::env;
use std::io::Write;
use std::path::PathBuf;
use std::time::Instant;

use astrocat_core::{catalog, ingest};

fn main() -> std::io::Result<()> {
    let root = PathBuf::from(env::args().nth(1).expect("usage: catalog <dir>"));

    let t = Instant::now();
    let scan = catalog::scan_dir(&root)?;
    eprintln!("scanned {} files in {:.1}s", scan.files_seen(), t.elapsed().as_secs_f32());

    let t = Instant::now();
    let frames = ingest::ingest(&scan, |done, total| {
        if done % 25 == 0 || done == total {
            eprint!("\r  measuring {done}/{total}");
            let _ = std::io::stderr().flush();
        }
    });
    eprintln!("\rmeasured {} frames in {:.1}s   ", frames.len(), t.elapsed().as_secs_f32());

    ingest::save(&root, &frames)?;
    println!("wrote {}", ingest::catalog_dir(&root).join("frames.tsv").display());

    let mut nights: Vec<&str> = frames.iter().map(|f| f.night.as_str()).collect();
    nights.sort();
    nights.dedup();
    for n in nights {
        let s: Vec<&ingest::FrameRecord> = frames.iter().filter(|f| f.night == n).collect();
        let stars: Vec<u32> = s.iter().map(|f| f.stars).collect();
        println!(
            "{n}  {:>4} frames   stars {}–{}   hfr {:.2}",
            s.len(),
            stars.iter().min().unwrap_or(&0),
            stars.iter().max().unwrap_or(&0),
            s.iter().map(|f| f.hfr).sum::<f32>() / s.len().max(1) as f32
        );
    }
    Ok(())
}
