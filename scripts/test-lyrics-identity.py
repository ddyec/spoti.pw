#!/usr/bin/env python3
"""Run production identity, translation grouping and QRC parsing on macOS.
Extract Foundation-only code, avoiding UIKit and duplicating no matching logic.
"""
from pathlib import Path
import subprocess
import tempfile
import json
import sys

root = Path(__file__).resolve().parents[1]
audit = json.loads((root / 'docs/lyrics-live-audit-round2-2026-10-18.json').read_text(encoding='utf-8'))
assert audit['all_passed'] and audit['reused_results'] == 0, 'Fresh multilingual audit did not pass'
qq_audit = json.loads((root / 'docs/lyrics-qq-retry-2026-10-18.json').read_text(encoding='utf-8'))
assert qq_audit['all_passed'], 'QQ phone-log regression audit did not pass'
print('Fresh multilingual audit gate passed', flush=True)
base = root / "tweak/Sources/Shared"
def section(path, begin, end):
    text = path.read_text(encoding="utf-8")
    assert text.count(begin) == 1 and text.count(end) == 1, f"Extraction boundary changed: {path}"
    return begin + text.split(begin)[1].split(end)[0]

model = section(base / "Lyrics/Lyrics.h", "typedef NS_ENUM(NSUInteger, SGKaraokeTiming)", "// The line as one string")
query = section(base / "LyricsSources/LyricsSources.h", "@interface SGLyricsQuery : NSObject", "typedef void (^SGLyricsAsk)")
query = query.split("@end")[0] + "@end\n@implementation SGLyricsQuery\n@end\n"
timing = section(base / "Lyrics/KaraokeTiming.m", "@implementation SGKaraokeWord", "NSArray<SGKaraokeLine *> *SGKaraokeStaticLines(")
timing += section(base / "Lyrics/KaraokeTiming.m", "SGKaraokeTiming SGKaraokeLinesTiming(", "#pragma mark - Spotify's own bodies")
lrc = section(base / "LyricsSources/LrcLib.m", "NSArray<SGKaraokeLine *> *SGLyricsLinesFromLRC(", "static SGLyricsResult *resultFrom(")
qrc = section(base / "LyricsSources/QQMusic.m", "static NSString *qrcBody(", "static SGLyricsResult *resultForLines(")
aliases = section(base / "LyricsSources/NetEase.m", "static BOOL titleMatches(", "static void get(")
matching = (base / "LyricsSources/LyricsMatching.m").read_text(encoding="utf-8").replace('#import "LyricsSources.h"', "")
krc = section(base / "LyricsSources/KuGou.m", "static NSArray *krcPronunciationRows(", "static void deliverCandidate(")
qqMetadata = section(base / "LyricsSources/QQMusic.m", "static NSString *singers(", "static void lyricReply(")
qqEligibility = section(base / "LyricsSources/QQMusic.m", "static BOOL matches(", "static NSString *decoded(")
eligibility = section(base / "LyricsSources/LyricsSources.m", "static BOOL needsChineseTranslations(", "// Calculate off main;")
preview = section(root / "tweak/Sources/Native/Player/LyricsPreview.x", "static CGRect previewFrame(", "static BOOL showing(")
redesignPreview = section(root / "tweak/Sources/Redesigned/Player/PlayerPreview.x", "static CGRect sgrPreviewFrame(", "static BOOL sgrShowing(")
prefetchSelection = section(base / "LyricsSources/LyricsSources.m", "static BOOL shouldPublishPrefetchedLines(", "void SGLyricsPrefetch(")
nativeVerdict = (base / 'Lyrics/NativeLyricsStatus.h').read_text(encoding='utf-8')
source = ("#import <Foundation/Foundation.h>\n#import <CoreGraphics/CoreGraphics.h>\n#import <dispatch/dispatch.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <math.h>\n"
          + nativeVerdict
          + model + query + "BOOL SGLyricsTimedCredit(NSString *); BOOL SGLyricsContainsHan(NSString *);\n"
          + "BOOL SGLyricsDiagnosticsEnabled(void) { return NO; }\nvoid SGLyricsLog(NSString *format, ...) {}\n"
          + timing + lrc + matching + aliases + qrc + eligibility + qqMetadata + qqEligibility + krc + preview + redesignPreview + prefetchSelection)
