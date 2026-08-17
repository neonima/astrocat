# AstroCat — design brief

Design the interface for **AstroCat**, a macOS app for preprocessing astrophotography.
It is a native SwiftUI + Metal app over a Rust core. Not a web app, not a dashboard.
Design to macOS conventions: real sidebars, toolbars, inspectors, keyboard-first, dense.

## Who uses it

One person, alone, at night. They own a ZWO Seestar — a small automated telescope that
points itself and shoots hundreds of 60-second exposures unattended. In the morning they
have 7GB of near-identical raw frames and no good way to judge them. They are technical,
patient, and care about the result, not the tool. They have used Siril and found it
punishing, and Lightroom, which they like but which cannot open their files.

Their actual complaint, in their words: *"I never can create a satisfying image."*

## What the app does

A home for projects, then four modules. A frame enters at import and leaves as a master
image or a movie.

**Projects and import** — the app keeps a home that lists your projects and runs imports.
A project is a target you are working on over time ("NGC 7000"), containing sessions from
many nights. This is where you create, rename, archive and reopen work, and where new
frames get brought in. See the dedicated section below; this is the part most likely to
be under-designed, and it is where the user's day actually starts.

**Library** — the frames arrive. Judge them, group them, throw away the bad ones.
Projects contain sessions; a session is one observing night. A night crosses midnight,
so "last night" means noon-to-noon, not a calendar date.

**Stack** — combine hundreds of frames into one. **Choosing what goes in is the module, not
a preamble to it.** You are selecting across sessions: all four nights, or only the two
clear ones, or last night's 60-second frames but not July's 30-second ones, or everything
above a quality threshold. The selection needs to be visible, revisable and re-runnable —
you will stack, look, cut more, and stack again. Then set rejection, run a job that takes
minutes, watch it, and compare the result against both the input and your previous attempt.

**Develop** — stretch, colour, gradient removal. Sliders with instant feedback. The edits
are non-destructive: the underlying data always stays linear, and the stretch is a display
parameter, never baked in.

**Timelapse** — order frames over time, apply one consistent look across all of them,
export a movie. Flicker between frames is the enemy.

## The data, concretely — design against these numbers

- **Frame size and orientation vary by camera, and one library holds a mix.** Today's
  sample set happens to be portrait 2160 × 3840 from a small smart telescope, but other
  cameras give landscape, square, and quite different pixel counts — a full-frame DSLR,
  a dedicated mono astro camera, an older sensor. Never assume an aspect ratio. The grid
  has to stay legible with portrait and landscape frames adjacent, and the image canvas
  has to fit anything without letterboxing that looks like a mistake. Decide deliberately
  whether cells are uniform (and how the overflow is handled) or the layout is justified.
- A session is **50–450 frames**, tens of MB each, several GB per target.
- Frames from one night are **visually near-identical** — a grid of thumbnails is 261
  grey rectangles with white dots. Thumbnails alone convey almost nothing.
- What *does* vary, measured across one real night: star count ran 885 → 924 for four
  hours, then collapsed to **92** near dawn before partly recovering to 472. Sky
  background, focus and noise drifted with it.
- A raw frame is **black on screen** until stretched. There is no embedded preview to
  fall back on. Every thumbnail requires computation.
- Useful per-frame numbers: star count, half-flux radius, eccentricity, sky background,
  noise, exposure, gain, sensor temperature, filter, timestamp.
- Metadata arrives as **FITS header cards** — fixed 80-column ASCII, `KEYWORD = value / comment`.
  That format is a real artifact of this domain and may be worth using rather than hiding.

## Projects and import — design this properly

Import is not a file picker followed by a progress bar. It is **scan, propose, review,
choose, ingest** — and the review step is where the design work is.

**What a scan actually finds.** Pointed at one real folder of 451 files, all with the same
`.fit` extension and similar names:

| | |
|---|---|
| 29 Jul | 138 frames, 30s, LP filter |
| 07 Aug | 51 frames, 60s, LP filter |
| 14 Aug | 261 frames, 60s, LP filter — runs past midnight into the 15th |
| — | 1 finished stack, sitting among the frames, indistinguishable by name |

