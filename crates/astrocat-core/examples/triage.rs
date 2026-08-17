use std::env;
use std::path::PathBuf;
use std::time::Instant;

use astrocat_core::{fits, stars, to_rgb_half, DetectOpts};

struct Row {
    name: String,
    count: usize,
    hfr: f32,
    ecc: f32,
    background: f32,
    noise: f32,
    ms: f32,
}

fn main() -> std::io::Result<()> {
    let files: Vec<PathBuf> = env::args().skip(1).map(PathBuf::from).collect();
    if files.is_empty() {
        eprintln!("usage: triage <frames...>");
        std::process::exit(2);
    }

    let opts = DetectOpts::default();
    let mut rows = Vec::new();
    let overall = Instant::now();

    for path in &files {
        let t = Instant::now();
        let img = fits::read(path)?;
        if img.header.int("STACKCNT").is_some() {
            continue;
        }

        let pedestal = img.pedestal();
        let rgb = to_rgb_half(&img);
        let gray: Vec<f32> = stars::green(&rgb)
            .iter()
            .map(|v| ((v - pedestal) / (65535.0 - pedestal)).clamp(0.0, 1.0))
            .collect();

        let field = stars::detect(&gray, rgb.width, rgb.height, &opts);
        rows.push(Row {
            name: path
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default(),
            count: field.stars.len(),
            hfr: field.median_hfr(),
            ecc: field.median_eccentricity(),
            background: field.background,
            noise: field.noise,
            ms: t.elapsed().as_secs_f32() * 1000.0,
        });
    }

    println!(
        "{:<52} {:>6} {:>7} {:>7} {:>9} {:>9} {:>7}",
        "frame", "stars", "hfr", "ecc", "bg", "noise", "ms"
    );
    for r in &rows {
        println!(
            "{:<52} {:>6} {:>7.2} {:>7.3} {:>9.5} {:>9.5} {:>7.0}",
            &r.name[..r.name.len().min(52)],
            r.count,
            r.hfr,
            r.ecc,
            r.background,
            r.noise,
            r.ms
        );
    }

    if rows.len() > 1 {
        let mut hfrs: Vec<f32> = rows.iter().map(|r| r.hfr).collect();
        hfrs.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let med = hfrs[hfrs.len() / 2];
        let worst = rows
            .iter()
            .max_by(|a, b| a.hfr.partial_cmp(&b.hfr).unwrap())
            .unwrap();
        println!(
            "\n{} frames in {:.1}s ({:.0} ms/frame)",
            rows.len(),
            overall.elapsed().as_secs_f32(),
            overall.elapsed().as_secs_f32() * 1000.0 / rows.len() as f32
        );
        println!(
            "median hfr {:.2}  best {:.2}  worst {:.2} ({})",
            med,
            hfrs[0],
            worst.hfr,
            &worst.name[..worst.name.len().min(52)]
        );
        let cut = med * 1.25;
        let rejected = rows.iter().filter(|r| r.hfr > cut).count();
        println!(
            "would reject {} of {} frames at hfr > 1.25x median ({:.2})",
            rejected,
            rows.len(),
            cut
        );
    }

    Ok(())
}
