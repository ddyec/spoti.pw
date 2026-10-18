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

## Follow-up: why the incomplete samples failed

At the user's request, pushing and Actions were paused for further investigation.
The original audit above remains unchanged as the before-state. The new
`lyrics-live-audit-strategy-2026-10-18.json` retains the nine earlier verified samples
and rechecks only the three incomplete samples with the adjusted strategy.

| Sample | Observed failure | Targeted adjustment | New evidence |
|---|---|---|---|
| 水星記 / 郭頂 | KuGou returned no candidates for the traditional names, although NetEase matched | Simplify domestic search text to 水星记 / 郭顶; preserve displayed metadata | NetEase + KuGou original similarity 0.9924 |
| Love Poem / IU | KuGou returned none for `Love Poem` or `love poem`, but candidates for `Love poem` | Use the selected recording's catalogue spelling in the one cross-check | NetEase + KuGou similarity 0.9802 |
| Spring Day / BTS | KuGou returned durations `286` and `274` in seconds; the old `/1000` rejected both. NetEase's leading candidates were live/Japanese versions | Interpret mixed units using the known recording length; retain the 8-second tolerance, rejecting 286 and accepting 274 | KuGou + LRCLIB diagnostic reference similarity 0.9743 |

All 12 sampled recordings now have an independently corroborated original-text
result in the combined audit. LRCLIB was only an independent diagnostic reference
for Spring Day; this experiment did not add it to the user's enabled providers or
production fallback chain. QQ returned application code 2001 during these checks;
that is an observed source rejection, not evidence of a particular quota cause.
The strategy deliberately does not rely on repeatedly retrying QQ.

Production changes corresponding to this experiment:

- Search conversion happens on QQ/NetEase/KuGou query text, not the UI song names.
- Successful provider results carry their actual catalogue spelling. The existing
  optional single cross-check can reuse it rather than generate casing variants.
- KuGou's duration normalization chooses the seconds/milliseconds interpretation
  nearest the known track length; the existing recording tolerance remains intact.
- Regression cases cover traditional queries, preserved Latin casing, both duration
  units and rejection of the alternate 286-second recording.

This is evidence for the search and matching strategy on the sampled recordings,
not a universal catalogue guarantee or iOS device acceptance. No Action has run
for this revision. The Objective-C regression suites and full IPA compilation still
need the later Action; the Windows checks validate Python syntax, production-source
extraction, layer imports and live source responses.

## Second independent round and Action gate

The user subsequently explicitly authorized a wholly different round, then an Action
only if all its checks passed. `lyrics-live-audit-round2-initial-2026-10-18.json`
preserves its initial failures. No songs or artists from the first round were reused.
The original ambiguous 寶貝 sample was resolved into both official recordings,
In the Night and In a Day, increasing the fixed corpus from 12 compositions to 13
recordings. The final `lyrics-live-audit-round2-2026-10-18.json` has zero reused
results from the earlier round, covering Chinese, English, Japanese, Korean,
French, Spanish and German.

The final 13 recordings passed independent original-text comparison (minimum
similarity 0.8663), 13 deliberately unrelated lyric bodies were rejected, and the
same-composition/different-recording 寶貝 case was rejected by version and duration.
Its similar words are not evidence that the recordings are interchangeable.

Findings: 遇見's first reference query timed out; 寶貝 required precise version names;
cardigan exposed English recording/publishing credits at opposite ends of the two
source payloads. Strong metadata prefixes are now filtered without removing ordinary
lyric text. Fine uses 太妍 in NetEase and TAEYEON in the reference catalogue: it passed
the existing reference-original-text path using LRCLIB as the diagnostic reference.
It is explicitly marked `requires_existing_reference` and is not claimed to work
through a guessed artist alias without such evidence. No production artist lookup
or extra fallback was added for it.

NetEase's own request function was also found to bypass the shared request cache.
It now goes through `SGLyricsReadJSON`, retaining its 3s timeout, with sorted URL
parameters so lyric and translation consumers can actually reuse the same request.

The Action checks the final audit gate, compiles/runs both Objective-C regressions,
and reads the IPA's real CFBundleShortVersionString before building. It must stop
if that version differs from 9.1.78. A successful Action still requires phone
acceptance of the cover/preview behavior described above.
