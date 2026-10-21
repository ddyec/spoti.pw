// Redesigned player: current line below the cover, independent of Spotify preview flags.
// Uses this look's artwork geometry and disappears while its full lyrics overlay is open.
#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/LyricsSources/LyricsDiagnostics.h"
#import "Shared/Player/PlayerState.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"
#import "Redesigned/Lyrics/SGRKaraokeView.h"
#include <math.h>

static char kSGRPreviewKey;
static __weak UIView *sgr_previewHost, *sgr_previewInfo;

static BOOL SGRPlayerPreviewAvailable(void) {
    if (!SGEnabled(SGRKeyPlayerLyricsPreview)) return NO;
    NSArray *lines = SGKaraokeLinesForTrack(SGKaraokePlayingTrack());
    return lines.count && SGKaraokeLinesTiming(lines) != SGKaraokeTimingNone;
}

// Foundation/CoreGraphics regression harness exercises this production geometry directly.
static CGRect sgrPreviewFrame(CGRect cover, CGRect info, CGRect host) {
    if (cover.size.width < 200 || info.size.height <= 0) return CGRectNull;
    CGFloat top = CGRectGetMaxY(cover) + 8, bottom = CGRectGetMinY(info) - 8;
    CGFloat height = bottom - top;
    CGFloat side = MAX(24, CGRectGetMinX(cover));
    if (height < 28 || top < CGRectGetMinY(host) || bottom > CGRectGetMaxY(host) ||
        host.size.width - side * 2 < 100) return CGRectNull;
    return CGRectMake(CGRectGetMinX(host) + side, top + (bottom - top - height) / 2,
                      host.size.width - side * 2, height);
}

// Input is the unshifted cover. Recompute an absolute lift, never accumulate it.
static CGFloat sgrPreviewNeededLift(CGRect cover, CGRect info, CGRect host, CGRect area,
                                    CGFloat neededHeight, NSInteger nativeStatus, BOOL ready) {
    if (!ready || nativeStatus != 0 || CGRectIsNull(cover) || CGRectIsNull(area) ||
        info.size.height <= 0 || cover.size.width < 200) return 0;
    CGFloat gap = CGRectGetMinY(info) - CGRectGetMaxY(cover) - 16;
    CGFloat firstSafeTop = MAX(CGRectGetMinY(host) + 8, CGRectGetMinY(area) + 8);
    CGFloat limit = MAX(0, CGRectGetMinY(cover) - firstSafeTop);
    return MIN(limit, ceil(MAX(0, neededHeight - gap)));
}

static BOOL sgrPreviewShouldRoll(BOOL sameTrack, NSInteger oldIndex, NSInteger newIndex,
                                 NSInteger elapsed, BOOL reducedMotion) {
    return sameTrack && oldIndex >= 0 && newIndex == oldIndex + 1 &&
        elapsed >= 0 && elapsed < 2000 && !reducedMotion;
}

