#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "LyricsSources.h"
#import <stdio.h>
#import <stdarg.h>
#import <stdatomic.h>

// File operations are serial and off the UI thread. Keep at most two 512 KiB files.
static const NSUInteger kLogLimit = 512 * 1024;
static _Atomic NSUInteger pendingWrites;
static dispatch_queue_t logQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.lyricsDiagnostics", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSString *logPath(BOOL previous) {
    NSString *directory = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
                           stringByAppendingPathComponent:@"LyricsDiagnostics"];
    return [directory stringByAppendingPathComponent:previous ? @"previous.log" : @"current.log"];
}

BOOL SGLyricsDiagnosticsEnabled(void) { return SGFlag(SGKeyLyricsDiagnostics, NO); }

void SGLyricsLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    SGLog(@"%@", message);
    if (!SGLyricsDiagnosticsEnabled()) return;
    // Debugging rapid prefetch/scroll activity must not create an unbounded queue.
    if (atomic_fetch_add(&pendingWrites, 1) >= 64) {
        atomic_fetch_sub(&pendingWrites, 1);
        return;
    }
    NSDate *date = NSDate.date;
    // No lyric bodies, request headers, tokens, or full URLs enter this log.
    if (message.length > 4096) message = [message substringToIndex:4096];
    dispatch_async(logQueue(), ^{
      @try {
        static NSISO8601DateFormatter *clock;
        if (!clock) {
            clock = [NSISO8601DateFormatter new];
            clock.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"time": [clock stringFromDate:date], @"event": message}
                                                       options:0 error:nil];
        if (!json) return;
        NSMutableData *row = [json mutableCopy];
        [row appendBytes:"\n" length:1];
        NSString *path = logPath(NO);
        NSFileManager *files = NSFileManager.defaultManager;
        [files createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSUInteger size = [[files attributesOfItemAtPath:path error:nil][NSFileSize] unsignedIntegerValue];
        if (size + row.length > kLogLimit) {
            [files removeItemAtPath:logPath(YES) error:nil];
            [files moveItemAtPath:path toPath:logPath(YES) error:nil];
            // If rotation failed, truncate to keep the bound rather than grow forever.
            if ([files fileExistsAtPath:path]) [files removeItemAtPath:path error:nil];
        }
        FILE *file = fopen(path.fileSystemRepresentation, "ab");
        if (!file) return;
        fwrite(row.bytes, 1, row.length, file);
        fclose(file);
      } @finally {
        atomic_fetch_sub(&pendingWrites, 1);
      }
    });
}

void SGLyricsDiagnosticsClear(void) {
    dispatch_async(logQueue(), ^{
        [NSFileManager.defaultManager removeItemAtPath:logPath(NO) error:nil];
        [NSFileManager.defaultManager removeItemAtPath:logPath(YES) error:nil];
        [NSFileManager.defaultManager removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"spotifyglass-lyrics-debug.log"] error:nil];
    });
}

void SGLyricsDiagnosticsExport(void (^done)(NSURL *file)) {
    dispatch_async(logQueue(), ^{
        NSMutableData *data = [NSMutableData data];
        for (NSNumber *previous in @[@YES, @NO]) {
            NSData *part = [NSData dataWithContentsOfFile:logPath(previous.boolValue)];
            if (part.length) [data appendData:part];
        }
        NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"spotifyglass-lyrics-debug.log"]];
        BOOL written = data.length && [data writeToURL:file atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ done(written ? file : nil); });
    });
}

void SGLyricsDiagnosticCandidate(NSString *provider, SGLyricsQuery *query, NSString *title,
                                NSString *artists, NSInteger seconds, NSInteger slack, BOOL requireTitle) {
    if (!SGLyricsDiagnosticsEnabled()) return;
    BOOL titleOK = !requireTitle || SGLyricsTitleMatches(title, query.title);
    NSString *titleCheck = titleOK ? @"pass" : SGLyricsTranslatedTitleCandidate(title, query) ? @"requires original-text evidence" : @"reject";
    NSUInteger artistsOK = SGLyricsArtistMatchCount(artists, query.artist);
    NSInteger gap = labs(seconds - query.seconds);
    NSString *duration = seconds <= 0 || query.seconds <= 0 ? @"unknown" : gap <= slack ? @"pass" : @"reject";
    SGLyricsLog(@"candidate: track %@ source %@ title '%@' artists '%@' duration %lds; title %@, artist matches %lu, duration %@ (gap %lds, tolerance %lds)",
                query.trackID, provider, title, artists, (long)seconds, titleCheck,
                (unsigned long)artistsOK, duration, (long)gap, (long)slack);
}

UIViewController *SGLyricsDiagnosticsPage(void) {
    SGModRow *enabled = SGOptionRow(@"Collect lyrics debug logs", @"Applies immediately. Logs stay on this device.", SGKeyLyricsDiagnostics);
    enabled.changed = ^(BOOL on) {
        SGLyricsLog(@"diagnostics: %@; Spotify %@, iOS %@; sources %@; translation %@", on ? @"enabled" : @"disabled",
                    [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"], UIDevice.currentDevice.systemVersion,
                    [SGLyricsOrder() componentsJoinedByString:@", "], SGLyricsTranslationLanguage() ?: @"any");
    };
    SGModRow *export = SGActionRow(@"Export lyrics debug logs", @"Share the log after reproducing the problem.", ^{
        SGLyricsDiagnosticsExport(^(NSURL *file) {
            UIViewController *top = SGTopController();
            if (!file) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No lyrics debug logs"
                    message:@"Enable collection, play a different song and then return to the problem song."
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
                [top presentViewController:alert animated:YES completion:nil];
                return;
            }
            UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
            sheet.popoverPresentationController.sourceView = top.view;
            sheet.popoverPresentationController.sourceRect = top.view.bounds;
            [top presentViewController:sheet animated:YES completion:nil];
        });
    });
    SGModRow *clear = SGActionRow(@"Clear lyrics debug logs", @"Remove the collected logs from this device.", ^{
        SGLyricsDiagnosticsClear();
    });
    return [[SGModPage alloc] initWithTitle:@"Lyrics diagnostics" intro:nil
        sections:@[SGSection(nil, @[enabled, export, clear])]
        footer:@"Records song metadata, search candidates, timing checks, network status and the chosen source. Keeps up to 1 MiB. Contains no lyric text or account credentials. If a song was already cached, restart Spotify before reproducing it."];
}
