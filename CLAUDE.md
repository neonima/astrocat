# AstroCat

Lightroom-like preprocessing for astrophotography FITS: stacking, timelapses, mp4 frame extraction. macOS-only, permanently.

## Code style

**Minimal comments.** Only where the reasoning is genuinely non-obvious and would otherwise be lost — a file-format trap, the derivation of a magic constant, a non-local invariant. No module-level prose, no doc comments on self-explanatory functions, no restating what the code says. Default to zero.

## Architecture

```
crates/astrocat-core   Rust: FITS, debayer, stretch, stacking. No platform or UI deps.
crates/astrocat-ffi    C ABI staticlib over core.
include/astrocat.h     Hand-written header. Keep in sync with astrocat-ffi.
apps/AstroCat          SwiftUI + Metal shell.
scripts/build.sh       cargo -> metallib -> swiftc -> dist/AstroCat.app
```

- **SwiftUI/AppKit over a Rust staticlib via C ABI.** macOS-only is a deliberate choice — use Metal, AVFoundation (mp4 decode, ProRes timelapse export) and Accelerate/vImage directly. No cross-platform abstraction layer.
- **Own FITS reader**, no cfitsio. **Own stacking math**, seeded from Python astro libs then ported down.
- **Python is a velocity strategy, not a plugin system.** Embedded in-process via PyO3 with zero-copy numpy over Rust buffers. Borrow astropy/photutils/sep/astroalign to ship fast, profile, port hot paths to Rust. No sandboxing; the API may churn.
- **Guardrail: Python lives in the job/batch layer only, never in the interactive develop path.** An op that needs to sit behind a slider gets ported to Rust first.
- One `Operator` trait, params JSON schema, registry keyed by op id. Per-op profiling from day one so porting targets come from measurements. Golden-image tests assert Rust and Python impls agree.
- A **project** is a directory containing `.astrocat/` (SQLite + preview cache). The app also has a home that indexes known projects and manages imports; opening any folder directly still works in place.
- Display uses an auto screen-stretch (STF), **display-only** — data stays linear.
- **Display is full resolution**, never a binned proxy. `debayer::to_display` goes through `to_rgb_full`. On undersampled data a 2x2 bin is the difference between judging star shape and guessing at it, and a crop cannot be judged against half the pixels it will keep. The measurement path goes through the same function, so a gain solved on one still lands correctly in the other — if one ever moves, both must.
- **Full resolution requires mipmaps.** The display texture is `mipmapped: true` with a blit-generated chain, and the shader's sampler uses `mip_filter::linear`. Fitting 3840 rows into a few hundred pixels of pane otherwise point-samples a periodic subset, and on 1-2px stars that renders a regular lattice instead of a star field. The blit is waited on: a draw encoded before an async mipmap generation samples empty levels and shows black.

## Develop: the stack

