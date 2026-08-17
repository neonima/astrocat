use std::env;
use std::path::PathBuf;

use astrocat_core::background::{self, BackgroundOpts};
use astrocat_core::{fits, to_rgb_half};

/// Peak-to-peak of the fitted model itself. Sampling the frame directly would
/// measure nebulosity, which extraction is supposed to preserve.
fn amplitude(plane: &[f32], w: usize, h: usize, opts: &BackgroundOpts) -> Option<(f32, usize)> {
    let model = background::fit(plane, w, h, opts)?;
    let (mut lo, mut hi) = (f64::MAX, f64::MIN);
    for i in 0..=32 {
        for j in 0..=32 {
            let v = model.eval(i as f64 / 16.0 - 1.0, j as f64 / 16.0 - 1.0);
            lo = lo.min(v);
            hi = hi.max(v);
        }
    }
    Some(((hi - lo) as f32, model.samples))
}

fn main() -> std::io::Result<()> {
    let mut args: Vec<String> = env::args().skip(1).collect();
    if args.len() < 2 {
        eprintln!("usage: flatten <in.fit> <out.fit> [degree]");
        std::process::exit(2);
    }
    let input = PathBuf::from(args.remove(0));
    let output = PathBuf::from(args.remove(0));
    let degree: usize = args.first().and_then(|s| s.parse().ok()).unwrap_or(2);

    let img = fits::read(&input)?;
    let pedestal = img.pedestal();
    // Float data is already normalised by whatever produced it; only integer
    // ADU needs scaling.
    let span = if img.header.int("BITPIX").unwrap_or(16) < 0 {
        1.0
    } else {
        (65535.0 - pedestal).max(1.0)
    };

    let (w, h, mut planes) = if img.planes == 3 && img.bayer_pattern().is_none() {
        let n = img.width * img.height;
        let p: Vec<Vec<f32>> = (0..3)
            .map(|c| {
                img.data[c * n..(c + 1) * n]
                    .iter()
                    .map(|v| (v - pedestal) / span)
                    .collect()
            })
            .collect();
        (img.width, img.height, p)
    } else {
        let rgb = to_rgb_half(&img);
        let p: Vec<Vec<f32>> = (0..3)
            .map(|c| {
                rgb.data
                    .iter()
                    .skip(c)
                    .step_by(3)
                    .map(|v| (v - pedestal) / span)
                    .collect()
            })
            .collect();
        (rgb.width, rgb.height, p)
    };

    let opts = BackgroundOpts {
        degree,
        ..Default::default()
    };

    println!("{}x{}  degree {degree}\n", w, h);
    println!("{:<8} {:>12} {:>12} {:>10} {:>9}", "channel", "gradient", "after", "reduction", "samples");

    for (c, name) in ["R", "G", "B"].iter().enumerate() {
        let Some((before, samples)) = amplitude(&planes[c], w, h, &opts) else {
            println!("{name:<8} fit failed");
            continue;
        };
        let model = background::fit(&planes[c], w, h, &opts).unwrap();
        let sky = model.level;
        background::subtract(&mut planes[c], w, h, &model);
        let after = amplitude(&planes[c], w, h, &opts).map(|(a, _)| a).unwrap_or(0.0);
        println!(
            "{:<8} {:>12.3e} {:>12.3e} {:>9.1}x {:>9}   ({:.1}% of sky {:.5})",
            name,
            before,
            after,
            before / after.max(1e-12),
            samples,
            100.0 * before / sky.max(1e-12),
            sky
        );
    }

    let extra = vec![
        ("CREATOR".into(), "'AstroCat'".into(), "".into()),
        ("HISTORY".into(), "'background extracted'".into(), format!("degree {degree}")),
    ];
    fits::write_f32(&output, w, h, &planes, &extra)?;
    println!("\nwrote {}", output.display());
    Ok(())
}
