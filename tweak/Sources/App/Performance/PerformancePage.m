#import "PerformancePage.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Diagnostics/SGPerformance.h"

static void message(NSString *title, NSString *text) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}
static SGModRow *metric(NSString *title, NSString *key, NSString *unit) {
    return SGStatRow(title, ^NSString *{
        NSDictionary *window = SGPerformanceSnapshot()[@"window"];
        return [window[@"count"] unsignedIntegerValue] ? [NSString stringWithFormat:@"%.1f %@", [window[key] doubleValue], unit] : @"Waiting for samples";
    });
}
UIViewController *SGPerformancePage(void) {
    SGModRow *enabled = SGOptionRow(@"Record performance", @"Applies now. Samples every 2 seconds while Spotify is active.", SGKeyPerformance);
    enabled.changed = ^(BOOL on) { SGPerformanceRefresh(); };
    SGModRow *scenario = SGChoiceRow(@"Test scenario", @"Use the same activity when comparing builds.", SGKeyPerformanceScenario,
        @[@"General use", @"Home scrolling", @"Player", @"Lyrics", @"Idle playback"], 0);
    scenario.chosen = ^(NSInteger choice) { SGPerformanceRefresh(); };
    SGModRow *baseline = SGActionRow(@"Save current baseline", @"After a minute of representative use, save the current window.", ^{
        BOOL saved = SGPerformanceSaveBaseline();
        message(saved ? @"Baseline saved" : @"More samples needed", saved ? @"Compare the same scenario and device conditions after your next change." : @"Enable recording and keep Spotify active in one scenario for at least 62 seconds.");
    });
    SGModRow *export = SGActionRow(@"Export performance history", @"JSON with build, device conditions, samples and baseline.", ^{
        SGPerformanceExport(^(NSURL *file) {
            if (!file) { message(@"Export failed", @"Could not write the performance report. Try again."); return; }
            UIViewController *top = SGTopController();
            UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
            sheet.popoverPresentationController.sourceView = top.view;
            sheet.popoverPresentationController.sourceRect = top.view.bounds;
            [top presentViewController:sheet animated:YES completion:nil];
        });
    });
    return [[SGModPage alloc] initWithTitle:@"Performance diagnostics" intro:nil sections:@[
        SGSection(nil, @[enabled, scenario]),
        SGNotedSection(@"Current one-minute window", @[
            SGStatRow(@"Status", ^NSString *{ return SGPerformanceSnapshot()[@"status"]; }),
            metric(@"Process CPU", @"cpu", @"% of one core"),
            metric(@"Memory footprint", @"memory", @"MiB"),
            metric(@"Main queue delay p95", @"p95", @"ms"),
            SGStatRow(@"Retained samples", ^NSString *{ return [SGPerformanceSnapshot()[@"retained"] stringValue]; }),
        ], @"CPU includes Spotify and all injected modules and can exceed 100%. Heartbeats sample responsiveness, not FPS or every short stall. Thermal state and Low Power Mode are recorded; a change starts a fresh window."),
        SGNotedSection(@"Repeated operations", @[
            SGStatRow(@"Bar passes / requests", ^NSString *{
                NSDictionary *counts = SGPerformanceSnapshot()[@"operations"];
                return [NSString stringWithFormat:@"%@ / %@", counts[@"bar_applied"], counts[@"bar_requests"]];
            }),
            SGStatRow(@"Lyrics passes / requests", ^NSString *{
                NSDictionary *counts = SGPerformanceSnapshot()[@"operations"];
                return [NSString stringWithFormat:@"%@ / %@", counts[@"lyrics_applied"], counts[@"lyrics_requests"]];
            }),
            SGStatRow(@"Stale lyric checks skipped", ^NSString *{ return [SGPerformanceSnapshot()[@"operations"][@"stale_lyrics_waits_skipped"] stringValue]; }),
        ], @"Counts for this process while recording is active. Multiple layout requests in one pass share one application. Counts reset when history is cleared."),
        SGSection(nil, @[
            baseline,
            SGStatRow(@"Baseline build", ^NSString *{ return SGPerformanceSnapshot()[@"baseline"][@"build"] ?: @"None"; }),
            export,
            SGActionRow(@"Clear history and baseline", @"Remove local measurements and start a fresh window.", ^{ SGPerformanceClear(); }),
        ]),
    ] footer:@"Stored locally; no automatic uploads. Keeps the most recent 600 samples across launches. A warning needs three consecutive one-minute windows above the baseline limits. Match scenario, iOS, Spotify, UI, device, power, thermal state and EEVEE profile. Other settings must be matched manually. Export before and after a change to investigate regressions."];
}
