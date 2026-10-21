# Repeated operations and lyric motion

Baseline: `b522102` (`fix/native-missing-lyrics-roll-20261020`), retaining its
custom QQ/KuGou and native-missing lyric behavior. EEVEE was inspected at
`fb0dc75` (`feat/ev1-spoti-companion-20261019`). This is a source review and
optimization, not a new IPA patching chain. Existing packaging is unchanged.

## Findings backed by call paths

| Operation | Existing behavior | Change |
| --- | --- | --- |
| Now-playing bar styling | Both container and child `viewDidLayoutSubviews` call `styleNowPlayingBar` on the same tree, including background and card walks | Coalesce requests per container until the next main-queue turn; tree changes in later passes are still processed |
| Full lyric geometry | Player, information, duration and floating units each call `replace` | Coalesce their requests into one application after layout; animation completion still reconciles geometry |
| Lyric grace checks | Each track change queues two callbacks; old callbacks can act on the next track | Only the newest generation may update availability or close the lyrics |
| Preview cover transform | Clearing an already empty `(nil, 0)` lift fails the string-only equality check and rescales covers repeatedly | Treat identical pointers, including nil, as equal; skip unchanged cover/shadow transforms |
| Preview timers | A view still in a window keeps its 250 ms timer in the background; visible paused text keeps a display link | Stop both on inactive/background and restart in foreground; run the word display link only during playback |
| Full lyric reversal | Every toggle resets thumb/line starting states; any old completion can clear `sg_moving` and remove the overlay | Retarget from current motion and ignore superseded completions |
| Opening while pausing | Overlay uses the cover's model target, although its spring is still visibly shrinking | Read the presentation geometry for the opening stand-in |

The bar/layout coalescing defers work by one main-queue turn. The player harness
must check initial appearance and transitions; no blanket cache skips future
layout passes. Counter rows expose requests versus actual applications.

## What is already deduplicated

`SGLyricsFetch` uses `sg_waiting` to combine simultaneous requests for the same
source cache key. `SGKaraokeRequestLyrics` tracks pending requests and retries.
The two EEVEE URLSession delegates are different delivery paths; duplicated
source text alone is not evidence that a response is processed twice. They must
not be removed indiscriminately.

Native and Redesigned repaint hooks run under mutually exclusive UI gates.
EV1's appearance/lyrics/gesture/flag groups are already inactive in its entry
point; their source files alone do not establish ongoing duplicate work.
Its two lyrics-only player-capture hooks still belonged to Premium groups on
older-version paths. The separate companion branch moves them to the inactive
lyrics group and stops starting global notification probes (`notifOn = true`).
No main branch or installed app has been changed.

## Visual acceptance takes priority

Full cover travel keeps a critically damped spring (420 ms opening, 360 ms
closing) because the picture moves across much of the player. Line entry is
240 ms after 40 ms; exit is 160 ms. Fast reversals do not restart at a preset
endpoint. Reduced Motion removes the spatial transition. Preview visibility
fades independently; consecutive lyric lines still roll upward with no text
crossfade and travel by their own height instead of the whole available gap.

`HARNESS_SCENARIO=lyrics-interruptions` exercises open-close-open, close-open-close,
repeated layout and opening during pause shrink. It checks attachment, final
thumbnail size and cleanup. Those checks do not prove every animation frame
looks natural; inspect a simulator recording and the actual Spotify player.

## Performance diagnostics

Mod Settings → Performance diagnostics is opt-in and works without FLEX. A
utility timer sends at most one pending main-queue heartbeat every two seconds;
inactive/background cancels it and invalidates old callbacks. CPU uses cumulative
process Mach time (100% means one core); memory is physical footprint, in MiB.
Main queue p95 is a sampled delay, not FPS or a count of all stalls.

Save a baseline after at least 30 samples in one context (about 62 seconds).
Context matches device model, iOS, Spotify, UI mode, power, thermal state,
EEVEE presence and the selected test scenario. Match playback, scrolling,
feature settings and EEVEE version manually; a baseline cannot infer workloads.
Three non-overlapping 30-sample windows must exceed a relative and absolute
limit to report a sustained regression: CPU +25% and +10 percentage points;
memory +20% and +30 MiB; main-queue p95 +50% and +50 ms. Changing context or
returning from background resets the window and streak. Baselines survive app
upgrades and remain explicitly replaceable; no automatic rebaselining masks
a slowdown.

Keeps the latest 600 timestamped samples across launches in Application Support,
with session/build identifiers and operation counters. Writes every 30 seconds
and on lifecycle changes, off-main. Clear removes baseline, history and the
temporary export. JSON export is manual. It contains no track titles, tokens or
lyric text and is never automatically uploaded. Device CPU/GPU gains are not
claimed without before/after measurements.

## Verification

- `bash scripts/test-performance.sh`: production summary/regression math.
- `scripts/check-layers.sh`: architecture boundaries.
- The macOS workflow runs existing lyric regressions, compiles the full tweak
  using flags from the SHA-256 verified clean 9.1.78 IPA, and compiles the player
  harness. The downloaded IPA is not modified or redistributed.
- On iOS 26+ in Redesigned UI, inspect preview lines, full lyric open/close,
  rapid reversal, pause/resume, track changes and Reduced Motion. Check Native
  UI diagnostics separately. Record before/after runs in matching scenarios.