The app must present that structure back to the user and let them choose what to bring in,
per session, before anything is committed.

**Rules the grouping follows.** Classify by header content, never by filename or extension —
the stacked file is only distinguishable by its header. Group by target, then by observing
night using a noon-to-noon rollover, then by filter and exposure length. Never group across
filters. In real data the nights separate cleanly: frames run continuously through a night
with gaps of minutes, and nights are separated by days, so boundaries are unambiguous.

**What the review screen has to answer:** what did you find, how is it grouped, how much of
it is already in this project, what's new, how big is it, and which parts do I want. Selection
should be possible at session granularity and finer.

**Re-import is the normal case,** not an edge case. The user shoots the same target again
next week and points at the same folder. Bringing in only the new frames — without
duplicating, and without a modal about it — should be the default behaviour.

**Project lifecycle.** Create, rename, reopen, archive, delete. A project is a directory
containing its own catalog and preview cache; the home is only an index of where those live.
Files are referenced in place by default, not copied, because a target is several GB.
Consequences the design must handle: an external drive that isn't mounted, files that moved,
a project opened on a machine that has never seen it. Relinking should be recoverable
without losing the culling and edits already done.

**Import also covers video.** Extracting frames from an mp4 is an import type, not a separate
module — frames come out and behave like any other frames from that point on.

## Visual direction — fixed, do not renegotiate

- **Near-black.** Neutral, not blue-black. The image is the only saturated thing on screen;
  everything else recedes. Surrounding UI colour biases how you judge an astro image, so
  chrome must stay achromatic.
- **Night-vision mode.** A toggle that shifts the entire interface to red-only, so it can
  be used beside a telescope without destroying dark adaptation. This is a real working
  mode, not a novelty — design it as a first-class palette, not a filter.
- No light mode. No translucency or vibrancy behind image content.
- Dense and quiet. This is an instrument.

## What to produce

1. **A token system** — palette (both modes), type scale, spacing, corner and border
   treatment. Name the tokens. Both palettes must be complete and specified together.
2. **The home and the import review screen** — projects list, and the screen that shows a
   scanned folder broken into sessions with per-session selection. Treat this as a primary
   screen, not a dialog.
3. **Library, at full fidelity** — the main working screen. Show it holding 261 frames.
4. **Stack**, showing selection across multiple sessions, a job running with progress, and
   the finished result compared against a single input frame.
5. **Develop** and **Timelapse** at lower fidelity — enough to prove the shell holds.
6. **States**: no projects yet, scan found nothing usable, re-import where most frames are
   already present, long job running, job cancelled, job failed, missing drive, a frame that
   won't parse.
6. **A component inventory** — what repeats, and the rules for it.

## The problem worth solving well

Judging 261 near-identical frames is the hard part, and a thumbnail grid is bad at it.
The information the user needs — what happened during the night, when the clouds came,
where focus drifted, which frames to cut — is *temporal*, and a grid throws time away.

One candidate: replace the conventional filmstrip with a **time-accurate trace** of the
session, plotting per-frame quality against real clock time, with gaps where the telescope
was slewing, doubling as the selector. Treat this as a starting provocation, not a
requirement. If you find something better, argue for it.

## Constraints worth knowing

- Long jobs are normal: analysing 261 frames takes 4s, registering them 72s, stacking 16s.
  Progress and cancellation are core UI, not an afterthought.
- Everything is non-destructive. Rejecting a frame, restretching, removing a gradient —
  all reversible. The UI should make that safety legible.
- Values are shown to five decimal places routinely. Tabular numerals are mandatory.
- The user compares things constantly: before/after, frame vs frame, our stack vs the
  telescope's own. Comparison is a first-class interaction, not a modal.

## Do not

- Do not design a web dashboard, marketing page, or onboarding flow.
- Do not use card grids with generous padding. This is a dense professional tool.
- Do not invent friendly empty-state illustrations or mascots.
- Do not use rainbow categorical colour. If colour encodes quality, it should mean
  something — stellar colour temperature runs blue-white through white to orange to red,
  which is a real scale from this domain and already reads as ordered.
