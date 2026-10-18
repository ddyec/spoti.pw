# 0.23 beta lyric priority correction

Base remains 0.23.0-beta, supported Spotify remains 9.1.78. No higher release merged.

## Evidence and changes

The supplied `spotifyglass-lyrics-debug(1).log` records QQ desktop search returning business code 2001 (HTTP 200) for Moon Halo. Subsequent tracks hit the provider cooldown and were incorrectly cached as catalogue misses. This explains QQ-only sessions displaying Spotify even for recordings present in QQ.

- Use the verified public QQ search directly, 12 metadata rows, at most two selected lyric candidates. QRC/LRC retrieval remains on musicu. No parallel endpoint fanout.
- Treat search failures/cooldown as temporary unavailability. Retry on a later request after 15 seconds; do not permanently cache the track as missing. A lower-priority answer obtained during failure expires so the first source can recover priority.
- Key results and in-flight requests by track and enabled source order. Discard callbacks from old configurations. Reload the current track on source changes.
- First usable timed provider wins over finer Spotify timing. Only enabled sources supply translations, in user order. A missing independent corroborator does not veto a provider-verified recording; actual contradictory evidence still rejects it.
- Remove the custom cover scale (0.86) and upward translation (-24). Spotify owns lyrics-related player geometry; upstream pause scaling remains.
- Native mode yields entirely to Spotify's visible lyrics preview and removes the custom fallback when native text appears. The upstream native setting hides/shows Spotify's own preview; upstream redesign still hides that surface. Redesign fallback continues reusing the detail-page karaoke renderer without resizing the cover.

## Validation

Fresh live report: `lyrics-qq-retry-2026-10-18.json`. Moon Halo, Attention, 夏霞, 晴天, Animals all fetched original QQ lyrics and matched independent original text (0.9475–0.9901). Animals meme title rejected. Diagnostic independent requests are not part of the QQ-only runtime. No full lyrics or access keys saved.

The new native Foundation regression runs extracted production source-walk/cache logic with deterministic providers: source priority, configuration-sensitive cache, cooldown retry without app restart, recovered first-source priority, stale callbacks, and enabled translation order. Existing recording identity, translation, request coalescing and multilingual gates remain required.

The live replay uses Windows text processing; it does not prove iOS execution or actual player geometry. Device acceptance: restart Spotify 9.1.78, check QQ-only and QQ-first with multiple providers, change source order, and open the player in the chosen appearance. Confirm source credits, no repeated cover shrink, and no duplicated native/custom preview. The original hide-lyrics-preview setting must be off.

## Higher upstream release numbers

Official release notes advertise 0.50, 0.51 and 1.0 beta features. During this inspection their public tags resolved to main commit 425d68b whose version.txt still reads 0.22.0; public beta remained 49e02e2 / 0.23.0-beta. Therefore public tagged source alone cannot establish the newer distributed binaries' Spotify compatibility or implementation. Stay on the agreed beta rather than infer compatibility from release numbering.

Official releases: https://github.com/skopevoj/spoti.pw/releases
