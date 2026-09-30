// Native player/Player.x already proves LyricsContainerView and layoutSubviews against the
// recorded player tree. Its parent is a plain artwork view, not an Encore arranged stack.
// Spotify's preview model need not receive the lyrics that our color-lyrics hook supplies.
// Render those cached lines in the existing preview bounds, using the shared player clock.
#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "NowPlaying.h"

BOOL SGNativeLyricsPreviewAvailable(void) {
    if (SGHidden(SGHideLyricsInline) || !SGLyricsEnabled()) return NO;
    NSArray *lines = SGKaraokeLinesForTrack(SGKaraokePlayingTrack());
    return lines.count && SGKaraokeLinesTiming(lines) != SGKaraokeTimingNone;
}

@interface SGNativeLyricsPreview : UILabel
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSMapTable<UIView *, NSNumber *> *savedAlpha;
- (void)refresh;
@end

@implementation SGNativeLyricsPreview
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.textColor = UIColor.whiteColor;
    self.textAlignment = NSTextAlignmentCenter;
    self.numberOfLines = 2;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.savedAlpha = [NSMapTable weakToStrongObjectsMapTable];
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
- (void)refresh {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIView *host = self.superview;
    if (!host) return;
    BOOL available = SGNativeLyricsPreviewAvailable();
    NSString *text = nil;
    if (available) {
        NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(SGKaraokePlayingTrack());
        NSInteger ms = SGKaraokePositionMs();
        NSInteger index = ms >= 0 ? SGKaraokeLeadLine(lines, ms) : -1;
        if (index >= 0) {
            SGKaraokeLine *line = lines[index];
            // A long instrumental break should not keep the previous sentence on screen.
            if (ms <= SGKaraokeSungEnd(line) + 4000) text = SGKaraokeLineText(line);
        }
    }
    if (![self.text isEqualToString:text]) self.text = text;
    for (UIView *child in host.subviews) {
        if (child == self) continue;
        if (available) {
            if (![self.savedAlpha objectForKey:child]) [self.savedAlpha setObject:@(child.alpha) forKey:child];
            child.alpha = 0;
        } else {
            NSNumber *alpha = [self.savedAlpha objectForKey:child];
            if (alpha) child.alpha = alpha.doubleValue;
        }
    }
    if (!available) [self.savedAlpha removeAllObjects];
    self.alpha = available ? 1 : 0;
    if (available && host.hidden) host.hidden = NO;
}
- (void)dealloc { [_timer invalidate]; }
@end

static char kPreviewKey;
%hook _TtC22Lyrics_NPVContainerKit19LyricsContainerView
- (void)layoutSubviews {
    %orig;
    UIView *host = (UIView *)self;
    SGNativeLyricsPreview *preview = objc_getAssociatedObject(host, &kPreviewKey);
    if (!preview && SGLyricsEnabled()) {
        preview = [[SGNativeLyricsPreview alloc] initWithFrame:host.bounds];
        objc_setAssociatedObject(host, &kPreviewKey, preview, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:preview];
    }
    if (!preview) return;
    preview.frame = CGRectInset(host.bounds, 8, 0);
    [host bringSubviewToFront:preview];
    [preview refresh];
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC22Lyrics_NPVContainerKit19LyricsContainerView"]);
}
