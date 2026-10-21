# Lyric transitions, loading stalls and persistent CPU — 2026-10-21

## Evidence from the supplied device reports

The second report contains 59 foreground samples over 127.43 seconds on Spotify 9.1.78,
Redesigned UI, iOS 27.2, build 24c30e015099, EEVEE loaded. Across these sample points,
mean CPU is 32.06%, median 29.82%, maximum 116.08% (100% is one core, not the whole device).
46 of 59 points exceed 20%. Sampled main-queue delays include 31.99, 45.47 and 58.24 ms;
the median is 0.24 ms. The existing baseline status does not rule out individual stalls.
The thermal-state field remains nominal; it does not measure surface temperature.

The old reports contain neither playback state nor stacks, and cannot attribute these costs
to Spotify, EEVEE, lyrics, rendering or audio. The two-second heartbeat can miss short stalls
and the measurements do not cover constructors before the monitor starts. Layout request
counts represent layout calls, not network requests. No claim of measured CPU improvement
or visually verified motion is made without the owner's next device run.

## Changes

- Preserve anchoring under the scaled artwork. Follow its presentation geometry during a
  bounded spring interval, without repeatedly reflowing text mid-animation.
- Clip lyric groups to the text band and move outgoing/incoming groups upward together,
  separated by a complete group height plus spacing. Superseded completions cannot restart old transitions.
- Full lyrics use a four-per-second metadata/position check while paused, static or awaiting
  data. High-frequency rendering resumes for timed playback and transient interactions;
  app inactivity and removal from the window stop both clocks.
- Decode bounded cache-eligibility JSON outside the lyrics request lock. Main-thread cache
  lookups no longer wait for that decoding; request coalescing and failure handling remain.
- Diagnostic schema 2 exports playback flags and lyric callback counters. Opt-in, foreground
  recording includes a bounded stack sampler (25 ms probe, 50 ms threshold, 24 records retained).
  It stops with recording/backgrounding. Sampling affects measurements, so the diagnostic
  context changes to prevent automatic comparison against old sampler-free baselines.
  Stack capture is best effort; it is not an exhaustive trace of every frame or early startup.
- Reuse hash-verified EV1 components for the pinned companion commit, with source compilation
  as fallback. Cache flags and Icon Composer output. Verify archive/component integrity and
  report stage durations. No simulator or screen recording is required.

## Device verification

On the owner's iOS 27.2 device, select Redesigned UI and check the player while normal lyrics
advance, with multi-line/translated lyrics, and during rapid pause/resume. Check that groups
never overlap and the anchor follows the artwork smoothly. With diagnostics enabled, collect
at least one minute each of timed playback, pause after animations settle, and browsing Home;
export before leaving the session. Playback-state fields and callback-count differences show
which clock was active; stack records identify any captured loading stalls. Save a fresh
baseline only in a stable matching scenario. Actual heat and CPU reduction need those runs.

## Packaging results

Runtime build db9c0cb completed in 7m23s (workflow 39542029484), including 325 seconds
in the combined packaging pipeline. EV1 and generated flags were reused. Compilation,
Foundation regressions and combined IPA validation passed. Alternate icon generation still
failed the existing CoreUI catalog validation (159 seconds); the shipped IPA therefore keeps
the original icon. The build-only follow-up caches this unsupported outcome for the exact
source assets, templates and Xcode, so later runs can avoid the repeated failed work. An
asset/template/tool change invalidates it and retries; successful output is also cached.

## Preview alignment regression fix

The owner’s next screenshot revealed a half-width shift and right-side truncation. Karaoke line
views use a leading/trailing layer anchor (x=0 or x=1), but the preview follower positioned them
as though that anchor were centered. Positioning now accounts for the actual anchor point,
without setting frame under an active transform. Sequential lines use the same simultaneous
upward movement throughout the 280 ms transition; no root crossfade replaces that motion.
Regression checks reconstruct the rendered bounds for left/center/right anchors at playing
and paused widths, and verify that mixed single/multi-line groups cannot intersect throughout
the upward transition. A mutation using the previous center assumption fails these checks.
Visual acceptance remains on the owner’s device; no simulator or recording is used.

## Play/pause typography continuity

The subsequent device check confirmed alignment but exposed clipping during artwork shrink
and a delayed rewrap after the follower window. The final design keeps a stable reading column
measured for the smallest artwork state and the per-song height budget. The same word and
translation views, glyph size and wrap inputs survive play/pause. Only the viewport position
and surrounding whitespace follow the artwork presentation geometry on each animation frame,
including rapid reversal. There is no text-scale animation, endpoint layout replacement or
late font substitution. Leading/trailing text stays anchored to the corresponding artwork edge.

Sentence changes retain their simultaneous upward movement. Very long groups keep their
translation and the existing vertical scroll instead of silently dropping content. Real host
resizing and source/translation changes still update the layout. Regression checks sweep
shrink/grow reversals and verify invariant measurement, continuous positioning and absence of
horizontal clipping for every anchor. Visual acceptance remains on the owner's device.
