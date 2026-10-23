# Stable player preview artwork anchor

Base: `4e65689` on `feat/performance-diagnostics-20261021`. Applies to the
Redesigned UI on Spotify 9.1.78; the Native UI is unchanged.

The previous preview lift ran only when Spotify lyrics were known missing.
That confused native catalogue availability with actual player space. A present
or unknown verdict could leave a bilingual preview clipped under the artwork,
as in the supplied Call of Silence screenshot. The screenshot alone does not
establish that track's native availability verdict.

The preview now reserves an 88-point bilingual band as soon as timed lyrics are
available. It captures a header-safe cover centre in player coordinates, leaving
an already sufficient gap alone. The artwork and shadow apply the same signed
correction relative to their current native parent geometry. Repeated layout,
late native lyrics and native movement in either direction cannot accumulate an
extra lift. An unchanged anchor is reapplied without starting another spring.
The existing cover layout hook and player layout hook enforce the anchor; no
unverified Spotify selector or native availability network probe is added.

The lyric target and the centred target are cached per track. When a current
nonempty lyric line is visible, the artwork uses the lyric target. Known timeline gaps of at least seven seconds (matching the full lyric page)
centre the artwork after the preceding sung line ends. The artwork starts returning
750 ms before the next line, allowing for the 250 ms timer and the cover spring.
Intro gaps use the first line's timestamp; the outro centres after the existing
four-second lyric hold. Seeks use the new playback position directly. Temporary
cache/clock gaps preserve the previous position rather than declaring a break. Translation arrival does not change its 88-point
budget. Track changes and host resizing invalidate the targets. Disabling preview
selects the centred target. Actual movement of the information row recalculates
them; changing only that row's height does not. Full lyrics, player transitions,
animated artwork and backgrounding suspend preview layout ownership.
Pause/resume retains the existing cover scale around the anchored centre.
Exceptionally tall lyric groups retain the existing scroll fallback.

## Validation

`python3 scripts/test-preview-anchor.py` compiles the actual production geometry
and state predicates using CoreGraphics value-type shims. It simulates 500 late
native parent-layout changes, signed compensation, playing/paused bounds,
header-limited layouts, cache gaps, LRC break boundaries and advance return, centred geometry, setting changes and track reset. It passes on
Linux. Layer checks, performance arithmetic regressions and diff checks pass.
The existing Foundation identity/layout suite has been updated to remove the
obsolete native-status gate assertions. The macOS IPA workflow runs both suites
in its existing check stage before packaging; its run is the compilation authority.
These mathematical tests do not execute UIKit hooks or verify presentation-layer
animation on a phone.

## Device acceptance

Install the resulting combined IPA with the usual signer, restart, and use
Redesigned UI on the owner's iOS 27.2 / Spotify 9.1.78 device. Play Call of Silence
and Moon Halo with translations. Check lyric/title separation, pause/resume,
full lyrics open/close, interludes, skipping to a lyricless track and returning
from background. Under slow networking, let custom and native lyrics arrive in
either order: the cover should settle once and avoid an additional native lift.
The source and companion component pin remain those of the baseline workflow.
