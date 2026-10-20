// Native Spotify availability is distinct from the selected provider's result.
// Network/auth/rate-limit failures are unknown, never catalogue misses.
#import <Foundation/Foundation.h>
static inline NSInteger SGNativeLyricsVerdict(NSInteger status, BOOL failed, BOOL validBody, BOOL hasLines) {
    if (failed) return -1;
    if (status == 404 || status == 204) return 0;
    if (status == 200 && validBody) return hasLines ? 1 : 0;
    return -1;
}
