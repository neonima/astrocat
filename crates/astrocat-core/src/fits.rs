use std::fs::File;
use std::io::{self, BufReader, Read};
use std::path::Path;

const BLOCK: usize = 2880;
const CARD: usize = 80;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
}

#[derive(Debug, Clone, Default)]
pub struct Header {
    pub cards: Vec<(String, Value)>,
    pub bytes: usize,
}

impl Header {
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.cards.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    pub fn int(&self, key: &str) -> Option<i64> {
        match self.get(key)? {
            Value::Int(i) => Some(*i),
            Value::Float(f) => Some(*f as i64),
            _ => None,
        }
    }

    pub fn float(&self, key: &str) -> Option<f64> {
        match self.get(key)? {
            Value::Float(f) => Some(*f),
            Value::Int(i) => Some(*i as f64),
            _ => None,
        }
    }

    pub fn text(&self, key: &str) -> Option<&str> {
        match self.get(key)? {
            Value::Str(s) => Some(s.as_str()),
            _ => None,
        }
    }
}

/// Plane-major: `data[plane * width * height + y * width + x]`.
/// Row 0 is the FITS bottom row.
#[derive(Debug, Clone)]
pub struct Image {
    pub width: usize,
    pub height: usize,
    pub planes: usize,
    pub data: Vec<f32>,
    pub header: Header,
}

impl Image {
    /// None for multi-plane data even when BAYERPAT is present: Seestar leaves
    /// the card in its own stacked RGB output, and demosaicing that destroys it.
    pub fn bayer_pattern(&self) -> Option<&str> {
        if self.planes != 1 {
            return None;
        }
        self.header.text("BAYERPAT").map(str::trim)
    }

    /// Pedestal the capture software added back after subtracting darks. Must
    /// come off before any multiplicative step or black-point estimate.
    pub fn pedestal(&self) -> f32 {
        self.header.float("BIAS").unwrap_or(0.0) as f32
    }
}

fn parse_value(s: &str) -> Option<Value> {
    let s = s.trim_start();
    if let Some(rest) = s.strip_prefix('\'') {
        let bytes = rest.as_bytes();
        let mut out = String::new();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'\'' {
                if i + 1 < bytes.len() && bytes[i + 1] == b'\'' {
                    out.push('\'');
                    i += 2;
                    continue;
                }
                break;
            }
            out.push(bytes[i] as char);
            i += 1;
        }
        return Some(Value::Str(out.trim_end().to_string()));
    }

    let v = s.split('/').next()?.trim();
    match v {
        "" => None,
        "T" => Some(Value::Bool(true)),
        "F" => Some(Value::Bool(false)),
        _ => {
            let norm = v.replace(['D', 'd'], "E");
            if let Ok(i) = norm.parse::<i64>() {
                Some(Value::Int(i))
            } else {
                norm.parse::<f64>().ok().map(Value::Float)
            }
        }
    }
}

pub fn read_header<R: Read>(r: &mut R) -> io::Result<Header> {
    let mut cards = Vec::new();
    let mut bytes = 0usize;
    let mut block = [0u8; BLOCK];

    loop {
        r.read_exact(&mut block)?;
        bytes += BLOCK;

        for c in block.chunks_exact(CARD) {
            let key = std::str::from_utf8(&c[0..8]).unwrap_or("").trim();
            if key == "END" {
                return Ok(Header { cards, bytes });
            }
            if key.is_empty() || key == "COMMENT" || key == "HISTORY" || c[8] != b'=' {
                continue;
            }
            if let Some(v) = parse_value(std::str::from_utf8(&c[9..]).unwrap_or("")) {
                cards.push((key.to_string(), v));
            }
        }
    }
}

pub fn read(path: &Path) -> io::Result<Image> {
    let file = File::open(path)?;
    let mut r = BufReader::with_capacity(1 << 20, file);
    let header = read_header(&mut r)?;

    let bitpix = header.int("BITPIX").unwrap_or(16);
    let naxis = header.int("NAXIS").unwrap_or(2);
    let width = header.int("NAXIS1").unwrap_or(0).max(0) as usize;
    let height = header.int("NAXIS2").unwrap_or(0).max(0) as usize;
    let planes = if naxis >= 3 {
        header.int("NAXIS3").unwrap_or(1).max(1) as usize
    } else {
        1
    };

    if width == 0 || height == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "FITS has no image dimensions",
        ));
    }

    let bzero = header.float("BZERO").unwrap_or(0.0) as f32;
    let bscale = header.float("BSCALE").unwrap_or(1.0) as f32;
    let n = width * height * planes;

    let bytes_per = match bitpix {
        8 => 1,
        16 => 2,
        32 | -32 => 4,
        64 | -64 => 8,
        other => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("unsupported BITPIX {other}"),
            ))
        }
    };

    let mut raw = vec![0u8; n * bytes_per];
    r.read_exact(&mut raw)?;

    let mut data = vec![0f32; n];
    match bitpix {
        8 => {
            for (i, b) in raw.iter().enumerate() {
                data[i] = *b as f32 * bscale + bzero;
            }
        }
        16 => {
            for (i, c) in raw.chunks_exact(2).enumerate() {
                data[i] = i16::from_be_bytes([c[0], c[1]]) as f32 * bscale + bzero;
            }
        }
        32 => {
            for (i, c) in raw.chunks_exact(4).enumerate() {
                data[i] = i32::from_be_bytes([c[0], c[1], c[2], c[3]]) as f32 * bscale + bzero;
            }
        }
        -32 => {
            for (i, c) in raw.chunks_exact(4).enumerate() {
                data[i] = f32::from_be_bytes([c[0], c[1], c[2], c[3]]) * bscale + bzero;
            }
        }
        64 => {
            for (i, c) in raw.chunks_exact(8).enumerate() {
                let v = i64::from_be_bytes([c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]]);
                data[i] = v as f32 * bscale + bzero;
            }
        }
        -64 => {
            for (i, c) in raw.chunks_exact(8).enumerate() {
                let v = f64::from_be_bytes([c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]]);
                data[i] = (v * bscale as f64 + bzero as f64) as f32;
            }
        }
        _ => unreachable!(),
    }

    Ok(Image {
        width,
        height,
        planes,
        data,
        header,
    })
}

