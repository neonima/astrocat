use crate::fits::Image;

#[derive(Debug, Clone)]
pub struct Rgb {
    pub width: usize,
    pub height: usize,
    pub data: Vec<f32>,
}

impl Rgb {
    pub fn pixels(&self) -> usize {
        self.width * self.height
    }
}

fn channel_index(c: u8) -> usize {
    match c {
        b'R' | b'r' => 0,
        b'B' | b'b' => 2,
        _ => 1,
    }
}

/// Collapses each 2x2 block to one RGB pixel: exact, no interpolation, and
/// indistinguishable from a full demosaic below 1:1.
pub fn to_rgb_half(img: &Image) -> Rgb {
    match (img.planes, img.bayer_pattern()) {
        (1, Some(pattern)) => bayer_half(img, pattern),
        (3, _) => rgb_planes_half(img),
        _ => mono_half(img),
    }
}

/// Full-resolution bilinear demosaic. Interpolates, unlike the half-res path,
/// but keeps the sensor's sampling — on undersampled data losing half the
/// scale costs more than interpolation does.
pub fn to_rgb_full(img: &Image) -> Rgb {
    let (w, h) = (img.width, img.height);
    match (img.planes, img.bayer_pattern()) {
        (1, Some(pattern)) => bayer_full(img, pattern),
        (3, _) => {
            let n = w * h;
            let mut data = vec![0f32; n * 3];
            for c in 0..3 {
                for i in 0..n {
                    data[i * 3 + c] = img.data[c * n + i];
                }
            }
            Rgb {
                width: w,
                height: h,
                data,
            }
        }
        _ => {
            let mut data = vec![0f32; w * h * 3];
            for i in 0..(w * h) {
                let v = img.data[i];
                data[i * 3] = v;
                data[i * 3 + 1] = v;
                data[i * 3 + 2] = v;
            }
            Rgb {
                width: w,
                height: h,
                data,
            }
        }
    }
}

/// Full-resolution RGB scaled to [0,1] with the pedestal removed, and the
/// pedestal that was used. Everything the app displays and everything measured
/// in display units goes through here — a colour offset solved against one has
/// to land on the same scale as the other.
pub fn to_display(img: &Image) -> (Rgb, f32) {
    let (rgb, pedestal, _) = to_display_scaled(img, 0.0);
    (rgb, pedestal)
}

/// `override_scale` above zero forces the full-scale value instead of deriving
/// it from this frame's own maximum. Derived frames need it: a starless layer's
/// brightest pixel is nebula where the master's is a star, so normalising each
/// by its own maximum puts them on different scales and any shared stretch then
/// lands in the wrong place. Returns the scale used so a caller can pass it on.
pub fn to_display_scaled(img: &Image, override_scale: f32) -> (Rgb, f32, f32) {
    let bitpix = img.header.int("BITPIX").unwrap_or(16);
    // Full resolution, not binned. On undersampled data a 2x2 bin is the
    // difference between judging star shape and guessing at it, and a crop
    // cannot be judged at all against half the pixels it will actually keep.
    // The measurement path comes through here too, so both move together and a
    // gain solved on one still lands correctly in the other.
    let mut rgb = to_rgb_full(img);
    let brightest = rgb.data.iter().copied().fold(f32::MIN, f32::max);

    // A pedestal larger than the data itself cannot be real — it means the
    // value was already removed and the card left behind. Honouring it would
    // drive every pixel negative and render black.
    let pedestal = if img.pedestal() > brightest {
        0.0
    } else {
        img.pedestal()
    };

    let full_scale = if override_scale > 0.0 {
        override_scale
    } else {
        match bitpix {
            8 => 255.0f32,
            16 => 65535.0f32,
            _ => brightest.max(1.0),
        }
    };
    let span = (full_scale - pedestal).max(if bitpix < 0 { 1e-6 } else { 1.0 });

    for v in rgb.data.iter_mut() {
        *v = ((*v - pedestal) / span).clamp(0.0, 1.0);
    }
    (rgb, pedestal, full_scale)
}

fn bayer_full(img: &Image, pattern: &str) -> Rgb {
    let (w, h) = (img.width, img.height);
    let p = pattern.as_bytes();
    let quad = [
        channel_index(*p.first().unwrap_or(&b'G')),
        channel_index(*p.get(1).unwrap_or(&b'R')),
        channel_index(*p.get(2).unwrap_or(&b'B')),
        channel_index(*p.get(3).unwrap_or(&b'G')),
    ];
    let colour_at = |x: usize, y: usize| quad[(y % 2) * 2 + (x % 2)];

    let mut data = vec![0f32; w * h * 3];
    let at = |x: isize, y: isize| -> f32 {
        let cx = x.clamp(0, w as isize - 1) as usize;
        let cy = y.clamp(0, h as isize - 1) as usize;
        img.data[cy * w + cx]
    };

    for y in 0..h {
        for x in 0..w {
            let (xi, yi) = (x as isize, y as isize);
            let own = colour_at(x, y);
            let mut px = [0f32; 3];
            px[own] = at(xi, yi);

            // Green sits on a quincunx, so it always has four orthogonal
            // neighbours; red and blue need the diagonal case as well.
            if own == 1 {
                let horiz = (at(xi - 1, yi) + at(xi + 1, yi)) * 0.5;
                let vert = (at(xi, yi - 1) + at(xi, yi + 1)) * 0.5;
                let left = colour_at((x + w - 1) % w, y);
                px[left] = horiz;
                px[if left == 0 { 2 } else { 0 }] = vert;
            } else {
                px[1] = (at(xi - 1, yi) + at(xi + 1, yi) + at(xi, yi - 1) + at(xi, yi + 1)) * 0.25;
                let other = if own == 0 { 2 } else { 0 };
                px[other] = (at(xi - 1, yi - 1)
                    + at(xi + 1, yi - 1)
                    + at(xi - 1, yi + 1)
                    + at(xi + 1, yi + 1))
                    * 0.25;
            }

            let o = (y * w + x) * 3;
            data[o] = px[0];
            data[o + 1] = px[1];
            data[o + 2] = px[2];
        }
    }

    Rgb {
        width: w,
        height: h,
        data,
    }
}

