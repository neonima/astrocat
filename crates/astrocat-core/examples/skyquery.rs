use std::path::PathBuf;

use astrocat_core::skycat::Store;

fn main() -> std::io::Result<()> {
    let mut args = std::env::args().skip(1);
    let dir = PathBuf::from(args.next().expect("usage: skyquery <dir> <ra> <dec> <radius>"));
    let ra: f64 = args.next().unwrap().parse().unwrap();
    let dec: f64 = args.next().unwrap().parse().unwrap();
    let radius: f64 = args.next().unwrap().parse().unwrap();

    let store = Store::open(&dir, -24.3545, 13.0, 20.0)?;
    println!(
        "tiles {} · stars {} · min_dec {:.4} · pending {}",
        store.tiles.len(),
        store.stars(),
        store.min_dec,
        store.pending()
    );
    let hits = store.cone(ra, dec, radius)?;
    println!("cone({ra}, {dec}, {radius}) -> {} stars", hits.len());
    if let Some(s) = hits.first() {
        println!("first: ra {:.5} dec {:+.5} G {:.2} BP-RP {:.3}", s.ra, s.dec, s.g, s.colour());
    }
    Ok(())
}
