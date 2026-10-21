// Redesigned player: current line below the cover, independent of Spotify preview flags.
// Uses this look's artwork geometry and disappears while its full lyrics overlay is open.
#import "Core/SGCore.h"
#import "Diagnostics/SGPerformance.h"
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

// Clip the transition to the text band, rather than exposing both lines in the entire gap.
static CGRect sgrPreviewViewport(CGRect gap, CGFloat textHeight) {
    CGFloat height = MIN(gap.size.height, MAX(1, textHeight));
    return CGRectMake(gap.origin.x, gap.origin.y + (gap.size.height - height) / 2, gap.size.width, height);
}

// Measure once in full-size cover coordinates. The canvas, not the text layout, follows
// the artwork's continuous presentation scale; no late wrap/font substitution is needed.
static CGSize sgrPreviewTextSize(CGRect layoutCover, CGRect host, CGFloat preferredHeight) {
    if (CGRectIsNull(layoutCover)) return CGSizeZero;
    CGFloat side = MAX(24, CGRectGetMinX(layoutCover));
    CGFloat width = floor(host.size.width - 2 * side);
    return width >= 100 ? CGSizeMake(width, preferredHeight) : CGSizeZero;
}

static CGFloat sgrPreviewTextScale(CGFloat viewportWidth, CGFloat layoutWidth) {
    return layoutWidth > 0 ? MIN(1, MAX(0.01, viewportWidth / layoutWidth)) : 1;
}

// Karaoke line views anchor at their leading/trailing edge, not at (0.5, 0.5).
// Align the stable text column to the corresponding edge of the canvas.
static CGPoint sgrPreviewLinePosition(CGSize viewport, CGSize text, CGPoint anchor) {
    return CGPointMake(viewport.width * anchor.x,
        MAX(0, (viewport.height - text.height) / 2) + text.height * anchor.y);
}

