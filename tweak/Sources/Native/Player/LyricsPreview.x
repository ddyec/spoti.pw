// Native preview owns its surface: Spotify may never create LyricsContainerView, or may
// give it zero bounds when its separate preview model has no data. Player controller,
// information unit and cover classes/selectors are proven by the existing player hooks
// and recorded player tree. No flag or private preview model is needed here.
#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/LyricsSources/LyricsDiagnostics.h"
#import "NowPlaying.h"

static char kPreviewKey;
static __weak UIView *sg_previewHost, *sg_previewInfo;

static BOOL SGNativeLyricsPreviewAvailable(void) {
    if (SGHidden(SGHideLyricsInline) || !SGLyricsEnabled()) return NO;
    NSArray *lines = SGKaraokeLinesForTrack(SGKaraokePlayingTrack());
    return lines.count && SGKaraokeLinesTiming(lines) != SGKaraokeTimingNone;
}

// Foundation/CoreGraphics regression harness exercises this production geometry directly.
static CGRect previewFrame(CGRect cover, CGRect info, CGRect host) {
    if (cover.size.width < 200 || info.size.height <= 0) return CGRectNull;
    CGFloat top = CGRectGetMaxY(cover) + 8, bottom = CGRectGetMinY(info) - 8;
    CGFloat height = MIN(64, bottom - top);
    CGFloat side = MAX(24, CGRectGetMinX(cover));
    if (height < 28 || top < CGRectGetMinY(host) || bottom > CGRectGetMaxY(host) ||
        host.size.width - side * 2 < 100) return CGRectNull;
    return CGRectMake(CGRectGetMinX(host) + side, top + (bottom - top - height) / 2,
                      host.size.width - side * 2, height);
}

static BOOL showing(UIView *view, UIView *host) {
    if (!view || ![view isDescendantOfView:host]) return NO;
    for (UIView *v = view; v && v != host; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    return YES;
}

@interface SGNativeLyricsPreview : UILabel
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, weak) UIView *cover;
@property (nonatomic, weak) UIView *platformPreview;
@property (nonatomic, copy) NSString *lastDiagnostic;
- (void)refresh;
- (void)findCover;
@end

@implementation SGNativeLyricsPreview
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.textColor = UIColor.whiteColor;
    self.textAlignment = NSTextAlignmentCenter;
    self.numberOfLines = 2;
    self.userInteractionEnabled = NO;
    self.alpha = 0;
    return self;
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self.timer invalidate];
    self.timer = nil;
    if (!self.window) return;
    __weak SGNativeLyricsPreview *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refresh];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self refresh];
}
- (void)findCover {
    UIView *host = self.superview;
    __block UIView *found = nil;
    SGForEachView(host, ^(UIView *view) {
        if ([NSStringFromClass(view.class) isEqualToString:@"_TtC22Lyrics_NPVContainerKit19LyricsContainerView"])
            self.platformPreview = view;
        if (view.bounds.size.width >= 200 && showing(view, host) &&
            [NSStringFromClass(view.class) isEqualToString:@"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView"]) {
            CGRect rect = [host convertRect:view.bounds fromView:view];
            // Visible centre cell only: neighbouring queue covers can share a window.
            if (CGRectGetMidX(rect) >= 0 && CGRectGetMidX(rect) <= host.bounds.size.width) found = view;
        }
    });
    self.cover = found;
}
- (void)refresh {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIView *host = self.superview, *info = sg_previewInfo;
    if (!host) return;
    BOOL geometry = showing(self.cover, host) && showing(info, host);
    CGRect coverRect = geometry ? [host convertRect:self.cover.bounds fromView:self.cover] : CGRectZero;
    CGRect infoRect = geometry ? [host convertRect:info.bounds fromView:info] : CGRectZero;
    CGRect frame = geometry ? previewFrame(coverRect, infoRect, host.bounds) : CGRectNull;
    geometry = !CGRectIsNull(frame);
    if (geometry) {
        if (!CGRectEqualToRect(frame, self.frame)) self.frame = frame;
    }
    NSString *track = SGKaraokePlayingTrack();
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(track);
    NSInteger ms = SGKaraokePositionMs(), index = -1;
    NSString *text = nil;
    BOOL available = SGNativeLyricsPreviewAvailable();
    if (available && ms >= 0) {
        index = SGKaraokeLeadLine(lines, ms);
        if (index >= 0) {
            SGKaraokeLine *line = lines[index];
            if (ms <= SGKaraokeSungEnd(line) + 4000) text = SGKaraokeLineText(line);
        }
    }
    if (![self.text isEqualToString:text]) self.text = text;
    self.alpha = geometry && available && text.length ? 0.85 : 0;
    // No arranged views are removed or collapsed. Restore the native styling whenever
    // our line is unavailable, including an instrumental gap or the hide switch.
    self.platformPreview.alpha = self.alpha > 0 ? 0 : (SGFlag(SGKeyPlayerBackdrop, NO) ? 0.72 : 1);
    if (SGLyricsDiagnosticsEnabled()) {
        NSString *reason = SGHidden(SGHideLyricsInline) ? @"hiddenBySetting" :
            (!SGLyricsEnabled() ? @"sourcesOff" : (!geometry ? @"noGeometry" :
            (!available ? @"noTimedLyrics" : (!text.length ? @"breakOrUnknownClock" : @"showing"))));
        NSString *key = [NSString stringWithFormat:@"%@:%@", track, reason];
        if (![self.lastDiagnostic isEqualToString:key]) {
            self.lastDiagnostic = key;
            SGLyricsLog(@"preview track=%@ state=%@ lines=%lu ms=%ld index=%ld cover=%@ info=%@ frame=%@",
                track, reason, (unsigned long)lines.count, (long)ms, (long)index,
                NSStringFromCGRect(coverRect), NSStringFromCGRect(infoRect), NSStringFromCGRect(self.frame));
        }
    } else self.lastDiagnostic = nil;
}
- (void)dealloc { [_timer invalidate]; }
@end

static void updatePreview(UIView *host) {
    SGNativeLyricsPreview *preview = objc_getAssociatedObject(host, &kPreviewKey);
    if (!preview && SGLyricsEnabled()) {
        preview = [[SGNativeLyricsPreview alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(host, &kPreviewKey, preview, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:preview];
    }
    if (!preview) return;
    [host bringSubviewToFront:preview];
    [preview findCover];
    [preview refresh];
}

%hook _TtC19NowPlaying_ViewImpl24NowPlayingViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *host = ((UIViewController *)self).viewIfLoaded;
    if (!host || host.bounds.size.height < 200) return;
    sg_previewHost = host;
    updatePreview(host);
}
%end

%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    sg_previewInfo = ((UIViewController *)self).viewIfLoaded;
    if (sg_previewHost) updatePreview(sg_previewHost);
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC19NowPlaying_ViewImpl24NowPlayingViewController",
        @"_TtC20NowPlaying_ModesImpl23InformationElementsUnit",
        @"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView",
        @"_TtC22Lyrics_NPVContainerKit19LyricsContainerView"]);
}
