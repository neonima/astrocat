use std::env;
use std::path::PathBuf;

use astrocat_core::catalog::{self, Kind};

fn mb(b: u64) -> f64 {
    b as f64 / 1_048_576.0
}

fn main() -> std::io::Result<()> {
    let root = PathBuf::from(
        env::args().nth(1).expect("usage: scan <dir>"),
    );
    let scan = catalog::scan_dir(&root)?;

    let exps: Vec<String> = scan
        .exposures()
        .iter()
        .map(|e| format!("{e:.0}s"))
        .collect();

    println!(
        "files {} · lights {} · masters {} · sessions {} · exposures {} · {:.1} GB",
        scan.files_seen(),
        scan.lights(),
        scan.masters(),
        scan.sessions(),
        exps.join(" "),
        mb(scan.bytes()) / 1024.0
    );
    println!("grouped by OBJECT + observing night (noon rollover) + FILTER + EXPTIME\n");

    println!(
        "{:<26} {:<14} {:>7} {:>10} {:>8} {:>7}",
        "group", "spec", "frames", "size", "span", "gaps"
    );

    for g in &scan.groups {
        let spec = if g.kind == Kind::Master {
            "master stack".to_string()
        } else {
            format!("{} {:.0}s", g.filter, g.exptime)
        };
        let gaps = g.gaps(120);
        println!(
            "{:<26} {:<14} {:>7} {:>9.1}G {:>6.0}m {:>7}",
            format!("{} · {}", g.object, g.night),
            spec,
            g.frames.len(),
            mb(g.bytes()) / 1024.0,
            g.span() as f64 / 60.0,
            gaps.len()
        );
        for (_, dur) in gaps {
            println!("{:<26} {:<14} gap {:.0} min", "", "", dur as f64 / 60.0);
        }
    }

    if !scan.unreadable.is_empty() {
        println!("\nunreadable:");
        for u in &scan.unreadable {
            println!("  {} — {}", u.path.display(), u.reason);
        }
    }

    if let Some(m) = scan.groups.iter().find(|g| g.kind == Kind::Master) {
        println!("\nclassified as master: {}", m.frames[0].reason);
    }
    if let Some(l) = scan.groups.iter().find(|g| g.kind == Kind::Light) {
        println!("classified as light:  {}", l.frames[0].reason);
    }

    Ok(())
}