tests = r'''
static void check(BOOL ok, NSString *label) {
    if (!ok) { NSLog(@"FAIL: %@", label); exit(1); }
}
int main(void) {
    @autoreleasepool {
        CGRect player = CGRectMake(0, 0, 402, 874);
        CGRect cover = CGRectMake(24, 118, 354, 354), info = CGRectMake(0, 576, 402, 64);
        CGRect previewRect = previewFrame(cover, info, player);
        check(!CGRectIsNull(previewRect) && CGRectGetMinY(previewRect) > CGRectGetMaxY(cover) &&
            CGRectGetMaxY(previewRect) < CGRectGetMinY(info), @"preview fits cover/title gap independently of native container");
        check(CGRectIsNull(previewFrame(cover, CGRectMake(0, 490, 402, 64), player)), @"preview never overlaps title in cramped layout");
        check(CGRectIsNull(previewFrame(CGRectZero, info, player)), @"missing cover cannot place preview over controls");
        CGRect bilingualRect = sgrPreviewFrame(cover, info, player);
        check(CGRectContainsRect(bilingualRect, previewRect) && CGRectGetMinY(bilingualRect) > CGRectGetMaxY(cover) &&
            CGRectGetMaxY(bilingualRect) < CGRectGetMinY(info), @"bilingual preview uses available gap without moving artwork or overlapping title");
        check(CGRectIsNull(sgrPreviewFrame(cover, CGRectMake(0, 490, 402, 64), player)), @"redesigned preview cannot overlap controls");
        CGRect lowCover = CGRectMake(24, 162, 354, 354), area = CGRectMake(0, 110, 402, 466);
        CGFloat lift = sgrPreviewNeededLift(lowCover, info, player, area, 88, 0, YES);
        check(lift == 44, @"native missing + bilingual preview reserves only bounded header-safe space");
        check(sgrPreviewNeededLift(lowCover, info, player, area, 88, 1, YES) == 0, @"native present never gets a second lift");
        check(sgrPreviewNeededLift(lowCover, info, player, area, 88, -1, YES) == 0, @"unknown or failed probe never shifts artwork");
        check(sgrPreviewNeededLift(lowCover, info, player, area, 88, 0, NO) == 0, @"no custom preview/full lyrics/transition restores artwork");
        check(sgrPreviewNeededLift(cover, info, player, area, 88, 0, YES) == 0, @"existing native spacing is not pushed twice");
        for (int i = 0; i < 50; i++) check(sgrPreviewNeededLift(lowCover, info, player, area, 88, 0, YES) == lift,
            @"layout refresh computes an absolute offset, not cumulative movement");
        check(SGNativeLyricsVerdict(404, NO, NO, NO) == 0, @"native 404 is absent");
        check(SGNativeLyricsVerdict(200, NO, YES, YES) == 1, @"valid native lyrics are present");
        check(SGNativeLyricsVerdict(200, NO, YES, NO) == 0, @"valid empty native lyrics are absent");
        for (NSNumber *status in @[@401, @403, @429, @500])
            check(SGNativeLyricsVerdict(status.integerValue, NO, YES, NO) == -1, @"auth/rate/server errors stay unknown");
        check(SGNativeLyricsVerdict(200, NO, NO, NO) == -1 && SGNativeLyricsVerdict(404, YES, NO, NO) == -1,
            @"malformed JSON and transport failure never mean no lyrics");
        for (CGFloat groupHeight = 24; groupHeight <= 160; groupHeight += 8) {
            CGRect viewport = sgrPreviewViewport(bilingualRect, groupHeight);
            check(CGRectContainsRect(bilingualRect, viewport), @"transition viewport never intersects artwork or controls");
            check(fabs(CGRectGetMidY(viewport) - CGRectGetMidY(bilingualRect)) < 0.001, @"short and bilingual lines keep the same anchor");
            check(viewport.size.height <= groupHeight, @"empty artwork gap cannot expose an extra lyric group");
        }
        check(sgrPreviewShouldRoll(YES, 2, 3, 250, NO), @"sequential lyric change rolls upward");
        check(!sgrPreviewShouldRoll(YES, 3, 2, 250, NO) && !sgrPreviewShouldRoll(YES, 2, 5, 250, NO), @"seeks do not replay intermediate lines");
        check(!sgrPreviewShouldRoll(NO, 2, 3, 250, NO) && !sgrPreviewShouldRoll(YES, 2, 3, 250, YES), @"track change and reduced motion do not animate");
        check(!sgrPreviewShouldRoll(YES, 2, 3, 5000, NO), @"return from background snaps to current line");
        check([SGLyricsSearchTitle(@"STAY (with Justin Bieber)") isEqualToString:@"STAY"], @"STAY collaborator display is not a different recording");
        check(SGLyricsTitleMatches(@"STAY", @"STAY (with Justin Bieber)"), @"domestic/international title credit equivalence");
        check(SGLyricsTitleMatches(@"STAY (Explicit)", @"STAY (with Justin Bieber)"), @"QQ explicit title label matches Spotify separate E badge");
        check(!SGLyricsTitleMatches(@"STAY (Explicit)", @"STAY (Clean)"), @"clean edition is not collapsed into explicit");
        check(!SGLyricsTitleMatches(@"STAY (Live) (Explicit)", @"STAY"), @"explicit cleanup retains live qualifier");
        for (NSString *bad in @[@"STAY (with Justin Bieber Live)", @"STAY (Live)", @"STAY (with Orchestra)",
              @"STAY (with Vocals)", @"STAY (Remix)", @"STAY (Acoustic Cover)", @"Stay - Justin Bieber&The Kid Laroi"])
            check(!SGLyricsTitleMatches(bad, @"STAY (with Justin Bieber)"), @"credit cleanup does not erase versions or uploader titles");
        SGLyricsQuery *stay = [SGLyricsQuery new]; stay.title = @"STAY (with Justin Bieber)";
        stay.artist = @"The Kid LAROI"; stay.seconds = 142;
        check(SGLyricsMetadataConfident(@"STAY", @"The Kid LAROI, Justin Bieber", 142, 6, stay), @"STAY still needs the real artist and recording duration");
        check(!SGLyricsMetadataConfident(@"STAY", @"恋雪海螺", 142, 6, stay), @"same length uploader is not the official recording");
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
        check(!SGLyricsTitleMatches(@"Animals (金坷垃)", @"Animals"), @"meme qualifier is not a Chinese translation");
        check(!SGLyricsTitleMatches(@"Animals（金坷垃）", @"Animals"), @"full-width qualifier rejected");
        check(SGLyricsTitleMatches(@"鴻門宴", @"鸿门宴"), @"traditional and simplified song title");
        check(SGLyricsArtistMatchCount(@"李荣浩", @"李榮浩") == 1, @"traditional and simplified artist");
        check(SGLyricsArtistMatchCount(@"あたらよ (Atarayo)", @"Atarayo") == 1, @"QQ catalogue includes Spotify artist alias");
        check([SGLyricsSearchText(@"郭頂 - 水星記") isEqualToString:@"郭顶 - 水星记"], @"domestic query uses simplified Chinese");
        check([SGLyricsSearchText(@"IU - Love poem") isEqualToString:@"IU - Love poem"], @"catalogue casing retained in search");
        check(SGLyricsDurationSeconds(@274, 274) == 274, @"KuGou seconds are not divided twice");
        check(SGLyricsDurationSeconds(@274000, 274) == 274, @"KuGou milliseconds normalized");
        check(SGLyricsDurationSeconds(@258264, 258) == 258, @"KuGou millisecond precision");
        check(SGLyricsDurationSeconds(@286, 274) == 286, @"alternate recording stays outside tolerance");
        check(!SGLyricsTitleMatches(@"寶貝 (In a Day)", @"寶貝 (In the Night)"), @"same lyrics cannot erase a recording version");
        check(labs(SGLyricsDurationSeconds(@145440, 161) - 161) > 8, @"day recording cannot pass night recording duration");
        SGLyricsQuery *animal = [SGLyricsQuery new];
        animal.title = @"Animals"; animal.artist = @"Maroon 5"; animal.seconds = 231;
        check(SGLyricsMetadataConfident(@"Animals", @"Maroon 5", 231, 6, animal), @"exact metadata allows direct use without extra fallback");
        check(!SGLyricsMetadataConfident(@"Animals (金坷垃)", @"Maroon 5", 231, 6, animal), @"correct artist and duration cannot validate meme");
        check(!SGLyricsMetadataConfident(@"Animals", @"Another Artist", 231, 6, animal), @"cover artist cannot validate recording");
        check(!SGLyricsMetadataConfident(@"Animals", @"Maroon 5", 0, 6, animal), @"missing length is not exact metadata");
        NSString *artists = @"HOYO-MiX, 茶理理, TetraCalyx, Hanser";
        check(SGLyricsArtistMatchCount(@"茶理理, TetraCalyx, Hanser, HOYO-MiX", artists) >= 3,
              @"official multi-artist recording");
        check(SGLyricsArtistMatchCount(@"Hard carry", artists) == 0, @"bootleg artist");
        check(SGLyricsArtistMatchCount(@"HOYO-MiX", artists) == 1, @"label-only local release");
        check(SGLyricsArtistMatchCount(@"茶理理", artists) == 1, @"short Chinese artist");
        NSArray *split = SGLyricsLinesFromLRC(@"[00:08]The paper birds are flying\n[00:11]over a quiet morning harbor\n[00:16]We watch the distant lights return");
        check(shouldPublishPrefetchedLines(nil, split), @"prefetch publishes when Spotify never requested lyrics");
        check(!shouldPublishPrefetchedLines(split, nil), @"missing result never removes existing display lyrics");
        SGKaraokeLine *fine = [SGKaraokeLine new]; fine.timing = SGKaraokeTimingWords;
        check(shouldPublishPrefetchedLines(@[fine], split), @"selected provider takes priority over finer Spotify timing");
        check(shouldPublishPrefetchedLines(split, @[fine]), @"word-timed provider upgrades display cache");
        NSString *joined = @"[00:08]The paper birds are flying over a quiet morning harbor\n[00:16]We watch the distant lights return";
        NSString *translation = @"[00:08]纸鸟飞过安静的晨港\n[00:16]我们看远方灯火归来";
        check(SGLyricsRecordingMatches(split, SGLyricsLinesFromLRC(joined)), @"split/merged original evidence");
        check(SGLyricsSourcesAgree(split, SGLyricsLinesFromLRC(joined)), @"independent sources agree despite split lines");
        check(!SGLyricsSourcesAgree(split, SGLyricsLinesFromLRC(@"[00:08]Completely unrelated lyrics appear in this song\n[00:16]A different recording cannot match")), @"unrelated body fails independent cross-check");
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
        check(SGLyricsTitleEvidenceCandidate(@"Hope Is the Thing With Feathers", query), @"same title can enter artist evidence stage");
        check(!SGLyricsTitleEvidenceCandidate(@"Hope Is the Thing With Feathers (Live)", query), @"artist evidence cannot erase live version");
        check(!SGLyricsTitleEvidenceCandidate(@"Another Song", query), @"artist evidence cannot admit unrelated title");
        NSDictionary *regional = @{@"title": @"Hope Is the Thing With Feathers", @"interval": @200,
                                     @"singer": @[@{@"name": @"地区发行方"}]};
        query.artist = @"International Label";
        query.seconds = 200;
        check(eligible(regional, query, YES), @"regional artist mismatch enters original evidence stage");
        check(!eligible(@{@"title": @"Hope Is the Thing With Feathers", @"interval": @240,
                          @"singer": @[@{@"name": @"地区发行方"}]}, query, YES), @"artist mismatch cannot bypass duration");
        query.referenceLines = nil;
        check(!eligible(regional, query, YES), @"regional artist mismatch needs original evidence");
        check(!SGLyricsTitleEvidenceCandidate(@"Hope Is the Thing With Feathers", query), @"artist mismatch cannot bypass missing original evidence");
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
        check(SGLyricsTimedCredit(@"词Lyricist：某某"), @"bilingual credit without whitespace");
        check(SGLyricsTimedCredit(@"母带后期处理工程师Mastering Engineer：某某"), @"mastering credit must not look like a lyric");
        check(SGLyricsTimedCredit(@"© 2020 Example Publishing"), @"copyright is not a lyric");
        check(SGLyricsTimedCredit(@"Produced by Example"), @"unpunctuated recording credit");
        check(SGLyricsTimedCredit(@"Drum Programming, Percussion, Piano, Bass, Electric Guitars,"), @"continued instrument credit");
        check(!SGLyricsTimedCredit(@"You wrote a song for me"), @"ordinary original line retained");
        NSArray *qrc = linesFromQRC(@"[0,1000]歌手：(0,100)某某(100,100)\n[1000,1000]作词/作曲：(1000,100)某某(1100,100)\n[2000,9000]The (8000,100)paper (8100,100)birds (8200,100)fly(8300,100)");
        check(qrc.count == 1 && ((SGKaraokeLine *)qrc[0]).start == 8000 && ((SGKaraokeLine *)qrc[0]).end == 8400,
              @"credits removed and real word clock controls start/end");
        NSArray *japanese = SGLyricsLinesFromLRC(@"[00:01]風が吹く\n[00:05]夏を待つ");
        check(needsChineseTranslations(japanese), @"Japanese with Han characters still needs translation");
        NSArray *kanjiOnly = SGLyricsLinesFromLRC(@"[00:01]夜空\n[00:05]希望");
        check(needsChineseTranslations(kanjiOnly), @"Han alone does not prove original language");
        map = SGLyricsChineseTranslationMap(japanese, @"[00:01]風が吹く\n[00:05]夏を待つ", @"[00:01]风吹过\n[00:05]等待夏天");
        check(map.count == 2, @"Japanese original aligns with Chinese translation");
        for (NSNumber *index in map) ((SGKaraokeLine *)japanese[index.unsignedIntegerValue]).translation = map[index];
        check(!needsChineseTranslations(japanese), @"attached Chinese translations avoid redundant lookup");
        check(!SGLyricsTitleMatches(@"Sung Birds 摇滚版", @"Sung Birds"), @"rock rendition is not a bilingual alias");
        check(SGLyricsTitleMatches(@"Sung Birds (feat. Guest)", @"Sung Birds"), @"feature credits omitted by domestic catalogue");
        check(!SGLyricsTitleMatches(@"Sung Birds (Live) (feat. Guest)", @"Sung Birds"), @"feature normalization retains recording variant");
        NSDictionary *spokenMap = SGLyricsPronunciationMap(japanese, japanese,
            SGLyricsLinesFromLRC(@"[00:01]kaze ga fuku\n[00:05]natsu wo matsu"));
        check(spokenMap.count == 2 && ((SGKaraokeLine *)spokenMap[@0]).timing == SGKaraokeTimingLine, @"LRC pronunciation has estimated timing");
        check(!SGLyricsPronunciationMap(split, split, split).count, @"English originals are not duplicated as pronunciation");
        spokenMap = SGLyricsPronunciationMap(japanese, japanese, SGLyricsLinesFromLRC(@"[00:05]natsu wo matsu"));
        check(!spokenMap[@0] && spokenMap[@1], @"missing pronunciation does not borrow neighbour");
        NSString *lang = @"{\"content\":[{\"type\":0,\"lyricContent\":[[\"ka\",\"ze\"]]}]}";
        NSString *tag = [[lang dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
        NSArray *krcLines = linesFromKRC([NSString stringWithFormat:@"[language:%@]\n[1000,1000]<0,400,0>か<400,600,0>ぜ", tag]);
        SGKaraokeLine *krcLine = krcLines.firstObject;
        check(krcLine.pronunciation.words.count == 2 && krcLine.pronunciation.words[1].start == 1400,
            @"KRC romanised syllables retain original clocks");
        krcLines = linesFromKRC([NSString stringWithFormat:@"[language:%@]\n[1000,1000]<0,1000,0>か", tag]);
        check(!((SGKaraokeLine *)krcLines.firstObject).pronunciation, @"KRC syllable count mismatch rejects pronunciation");
        krcLines = linesFromKRC(@"[language:bad]\n[1000,1000]<0,1000,0>か");
        check(krcLines.count == 1 && !((SGKaraokeLine *)krcLines.firstObject).pronunciation, @"malformed romanisation never removes original lyrics");
        puts("Lyrics identity regression checks passed");
    }
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix="lyrics-identity-") as directory:
    path = Path(directory)
    (path / "identity.m").write_text(source + tests, encoding="utf-8")
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation", "-framework", "CoreGraphics",
                    str(path / "identity.m"), "-o", str(path / "identity")], check=True)
    subprocess.run([str(path / "identity")], check=True)

subprocess.run([sys.executable, str(root / 'scripts/test-lyrics-requests.py')], check=True)
subprocess.run([sys.executable, str(root / 'scripts/test-lyrics-order.py')], check=True)
