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
