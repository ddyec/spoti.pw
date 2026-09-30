# Lyrics matching and translation alignment

Search keeps the core title while removing recognised soundtrack/theme descriptions.
Explicit recording variants (instrumental, remix, live, bootleg, etc.) stay distinct.
An artist list can be a subset of another release's credits: a shared artist suffices;
candidate ranking prefers more shared artists, then the closest duration.

NetEase catalogue aliases can establish a translated title directly. Otherwise,
when Spotify's original lyrics are available, a failed title search can try up to
three separately credited artists, with at most 40 search results per request.
Cross-script titles enter a tentative stage. They are accepted only after original
lyric text matches at least 40 normalised characters and half the reference text,
within the existing timing/recording checks. Artist-only similarity is insufficient.
No original lyric evidence means no guessed translated title. Searches are bounded,
so absent or low-ranked catalogue entries can still fall back to Spotify.

Alignment compares contiguous groups of up to four original lines on either side,
ignoring punctuation and spacing. The group text must match and its time must agree.
Multiple source translations forming one displayed sentence are joined in order.
When one source sentence spans several displayed lines, its complete translation
belongs to the first line of that group. Chinese text is not split by character count
or copied into every fragment. Missing translations never borrow unrelated neighbours.

QQ QRC uses the first and last actual word timestamps for line start/end, rather than
potentially padded line headers. Recognised credit rows are removed independently
of an earlier unknown introductory row. This does not apply a global time shift.

`scripts/test-lyrics-identity.py` extracts and runs the production Foundation helpers
and parsers on macOS. Its fixtures are synthetic. Windows can check script extraction,
source patterns and layer imports, but cannot establish iOS runtime acceptance.
Lyrics diagnostics can export candidate decisions, network status and the final source.

Regional releases can have completely different artist credits. A matching title and
known duration may enter an evidence stage once Spotify originals exist. With no
shared artist, downloaded originals must meet the full recording-evidence threshold;
a title and duration alone never establish identity. This also applies to translation
lookups and does not use a per-song or per-artist alias table.

NetEase attaches Chinese tlyric translations from the same lyric response, using the
existing original-text and timestamp alignment, before returning its lines. Han in
an original is not a language detector: Japanese originals containing kanji remain
eligible for missing Chinese translations. Diagnostics distinguish a missing payload,
an alignment yielding zero translations, and a lookup skipped because translations
already exist or that exact line set has been queried.

Pronunciation uses provider data only: NetEase romalrc/yromalrc, QQ encrypted roma
QRC with LRC fallback, and optional KRC language type-0 syllables. Word clocks are
retained when available; LRC pronunciation is estimated over the displayed line.
Original-text groups and timestamp agreement prevent borrowing an unrelated row.
Malformed KRC row/word counts suppress pronunciation, keeping original lyrics intact.
A finer Spotify original can receive aligned pronunciation from the selected provider.
The existing redesigned lyrics corner menu exposes Pronunciation when data is present.
No synthesized Japanese kanji reading or machine translation is introduced.
# Native player preview

Source prefetch publishes validated karaoke lines directly to the display cache. The
redesigned lyrics page and preview no longer depend on Spotify making a color-lyrics
request to copy a successful provider result there. Existing finer timing is retained;
the provider can still supply translations/pronunciation. `prefetch` diagnostics record
publication or retention without logging lyric text.

The native player now renders the shared cache's current timed line in its own overlay on
the player, measured between the visible cover and the information row. It does not depend
on Spotify creating or sizing `LyricsContainerView` or populating its preview model. This is
enabled with any custom lyrics source unless **Hide on the player → Lyrics preview** is on.
It uses the same playback clock and lead-line selection as the other lyric surfaces, clears
on track changes and instrumental breaks, and polls only while attached to a window. No
network or parsing work runs in its update. Unsynced/no-source tracks retain Spotify's preview.
The redesigned player has its own independent preview, enabled by default at **Player →
Now playing → Lyrics preview**. It hides while the full lyrics overlay is open or the player
transition is running. The native hide switch does not control the redesign. Device acceptance
is required for the preview's bounds and visibility on the installed Spotify version.
With lyrics diagnostics enabled, `preview` events record the track, display state, cache
count, position and measured rectangles, without recording lyric text. These distinguish a
disabled hide setting, missing timed lyrics, invalid geometry and a displayed line.