- **Stages are instances, not names.** A layer's pipeline is `[OpInstance]`, each with its own id and its own complete parameter set. That is what makes the same operation addable twice — two Tone stages pushing different bands — and it is also what makes per-layer templates and placement-aware dragging fall out for free rather than needing their own machinery.
- **The shader takes an array of `OpSlot`, one per stage.** Field order in `Operations.swift` mirrors `OpSlot` in `Shaders.metal` exactly; a mismatch is a silent misread, not a compile error. Zone curves are concatenated 256-entry blocks and each slot carries its own block index.
- **Placement is a property of the kind, checked before the drop.** `Domain` is `.linear`, `.nonLinear`, `.either`, `.boundary` or `.spine`, and the stretch is the boundary — that is enough to decide every legal position without enumerating rules per pair. `.either` exists because noise reduction genuinely belongs on both sides (chrominance while linear, luminance after), so it warns rather than refuses.
- **Detail is capped at one instance and says why.** It needs a blurred copy of the whole frame at that point, so it drives the two-pass render and cannot be instanced like the per-pixel stages. A second one would silently do nothing.
- **The histogram walks the same slot list the shader walks.** It is a real duplication of the per-pixel maths in Swift, accepted because the alternative is a histogram of a picture nobody is looking at — and with instanced stages, a hardcoded calibrate/palette/stretch/zones sequence would no longer describe the pipeline at all.
- **Before/after is a branch in the shader, not a second view.** It was two Metal views — one plain, one `.frame(...)`-ed and masked — which have to agree on layout to line up, and when they disagree the seam is glaring as an effect and invisible as a cause. `Uniforms.splitX` and `Uniforms.before` make it one view, one draw. Asserted: with the same pipeline on both sides, splitting produces a byte-identical image to not splitting (`0 of 360000 samples differ`).
- **`Renderer.render(width:height:)` renders offscreen and returns the pixels**, so "these two panes should look the same" is a checkable claim rather than an argument. `draw(in:)` and it share one `encode` path, so the test exercises the shipping code.
- **`--selftest <master.fit>` drives the model headlessly** and prints, per layer, which stages are on and which `OpSlot`s reached the shader. The UI cannot be interrogated from outside the app, and diagnosing "this control does nothing" by reading the code has a bad record here — three of the last four such reports were misdiagnosed from screenshots and settled in one step by a measurement. Run it before forming a theory.
- **A stage switched on but with no measurement behind it is a lie.** A Colour calibration stage produces no slot until `colorCal` exists, so it sits inert and then wakes up when something unrelated triggers a fit — which reads as that unrelated action having changed the wrong layer. Measure at load whenever any live stack has one switched on.
- **An `NSViewRepresentable` that overrides `mouseDown` swallows the click.** `CanvasView` did, without calling super, so an `onTapGesture` wrapped around a layer pane never fired — clicking a pane to select it silently did nothing while the segmented control worked. Selection has to be reported from `mouseDown` itself.
- **A stage id from one layer names nothing in the other**, since the stacks hold different instances. Switching layers has to carry the selection across by *kind*, or the inspector points at nothing and every control returns early — which reads as the app being frozen rather than as a lost selection.
- **The `OpSlot` layout is asserted in the shader** (`static_assert(sizeof(OpSlot) == 176)`). Swift writes those bytes and Metal reads them with nothing in between to check they agree; a drift would be a silent misread, not a compile error. Measured: Swift size 172, stride 176, alignment 16.
- **`Master` and `Output` are pinned ends, not steps.** Output is where the merge is seen without a split and where export lives; giving the result a place in the list is what stops "the final picture" being a mode you have to remember to leave.

## Develop: layers

- A separated frame is **two pictures, not one picture with a switch**. `LayerState` holds a complete parameter set plus its own `Renderer` and `LoadedFrame`; the model holds one per layer and `active` picks which the inspector's bindings address. Selecting a pane changes an address and nothing else — no file load, no copied values, no flags to drift.
- **Every push configures every live state**, not just the selected one, so the unselected pane cannot fall behind or run a hand-picked subset of the pipeline.
- The operation list is **derived, never stored**: shared order plus per-state switches, with the description strings computed from live values. A parallel array of switches and labels has to be kept in step by hand in as many places as there are ways to change a value, and every pane that has worn the wrong label was one of those places missed.
- **Layers never get their own STF fit.** The method places the measured sky at a quarter brightness and a star layer has no sky, so a fresh fit collapses and blows out. Both borrow the master's numbers — which is also the only choice under which the screen merge reconstructs the master.
- **Separate the measurement from its application.** Colour calibration is *measured* on the master by necessity — star photometry needs stars, and a starless layer has none — but *applying* it is per layer. Making the switch itself shared meant ticking it while the star layer was selected transformed the pane the user was not editing, and made the inspector's own "these controls belong to this layer" claim false. The spine that is genuinely shared is only the source, background extraction and the split.
- **Not calibrating the star layer is a real choice, not a corner case.** The gains that neutralise the sky (`0.620 / 0.966 / 1.000` here) applied to a star layer already 97% clipped in red push its stars cyan.
### Star removal: stretch first, always

- **Star-removal models are trained on stretched images and must never be handed a linear frame.** StarNet2's README is explicit that float FITS input is read as floating-point samples with no rescaling, so our linear master — median `0.0018` — arrives as effectively black tiles. `stretch::ml_midtone` prepares a non-linear copy, StarNet2 runs on that, and `ac_fits_unstretch` inverts it exactly.
- Measured on the 211-frame stack, same file, same binary, only the input changed:

| starless layer, pixels at zero | R | G | B |
|---|---|---|---|
| linear input | 0.047% | **0.82%** | **1.04%** |
| stretched input | **0** | **0** | **0** |

  The starless minima then land on the master's own (`0.002537 / 0.000778 / 0.000049` against `0.002536 / 0.000778 / 0.000055`). Those zeros were the black speckles in the starless pane. The star layer's channel balance is fixed by the same change: 62% / 59% / 35% zero instead of **97%** / 1% / 0.02%.
