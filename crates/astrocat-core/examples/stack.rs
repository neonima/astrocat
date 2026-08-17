use std::env;
use std::io::Write;
use std::path::PathBuf;
use std::time::Instant;

use astrocat_core::stack::{self, Stage, StackOpts};

fn main() -> std::io::Result<()> {
    let mut args: Vec<String> = env::args().skip(1).collect();
    if args.len() < 2 {
        eprintln!("usage: stack <out.fit> <frames...>");
        std::process::exit(2);
    }
    let out = PathBuf::from(args.remove(0));
    let files: Vec<PathBuf> = args.into_iter().map(PathBuf::from).collect();

    let t0 = Instant::now();
    let mut stage = None;

    let result = stack::run(&files, &out, &StackOpts::default(), |s, done, total| {
        if stage != Some(s) {
            eprintln!();
            stage = Some(s);
        }
        if done % 20 == 0 || done == total {
            eprint!(
                "\r{:<9} {done}/{total}   ",
                match s {
                    Stage::Analyse => "analyse",
                    Stage::Register => "register",
                    Stage::Combine => "combine",
                }
            );
            let _ = std::io::stderr().flush();
        }
        true
    });

    let Ok(r) = result else {
        eprintln!("\ncancelled");
        return Ok(());
    };

    println!("\n\nframes used   {} ({} failed to register)", r.frames_used, r.frames_failed);
    println!("rotation      {:.2}° to {:.2}°", r.rotation_min, r.rotation_max);
    println!("drift         up to {:.1} px", r.drift_px);
    println!("clipped       {:.2}% of samples", r.clipped_pct);
    println!("stars         {}", r.stars);
    println!("green noise   {:.3e}", r.noise);
    println!("gradient      {:.5}", r.gradient);
    println!(
        "\nanalyse {:.1}s   register {:.1}s   combine {:.1}s   total {:.1}s",
        r.analyse_s,
        r.register_s,
        r.combine_s,
        t0.elapsed().as_secs_f32()
    );
    println!("output        {} ({}x{})", out.display(), r.width, r.height);
    Ok(())
}
