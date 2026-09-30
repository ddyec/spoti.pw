// Redesigned player: current line below the cover, independent of Spotify preview flags.
// Uses this look's artwork geometry and disappears while its full lyrics overlay is open.
#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/LyricsSources/LyricsDiagnostics.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"

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
    CGFloat height = MIN(64, bottom - top);
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

@interface SGRPlayerPreview : UILabel
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *lastDiagnostic;
- (void)refresh;
@end

@implementation SGRPlayerPreview
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
    __weak SGRPlayerPreview *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refresh];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self refresh];
}
- (void)refresh {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIView *host = self.superview, *info = sgr_previewInfo;
    if (!host) return;
    // Sources can finish after the footer's track-change grace period. Refresh its
    // availability from the same display cache; this call exits when nothing changed.
    SGRPlayerLyricsChanged();
    CGRect coverRect = SGRPlayerCoverFrameIn(host);
    BOOL geometry = !CGRectIsNull(coverRect) && sgrShowing(info, host);
    CGRect infoRect = geometry ? [host convertRect:info.bounds fromView:info] : CGRectZero;
    CGRect frame = geometry ? sgrPreviewFrame(coverRect, infoRect, host.bounds) : CGRectNull;
    geometry = !CGRectIsNull(frame);
    if (geometry) {
        if (!CGRectEqualToRect(frame, self.frame)) self.frame = frame;
    }
    NSString *track = SGKaraokePlayingTrack();
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(track);
    NSInteger ms = SGKaraokePositionMs(), index = -1;
    NSString *text = nil;
    BOOL available = SGRPlayerPreviewAvailable() && !SGRPlayerLyricsOpen() && !SGRPlayerIsTransitioning();
    if (available && ms >= 0) {
        index = SGKaraokeLeadLine(lines, ms);
        if (index >= 0) {
            SGKaraokeLine *line = lines[index];
            if (ms <= SGKaraokeSungEnd(line) + 4000) text = SGKaraokeLineText(line);
        }
    }
    if (![self.text isEqualToString:text]) self.text = text;
    self.alpha = geometry && available && text.length ? 0.85 : 0;
    if (SGLyricsDiagnosticsEnabled()) {
        NSString *reason = !SGEnabled(SGRKeyPlayerLyricsPreview) ? @"disabledBySetting" :
            (SGRPlayerLyricsOpen() ? @"fullLyricsOpen" : (!geometry ? @"noGeometry" :
            (!available ? @"noTimedLyricsOrTransition" : (!text.length ? @"breakOrUnknownClock" : @"showing"))));
        NSString *key = [NSString stringWithFormat:@"%@:%@", track, reason];
        if (![self.lastDiagnostic isEqualToString:key]) {
            self.lastDiagnostic = key;
            SGLyricsLog(@"redesignPreview track=%@ state=%@ lines=%lu ms=%ld index=%ld cover=%@ info=%@ frame=%@",
                track, reason, (unsigned long)lines.count, (long)ms, (long)index,
                NSStringFromCGRect(coverRect), NSStringFromCGRect(infoRect), NSStringFromCGRect(self.frame));
        }
    } else self.lastDiagnostic = nil;
}
- (void)dealloc { [_timer invalidate]; }
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