- **No shadow clip in the preparation.** With `c0 = 0` the MTF is its own inverse at midtone `1 - m`, so the round trip is exact — 0.002% worst-case relative error. Adding the usual `median - 2.8·MAD` black point makes the inverse ill-conditioned and costs 19% at the sky level, which is where all the nebulosity is.
- **Order matters on the way back: swap planes, then unstretch.** The midtones are per channel, so inverting before the BGR correction applies each one to the wrong plane.
- What survives is a limit of the tool, not of the preparation: the screen merge reproduces the master to a mean absolute error of `4-7e-5`, but the worst case is `0.10` at saturated star cores, where StarNet2's unscreen is not quite the inverse of a screen.
- **Do not judge star colour on the extracted star layer.** Its cores measure `R/G = 1.29` against the master's `1.56`, so applying the master's calibration gains to it over-corrects red by about 20% and turns the stars cyan. Reproduce with `cargo run --release --example starless -- <master> <starnet2>`.
- **`--upsample` is worth its cost on this data and is the default.** Measured on the 211-frame stack, star *removal* is unchanged — 1.9% of star flux left behind against 2.0% — but the star *layer* captures **88.3%** of it instead of 79.3%, mean reconstruction error at stars falls from `0.0203` to `0.0131`, and the 99.99th percentile halves from `0.053` to `0.027`. It costs 3.7x the runtime (36s against 10s at 2160x3840). This is the flag's stated purpose and 3.67"/px is exactly the case for it.
- **The wrapper generalises; the tool does not.** `StarRemover` carries only what differs between backends — argument spelling, whether the model wants stretched input, whether it writes BGR. Prepare/infer/invert is shared. A second model is a registry entry, not a code path.
- **The options that produced the layers are recorded** in a `.separation.json` beside them. Without it, changing an option leaves the old pixels in place and reads as the option doing nothing.
- **GraXpert is not a substitute here.** It does background extraction and denoising, not star removal, so it cannot replace StarNet2 in this slot — it is a candidate for the background-extraction stage we currently do ourselves. Installed at `/Applications/GraXpert.app`. Cosmic Clarity's Darkstar is the free star-removal alternative but is **not installed**, and a registry entry for a tool that cannot be driven reads as a capability — so it is deliberately absent.

## Persistence

Everything the user cannot recreate — develop edits, culling decisions, separation provenance — has to survive the app being replaced under it. The rule is that a release changes the code, never the meaning of a file already on disk.

- **Synthesised `Codable` throws on a missing key even when the property has a default.** Adding one field makes every file written before it unreadable, and the `try?` around the decode turns that into a silent reset. `Settings.decode` merges the file over a default instance and decodes that, so a new field takes its default and every other edit survives. Never call `JSONDecoder` on a settings type directly — conform it to `Migratable` and go through `Settings`.
- **The merge is recursive**, because a field added to `ToneParams` or `DetailParams` is exactly as fatal as one added to `DevelopSettings`.
- **A field whose type changed costs that field, not the file.** The decode retries with the offending key replaced by its default, so one bad value cannot take a night's editing with it. A malformed array is replaced whole — the coding path stops at the first index.
- **Migrations are only for what a default cannot express**: a value spelled differently, or one that now means something else. They are an ordered *list*, not a switch on a separately declared version — the version is `migrations.count + 1`, so a migration cannot be added without the version moving and the version cannot move without a migration to justify it. A file two releases behind runs the steps between where it is and here, in order and once each; measured on a three-step chain, a v1 file walks `v2, v3, v4` and a v3 file only `v4`. A file from a newer build is read as far as this build understands rather than migrated backwards.
- **An enum's raw value is an identifier, not a label.** `WhiteReference` and `Palette` stored the picker's own text, so renaming "SHO (synthetic SII)" in the UI would have reset the setting for everyone who had it. They store case names now and carry a `label`; v1 files are respelled by a frozen table — the strings that were actually written, not whatever the labels say today.
- **The TSV header is the schema.** `ingest::load` reads by column name, so a later release can add, drop or reorder a column without shifting every value in every catalogue one place along — which would land a rejection flag in a star count. `columns()` pairs the names with the values so the header and the row cannot drift apart. Verified: re-saving the real 450-frame catalogue is byte-identical to what the positional writer produced.
- **An older build writing over a newer file does not destroy it.** `Settings.encode` keeps the keys it found and does not understand, so a downgrade costs only what that build could have changed anyway. It stamps its own version, which means the newer build walks those steps again over keys that are already in their final shape — so **a migration has to be safe to run twice.** Write it to match the *old* form and do nothing otherwise: `Settings.respell` looks up the old spelling, and the unit change in the check's three-step fixture only converts a value small enough to still be in the old unit. A migration that transforms blindly would compound. This is the sharpest edge in the design and the only rule the compiler cannot enforce.
- **Measurements are deliberately not persisted.** Colour calibration is re-fitted from the frame rather than trusted from a file that may now describe other pixels, so a migration never has to reason about whether a stored number is still true.
- **The stack setup is one struct, not a dozen properties.** `StackSettings` is `StackModel`'s single mutable settings value, so a control added to it is saved because it is there — not because someone remembered a parallel list. It lives in `.astrocat/stack.json`: two projects are two sets of frames and rarely want the same rejection. What the strategist decides (`fullResolution`, `drizzle`) and what the catalogue supplies (`subExptime`) are deliberately outside it — a stored copy would argue with the frames actually going in.
- **The session selection is stored by night, never by session id.** Ids are positions in the catalogue and move when it is re-ingested. An empty list means all nights, which is also what an unrecorded selection restores to, so a night shot later is included rather than left out of a list written before it existed.
- Still not persisted, on purpose: zoom, pan, and the before/after view mode. Where you were looking is not an edit.