fn bayer_half(img: &Image, pattern: &str) -> Rgb {
    let (w, h) = (img.width, img.height);
    let (ow, oh) = (w / 2, h / 2);
    let mut data = vec![0f32; ow * oh * 3];

    // Pattern names the colour at (0,0), (0,1), (1,0), (1,1) of each block.
    let p = pattern.as_bytes();
    let quad: [usize; 4] = [
        channel_index(*p.first().unwrap_or(&b'G')),
        channel_index(*p.get(1).unwrap_or(&b'R')),
        channel_index(*p.get(2).unwrap_or(&b'B')),
        channel_index(*p.get(3).unwrap_or(&b'G')),
    ];

    for oy in 0..oh {
        let (r0, r1) = (oy * 2 * w, (oy * 2 + 1) * w);
        for ox in 0..ow {
            let x = ox * 2;
            let src = [
                img.data[r0 + x],
                img.data[r0 + x + 1],
                img.data[r1 + x],
                img.data[r1 + x + 1],
            ];

            let mut acc = [0f32; 3];
            let mut cnt = [0f32; 3];
            for k in 0..4 {
                acc[quad[k]] += src[k];
                cnt[quad[k]] += 1.0;
            }

            let o = (oy * ow + ox) * 3;
            for c in 0..3 {
                data[o + c] = if cnt[c] > 0.0 { acc[c] / cnt[c] } else { 0.0 };
            }
        }
    }

    Rgb {
        width: ow,
        height: oh,
        data,
    }
}

fn rgb_planes_half(img: &Image) -> Rgb {
    let (w, h) = (img.width, img.height);
    let (ow, oh) = (w / 2, h / 2);
    let plane = w * h;
    let mut data = vec![0f32; ow * oh * 3];

    for c in 0..3 {
        let base = c * plane;
        for oy in 0..oh {
            let (r0, r1) = (base + oy * 2 * w, base + (oy * 2 + 1) * w);
            for ox in 0..ow {
                let x = ox * 2;
                let sum = img.data[r0 + x]
                    + img.data[r0 + x + 1]
                    + img.data[r1 + x]
                    + img.data[r1 + x + 1];
                data[(oy * ow + ox) * 3 + c] = sum * 0.25;
            }
        }
    }

    Rgb {
        width: ow,
        height: oh,
        data,
    }
}

fn mono_half(img: &Image) -> Rgb {
    let (w, h) = (img.width, img.height);
    let (ow, oh) = (w / 2, h / 2);
    let mut data = vec![0f32; ow * oh * 3];

    for oy in 0..oh {
        let (r0, r1) = (oy * 2 * w, (oy * 2 + 1) * w);
        for ox in 0..ow {
            let x = ox * 2;
            let v = (img.data[r0 + x]
                + img.data[r0 + x + 1]
                + img.data[r1 + x]
                + img.data[r1 + x + 1])
                * 0.25;
            let o = (oy * ow + ox) * 3;
            data[o] = v;
            data[o + 1] = v;
            data[o + 2] = v;
        }
    }

    Rgb {
        width: ow,
        height: oh,
        data,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fits::{Header, Value};

    fn img(
        width: usize,
        height: usize,
        planes: usize,
        data: Vec<f32>,
        bayer: Option<&str>,
    ) -> Image {
        let mut header = Header::default();
        if let Some(b) = bayer {
            header.cards.push(("BAYERPAT".into(), Value::Str(b.into())));
        }
        Image {
            width,
            height,
            planes,
            data,
            header,
        }
    }

    #[test]
    fn grbg_maps_channels_correctly() {
        let i = img(2, 2, 1, vec![10.0, 20.0, 30.0, 40.0], Some("GRBG"));
        let rgb = to_rgb_half(&i);
        assert_eq!(rgb.width, 1);
        assert_eq!(rgb.height, 1);
        assert_eq!(rgb.data, vec![20.0, 25.0, 30.0]);
    }

    #[test]
    fn rggb_maps_channels_correctly() {
        let i = img(2, 2, 1, vec![10.0, 20.0, 30.0, 40.0], Some("RGGB"));
        assert_eq!(to_rgb_half(&i).data, vec![10.0, 25.0, 40.0]);
    }

    #[test]
    fn three_plane_input_is_not_demosaiced() {
        let data = vec![
            1.0, 1.0, 1.0, 1.0, 2.0, 2.0, 2.0, 2.0, 3.0, 3.0, 3.0, 3.0,
        ];
        let i = img(2, 2, 3, data, Some("GRBG"));
        assert_eq!(to_rgb_half(&i).data, vec![1.0, 2.0, 3.0]);
    }
}
