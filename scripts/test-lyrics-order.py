"""Compile the real source walk/cache against deterministic providers on macOS."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
header = (root/'tweak/Sources/Shared/LyricsSources/LyricsSources.h').read_text(encoding='utf-8')
production = (root/'tweak/Sources/Shared/LyricsSources/LyricsSources.m').read_text(encoding='utf-8')
def cut(text, begin, end):
    assert text.count(begin)==1 and text.count(end)==1, begin
    return begin+text.split(begin)[1].split(end)[0]

models = cut(header, '@interface SGLyricsCredit : NSObject', '// The lines as Spotify')
provider = cut(header, '@interface SGLyricsProvider : NSObject', '// All sources,') if '// All sources,' in header else '@interface SGLyricsProvider : NSObject'+header.split('@interface SGLyricsProvider : NSObject')[1].split('@end')[0]+'@end\n'
cache = cut(production, '// Main queue only, except sg_missing and the credits.', 'static void sourceOrderChanged(void) {')
walk = cut(production, '// Whether the source\'s lines are better', 'static BOOL shouldPublishPrefetchedLines(')
learn = cut(production, 'static void learnFrom(', '#pragma mark - the walk')
translations = cut(production, 'static NSArray<NSString *> *translationOrder(', 'static void translateAt(')
source = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <stdatomic.h>
#include <stdio.h>
typedef NS_ENUM(NSUInteger, SGKaraokeTiming) { SGKaraokeTimingWords=0, SGKaraokeTimingLine, SGKaraokeTimingNone };
@interface SGKaraokeLine : NSObject
@property(nonatomic) SGKaraokeTiming timing;
@end
@implementation SGKaraokeLine
@end
''' + models + r'''
typedef void (^SGLyricsAsk)(SGLyricsQuery *, void (^)(SGLyricsResult *));
''' + provider + r'''
@implementation SGLyricsCredit
@end
@implementation SGLyricsResult
@end
@implementation SGLyricsQuery
@end
@implementation SGLyricsProvider
@end
static NSArray *testOrder;
static NSMutableDictionary *providers, *references;
static NSMutableArray *asked;
static _Atomic NSUInteger sg_failures;
static const NSUInteger kKeptTracks=40;
static NSArray *SGLyricsOrder(void) { return testOrder; }
static SGLyricsProvider *SGLyricsProviderFor(NSString *key) { return providers[key]; }
static NSArray *referenceFor(NSString *key) { return references[key]; }
static SGLyricsQuery *queryFor(NSString *track) {
    SGLyricsQuery *q=[SGLyricsQuery new]; q.trackID=track; q.title=@"Song"; q.artist=@"Artist"; q.seconds=200;
    q.referenceLines=referenceFor(track); return q;
}
static void SGLyricsLog(NSString *format, ...) {}
static SGKaraokeTiming SGKaraokeLinesTiming(NSArray *lines) { return lines.count ? ((SGKaraokeLine *)lines[0]).timing : SGKaraokeTimingNone; }
static BOOL SGLyricsSourcesAgree(NSArray *a, NSArray *b) { return a.count && [a isEqual:b]; }
SGLyricsCredit *SGLyricsCreditNamed(NSString *name) { SGLyricsCredit *c=[SGLyricsCredit new];c.text=name;return c; }
''' + cache + learn + translations + walk + r'''
static void check(BOOL ok, NSString *name) { if(!ok) { NSLog(@"FAIL: %@", name); exit(1); } }
static void spin(BOOL (^ready)(void)) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:2];
    while(!ready() && until.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    check(ready(), @"async walk completed");
}
static SGLyricsResult *result(SGKaraokeTiming timing) {
    SGLyricsResult *r=[SGLyricsResult new];SGKaraokeLine *l=[SGKaraokeLine new];l.timing=timing;
    r.karaokeLines=@[l];r.texts=@[@"Original lyric"];r.starts=@[@0];r.synced=YES;r.metadataVerified=YES;return r;
}
static void install(NSString *key, SGLyricsResult *reply) {
    SGLyricsProvider *p=[SGLyricsProvider new];p.key=key;p.name=key;p.needsName=YES;
    p.ask=^(SGLyricsQuery *q, void(^done)(SGLyricsResult *)) { [asked addObject:key];done(reply); };
    providers[key]=p;
}
static SGLyricsResult *fetch(NSString *track) {
    __block BOOL done=NO;__block SGLyricsResult *got=nil;
    SGLyricsFetch(track,^(SGLyricsResult *r){got=r;done=YES;});spin(^BOOL{return done;});return got;
}
int main(void) { @autoreleasepool {
    providers=[NSMutableDictionary dictionary]; references=[NSMutableDictionary dictionary];asked=[NSMutableArray array];
    testOrder=@[@"qqmusic",@"netease"];
    install(@"qqmusic",result(SGKaraokeTimingLine));install(@"netease",result(SGKaraokeTimingWords));
    check([fetch(@"priority").provider isEqual:@"qqmusic"] && [asked isEqual:@[@"qqmusic"]], @"first synced source wins without requesting finer second source");
    [asked removeAllObjects];testOrder=@[@"netease",@"qqmusic"];
    check([fetch(@"priority").provider isEqual:@"netease"] && [asked isEqual:@[@"netease"]], @"changing order cannot reuse old provider cache");
    check([SGLyricsCachedResult(@"priority").provider isEqual:@"netease"], @"cache read uses current source order");
    testOrder=@[@"qqmusic"];[asked removeAllObjects];
    SGLyricsResult *single=result(SGKaraokeTimingLine);single.metadataVerified=NO;install(@"qqmusic",single);
    check([fetch(@"single").provider isEqual:@"qqmusic"] && asked.count==1,@"one verified provider does not require an enabled verifier");
    SGLyricsResult *failure=[SGLyricsResult new];failure.unavailable=YES;failure.retryAfter=NSDate.timeIntervalSinceReferenceDate+15;
    install(@"qqmusic",failure);[asked removeAllObjects];
    check(!fetch(@"failed") && SGLyricsMayHave(@"failed"),@"provider error is not cached as no lyrics");
    NSString *failedKey=sourceCacheKey(@"failed",testOrder);
    check(sg_kept[failedKey]!=NSNull.null,@"cooldown cannot poison catalogue cache");
    check(!fetch(@"failed") && asked.count==1,@"cooldown prevents repeated requests");
    sg_retryAfter[failedKey]=@(NSDate.timeIntervalSinceReferenceDate-1);install(@"qqmusic",result(SGKaraokeTimingLine));
    check([fetch(@"failed").provider isEqual:@"qqmusic"] && asked.count==2,@"same track retries without restarting app");
    testOrder=@[@"qqmusic",@"netease"];install(@"qqmusic",failure);[asked removeAllObjects];
    check([fetch(@"promote").provider isEqual:@"netease"],@"next source answers when first unavailable");
    sg_retryAfter[sourceCacheKey(@"promote",testOrder)]=@(NSDate.timeIntervalSinceReferenceDate-1);
    install(@"qqmusic",result(SGKaraokeTimingLine));
    check([fetch(@"promote").provider isEqual:@"qqmusic"] && asked.count==3,@"recovered first provider regains priority");
    __block void(^late)(SGLyricsResult *);
    SGLyricsProvider *p=providers[@"qqmusic"];p.ask=^(SGLyricsQuery *q,void(^done)(SGLyricsResult *)){late=[done copy];};
    __block BOOL oldDone=NO;__block SGLyricsResult *oldResult;
    SGLyricsFetch(@"race",^(SGLyricsResult *r){oldResult=r;oldDone=YES;});spin(^BOOL{return late!=nil;});
    testOrder=@[@"netease",@"qqmusic"];check([fetch(@"race").provider isEqual:@"netease"],@"new configuration can fetch during old in-flight request");
    late(result(SGKaraokeTimingWords));spin(^BOOL{return oldDone;});
    check(!oldResult && [SGLyricsCachedResult(@"race").provider isEqual:@"netease"],@"late old-order callback cannot publish stale provider");
    check([translationOrder(@[@"qqmusic"]) isEqual:@[@"qqmusic"]],@"QQ-only never asks NetEase for translation");
    check([translationOrder(@[@"netease",@"kugou",@"qqmusic"]) isEqual:@[@"netease",@"qqmusic"]],@"translation preserves enabled source priority");
    puts("Lyrics source-order and retry regression checks passed");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='lyrics-order-') as directory:
    path=Path(directory)
    (path/'order.m').write_text(source,encoding='utf-8')
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-framework','Foundation',str(path/'order.m'),'-o',str(path/'order')],check=True)
    subprocess.run([str(path/'order')],check=True)
