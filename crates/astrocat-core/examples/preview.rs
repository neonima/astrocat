use std::env;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::time::Instant;

use astrocat_core::{auto_stf_channels, fits, stretch, to_rgb_half};

fn main() -> std::io::Result<()> {
    let mut args = env::args().skip(1);
    let input = PathBuf::from(args.next().expect("usage: preview <in.fit> [out.ppm]"));
    let output = PathBuf::from(
        args.next()
            .unwrap_or_else(|| "/tmp/astrocat-preview.ppm".to_string()),
    );

    let t = Instant::now();
    let img = fits::read(&input)?;
    let t_read = t.elapsed();

    println!(
        "{}x{} planes={} bitpix={} bayer={:?} pedestal={}",
        img.width,
        img.height,
        img.planes,
        img.header.int("BITPIX").unwrap_or(0),
        img.bayer_pattern(),
        img.pedestal()
    );
    println!(
        "object={:?} exp={:?}s gain={:?} temp={:?}",
        img.header.text("OBJECT"),
        img.header.float("EXPTIME"),
        img.header.float("GAIN"),
        img.header.float("CCD-TEMP")
    );

    let t = Instant::now();
    let rgb = to_rgb_half(&img);
    let t_debayer = t.elapsed();

    let pedestal = img.pedestal();
    let span = (65535.0 - pedestal).max(1.0);
    let normalised: Vec<f32> = rgb
        .data
        .iter()
        .map(|v| ((v - pedestal) / span).clamp(0.0, 1.0))
        .collect();

    let t = Instant::now();
    let stf = auto_stf_channels(&normalised, 7);
    let t_stf = t.elapsed();

    for (c, s) in ["R", "G", "B"].iter().zip(stf.iter()) {
        println!(
            "{c}: shadows={:.6} midtone={:.6} median={:.6} mad={:.6} -> screen {:.3}",
            s.shadows,
            s.midtone,
            s.median,
            s.mad,
            stretch::apply(s, s.median)
        );
    }

    let t = Instant::now();
    let mut w = BufWriter::new(File::create(&output)?);
    write!(w, "P6\n{} {}\n255\n", rgb.width, rgb.height)?;
    // FITS row 0 is the bottom row; PPM starts at the top.
    for y in (0..rgb.height).rev() {
        let mut row = Vec::with_capacity(rgb.width * 3);
        for x in 0..rgb.width {
            let o = (y * rgb.width + x) * 3;
            for c in 0..3 {
                row.push((stretch::apply(&stf[c], normalised[o + c]) * 255.0) as u8);
            }
        }
        w.write_all(&row)?;
    }
    w.flush()?;
    let t_write = t.elapsed();

    println!(
        "read {:.0}ms  debayer {:.0}ms  stf {:.0}ms  write {:.0}ms  -> {}",
        t_read.as_secs_f32() * 1000.0,
        t_debayer.as_secs_f32() * 1000.0,
        t_stf.as_secs_f32() * 1000.0,
        t_write.as_secs_f32() * 1000.0,
        output.display()
    );

    Ok(())
}