## Build

```bash
./scripts/build.sh && open dist/AstroCat.app
```

```bash
cargo test --workspace
```

```bash
./scripts/check-settings.sh
```

The settings checks are two binaries: the mechanism against fixtures that stand in for a file changing shape between releases, and the same guarantee against the real `DevelopSettings` and `StackSettings` — built from the app's own sources minus `App.swift`, whose `@main` cannot coexist with a check's entry point. The second one goes through `StackModel` rather than the struct, so what it checks is the wiring: opening a project reads its file, changing a control writes one. Pass a master path to print what its develop settings actually restore to, read through a copy so nothing is written back.

## Stacking

- Output is **32-bit float linear FITS** (`BITPIX -32`), never a stretched 8-bit image. Averaging hundreds of frames produces fractional values; 16-bit integer would quantise away the precision stacking just bought. Stretch stays display-only.
- Propagate provenance into the header: `OBJECT`, `DATE-OBS` of the first frame, summed `TOTALEXP`, `STACKCNT`, plus `HISTORY` cards for each pipeline stage.
- **Never measure stack noise with a global MAD.** Once noise falls below the real nebulosity in the frame, global MAD measures structure, not noise, and efficiency appears to collapse as frames are added. Use the **10th percentile of per-tile MAD (32x32 tiles)** — the quietest tiles — applied identically to every image being compared, in identical normalised units.
- Measured baseline on the same 261-frame night, half-res green: single sub `1.179e-03`, Seestar stack `6.903e-05` (17.1x), AstroCat 244-frame stack `6.406e-05` (18.4x). **Seestar's noise reduction is essentially at the √N limit — it is not the weak spot.** We are ~1.08x cleaner, a real but modest win.
- Both stacks score above 100% of the √N ideal, which is a measurement artifact: bilinear resampling correlates adjacent pixels and flatters tile-MAD. Trust the *relative* comparison between similarly-resampled stacks; do not trust absolute efficiency percentages.
- The real opportunities are gradient/light-pollution removal, star sharpness on undersampled data (drizzle), colour calibration, and triage workflow — not noise.

## Background extraction