static CGFloat sgrPreviewRollDistance(CGFloat viewportHeight, CGFloat outgoingHeight, CGFloat incomingHeight) {
    return MAX(viewportHeight, MAX(outgoingHeight, incomingHeight)) + 8;
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
@property (nonatomic, strong) UIView *canvas;
@property (nonatomic) CGFloat canvasScale;
@property (nonatomic, strong) UIView *lineView;
@property (nonatomic, strong) UIView *retiring;
@property (nonatomic, strong) SGKaraokeLine *line;
@property (nonatomic, copy) NSString *translation;
@property (nonatomic, copy) NSString *track;
@property (nonatomic) NSInteger lineIndex;
@property (nonatomic) NSInteger position;
@property (nonatomic) CGSize measured;
@property (nonatomic) BOOL showing;
@property (nonatomic) CFTimeInterval artworkUntil;
@property (nonatomic) NSUInteger transitionID;
- (void)refresh;
- (void)followArtwork;
@end

@implementation SGRPlayerPreview
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.clipsToBounds = YES;
    self.alpha = 0;
    _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = NO;
    _scroll.clipsToBounds = YES;
    [self addSubview:_scroll];
    _canvas = [[UIView alloc] initWithFrame:CGRectZero];
    _canvasScale = 1;
    [_scroll addSubview:_canvas];
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
- (void)updateGeometry {
    UIView *host = self.superview, *info = sgr_previewInfo;
    if (!host || !sgrShowing(info, host)) return;
    CGRect cover = SGRPlayerCoverPresentationFrameIn(host);
    CGRect gap = CGRectIsNull(cover) ? CGRectNull : sgrPreviewFrame(cover, [host convertRect:info.bounds fromView:info], host.bounds);
    if (CGRectIsNull(gap)) { self.frame = CGRectZero; return; }
    CGFloat scale = sgrPreviewTextScale(gap.size.width, self.measured.width);
    CGFloat height = MAX(self.lineView.bounds.size.height, self.retiring.bounds.size.height);
    CGRect viewport = sgrPreviewViewport(gap, height * scale);
    if (!CGRectEqualToRect(self.frame, viewport)) self.frame = viewport;
    if (!CGRectEqualToRect(self.scroll.frame, self.bounds)) self.scroll.frame = self.bounds;
    CGSize layoutViewport = CGSizeMake(self.measured.width, self.bounds.size.height / scale);
    CGFloat contentHeight = MAX(layoutViewport.height, height);
    CGRect canvasBounds = CGRectMake(0, 0, self.measured.width, contentHeight);
    CGPoint canvasCenter = CGPointMake(self.bounds.size.width / 2, contentHeight * scale / 2);
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    // Bounds/center remain well-defined under the scale, and roll transforms remain on
    // the child views. One transform never overwrites the other's motion.
    if (!CGRectEqualToRect(self.canvas.bounds, canvasBounds)) self.canvas.bounds = canvasBounds;
    if (!CGPointEqualToPoint(self.canvas.center, canvasCenter)) self.canvas.center = canvasCenter;
    if (!CGAffineTransformEqualToTransform(self.canvas.transform, transform)) self.canvas.transform = transform;
    self.canvasScale = scale;
    for (NSUInteger i = 0; i < 2; i++) {
        UIView *text = i == 0 ? self.lineView : self.retiring;
        if (!text) continue;
        CGPoint position = sgrPreviewLinePosition(layoutViewport, text.bounds.size, text.layer.anchorPoint);
        if (!CGPointEqualToPoint(text.layer.position, position)) text.layer.position = position;
    }
    CGSize contentSize = CGSizeMake(self.bounds.size.width, contentHeight * scale);
    if (!CGSizeEqualToSize(self.scroll.contentSize, contentSize)) self.scroll.contentSize = contentSize;
}
- (void)updateLink {
    SPTPlayerState *state = SGPlayerState();
    BOOL needed = self.showing && ((state.isPlaying && !state.isPaused) || CACurrentMediaTime() < self.artworkUntil);
    if (!needed) { [self.link invalidate]; self.link = nil; }
    if (needed && !self.link) {
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(animateText)];
        CGFloat hz = self.window.screen.maximumFramesPerSecond;
        self.link.preferredFrameRateRange = CAFrameRateRangeMake(MIN(30, hz), hz, hz);
        [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}
- (void)followArtwork {
    // Follow the visible spring, including rapid reversal; no 250 ms polling steps on pause.
    self.artworkUntil = CACurrentMediaTime() + 0.8;
    [self updateLink];
}
- (void)animateText {
    SGPerformanceCount(SGPerformancePreviewTick);
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || SGRPlayerIsTransitioning()) return;
    if (self.artworkUntil > 0) {
        [self updateGeometry];
        if (CACurrentMediaTime() >= self.artworkUntil) {
            self.artworkUntil = 0;
            [self updateLink];
        }
    }
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
    CGSize textSize = sgrPreviewTextSize(SGRPlayerPreviewLayoutCoverFrameIn(host), host.bounds, needed);
    BOOL visible = ready && !CGRectIsNull(frame) && textSize.width > 0;
    if (visible != self.showing) {
        self.showing = visible;
        // Only the surface fades. Sequential lyric lines keep their upward movement.
        [UIView animateWithDuration:visible ? 0.20 : 0.14 delay:0
            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut
            animations:^{ self.alpha = visible ? 1 : 0; } completion:nil];
    }
    if (!visible) {
        [self.link invalidate]; self.link = nil;
        self.transitionID++;
        self.artworkUntil = 0;
        [self.retiring removeFromSuperview]; self.retiring = nil;
        self.track = nil; self.lineIndex = -1; self.position = -1;
        return;
    }
    BOOL sameTrack = [self.track isEqualToString:track];
    if (!sameTrack || line != self.line || !CGSizeEqualToSize(self.measured, textSize) ||
        ![(line.translation ?: @"") isEqualToString:(self.translation ?: @"")]) {
        BOOL rolls = sgrPreviewShouldRoll(sameTrack, self.lineIndex, index, ms - self.position,
            UIAccessibilityIsReduceMotionEnabled());
        NSUInteger transition = ++self.transitionID;
        [self.retiring removeFromSuperview]; self.retiring = nil;
        UIView *outgoing = self.lineView;
        [outgoing.layer removeAllAnimations]; outgoing.transform = CGAffineTransformIdentity; outgoing.alpha = 1;
        self.line = line; self.translation = line.translation; self.measured = textSize;
        self.lineView = SGRKaraokePreviewLine(line, textSize.width, textSize.height);
        self.lineView.frame = (CGRect){CGPointZero, self.lineView.bounds.size};
        [self.canvas addSubview:self.lineView];
        self.scroll.contentOffset = CGPointZero;
        [self updateGeometry];
        if (rolls && outgoing) {
            UIView *incoming = self.lineView;
            // Both groups move upward on one timeline. Keep a full group plus breathing
            // room between them, with their entry/exit outside the clipped text band.
            self.retiring = outgoing;
            [self updateGeometry];
            CGFloat travel = sgrPreviewRollDistance(self.bounds.size.height / self.canvasScale,
                outgoing.bounds.size.height, incoming.bounds.size.height);
            incoming.transform = CGAffineTransformMakeTranslation(0, travel);
            __weak SGRPlayerPreview *weakSelf = self;
            [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowUserInteraction
                animations:^{
                    outgoing.transform = CGAffineTransformMakeTranslation(0, -travel);
                    incoming.transform = CGAffineTransformIdentity;
                } completion:^(BOOL finished) {
                    [outgoing removeFromSuperview];
                    SGRPlayerPreview *preview = weakSelf;
                    if (!preview || preview.transitionID != transition) return;
                    preview.retiring = nil;
                    [preview updateGeometry];
                }];
        } else [outgoing removeFromSuperview];
    }

    self.track = track; self.lineIndex = index; self.position = ms;
    [self animateText];
    [self updateGeometry];
    [self updateLink];
}
@end

void SGRPlayerPreviewArtworkWillAnimate(void) {
    SGRPlayerPreview *preview = objc_getAssociatedObject(sgr_previewHost, &kSGRPreviewKey);
    [preview followArtwork];
}

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
