"""Exercise the production request coalescer with a deterministic transport on macOS."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
text = (root / 'tweak/Sources/Shared/LyricsSources/LyricsSources.m').read_text(encoding='utf-8')
coalescer = 'static void send(' + text.split('static void send(', 1)[1].split('static id jsonIn(', 1)[0]
source = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
static NSMutableArray *replies;
static NSUInteger requests;
static void sendUncached(NSURLRequest *request, void (^done)(NSData *body)) {
    requests++;
    [replies addObject:[done copy]];
}
static void check(BOOL ok, NSString *name) { if (!ok) { NSLog(@"FAIL: %@", name); exit(1); } }
static void answer(NSUInteger index, NSString *body) {
    void (^reply)(NSData *) = replies[index];
    reply([body dataUsingEncoding:NSUTF8StringEncoding]);
}
''' + coalescer + r'''
int main(void) { @autoreleasepool {
    replies = [NSMutableArray array];
    NSMutableURLRequest *a = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://catalogue.invalid/search?q=Animals"]];
    __block NSUInteger called = 0;
    for (NSUInteger i=0; i<10; i++) send(a, ^(NSData *body) { called++; });
    check(requests == 1, @"concurrent preview/lyrics/translation share one request");
    answer(0, @"{\"code\":200}");
    check(called == 10, @"all waiting consumers receive one response");
    dispatch_semaphore_t cached = dispatch_semaphore_create(0);
    send(a, ^(NSData *body) { dispatch_semaphore_signal(cached); });
    check(dispatch_semaphore_wait(cached, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0 && requests == 1, @"successful response reused");
    [a setValue:@"zh" forHTTPHeaderField:@"Accept-Language"];
    send(a, ^(NSData *body) {});
    check(requests == 2, @"different language headers do not alias");
    answer(1, nil);
    send(a, ^(NSData *body) {});
    check(requests == 3, @"transport failure remains retryable");
    answer(2, @"{\"code\":0,\"req\":{\"code\":2001}}");
    send(a, ^(NSData *body) {});
    check(requests == 4, @"QQ application error is not retained as a successful response");
    answer(3, @"{\"code\":200}");
    a.HTTPMethod = @"POST"; a.HTTPBody = [@"first" dataUsingEncoding:NSUTF8StringEncoding];
    send(a, ^(NSData *body) {});
    a.HTTPBody = [@"second" dataUsingEncoding:NSUTF8StringEncoding];
    send(a, ^(NSData *body) {});
    check(requests == 6, @"distinct POST searches never share a response");
    puts("Lyrics request regression checks passed");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='lyrics-requests-') as directory:
    path = Path(directory)
    (path / 'requests.m').write_text(source, encoding='utf-8')
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                    str(path / 'requests.m'), '-o', str(path / 'requests')], check=True)
    subprocess.run([str(path / 'requests')], check=True)