- Measured on the 244-frame stack, the light-pollution gradient was **29–47% of the sky level** (R 46.8%, G 28.9%, B 45.6%) and is removed by 119–690x. This is the single largest visual improvement available.
- **Reject sample tiles on residuals from a preliminary fit, never on raw brightness.** The bright end of a strong gradient is signal to be modelled; rejecting by brightness discards it and the fit then extrapolates. Rejection is one-sided (upward) because nebulosity only adds light.
- Default degree 2. Higher orders start following nebulosity instead of sky, which silently eats real signal.
- **Don't measure the gradient by sampling the frame** (centre patches are nebula, which extraction correctly preserves). Measure the fitted model's own peak-to-peak amplitude, before and after.
- When comparing before/after visually, apply **identical** stretch parameters to both and match sky levels. A per-image auto-STF re-fits itself and hides the very difference being demonstrated.
- **Group by `FILTER`, never stack across filters.** The stack key is (OBJECT, night, FILTER); exposure length can be normalised across, filter cannot.
- **`FILTER` also selects the stretch policy.** Broadband/LP → unlinked per-channel STF, which correctly neutralises a sky that should be neutral. Dual-band/narrowband → linked STF: unlinked would force the background grey and destroy the Ha/OIII colour separation that is the entire point of the data. Same code, opposite outcome; the filter card is the only thing that distinguishes them.

## Colour calibration

- The correction is **affine per channel, `out = (in - offset) * gain`** — not a gain alone. Two constraints (stars neutral, sky neutral) need two free parameters per channel. Solve `gain` from the star colours first, then `offset` places all three backgrounds on a common level. Anchor that level on the lowest `sky[c] * gain[c]` and every offset comes out non-negative, so no channel is lifted into invented signal.
- **Normalise the gains so the maximum is 1.** Calibration then only ever attenuates and cannot push anything into clipping; the stretch's midtone absorbs the overall darkening.
- **Calibrated data must be stretched linked.** An unlinked STF re-fits each channel to its own median and MAD, and since the gain scales each channel's noise differently it re-imposes a cast and undoes the calibration. Measured on the Seestar stack: after calibration the three unlinked midtones came out `0.00417 / 0.00191 / 0.00246` even though the three backgrounds were identical to six decimals.
- Photometry is **aperture photometry with one aperture shared by all three channels**, centred on the green centroid. Undersampled stars are fine — an aperture sum does not need a resolved PSF, only an aperture that holds all the flux and does not move between channels. Reject blended and low-SNR stars, and check saturation **per channel on raw values**: a star clipped in red but not green reads neutral and drags the white reference toward grey.
- **Measure in display units.** `debayer::to_display` is the one normalisation both the texture and the calibration go through. A number solved against any other scale lands somewhere else in the shader.
- **`FILTER` gates the mode, exactly as it gates the stretch policy.** Dual-band/narrowband gets sky neutralisation only.

Measured on this data (`cargo run --release --example colorcal -- <file> stars`):

| | sky R / G / B | star R/G | solved gain |
|---|---|---|---|
| single 60s sub | 57.7 / 22.9 / 19.4 % | 1.61 ± 0.40 (177 stars) | 0.60 / 0.97 / 1.00 |
| Seestar 261-frame stack | 31.9 / 34.0 / 34.2 % | 1.37 ± 0.18 (467 stars) | 0.72 / 0.99 / 1.00 |

- **The Seestar already neutralises the sky in its own stack but does not correct star colour.** The subs are not neutralised at all — 58% of the sky signal is red.

### Catalogue calibration

Measured against real Gaia DR3 on the 261-frame stack: **328 of 596 detected stars matched**, colour span 0.63 mag in `BP-RP`, `R/G = 1.398 ± 0.131` at a G2V white, gain `0.700 / 0.979 / 1.000`, 172 ms.

