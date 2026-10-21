#import <Foundation/Foundation.h>

#define SGKeyPerformance @"spotifyglass.performance.enabled"
#define SGKeyPerformanceScenario @"spotifyglass.performance.scenario"

typedef NS_ENUM(NSUInteger, SGPerformanceEvent) {
    SGPerformanceBarRequested, SGPerformanceBarApplied,
    SGPerformanceLyricsRequested, SGPerformanceLyricsApplied,
    SGPerformanceStaleLyricsWait, SGPerformanceLyricsTick, SGPerformancePreviewTick, SGPerformanceEventCount
};
// Constant-time, allocation-free counters; call on main. No work while collection is off.
void SGPerformanceCount(SGPerformanceEvent event);

// Main-thread API. Collection is opt-in, foreground-only and independent of FLEX.
void SGPerformanceStart(void);
void SGPerformanceRefresh(void);
NSDictionary *SGPerformanceSnapshot(void);
BOOL SGPerformanceSaveBaseline(void);
void SGPerformanceClear(void);
void SGPerformanceExport(void (^done)(NSURL *file));

// Player publishes only state flags; diagnostics never imports the player layer. Main thread.
void SGPerformanceSetPlaybackState(BOOL playing, BOOL paused, BOOL loading);
