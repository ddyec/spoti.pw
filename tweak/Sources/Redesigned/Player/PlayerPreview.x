// Redesigned player: current line below the cover, independent of Spotify preview flags.
// Uses this look's artwork geometry and disappears while its full lyrics overlay is open.
#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/LyricsSources/LyricsDiagnostics.h"
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
@property (nonatomic, strong) SGKaraokeLine *line;
@property (nonatomic, copy) NSString *translation;
@property (nonatomic) CGSize measured;
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
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self.timer invalidate]; self.timer = nil;
    [self.link invalidate]; self.link = nil;
    if (!self.window) return;
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
    // Spotify owns artwork layout; reading its final frame avoids a second shrink.
    SGRPlayerLyricsChanged();
    CGRect cover = SGRPlayerCoverFrameIn(host);
    CGRect information = sgrShowing(info, host) ? [host convertRect:info.bounds fromView:info] : CGRectZero;
    CGRect frame = CGRectIsNull(cover) ? CGRectNull : sgrPreviewFrame(cover, information, host.bounds);
    CGFloat clip = 0; SGRPlayerAnimatedShowing(&clip, NULL);
    NSInteger ms = SGKaraokePositionMs();
    NSArray *lines = SGKaraokeLinesForTrack(SGKaraokePlayingTrack());
    NSInteger index = timed && ms >= 0 ? SGKaraokeLeadLine(lines, ms) : -1;
    SGKaraokeLine *line = index >= 0 ? lines[index] : nil;
    BOOL visible = timed && line && ms <= SGKaraokeSungEnd(line) + 4000 && !CGRectIsNull(frame) &&
        !SGRPlayerLyricsOpen() && !SGRPlayerIsTransitioning() && clip < 0.01 &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    self.alpha = visible ? 1 : 0;
    if (!visible) { [self.link invalidate]; self.link = nil; return; }
    self.frame = frame;
    self.scroll.frame = self.bounds;
    if (line != self.line || !CGSizeEqualToSize(self.measured, self.bounds.size) ||
        ![(line.translation ?: @"") isEqualToString:(self.translation ?: @"")]) {
        BOOL changesLine = self.line && line != self.line;
        [self.lineView removeFromSuperview];
        self.line = line; self.translation = line.translation; self.measured = self.bounds.size;
        self.lineView = SGRKaraokePreviewLine(line, self.bounds.size.width, self.bounds.size.height);
        self.lineView.frame = CGRectMake(0, MAX(0, (self.bounds.size.height - self.lineView.bounds.size.height) / 2),
            self.bounds.size.width, self.lineView.bounds.size.height);
        [self.scroll addSubview:self.lineView];
        self.scroll.contentSize = CGSizeMake(self.bounds.size.width, MAX(self.bounds.size.height, self.lineView.bounds.size.height));
        self.scroll.contentOffset = CGPointZero;
        if (changesLine && !UIAccessibilityIsReduceMotionEnabled()) {
            CATransition *fade = [CATransition animation]; fade.type = kCATransitionFade; fade.duration = 0.25;
            [self.scroll.layer addAnimation:fade forKey:@"lyricsLine"];
        }
    }
    [self animateText];
    if (!self.link) {
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