- **The field-star reference was not wrong here after all.** It gives `R/G = 1.370` against the catalogue's `1.398` — a 2% difference. The prediction that Cygnus reddening would make the field average visibly too red does not survive contact with the measurement, because a magnitude-limited sample at G < 13 is dominated by distant intrinsically-blue stars: the median matched star sits at `BP-RP = 0.745`, *bluer* than the Sun's 0.82, and that bias largely cancels the reddening. The catalogue's value is not a big correction on this field; it is that the answer no longer rests on an assumption, and the fitted slope proves the match is real.
- **The fitted slope is the diagnostic that matters.** `+0.117` per mag in R and `-0.020` in B: redder catalogue stars measure redder. A slope near zero over a wide colour span means either the match is spurious or the filter passes no colour information. R being six times steeper than B is the LP filter — it cuts blue hard enough that B carries little colour.
- **Match count is the other check.** At this catalogue density, chance alignment within 3 px would yield about 21 matches out of 596. Anything near that number means the WCS is wrong.
- **A blind plate solve is never needed**, and on Seestar stacks no solve is needed at all: the device writes `CTYPE1 = 'RA---TAN-SIP'` with CRVAL/CRPIX/CD and SIP distortion into its own stack. Read it before fitting anything.
- **AstroCat's own stacks are solved**, since subs carry no WCS to propagate. `solve.rs` projects catalogue stars through a hint WCS built from the header's `RA`/`DEC` and the nominal scale, then hands both star lists to the same triangle matcher `register.rs` uses for registration. Composing the fitted similarity with the hint gives another TAN WCS — no hint needs keeping.
- **Both handednesses must be tried.** A similarity transform cannot reflect, and sky-to-pixel parity depends on the optical train, so project once each way and keep whichever matches more stars.
- **Let the scale float.** `FOCALLEN` is nominal: the header says `SCALE = 3.7386` where the solve gives 3.674, about 2% out. Constrain the fitted scale loosely (0.75–1.35) purely to reject nonsense.
- Measured on the 211-frame AstroCat stack: solved centre `314.8088 +44.5387`, **323 stars matched**, `R/G = 1.645`, gain `0.584 / 0.961 / 1.000`. The correction is larger than on the Seestar's own stack (`R/G = 1.398`) because ours preserves raw sensor response while the device has already partly balanced its own — and 1.645 agrees with the raw subs' 1.61.
- **Those numbers were measured on the binned proxy.** Re-measured on the same stack at full resolution the field-star mode finds 1702 stars and uses 630 (was 596/~467), giving `R/G = 1.558 ± 0.153`, gain `0.620 / 0.966 / 1.000`, 566 ms. The 5% shift is the larger, fainter sample, not a bug — but it is why the two normalisations must never be mixed.
- **Solving is seconds, not milliseconds** — a full read, debayer, star detect and triangle match. Keep it off the main thread and cache the result per frame.
- **The fit is a regression, not a synthesis.** Real SPCC convolves catalogue spectra with sensor QE and filter transmission; those curves do not exist for the Seestar. Regressing instrumental `log10(R/G)` and `log10(B/G)` against catalogue `BP-RP` and reading the gains off the chosen white is empirically equivalent, at the cost of not extrapolating past the colour range it saw. Below a 0.25 mag span the slope is fitted to noise, so it falls back to a flat offset and says so.

### The all-sky store

- **Scope the download by the site's observable sky.** From `SITELAT`, declinations below `latitude - 90 + min_altitude` never clear the horizon usefully. At 45.6°N with a 20° floor that is `dec > -24.4°`, about 70% of the sphere.
- **Use range predicates, never `CONTAINS(POINT, CIRCLE)`.** A 2.4° cone at G < 13 in the galactic plane times out the sync endpoint; the equivalent 10°x10° box with plain `ra`/`dec` ranges returns 30,520 rows in 5 seconds.
- **The archive answers a failed query with HTTP 200 and a VOTABLE error document.** Parsing that as CSV yields zero rows and would mark the tile complete, losing that patch of sky silently. Check the response actually starts with the CSV header.
- Ask for `MAXREC` explicitly so truncation is detectable, and split a tile that comes back at the cap — or that fails twice — into quarters rather than retrying it whole.

## Input data facts (measured, not assumed)

Seestar S30 Pro subs, verified 2026-08-15:

- **Darks and flats are already applied on-device.** Min-stack of 20 frames has zero pixels >10σ, no amp glow, corner sky within 3% of centre. No calibration subsystem is needed for Seestar — but keep a calibration *stage* that no-ops, since ASI/DSLR support will need it.
- **A bias pedestal is deliberately left in.** The `BIAS` card is that pedestal (1108 on subs, 1106 on the stack). Read it from the header, never hardcode. Remove it before any multiplicative step or black-point estimate.
- Subs are `2160x3840` portrait, BITPIX 16 with BZERO 32768, `BAYERPAT='GRBG'`, big-endian.
- **No WCS on subs** — `RA`/`DEC` are mount pointing only. Registration must be star-based, and must handle rotation (alt-az mount, 1.4–4.8 px drift per 30s frame).
- **Trap:** the on-device stack is `NAXIS3=3` RGB but still carries `BAYERPAT`. Dispatch on NAXIS3, never on the presence of the card.
- Scale is 3.67″/px over ~2.2°x3.9° — badly undersampled, stars are 1–2px. Drizzle is well motivated.
- A folder mixes lights from multiple nights, multiple exposure lengths, and stacked results. Classify by header; group by `OBJECT` then `DATE-OBS` night.
