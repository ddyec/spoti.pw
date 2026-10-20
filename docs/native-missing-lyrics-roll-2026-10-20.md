# 9.1.78 native-missing preview and English release labels

Baseline: `d95a5c5`, the previously tested custom lyrics branch. This is not the
official 1.0 Beta / Spotify 9.1.90 branch. Input is the user's existing
`EeveeSpotify-6.6.8-9.1.78.ipa` from `ddyec/python38`, release `22`.
EEVEE is not rebuilt or replaced; packaging checks its 81 payload files against
the supplied input. Existing EEVEE settings/state remain those of that package
and installation. This change does not claim to change EEVEE's startup defaults.

## Player behavior

Spotify's raw `has_lyrics` is noted before the custom lyric hook changes it.
Absent metadata now stays unknown. Only unknown native availability is queried
quietly, using Spotify's captured headers and the existing own-request bypass.
At most one request per track is in flight; unsuccessful unknown probes have a
30-second cooldown and a two-attempt cap in a bounded 40-track cache. Responses
are keyed to the requested track, never the track playing when the reply lands.
The probe never writes Spotify lyrics into the selected-provider display cache.

A real 404/204 or valid empty lyrics JSON means missing. Authentication errors,
rate limits, server errors, malformed JSON and transport failures stay unknown.
Only known missing native lyrics plus ready custom timed lyrics can reserve
additional space. Available space is measured against the information row and
artwork band; the cover and shadow move upward by an absolute bounded offset,
without changing the existing playing/paused scale. Repeated layout does not
accumulate displacement. Full lyrics, transitions, animated artwork and absent
custom lyrics release that compensation. Extra-long lines retain scrolling
when the available header-safe space is insufficient.

Sequential line changes slide the old view upward out and the new view upward
in through the clipped preview. There is no crossfade. Track changes, seeks,
background return and Reduce Motion snap to the current line. Translation-only
or size updates do not replay a line-change animation.

## STAY investigation

The supplied log identifies Spotify `5HCyWlXZPP0y6Gqq8TgA20`,
`STAY (with Justin Bieber)`, The Kid LAROI, 142 seconds. It searched the full
credit-bearing title and fell back to Spotify. The NetEase candidates included
uploaders, karaoke, acoustic covers and remixes; none warrants relaxed identity.

A bounded QQ query with the normalized title finds song `318931533`,
`STAY (Explicit)`, The Kid LAROI / Justin Bieber, 141 seconds. The follow-up
fetched 1,434 normalized lyric characters. KuGou did not return a verified
candidate in that same bounded check; this result is a verified-metadata single
source, not independent text corroboration.

The title normalizer now handles trailing `(with <performer>)` as a credit and
an exact trailing `(Explicit)` as a parental-advisory display label. It preserves
Clean/Radio/Live/Remix/Cover markers, including markers nested in a credit.
Artist and duration checks, metadata limits, source ordering and the two-candidate
lyric-fetch limit are unchanged. No artist-library search is added.

## Validation and device acceptance

The native Foundation/CoreGraphics regression extracts the real status verdict,
layout, line-change decision and matching code. It covers native present versus
missing versus unknown, layout repetition/header bounds, normal sequential
scrolling versus seeks/Reduce Motion, STAY credit/advisory equivalence and wrong
artist/version rejection. The English audit replays eight common recordings
against QQ and KuGou with production regexes; it is not execution of iOS hooks.

On iOS 27.2 / Spotify 9.1.78 in the redesigned look, install the output with the
normal signer and restart. Check a native-lyrics song, a native-missing song with
QQ lyrics, a long Latin line and STAY. Confirm no extra shrink, no cover drift
after repeated opens/skips, no lyric/title overlap, upward sequential movement,
and unchanged source order. Device appearance remains unverified until that test.


## Completed English catalogue replay

The 2026-10-20 bounded audit found verified lyrics for all eight samples:
STAY, I Don't Care, See You Again, We Don't Talk Anymore, Closer,
Something Just Like This, Señorita, and Die With A Smile. Four had both
QQ/KuGou text corroboration (similarity 0.7464–0.9946); four had one verified
QQ result and no verified KuGou candidate. This is not proof that every
provider has every recording. Full metadata and query limits are retained in
`english-release-label-audit-2026-10-20.json`.

Negative controls passed for live/remix/clean/cover/karaoke and arrangement
suffixes, including a version marker inside a performer credit and an unrelated
uploader artist. The search breadth and acceptance thresholds were unchanged.
Reference durations for seven samples came from the US Apple catalogue; STAY
used the supplied device log's 142 seconds. The audit replays production
normalization rules on Windows; native regression and on-device display are
separate checks.
