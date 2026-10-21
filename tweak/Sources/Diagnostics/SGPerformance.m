#import "SGPerformance.h"
#import "SGHangSampler.h"
#import "SGPerformanceMath.h"
#import "Core/SGCore.h"
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <sys/utsname.h>
#import <stdatomic.h>
#include <string.h>

#ifndef SG_BUILD_SHA
#define SG_BUILD_SHA "local"
#endif

static NSString *const kBaseline = @"spotifyglass.performance.baseline";
static const NSUInteger kHistoryLimit = 600;
static atomic_bool sg_pending;
static BOOL sg_collecting;
static BOOL sg_playing, sg_paused, sg_loading, sg_stateKnown;
void SGPerformanceSetPlaybackState(BOOL playing, BOOL paused, BOOL loading) {
    sg_playing = playing; sg_paused = paused; sg_loading = loading; sg_stateKnown = YES;
}
static uint64_t sg_events[SGPerformanceEventCount];

void SGPerformanceCount(SGPerformanceEvent event) {
    if (sg_collecting && event < SGPerformanceEventCount) sg_events[event]++;
}

static NSDictionary *eventCounts(void) {
    return @{@"bar_requests": @(sg_events[SGPerformanceBarRequested]),
        @"bar_applied": @(sg_events[SGPerformanceBarApplied]),
        @"lyrics_requests": @(sg_events[SGPerformanceLyricsRequested]),
        @"lyrics_applied": @(sg_events[SGPerformanceLyricsApplied]),
        @"lyrics_ticks": @(sg_events[SGPerformanceLyricsTick]),
        @"preview_ticks": @(sg_events[SGPerformancePreviewTick]),
        @"stale_lyrics_waits_skipped": @(sg_events[SGPerformanceStaleLyricsWait])};
}

static NSString *eeveeProfile(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strcasestr(name, "eevee")) return @"loaded";
    }
    return @"absent";
}

@interface SGPerformanceMonitor : NSObject
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, strong) dispatch_queue_t files;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *history;
@property (nonatomic, copy) NSDictionary *latest;
@property (nonatomic, copy) NSString *session, *context;
@property (nonatomic) SGPerfSummary summary;
@property (nonatomic) NSUInteger generation, historyEpoch, windowCount, streak, sinceSave;
@property (nonatomic) double lastTime, lastCPU;
@property (nonatomic) BOOL regressed, loaded;
- (void)refresh;
- (void)persist;
- (void)sample:(double)delay;
@end

static NSString *historyPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"spoti.pw/performance.json"];
}

static double cpuSeconds(void) {
    task_absolutetime_info_data_t info;
    mach_msg_type_number_t count = TASK_ABSOLUTETIME_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_ABSOLUTETIME_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    return ((double)info.total_user + info.total_system) * base.numer / base.denom / 1e9;
}

static NSDictionary *summaryJSON(SGPerfSummary s) {
    return @{@"cpu": @(s.cpu), @"memory": @(s.memory), @"p95": @(s.p95), @"count": @(s.count)};
}
static SGPerfSummary readSummary(NSDictionary *s) {
    return (SGPerfSummary){[s[@"cpu"] doubleValue], [s[@"memory"] doubleValue],
        [s[@"p95"] doubleValue], [s[@"count"] unsignedIntegerValue]};
}

