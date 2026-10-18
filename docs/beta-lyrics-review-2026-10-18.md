# Beta update and selective lyrics review

Checked on 2026-10-18. Upstream `main` is `425d68b`, version 0.22.0. Its change over
the previous local main is the repeated update-notice fix. Upstream `beta` is
`49e02e2`, version 0.23.0-beta. This branch integrates beta with the existing custom
lyrics work; the old test branch remains available.

## Compatibility and upstream changes

The existing branch README, supplied device log, beta README,
`SGSupportedSpotifyVersion` and beta's private audio queue guard all target Spotify
9.1.78. No Spotify version migration is part of this change.

Beta adds animated/fluid player artwork, an Apple Music style mini player, a system
player menu, tap-to-seek, album animation, Sing, optional Spicy Lyrics and fixes for
backwards lyric timestamps. It also contains broader changes to settings and audio.
It is suitable as an isolated test branch, subject to real phone acceptance.

Upstream still hides `LyricsContainerView` in the redesigned player. Its player
lyrics overlay opens via the lyrics control; it does not implement the custom
current-line bilingual preview below the full-size album cover. No implementation
of that preview was found in beta. This is a source inspection, not a claim about
the author's unpublished plans.

## Preview implementation

The custom preview listens for the shared hook's lines and translation notifications.
Timed lyrics reserve space immediately using the artwork's existing cover/plate
transform: scale 0.86 and translate up 24pt, composed with its existing pause scale.
The preview setting controls this reservation. Full lyrics and player transitions
hide the preview; the full lyrics overlay retains its own existing behavior.

The preview now instantiates the SAME `SGRKaraokeLineView` as the detail page through
`SGRKaraokePreviewLine`, sharing its word sweep, floating animation, translation
layout, script direction and simulated-timing preference. Only the current line is
built. Original font is 24pt, with a 20pt minimum. Translation uses the detail-page
size ratio and yields to the original if space is short. Exceptionally long lines
can be scrolled in the reserved preview region instead of being reduced to 10pt.
Line changes crossfade unless Reduce Motion is enabled.

Geometry and line selection refresh at 4Hz or on a notification. A display link
runs only while the preview is visible, advances only the existing word renderer,
and respects the screen's maximum refresh rate. Parsing, translation alignment and
optional cross-source comparison run off the main thread.

## Matching and requests

The supplied log proves QQ candidate 125513551, `Animals (金坷垃)`, was accepted for
Maroon 5's `Animals`, then other songs by the same artist were fetched for translation.
Bracket qualifiers no longer count as bilingual aliases. Traditional/simplified
Chinese names normalize for matching. Explicit catalogue aliases and evidence-based
regional matching are retained; these are not used to silently erase versions.

Exact title + matching artist + known duration within provider tolerance permits
direct use without demanding redundant provider agreement. This is deliberately a
practical confidence path, not a guarantee against every mislabeled catalogue entry.
Ambiguous candidates without a Spotify original may consult ONE other enabled,
independent catalogue. Disagreement or no corroboration ends that attempt; it does
not fan out to a third catalogue. Where Spotify's original is present, provider
validation and the final page decision compare original text.

QQ/NetEase search responses are limited to 12 metadata candidates. QQ, NetEase and
KuGou download at most two candidate recordings per lookup. Artist-only catalogue
scanning and the automatic repeat of an entire source walk were removed. The walk
stops at the first synced answer. Translation checks only eligible song candidates,
stops at its first usable verified translation, and reuses matching NetEase payloads.
QQ application search errors stop keyword retries and introduce a 60s quiet period.

Identical requests share in-flight work and successful raw bytes for 120s, bounded
to 32 responses of at most 256KiB each. Keys include method, URL, headers and POST
body; JSON POST keys are serialized in stable order. Network and QQ application
errors are not retained as successful responses. Line objects are decoded afresh.

## Live preflight

`lyrics-live-audit-2026-10-18.json` records 12 songs covering Chinese, English,
Japanese, Korean, French and Spanish. Nine matched recordings had independent text
agreement (0.8741–1.0), two had a usable metadata-matched single-source result, and
one (`Spring Day`) remained unmatched. Unavailable results are not marked correct.
`Animals (金坷垃)` is a negative regression. `鸿门宴` also exposed combined Chinese/
English credit labels; filtering these raised independent text similarity to 0.9862.

This live audit uses metadata replay on Windows, Apple catalogue references (and
the supplied Spotify metadata for two repro tracks), and an independent text
similarity calculation. It is NOT execution of the iOS hook or audio identity proof.
Reports retain identifiers, counts and similarity scores, not complete lyric bodies
or download access keys. The native Objective-C identity/geometry and request-cache
regressions run in the IPA Action before compilation. Device rendering remains a
separate acceptance step.

## Phone acceptance

Install the Action IPA made from Spotify 9.1.78, restart, enable the redesigned look
and Lyrics preview, and open the player on iOS 26+. Play `Animals` and `鴻門宴`:
the cover should reserve room once hooked lyrics arrive, large preview text should
follow the detail page's word timing, and no 金坷垃 text should appear. Also check
long original/translation lines, late translations, pause/resume, full lyrics
open/close, track changes, and Reduce Motion. Repeat with animated artwork disabled
when checking the cover preview, since animated artwork replaces the cover itself.