static BOOL sgrShowing(UIView *view, UIView *host) {
    if (!view || ![view isDescendantOfView:host]) return NO;
    for (UIView *v = view; v && v != host; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    return YES;
}

@interface SGRPlayerPreview : UIView
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *lineView;
@property (nonatomic, strong) UIView *retiring;
@property (nonatomic, strong) SGKaraokeLine *line;
@property (nonatomic, copy) NSString *translation;
@property (nonatomic, copy) NSString *track;
@property (nonatomic) NSInteger lineIndex;
@property (nonatomic) NSInteger position;
@property (nonatomic) CGSize measured;
@property (nonatomic) BOOL showing;
- (void)refresh;
@end

@implementation SGRPlayerPreview
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.clipsToBounds = YES;
    self.alpha = 0;
    _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = NO;
    [self addSubview:_scroll];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:SGKaraokeLinesDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:SGLyricsTranslationUpdatedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:SGKaraokeNativeLyricsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scheduleRefresh) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scheduleRefresh) name:UIApplicationWillResignActiveNotification object:nil];
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self scheduleRefresh];
}
- (void)scheduleRefresh {
    [self.timer invalidate]; self.timer = nil;
    [self.link invalidate]; self.link = nil;
    if (!self.window || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        self.showing = NO;
        self.alpha = 0;
        SGRPlayerSetPreviewLift(nil, 0);
        return;
    }
    __weak SGRPlayerPreview *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) { [weakSelf refresh]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self refresh];
}
- (void)animateText {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || SGRPlayerIsTransitioning()) return;
    SGRKaraokePreviewShowTime(self.lineView, SGKaraokePositionMs());
}
- (void)refresh {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; }); return; }
    UIView *host = self.superview, *info = sgr_previewInfo;
    if (!host) return;
    BOOL timed = SGRPlayerPreviewAvailable();
    // Keep Spotify's artwork scale. Only supplement its absent native lyrics layout.
    SGRPlayerLyricsChanged();
    NSString *track = SGKaraokePlayingTrack();
    NSInteger ms = SGKaraokePositionMs();
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(track);
    NSInteger index = timed && ms >= 0 ? SGKaraokeLeadLine(lines, ms) : -1;
    SGKaraokeLine *line = index >= 0 ? lines[index] : nil;
    CGFloat clip = 0; SGRPlayerAnimatedShowing(&clip, NULL);
    BOOL ready = timed && line && ms <= SGKaraokeSungEnd(line) + 4000 &&
        !SGRPlayerLyricsOpen() && !SGRPlayerIsTransitioning() && clip < 0.01 &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    if (ready) SGKaraokeProbeNativeLyrics(track);
    CGRect cover = SGRPlayerCoverFrameIn(host);
    CGRect information = sgrShowing(info, host) ? [host convertRect:info.bounds fromView:info] : CGRectZero;
    CGRect baseline = cover;
    if (!CGRectIsNull(baseline)) baseline.origin.y += SGRPlayerPreviewLift();
    // Reserve a stable per-song budget, not a different cover position on each line.
    CGFloat needed = 64;
    for (SGKaraokeLine *candidate in lines) if (candidate.translation.length) { needed = 88; break; }
    CGFloat lift = sgrPreviewNeededLift(baseline, information, host.bounds, SGRPlayerArtworkAreaIn(host),
        needed, SGLyricsSpotifyHas(track), ready);
    SGRPlayerSetPreviewLift(track, lift);
    cover = SGRPlayerCoverFrameIn(host);
    CGRect frame = CGRectIsNull(cover) ? CGRectNull : sgrPreviewFrame(cover, information, host.bounds);
    BOOL visible = ready && !CGRectIsNull(frame);
    if (visible != self.showing) {
        self.showing = visible;
        // Only the surface fades. Sequential lyric lines keep their upward movement.
        [UIView animateWithDuration:visible ? 0.20 : 0.14 delay:0
            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut
            animations:^{ self.alpha = visible ? 1 : 0; } completion:nil];
    }
    if (!visible) {
        [self.link invalidate]; self.link = nil;
        [self.retiring removeFromSuperview]; self.retiring = nil;
        self.track = nil; self.lineIndex = -1; self.position = -1;
        return;
    }
    self.frame = frame;
    self.scroll.frame = self.bounds;
    BOOL sameTrack = [self.track isEqualToString:track];
    if (!sameTrack || line != self.line || !CGSizeEqualToSize(self.measured, self.bounds.size) ||
        ![(line.translation ?: @"") isEqualToString:(self.translation ?: @"")]) {
        BOOL rolls = sgrPreviewShouldRoll(sameTrack, self.lineIndex, index, ms - self.position,
            UIAccessibilityIsReduceMotionEnabled());
        [self.retiring removeFromSuperview]; self.retiring = nil;
        UIView *outgoing = self.lineView;
        [outgoing.layer removeAllAnimations]; outgoing.transform = CGAffineTransformIdentity;
        self.line = line; self.translation = line.translation; self.measured = self.bounds.size;
        self.lineView = SGRKaraokePreviewLine(line, self.bounds.size.width, self.bounds.size.height);
        self.lineView.frame = CGRectMake(0, MAX(0, (self.bounds.size.height - self.lineView.bounds.size.height) / 2),
            self.bounds.size.width, self.lineView.bounds.size.height);
        [self.scroll addSubview:self.lineView];
        self.scroll.contentSize = CGSizeMake(self.bounds.size.width, MAX(self.bounds.size.height, self.lineView.bounds.size.height));
        self.scroll.contentOffset = CGPointZero;
        if (rolls && outgoing) {
            UIView *incoming = self.lineView;
            CGFloat travel = MAX(outgoing.bounds.size.height, incoming.bounds.size.height) + 8;
            incoming.transform = CGAffineTransformMakeTranslation(0, travel);
            self.retiring = outgoing;
            __weak SGRPlayerPreview *weakSelf = self;
            [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowUserInteraction
                animations:^{
                    outgoing.transform = CGAffineTransformMakeTranslation(0, -travel);
                    incoming.transform = CGAffineTransformIdentity;
                } completion:^(BOOL finished) {
                    [outgoing removeFromSuperview];
                    if (weakSelf.retiring == outgoing) weakSelf.retiring = nil;
                }];
        } else [outgoing removeFromSuperview];
    }
    self.track = track; self.lineIndex = index; self.position = ms;
    [self animateText];
    SPTPlayerState *state = SGPlayerState();
    BOOL advancing = state.isPlaying && !state.isPaused;
    if (!advancing) { [self.link invalidate]; self.link = nil; }
    if (advancing && !self.link) {
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(animateText)];
        CGFloat hz = self.window.screen.maximumFramesPerSecond;
        self.link.preferredFrameRateRange = CAFrameRateRangeMake(MIN(30, hz), hz, hz);
        [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}
@end

static void updatePreview(UIView *host) {
    SGRPlayerPreview *preview = objc_getAssociatedObject(host, &kSGRPreviewKey);
    if (!preview) {
        preview = [[SGRPlayerPreview alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(host, &kSGRPreviewKey, preview, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:preview];
    }
    if (!preview) return;
    [host bringSubviewToFront:preview];
    [preview refresh];
}

%hook _TtC19NowPlaying_ViewImpl24NowPlayingViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *host = ((UIViewController *)self).viewIfLoaded;
    if (!host || host.bounds.size.height < 200) return;
    sgr_previewHost = host;
    updatePreview(host);
}
%end

%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    sgr_previewInfo = ((UIViewController *)self).viewIfLoaded;
    if (sgr_previewHost) updatePreview(sgr_previewHost);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC19NowPlaying_ViewImpl24NowPlayingViewController",
        @"_TtC20NowPlaying_ModesImpl23InformationElementsUnit"]);
}