@implementation SGPerformanceMonitor {
    SGPerfPoint _window[30];
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _files = dispatch_queue_create("spotifyglass.performance.files", DISPATCH_QUEUE_SERIAL);
    _history = [NSMutableArray array];
    _session = NSUUID.UUID.UUIDString;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification])
        [center addObserver:self selector:@selector(refresh) name:name object:nil];
    // Read bounded history off-main. Current-process samples always stay last.
    dispatch_async(_files, ^{
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:historyPath() error:nil];
        NSData *data = [attrs[NSFileSize] unsignedLongLongValue] <= 2 * 1024 * 1024 ? [NSData dataWithContentsOfFile:historyPath()] : nil;
        id saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *rows = [saved isKindOfClass:NSDictionary.class] && [saved[@"samples"] isKindOfClass:NSArray.class] ? saved[@"samples"] : @[];
        if (rows.count > kHistoryLimit) rows = [rows subarrayWithRange:NSMakeRange(rows.count - kHistoryLimit, kHistoryLimit)];
        dispatch_async(dispatch_get_main_queue(), ^{
            // Clearing while the read was in flight must not resurrect deleted samples.
            self.loaded = YES;
            if (self.historyEpoch) { [self persist]; return; }
            NSMutableArray *combined = [NSMutableArray arrayWithArray:rows];
            [combined addObjectsFromArray:self.history];
            if (combined.count > kHistoryLimit) [combined removeObjectsInRange:NSMakeRange(0, combined.count - kHistoryLimit)];
            self.history = combined;
            [self persist];
        });
    });
    return self;
}
- (void)refresh {
    sg_collecting = NO;
    SGHangSamplerSetPerformanceEnabled(NO);
    self.generation++;
    if (self.timer) dispatch_source_cancel(self.timer);
    self.timer = nil;
    self.lastTime = 0;
    self.windowCount = self.streak = 0;
    self.summary = (SGPerfSummary){0};
    self.regressed = NO;
    [self persist];
    if (!SGFlag(SGKeyPerformance, NO) || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    sg_collecting = YES;
    SGHangSamplerSetPerformanceEnabled(YES);
    NSUInteger generation = self.generation;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    self.timer = timer;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(timer, ^{
        // At most one outstanding heartbeat, even during a long main-thread stall.
        if (atomic_exchange(&sg_pending, true)) return;
        double sent = CACurrentMediaTime();
        dispatch_async(dispatch_get_main_queue(), ^{
            atomic_store(&sg_pending, false);
            if (generation != self.generation || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
            [self sample:(CACurrentMediaTime() - sent) * 1000];
        });
    });
    dispatch_resume(timer);
}
- (void)sample:(double)delay {
    double now = CACurrentMediaTime(), cpu = cpuSeconds();
    double elapsed = now - self.lastTime, previousCPU = self.lastCPU;
    BOOL primed = self.lastTime > 0;
    self.lastTime = now;
    self.lastCPU = cpu;
    if (!primed || cpu < 0 || previousCPU < 0 || cpu < previousCPU || elapsed <= 0) return;
    task_vm_info_data_t vm;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) != KERN_SUCCESS) return;
    NSProcessInfo *process = NSProcessInfo.processInfo;
    NSString *profile = eeveeProfile();
    struct utsname device;
    uname(&device);
    NSString *context = [NSString stringWithFormat:@"%s|%@|%@|%@|%d|%ld|%ld|%@|stack50-v2|%d%d%d%d", device.machine,
        UIDevice.currentDevice.systemVersion,
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
        SGRedesignedUI() ? @"redesigned" : @"native", process.lowPowerModeEnabled,
        (long)process.thermalState, (long)[NSUserDefaults.standardUserDefaults integerForKey:SGKeyPerformanceScenario], profile, sg_stateKnown, sg_playing, sg_paused, sg_loading];
    if (![context isEqualToString:self.context]) {
        self.context = context;
        self.windowCount = self.streak = 0;
        self.regressed = NO;
        // The preceding CPU interval may straddle pause/loading/scenario changes.
        // Begin comparison with the next complete interval in the new context.
        return;
    }
    SGPerfPoint point = {(cpu - previousCPU) / elapsed * 100, vm.phys_footprint / 1048576.0, delay};
    NSUInteger slot = self.windowCount % 30;
    _window[slot] = point;
    self.windowCount++;
    self.summary = SGPerfSummarize(_window, MIN(self.windowCount, 30));
    NSDictionary *baseline = [NSUserDefaults.standardUserDefaults dictionaryForKey:kBaseline];
    BOOL comparable = [baseline[@"context"] isEqual:context];
    // Three independent, non-overlapping one-minute windows avoid one spike setting an alarm.
    if (self.windowCount % 30 == 0) {
        self.streak = comparable && SGPerfRegressed(self.summary, readSummary(baseline[@"summary"])) ? self.streak + 1 : 0;
        self.regressed = self.streak >= 3;
    }
    self.latest = @{@"time": @(NSDate.date.timeIntervalSince1970), @"session": self.session,
        @"build": @(SG_BUILD_SHA), @"mod": @(SG_VERSION), @"context": context,
        @"cpu": @(point.cpu), @"memory": @(point.memory), @"delay": @(point.delay),
        @"regressed": @(self.regressed), @"operations": eventCounts(),
        @"playback": @{@"known": @(sg_stateKnown), @"playing": @(sg_playing), @"paused": @(sg_paused), @"loading": @(sg_loading)}};
    [self.history addObject:self.latest];
    if (self.history.count > kHistoryLimit) [self.history removeObjectAtIndex:0];
    if (++self.sinceSave >= 15) { self.sinceSave = 0; [self persist]; }
}
- (void)persist {
    if (!self.loaded) return;
    NSDictionary *report = @{@"schema": @2, @"samples": [self.history copy], @"main_thread_stalls": SGHangSamplerSnapshot()};
    dispatch_async(self.files, ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
        NSString *path = historyPath();
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:nil];
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
    });
}
@end