fn card(key: &str, value: &str, comment: &str) -> [u8; CARD] {
    let mut c = [b' '; CARD];
    let body = if comment.is_empty() {
        format!("{key:<8}= {value:>20}")
    } else {
        format!("{key:<8}= {value:>20} / {comment}")
    };
    for (i, b) in body.bytes().take(CARD).enumerate() {
        c[i] = b;
    }
    c
}

/// Writes 32-bit float, plane-major. Float because averaging hundreds of frames
/// produces fractional values that 16-bit integer would quantise away.
pub fn write_f32(
    path: &Path,
    width: usize,
    height: usize,
    planes: &[Vec<f32>],
    extra: &[(String, String, String)],
) -> io::Result<()> {
    use std::io::{BufWriter, Write};

    let mut w = BufWriter::with_capacity(1 << 20, File::create(path)?);
    let mut header: Vec<u8> = Vec::new();

    header.extend_from_slice(&card("SIMPLE", "T", "conforms to FITS standard"));
    header.extend_from_slice(&card("BITPIX", "-32", "32-bit float"));
    header.extend_from_slice(&card("NAXIS", "3", ""));
    header.extend_from_slice(&card("NAXIS1", &width.to_string(), ""));
    header.extend_from_slice(&card("NAXIS2", &height.to_string(), ""));
    header.extend_from_slice(&card("NAXIS3", &planes.len().to_string(), ""));
    for (k, v, c) in extra {
        header.extend_from_slice(&card(k, v, c));
    }
    header.extend_from_slice(&card("END", "", ""));

    // END is written as a bare keyword, not a value card.
    let end = header.len() - CARD;
    header.truncate(end);
    let mut e = [b' '; CARD];
    e[..3].copy_from_slice(b"END");
    header.extend_from_slice(&e);

    while header.len() % BLOCK != 0 {
        header.push(b' ');
    }
    w.write_all(&header)?;

    let mut written = 0usize;
    for plane in planes {
        for v in plane {
            w.write_all(&v.to_be_bytes())?;
            written += 4;
        }
    }
    let pad = (BLOCK - written % BLOCK) % BLOCK;
    w.write_all(&vec![0u8; pad])?;
    w.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_a_written_file() {
        let dir = std::env::temp_dir().join("astrocat-fits-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("rt.fit");

        let planes = vec![vec![1.5f32, 2.5, 3.5, 4.5], vec![-1.0f32, 0.0, 8.25, 16.5]];
        write_f32(
            &path,
            2,
            2,
            &planes,
            &[("OBJECT".into(), "'TEST'".into(), "target".into())],
        )
        .unwrap();

        let back = read(&path).unwrap();
        assert_eq!((back.width, back.height, back.planes), (2, 2, 2));
        assert_eq!(back.header.int("BITPIX"), Some(-32));
        assert_eq!(back.header.text("OBJECT"), Some("TEST"));
        assert_eq!(back.data, vec![1.5, 2.5, 3.5, 4.5, -1.0, 0.0, 8.25, 16.5]);
    }

    #[test]
    fn parses_typical_cards() {
        assert_eq!(parse_value("                    16 / bits"), Some(Value::Int(16)));
        assert_eq!(parse_value("                    T / yes"), Some(Value::Bool(true)));
        assert_eq!(
            parse_value("     2.90000009536743 / pixel size"),
            Some(Value::Float(2.90000009536743))
        );
        assert_eq!(
            parse_value("'GRBG    '           / Bayer pattern"),
            Some(Value::Str("GRBG".to_string()))
        );
        assert_eq!(
            parse_value("'NGC 7000'           / object"),
            Some(Value::Str("NGC 7000".to_string()))
        );
    }

    #[test]
    fn parses_fortran_exponent() {
        assert_eq!(
            parse_value("   2.06472528197D-05 / matrix"),
            Some(Value::Float(2.06472528197e-5))
        );
    }
}
