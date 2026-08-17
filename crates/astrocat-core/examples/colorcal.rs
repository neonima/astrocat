use std::env;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::time::Instant;

use astrocat_core::color::{self, Calibration, ColorOpts, Reference};
use astrocat_core::debayer::{to_display, Rgb};
use astrocat_core::stretch::{self, Stf};
use astrocat_core::fits;

/// Downsampled so a 1080x1920 frame is viewable, and written top-down because
/// every image viewer disagrees with FITS about row order.
fn write_ppm(path: &str, rgb: &Rgb, cal: &Calibration, stf: [Stf; 3]) -> std::io::Result<()> {
    let step = 2;
    let (w, h) = (rgb.width / step, rgb.height / step);
    let mut f = BufWriter::new(File::create(path)?);
    write!(f, "P6\n{w} {h}\n255\n")?;
    let mut row = vec![0u8; w * 3];
    for y in (0..h).rev() {
        for x in 0..w {
            let i = (y * step) * rgb.width + x * step;
            for c in 0..3 {
                let v = cal.value(c, rgb.data[i * 3 + c]);
                row[x * 3 + c] = (stretch::apply(&stf[c], v) * 255.0).clamp(0.0, 255.0) as u8;
            }
        }
        f.write_all(&row)?;
    }
    Ok(())
}

fn main() -> std::io::Result<()> {
    let mut args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("usage: colorcal <in.fit> [background|stars]");
        std::process::exit(2);
    }
    let input = PathBuf::from(args.remove(0));
    let reference = match args.first().map(String::as_str) {
        Some("background") => Reference::Background,
        Some("catalogue") => Reference::Catalogue,
        _ => Reference::StarField,
    };
    let white: f32 = args
        .iter()
        .find_map(|a| a.strip_prefix("white="))
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.82);

    let img = fits::read(&input)?;
    let filter = img.header.text("FILTER").unwrap_or("").trim().to_string();
    let (rgb, pedestal) = to_display(&img);
    let wcs = astrocat_core::wcs::Wcs::from_header(&img.header, img.width, img.height);

    match &wcs {
        Some(w) => {
            let (ra, dec) = w.centre();
            println!(
                "wcs         centre {ra:.5} {dec:+.5}  radius {:.3} deg  {:.3} arcsec/px  rot {:.2} deg",
                w.radius_deg(),
                w.scale_arcsec(),
                w.rotation_deg()
            );
        }
        None => println!("wcs         none — catalogue mode needs a plate solve"),
    }

    let catalogue: Option<Vec<astrocat_core::color::CatalogStar>> = args
        .iter()
        .find(|a| a.ends_with(".csv"))
        .and_then(|p| std::fs::read_to_string(p).ok())
        .map(|t| color::parse_gaia_csv(&t));
    if let Some(c) = &catalogue {
        println!("catalogue   {} stars", c.len());
    }

    println!(
        "{}x{}  planes {}  filter {:?}{}  pedestal {pedestal}",
        rgb.width,
        rgb.height,
        img.planes,
        filter,
        if color::is_narrowband(&filter) {
            "  [narrowband — photometric colour is meaningless here]"
        } else {
            ""
        }
    );

    let t = Instant::now();
    let fit = match (&wcs, &catalogue) {
        (Some(w), Some(stars)) => Some(color::CatalogueFit {
            wcs: w,
            stars,
            white,
            downsample: img.width as f64 / rgb.width as f64,
        }),
        _ => None,
    };
    let Some(c) = color::measure_with(
        &rgb,
        &ColorOpts {
            reference,
            ..Default::default()
        },
        fit,
    ) else {
        eprintln!("could not measure");
        std::process::exit(1);
    };
    let ms = t.elapsed().as_secs_f32() * 1000.0;

    let pct = |v: [f32; 3]| {
        let s = (v[0] + v[1] + v[2]).max(1e-9);
        format!(
            "{:.1} / {:.1} / {:.1} %",
            100.0 * v[0] / s,
            100.0 * v[1] / s,
            100.0 * v[2] / s
        )
    };

    println!("stars       {} found, {} used", c.stars_found, c.stars_used);
    if reference == Reference::Catalogue {
        println!(
            "matched     {} stars · colour span {:.2} · slope {:+.4} / {:+.4} per BP-RP · white {white:.2}",
            c.matched, c.colour_span, c.slope[0], c.slope[1]
        );
    }
    println!(
        "white ref   R/G {:.4} ±{:.4}   B/G {:.4} ±{:.4}",
        c.ratio[0], c.scatter[0], c.ratio[2], c.scatter[2]
    );
    println!(
        "gain        {:.4} / {:.4} / {:.4}",
        c.gain[0], c.gain[1], c.gain[2]
    );
    println!(
        "offset      {:.6} / {:.6} / {:.6}",
        c.offset[0], c.offset[1], c.offset[2]
    );
    println!(
        "sky before  {:.6} / {:.6} / {:.6}   {}",
        c.sky_before[0],
        c.sky_before[1],
        c.sky_before[2],
        pct(c.sky_before)
    );
    println!(
        "sky after   {:.6} in all three          {}",
        c.sky_after,
        pct([c.sky_after; 3])
    );
    println!(
        "stf after   shadows {:.5} / {:.5} / {:.5}   midtone {:.5} / {:.5} / {:.5}",
        c.shadows[0], c.shadows[1], c.shadows[2], c.midtone[0], c.midtone[1], c.midtone[2]
    );
    println!("measured in {ms:.0} ms");

    if let Some(stem) = args.iter().find(|a| a.ends_with(".ppm")) {
        let identity = Calibration::identity();

        // Today's default view. The unlinked STF neutralises the sky by
        // re-fitting each channel, so this is not the raw colour of the data.
        let unlinked = astrocat_core::auto_stf_channels(&rgb.data, 7);
        write_ppm(&stem.replace(".ppm", "-unlinked.ppm"), &rgb, &identity, unlinked)?;

        // Same stretch policy on both sides, so the only difference between
        // these two is the calibration itself.
        let raw = stretch::auto_stf(&rgb.data, 7);
        write_ppm(&stem.replace(".ppm", "-before.ppm"), &rgb, &identity, [raw; 3])?;

        let linked = Stf {
            shadows: c.linked_shadows,
            midtone: c.linked_midtone,
            median: 0.0,
            mad: 0.0,
        };
        write_ppm(&stem.replace(".ppm", "-after.ppm"), &rgb, &c, [linked; 3])?;
        println!("wrote {stem} unlinked/before/after");
    }
    Ok(())
}
