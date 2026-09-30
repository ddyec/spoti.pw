#!/usr/bin/env python3
"""Run production identity, translation grouping and QRC parsing on macOS.
Extract Foundation-only code, avoiding UIKit and duplicating no matching logic.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
base = root / "tweak/Sources/Shared"
def section(path, begin, end):
    text = path.read_text(encoding="utf-8")
    assert text.count(begin) == 1 and text.count(end) == 1, f"Extraction boundary changed: {path}"
    return begin + text.split(begin)[1].split(end)[0]

model = section(base / "Lyrics/Lyrics.h", "typedef NS_ENUM(NSUInteger, SGKaraokeTiming)", "// The line as one string")
query = section(base / "LyricsSources/LyricsSources.h", "@interface SGLyricsQuery : NSObject", "typedef void (^SGLyricsAsk)")
query = query.split("@end")[0] + "@end\n@implementation SGLyricsQuery\n@end\n"
timing = section(base / "Lyrics/KaraokeTiming.m", "@implementation SGKaraokeWord", "NSArray<SGKaraokeLine *> *SGKaraokeStaticLines(")
lrc = section(base / "LyricsSources/LrcLib.m", "NSArray<SGKaraokeLine *> *SGLyricsLinesFromLRC(", "static SGLyricsResult *resultFrom(")
qrc = section(base / "LyricsSources/QQMusic.m", "static NSString *qrcBody(", "static SGLyricsResult *resultForLines(")
aliases = section(base / "LyricsSources/NetEase.m", "static BOOL titleMatches(", "static void get(")
matching = (base / "LyricsSources/LyricsMatching.m").read_text(encoding="utf-8").replace('#import "LyricsSources.h"', "")
source = ("#import <Foundation/Foundation.h>\n#import <dispatch/dispatch.h>\n#include <stdio.h>\n#include <stdlib.h>\n"
          + model + query + "BOOL SGLyricsTimedCredit(NSString *);\n"
          + "BOOL SGLyricsDiagnosticsEnabled(void) { return NO; }\nvoid SGLyricsLog(NSString *format, ...) {}\n"
          + timing + lrc + matching + aliases + qrc)
tests = r'''
static void check(BOOL ok, NSString *label) {
    if (!ok) { NSLog(@"FAIL: %@", label); exit(1); }
}
int main(void) {
    @autoreleasepool {
        NSString *longTitle = @"Moon Halo - Honkai Impact 3Rd \"Everlasting Flames\" Animated Short Theme";
        for (NSString *title in @[
            longTitle,
            @"Moon Halo [Honkai Impact 3Rd Everlasting Flames Animated Short Theme]",
            @"Moon Halo（崩坏3《薪炎明燃》印象曲）",
            @"Moon Halo — Honkai Impact 3Rd OST"]) {
            check([SGLyricsSearchTitle(title) isEqualToString:@"Moon Halo"], title);
            check(SGLyricsTitleMatches(@"Moon Halo", title), title);
            check(SGLyricsTitleMatches(title, @"Moon Halo"), title);
        }
        for (NSString *title in @[
            @"Moon Halo (伴奏)", @"Moon Halo (片段版)", @"Moon Halo - Instrumental",
            @"Moon Halo (UK hardcore bootleg)", @"Moon Halo (Live)",
            @"Moon Halo (Piano Version)", @"Moon Halo - Soundtrack Theme (Instrumental)",
            @"Moon Halo（崩坏3主题曲伴奏）"]) {
            check(!SGLyricsTitleMatches(title, longTitle), title);
            check([SGLyricsSearchTitle(title) isEqualToString:title], title);
        }
        check(!SGLyricsTitleMatches(@"Love", @"Love Story"), @"unrelated title");
        check(!SGLyricsTitleMatches(@"Song", @"Song - Part II"), @"meaningful subtitle");
        check(SGLyricsTitleMatches(@"轻涟 La vaguelette", @"La vaguelette"), @"bilingual title");
        check(!SGLyricsTitleMatches(@"轻涟", @"涟"), @"Chinese substring");
        check(!SGLyricsTitleMatches(nil, longTitle), @"missing title");
        NSString *artists = @"HOYO-MiX, 茶理理, TetraCalyx, Hanser";
        check(SGLyricsArtistMatchCount(@"茶理理, TetraCalyx, Hanser, HOYO-MiX", artists) >= 3,
              @"official multi-artist recording");
        check(SGLyricsArtistMatchCount(@"Hard carry", artists) == 0, @"bootleg artist");
        check(SGLyricsArtistMatchCount(@"HOYO-MiX", artists) == 1, @"label-only local release");
        check(SGLyricsArtistMatchCount(@"茶理理", artists) == 1, @"short Chinese artist");
        NSArray *split = SGLyricsLinesFromLRC(@"[00:08]The paper birds are flying\n[00:11]over a quiet morning harbor\n[00:16]We watch the distant lights return");
        NSString *joined = @"[00:08]The paper birds are flying over a quiet morning harbor\n[00:16]We watch the distant lights return";
        NSString *translation = @"[00:08]纸鸟飞过安静的晨港\n[00:16]我们看远方灯火归来";
        check(SGLyricsRecordingMatches(split, SGLyricsLinesFromLRC(joined)), @"split/merged original evidence");
        NSDictionary *map = SGLyricsChineseTranslationMap(split, joined, translation);
        check([map[@0] isEqualToString:@"纸鸟飞过安静的晨港"] && !map[@1], @"whole translation belongs to start of split sentence");
        check([map[@2] isEqualToString:@"我们看远方灯火归来"], @"next sentence unaffected");
        NSArray *merged = SGLyricsLinesFromLRC(joined);
        NSString *splitLRC = @"[00:08]The paper birds are flying\n[00:11]over a quiet morning harbor\n[00:16]We watch the distant lights return";
        NSString *splitTranslation = @"[00:08]纸鸟正在飞翔\n[00:11]飞过安静的晨港\n[00:16]我们看远方灯火归来";
        map = SGLyricsChineseTranslationMap(merged, splitLRC, splitTranslation);
        check([map[@0] isEqualToString:@"纸鸟正在飞翔\n飞过安静的晨港"], @"combine translations in source order");
        map = SGLyricsChineseTranslationMap(split, splitLRC, @"[00:08]纸鸟正在飞翔\n[00:16]我们看远方灯火归来");
        check(!map[@1], @"missing translation must not borrow from neighbor");
        SGLyricsQuery *query = [SGLyricsQuery new];
        query.title = @"Hope Is the Thing With Feathers";
        query.referenceLines = split;
        check(SGLyricsTranslatedTitleCandidate(@"希望有羽毛和翅膀", query), @"Chinese title enters evidence stage");
        check(!SGLyricsTranslatedTitleCandidate(@"希望有羽毛和翅膀（伴奏）", query), @"alias does not erase version");
        check(!SGLyricsRecordingMatches(split, SGLyricsLinesFromLRC(@"[00:08]Other words from a different song\n[00:16]These lights have never returned")), @"unrelated lyrics rejected");
        query.referenceLines = nil;
        check(!SGLyricsTranslatedTitleCandidate(@"希望有羽毛和翅膀", query), @"no original evidence, no guessed alias");
        check(titleMatches(@{@"name": @"希望有羽毛和翅膀", @"alias": @[@"Hope Is the Thing With Feathers"]}, query), @"explicit catalogue alias without original lyrics");
        check(SGLyricsArtistMatchCount(@"HOYO-MiX", @"Chevy, Robin, HOYO-MiX") == 1, @"label retained while singers differ");
        check(SGLyricsArtistMatchCount(@"あたらよ", @"Atarayo") == 1, @"kana artist romanisation");
        check(SGLyricsArtistMatchCount(@"Atarayo", @"あたらよ") == 1, @"romanisation in either direction");
        check(SGLyricsTitleMatches(@"Polumnia Omnia 三千娑世御咏歌", @"Polumnia Omnia"), @"Polumnia bilingual title");
        check(!SGLyricsTitleMatches(@"Polumnia Omnia 三千娑世御咏歌 (演绎版)", @"Polumnia Omnia"), @"Polumnia performance version rejected");
        check(SGLyricsTitleMatches(@"夏霞", @"夏霞"), @"Natsugasumi exact title");
        check(!SGLyricsTitleMatches(@"夏霞 (Acoustic ver.)", @"夏霞"), @"Natsugasumi acoustic version rejected");
        NSArray *shortLines = SGLyricsLinesFromLRC(@"[00:01]Come back\n[00:05]Stay here");
        map = SGLyricsChineseTranslationMap(shortLines, @"[00:01]Come back\n[00:05]Stay here", @"[00:01]回来\n[00:05]留下");
        check(map.count == 2, @"short translations do not require alias-level evidence");
        check(SGLyricsTimedCredit(@"\u200B作词/作曲：某某"), @"combined role and invisible prefix");
        check(SGLyricsTimedCredit(@"演唱（Vocal）：某某"), @"parenthesized role");
        NSArray *qrc = linesFromQRC(@"[0,1000]歌手：(0,100)某某(100,100)\n[1000,1000]作词/作曲：(1000,100)某某(1100,100)\n[2000,9000]The (8000,100)paper (8100,100)birds (8200,100)fly(8300,100)");
        check(qrc.count == 1 && ((SGKaraokeLine *)qrc[0]).start == 8000 && ((SGKaraokeLine *)qrc[0]).end == 8400,
              @"credits removed and real word clock controls start/end");
        puts("Lyrics identity regression checks passed");
    }
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix="lyrics-identity-") as directory:
    path = Path(directory)
    (path / "identity.m").write_text(source + tests)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                    str(path / "identity.m"), "-o", str(path / "identity")], check=True)
    subprocess.run([str(path / "identity")], check=True)