static SGPerformanceMonitor *monitor(void) {
    static SGPerformanceMonitor *value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ value = [SGPerformanceMonitor new]; });
    return value;
}
void SGPerformanceStart(void) {
    // An opted-out launch creates no monitor, reads no history and starts no diagnostic work.
    if (SGFlag(SGKeyPerformance, NO)) [monitor() refresh];
}
void SGPerformanceRefresh(void) { [monitor() refresh]; }
NSDictionary *SGPerformanceSnapshot(void) {
    SGPerformanceMonitor *m = monitor();
    NSDictionary *baseline = [NSUserDefaults.standardUserDefaults dictionaryForKey:kBaseline];
    NSString *status = !SGFlag(SGKeyPerformance, NO) ? @"Off" : !m.timer ? @"Paused" :
        m.summary.count < 30 ? @"Collecting a one-minute window" : !baseline ? @"No baseline saved" :
        ![baseline[@"context"] isEqual:m.context] ? @"Baseline context differs" : m.regressed ? @"Sustained regression detected" : @"Within baseline limits";
    return @{@"status": status, @"latest": m.latest ?: @{}, @"window": summaryJSON(m.summary),
        @"baseline": baseline ?: @{}, @"retained": @(m.history.count), @"operations": eventCounts()};
}
BOOL SGPerformanceSaveBaseline(void) {
    SGPerformanceMonitor *m = monitor();
    if (!m.timer || m.summary.count < 30) return NO;
    [NSUserDefaults.standardUserDefaults setObject:@{@"summary": summaryJSON(m.summary), @"context": m.context,
        @"build": @(SG_BUILD_SHA), @"time": @(NSDate.date.timeIntervalSince1970)} forKey:kBaseline];
    m.streak = 0;
    m.regressed = NO;
    return YES;
}
void SGPerformanceClear(void) {
    SGPerformanceMonitor *m = monitor();
    m.historyEpoch++;
    SGHangSamplerClear();
    memset(sg_events, 0, sizeof(sg_events));
    [m.history removeAllObjects];
    m.latest = nil;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kBaseline];
    [m refresh];
    dispatch_async(m.files, ^{
        [NSFileManager.defaultManager removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"spoti-performance.json"] error:nil];
    });
}
void SGPerformanceExport(void (^done)(NSURL *file)) {
    SGPerformanceMonitor *m = monitor();
    NSDictionary *report = @{@"schema": @2, @"snapshot": SGPerformanceSnapshot(), @"samples": [m.history copy],
        @"main_thread_stalls": SGHangSamplerSnapshot(),
        @"stall_capture": @{@"threshold_ms": @50, @"poll_ms": @25, @"limit": @24, @"scope": @"current process, foreground while recording"}};
    dispatch_async(m.files, ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"spoti-performance.json"]];
        BOOL ok = [data writeToURL:file options:NSDataWritingAtomic error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ done(ok ? file : nil); });
    });
}
