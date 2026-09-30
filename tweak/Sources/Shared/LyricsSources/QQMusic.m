// QQ Music's public musicu search and word-timed QRC, with LRC when QRC is unavailable.
#import "Core/SGCore.h"
#import "LyricsSources.h"
#import "QQMusicQRC.h"
#import <string.h>
#import <zlib.h>

static NSString *const kMusicu = @"https://u.y.qq.com/cgi-bin/musicu.fcg";

static NSDictionary<NSString *, NSString *> *headers(void) {
    return @{@"Referer": @"https://y.qq.com/", @"User-Agent": @"Mozilla/5.0", @"Accept": @"application/json"};
}

static NSString *singers(NSDictionary *song) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *singer in [song[@"singer"] isKindOfClass:NSArray.class] ? song[@"singer"] : @[]) {
        NSString *name = [singer isKindOfClass:NSDictionary.class] ? singer[@"name"] : nil;
        if ([name isKindOfClass:NSString.class] && name.length) [names addObject:name];
    }
    return [names componentsJoinedByString:@", "];
}

static BOOL matchesRecording(NSDictionary *song, SGLyricsQuery *query) {
    if (query.seconds > 0 && [song[@"interval"] respondsToSelector:@selector(integerValue)] &&
        labs([song[@"interval"] integerValue] - query.seconds) > 6) return NO;
    return SGLyricsArtistMatchCount(singers(song), query.artist) > 0 ||
        (query.seconds > 0 && [song[@"interval"] integerValue] > 0 &&
         SGLyricsTitleEvidenceCandidate(song[@"title"] ?: song[@"songname"], query));
}

static void lyricReply(NSNumber *songID, BOOL translation, BOOL qrc, void (^done)(NSDictionary *data)) {
    NSDictionary *request = @{@"music.musichallSong.PlayLyricInfo.GetPlayLyricInfo": @{
        @"method": @"GetPlayLyricInfo", @"module": @"music.musichallSong.PlayLyricInfo",
        @"param": @{@"crypt": @0, @"qrc": qrc ? @1 : @0, @"trans": translation ? @1 : @0, @"roma": @1, @"songID": songID}}};
    SGLyricsPostJSON([NSURL URLWithString:kMusicu], headers(), request, ^(id root) {
        id value = [root isKindOfClass:NSDictionary.class]
            ? root[@"music.musichallSong.PlayLyricInfo.GetPlayLyricInfo"] : nil;
        NSDictionary *reply = [value isKindOfClass:NSDictionary.class] ? value : nil;
        NSDictionary *data = [reply[@"data"] isKindOfClass:NSDictionary.class] ? reply[@"data"] : nil;
        done(data);
    });
}

static BOOL matches(NSDictionary *song, SGLyricsQuery *query) {
    NSString *title = [song[@"title"] isKindOfClass:NSString.class] ? song[@"title"] : song[@"songname"];
    return SGLyricsTitleMatches(title, query.title) && matchesRecording(song, query);
}

static BOOL eligible(NSDictionary *song, SGLyricsQuery *query, BOOL requireTitle) {
    if (!matchesRecording(song, query)) return NO;
    return !requireTitle || matches(song, query) || SGLyricsTranslatedTitleCandidate(song[@"title"] ?: song[@"songname"], query);
}

static NSString *decoded(NSDictionary *data, NSString *key) {
    NSString *encoded = [data[key] isKindOfClass:NSString.class] ? data[key] : nil;
    NSData *bytes = encoded.length ? [[NSData alloc] initWithBase64EncodedString:encoded options:0] : nil;
    return bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
}

static NSString *decodedQRCKey(NSDictionary *data, NSString *key) {
    NSString *hex = [data[key] isKindOfClass:NSString.class] ? data[key] : nil;
    if (!hex.length || hex.length > 2 * 1024 * 1024 || hex.length % 16) return nil;
    NSMutableData *encrypted = [NSMutableData dataWithLength:hex.length / 2];
    const char *source = hex.UTF8String;
    if (!source || strlen(source) != hex.length) return nil;
    uint8_t *bytes = encrypted.mutableBytes;
    for (NSUInteger i = 0; i < encrypted.length; i++) {
        int hi = source[2 * i], lo = source[2 * i + 1];
        hi = hi >= '0' && hi <= '9' ? hi - '0' : hi >= 'A' && hi <= 'F' ? hi - 'A' + 10 : hi >= 'a' && hi <= 'f' ? hi - 'a' + 10 : -1;
        lo = lo >= '0' && lo <= '9' ? lo - '0' : lo >= 'A' && lo <= 'F' ? lo - 'A' + 10 : lo >= 'a' && lo <= 'f' ? lo - 'a' + 10 : -1;
        if (hi < 0 || lo < 0) return nil;
        bytes[i] = (uint8_t)((hi << 4) | lo);
    }
    NSMutableData *plain = [NSMutableData dataWithLength:encrypted.length];
    SGQQQRCDecrypt(encrypted.bytes, encrypted.length, plain.mutableBytes);
    NSMutableData *inflated = [NSMutableData dataWithLength:1024 * 1024];
    uLongf length = (uLongf)inflated.length;
    if (uncompress(inflated.mutableBytes, &length, plain.bytes, (uLong)plain.length) != Z_OK) return nil;
    return [[NSString alloc] initWithBytes:inflated.bytes length:(NSUInteger)length encoding:NSUTF8StringEncoding];
}

static NSString *qrcBody(NSString *xml) {
    NSRange attr = [xml rangeOfString:@"LyricContent=\""];
    if (attr.location == NSNotFound) return [xml hasPrefix:@"["] ? xml : nil;
    NSUInteger start = NSMaxRange(attr);
    NSRange end = [xml rangeOfString:@"\"" options:0 range:NSMakeRange(start, xml.length - start)];
    if (end.location == NSNotFound) return nil;
    NSString *body = [xml substringWithRange:NSMakeRange(start, end.location - start)];
    for (NSArray<NSString *> *pair in @[@[@"&quot;", @"\""], @[@"&apos;", @"'"],
                                       @[@"&lt;", @"<"], @[@"&gt;", @">"],
                                       @[@"&#10;", @"\n"], @[@"&#xA;", @"\n"], @[@"&amp;", @"&"]]) {
        body = [body stringByReplacingOccurrencesOfString:pair[0] withString:pair[1]];
    }
    return body;
}

// QRC: [lineStart,lineLength]word (absoluteWordStart,wordLength)next (start,length).
// The space before a token belongs to the preceding word, unlike YRC's prefix tokens.
static NSArray<SGKaraokeLine *> *linesFromQRC(NSString *xml) {
    NSString *body = qrcBody(xml);
    if (!body.length) return nil;
    static NSRegularExpression *header, *part;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        header = [NSRegularExpression regularExpressionWithPattern:@"^\\[(\\d+),(\\d+)\\]" options:0 error:nil];
        part = [NSRegularExpression regularExpressionWithPattern:@"\\((\\d+),(\\d+)\\)" options:0 error:nil];
    });
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (NSString *rawRow in [body componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *row = [rawRow stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSTextCheckingResult *head = [header firstMatchInString:row options:0 range:NSMakeRange(0, row.length)];
        if (!head) continue;
        NSInteger lineStart = [row substringWithRange:[head rangeAtIndex:1]].integerValue;
        NSInteger lineLength = [row substringWithRange:[head rangeAtIndex:2]].integerValue;
        if (lineStart < 0 || lineStart > 36000000 || lineLength < 0 || lineLength > 600000) continue;
        NSArray<NSTextCheckingResult *> *parts = [part matchesInString:row options:0
            range:NSMakeRange(NSMaxRange(head.range), row.length - NSMaxRange(head.range))];
        NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
        SGKaraokeWord *open = nil;
        BOOL spaced = YES;
        NSUInteger from = NSMaxRange(head.range);
        for (NSTextCheckingResult *match in parts) {
            NSString *raw = [row substringWithRange:NSMakeRange(from, match.range.location - from)];
            NSString *text = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSInteger start = [row substringWithRange:[match rangeAtIndex:1]].integerValue;
            NSInteger length = [row substringWithRange:[match rangeAtIndex:2]].integerValue;
            from = NSMaxRange(match.range);
            if (start < 0 || start > 36000000 || length < 0 || length > 600000) continue;
            NSInteger end = start + MAX((NSInteger)1, length);
            BOOL unspaced = SGKaraokeUnspacedScript(text);
            if (text.length && open && !spaced && !unspaced) {
                open.text = [open.text stringByAppendingString:text];
                open.end = MAX(open.end, end);
            } else if (text.length) {
                SGKaraokeWord *word = [SGKaraokeWord new];
                word.text = text;
                word.start = start;
                word.end = end;
                word.joined = !spaced;
                [words addObject:word];
                open = unspaced ? nil : word;
            }
            spaced = raw.length > text.length || !text.length;
            if (spaced) open = nil;
        }
        if (!words.count) continue;
        SGKaraokeLine *line = [SGKaraokeLine new];
        line.words = words;
        // The word clock is the singing clock. A padded line header can begin in
        // the preceding credits or intro, so do not use it to drive scrolling.
        line.start = words.firstObject.start;
        line.end = words.lastObject.end;
        line.timing = SGKaraokeTimingWords;
        NSString *text = SGKaraokeLineText(line);
        if (SGLyricsTimedCredit(text)) {
            if (SGLyricsDiagnosticsEnabled()) SGLyricsLog(@"qqmusic: removed credit at %ldms", (long)line.start);
            continue;
        }
        [lines addObject:line];
    }
    return lines.count ? lines : nil;
}

static SGLyricsResult *resultForLines(NSArray<SGKaraokeLine *> *lines) {
    if (!lines.count) return nil;
    SGLyricsResult *result = [SGLyricsResult new];
    result.synced = YES;
    result.wordTimed = SGKaraokeLinesTiming(lines) == SGKaraokeTimingWords;
    result.karaokeLines = lines;
    NSArray<NSNumber *> *starts;
    NSArray<NSString *> *texts;
    SGLyricsPageLines(lines, &starts, &texts);
    result.starts = starts;
    result.texts = texts;
    return result;
}

static void lyricsForSong(NSNumber *songID, void (^done)(SGLyricsResult *)) {
    lyricReply(songID, YES, YES, ^(NSDictionary *data) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *xml = decodedQRCKey(data, @"lyric");
            NSArray<SGKaraokeLine *> *lines = xml ? linesFromQRC(xml) : nil;
            NSString *romaXML = decodedQRCKey(data, @"roma");
            NSString *romaText = romaXML ?: decoded(data, @"roma");
            NSArray *romanLines = linesFromQRC(romaText) ?: SGLyricsLinesFromLRC(romaText);
            NSDictionary<NSNumber *, SGKaraokeLine *> *spoken = SGLyricsPronunciationMap(lines, lines, romanLines);
            for (NSNumber *index in spoken) lines[index.unsignedIntegerValue].pronunciation = spoken[index];
            SGLyricsLog(@"qqmusic: song %@ attached %lu pronunciation lines from QRC", songID, (unsigned long)spoken.count);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (lines.count) {
                    SGLyricsLog(@"qqmusic: QRC %@ decoded %lu word timed lines", songID, (unsigned long)lines.count);
                    done(resultForLines(lines));
                    return;
                }
                SGLyricsLog(@"qqmusic: QRC %@ unavailable; trying LRC", songID);
                lyricReply(songID, YES, NO, ^(NSDictionary *lrcData) {
                    NSString *lrc = decoded(lrcData, @"lyric");
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        SGLyricsResult *result = resultForLines(lrc ? SGLyricsLinesFromLRC(lrc) : nil);
                        NSString *romaXML = decodedQRCKey(lrcData, @"roma");
                        NSString *romaText = romaXML ?: decoded(lrcData, @"roma");
                        NSArray *romanLines = linesFromQRC(romaText) ?: SGLyricsLinesFromLRC(romaText);
                        NSDictionary<NSNumber *, SGKaraokeLine *> *spoken = SGLyricsPronunciationMap(result.karaokeLines, result.karaokeLines, romanLines);
                        for (NSNumber *index in spoken) result.karaokeLines[index.unsignedIntegerValue].pronunciation = spoken[index];
                        SGLyricsLog(@"qqmusic: song %@ attached %lu pronunciation lines from LRC", songID, (unsigned long)spoken.count);
                        dispatch_async(dispatch_get_main_queue(), ^{ done(result); });
                    });
                });
            });
        });
    });
}

static void searchKeyword(NSString *keyword, void (^done)(NSArray<NSDictionary *> *list)) {
    NSDictionary *request = @{
        @"comm": @{@"ct": @"19", @"cv": @"1859", @"uin": @"0"},
        @"req": @{@"method": @"DoSearchForQQMusicDesktop", @"module": @"music.search.SearchCgiService",
                  @"param": @{@"grp": @1, @"num_per_page": @40, @"page_num": @1,
                               @"query": keyword, @"search_type": @0}}
    };
    SGLyricsPostJSON([NSURL URLWithString:kMusicu], headers(), request, ^(id root) {
        id value = [root isKindOfClass:NSDictionary.class] ? root[@"req"] : nil;
        NSDictionary *requestReply = [value isKindOfClass:NSDictionary.class] ? value : nil;
        NSDictionary *data = [requestReply[@"data"] isKindOfClass:NSDictionary.class] ? requestReply[@"data"] : nil;
        NSDictionary *body = [data[@"body"] isKindOfClass:NSDictionary.class] ? data[@"body"] : nil;
        NSDictionary *song = [body[@"song"] isKindOfClass:NSDictionary.class] ? body[@"song"] : nil;
        NSArray *list = [song[@"list"] isKindOfClass:NSArray.class] ? song[@"list"] : @[];
        SGLyricsLog(@"qqmusic: search '%@' status %@, %lu candidates", keyword, requestReply[@"code"], (unsigned long)list.count);
        done(list);
    });
}

static void searchArtists(SGLyricsQuery *query, BOOL requireTitle, NSUInteger index, void (^done)(NSArray<NSDictionary *> *)) {
    NSArray *artists = SGLyricsSearchArtists(query.artist);
    if (index >= artists.count || !query.referenceLines.count) { done(@[]); return; }
    searchKeyword(artists[index], ^(NSArray<NSDictionary *> *list) {
        for (id song in list) if ([song isKindOfClass:NSDictionary.class] && eligible(song, query, requireTitle)) { done(list); return; }
        searchArtists(query, requireTitle, index + 1, done);
    });
}

static void search(SGLyricsQuery *query, BOOL requireTitle, void (^done)(NSArray<NSDictionary *> *list)) {
    if (!query.title.length || !query.artist.length) { done(@[]); return; }
    NSString *lead = SGLyricsLeadArtist(query.artist) ?: query.artist;
    NSString *title = SGLyricsSearchTitle(query.title);
    searchKeyword([NSString stringWithFormat:@"%@ %@", title, lead], ^(NSArray<NSDictionary *> *list) {
        for (NSDictionary *song in list) {
            if ([song isKindOfClass:NSDictionary.class] &&
                eligible(song, query, requireTitle)) { done(list); return; }
        }
        // Some catalogues omit the international title or index only the single's title.
        searchKeyword(title, ^(NSArray<NSDictionary *> *titleList) {
            for (id song in titleList) if ([song isKindOfClass:NSDictionary.class] && eligible(song, query, requireTitle)) { done(titleList); return; }
            if (requireTitle) done(@[]);
            else searchArtists(query, requireTitle, 0, done);
        });
    });
}

static void findSongsAt(SGLyricsQuery *query, NSUInteger attempt, void (^done)(NSArray<NSDictionary *> *songs)) {
    NSArray *artists = SGLyricsSearchArtists(query.artist);
    if (attempt && (!query.referenceLines.count || attempt > artists.count)) { done(@[]); return; }
    void (^receive)(NSArray<NSDictionary *> *) = ^(NSArray<NSDictionary *> *list) {
        NSMutableArray<NSDictionary *> *fitting = [NSMutableArray array];
        for (NSDictionary *candidate in list) {
            if (SGLyricsDiagnosticsEnabled() && [candidate isKindOfClass:NSDictionary.class]) {
                NSInteger seconds = [candidate[@"interval"] respondsToSelector:@selector(integerValue)]
                    ? [candidate[@"interval"] integerValue] : 0;
                SGLyricsDiagnosticCandidate(@"qqmusic", query, candidate[@"title"] ?: candidate[@"songname"],
                                            singers(candidate), seconds, 6, YES);
                if (![candidate[@"id"] isKindOfClass:NSNumber.class]) SGLyricsLog(@"qqmusic: candidate has no usable song ID");
            }
            if (![candidate isKindOfClass:NSDictionary.class] || !eligible(candidate, query, YES) ||
                ![candidate[@"id"] isKindOfClass:NSNumber.class]) continue;
            [fitting addObject:candidate];
        }
        [fitting sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL aTitle = matches(a, query), bTitle = matches(b, query);
            if (aTitle != bTitle) return aTitle ? NSOrderedAscending : NSOrderedDescending;
            NSUInteger aScore = SGLyricsArtistMatchCount(singers(a), query.artist);
            NSUInteger bScore = SGLyricsArtistMatchCount(singers(b), query.artist);
            if (aScore != bScore) return aScore > bScore ? NSOrderedAscending : NSOrderedDescending;
            NSInteger aGap = labs([a[@"interval"] integerValue] - query.seconds);
            NSInteger bGap = labs([b[@"interval"] integerValue] - query.seconds);
            return aGap < bGap ? NSOrderedAscending : aGap > bGap ? NSOrderedDescending : NSOrderedSame;
        }];
        NSMutableArray<NSDictionary *> *ids = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSDictionary *song in fitting) {
            if (ids.count >= 6) break;
            if (![seen containsObject:song[@"id"]]) { [ids addObject:song]; [seen addObject:song[@"id"]]; }
        }
        if (!ids.count) SGLyricsLog(@"qqmusic: no matching recording for %@ by %@", query.title, query.artist);
        done(ids);
    };
    if (!attempt) search(query, YES, receive);
    else searchKeyword(artists[attempt - 1], receive);
}

static void tryLyrics(NSArray<NSDictionary *> *ids, NSUInteger index, SGLyricsQuery *query, void (^done)(SGLyricsResult *)) {
    if (index >= ids.count) { done(nil); return; }
    NSDictionary *song = ids[index];
    lyricsForSong(song[@"id"], ^(SGLyricsResult *result) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BOOL verified = result && ((matches(song, query) && SGLyricsArtistMatchCount(singers(song), query.artist)) || SGLyricsRecordingMatches(query.referenceLines, result.karaokeLines));
            dispatch_async(dispatch_get_main_queue(), ^{
                SGLyricsLog(@"qqmusic: candidate %@ title '%@' recording evidence %@", song[@"id"], song[@"title"], verified ? @"accepted" : @"rejected");
                if (verified) done(result);
                else tryLyrics(ids, index + 1, query, done);
            });
        });
    });
}

static void askAt(SGLyricsQuery *query, NSUInteger attempt, void (^done)(SGLyricsResult *)) {
    findSongsAt(query, attempt, ^(NSArray<NSDictionary *> *ids) {
        tryLyrics(ids, 0, query, ^(SGLyricsResult *result) {
            if (result) done(result);
            else if (query.referenceLines.count && attempt < SGLyricsSearchArtists(query.artist).count) askAt(query, attempt + 1, done);
            else done(nil);
        });
    });
}

SGLyricsAsk SGQQMusicAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *)) { askAt(query, 0, done); };

static void tryTranslations(NSArray<NSDictionary *> *songs, NSUInteger index, SGLyricsQuery *query,
                            NSArray<SGKaraokeLine *> *target, SGLyricsTranslationReply done) {
    if (index >= MIN(songs.count, 6)) { done(nil, nil); return; }
    NSDictionary *song = songs[index];
    NSNumber *songID = [song[@"id"] isKindOfClass:NSNumber.class] ? song[@"id"] : nil;
    if (!songID || !matchesRecording(song, query)) {
        tryTranslations(songs, index + 1, query, target, done);
        return;
    }
    lyricReply(songID, YES, NO, ^(NSDictionary *data) {
        NSString *original = decoded(data, @"lyric");
        NSString *translated = decoded(data, @"trans");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSUInteger overlap = translated.length ? SGLyricsOriginalOverlap(target, original) : 0;
            BOOL identity = SGLyricsArtistMatchCount(singers(song), query.artist) || SGLyricsRecordingMatches(target, SGLyricsLinesFromLRC(original));
            dispatch_async(dispatch_get_main_queue(), ^{
                SGLyricsLog(@"qqmusic: translation candidate %@ title %@, %lu original lines match, recording identity %@",
                      songID, song[@"title"], (unsigned long)overlap, identity ? @"accepted" : @"rejected");
                if (identity && overlap >= MIN((NSUInteger)2, target.count)) done(original, translated);
                else tryTranslations(songs, index + 1, query, target, done);
            });
        });
    });
}

void SGQQMusicTranslationAsk(SGLyricsQuery *query, NSArray<SGKaraokeLine *> *target, SGLyricsTranslationReply done) {
    search(query, NO, ^(NSArray<NSDictionary *> *list) {
        NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
        for (NSDictionary *song in list) {
            if ([song isKindOfClass:NSDictionary.class] && matchesRecording(song, query)) [candidates addObject:song];
        }
        [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL aTitle = SGLyricsTitleMatches(a[@"title"], query.title);
            BOOL bTitle = SGLyricsTitleMatches(b[@"title"], query.title);
            if (aTitle != bTitle) return aTitle ? NSOrderedAscending : NSOrderedDescending;
            NSUInteger aArtists = SGLyricsArtistMatchCount(singers(a), query.artist);
            NSUInteger bArtists = SGLyricsArtistMatchCount(singers(b), query.artist);
            if (aArtists != bArtists) return aArtists > bArtists ? NSOrderedAscending : NSOrderedDescending;
            NSInteger aGap = labs([a[@"interval"] integerValue] - query.seconds);
            NSInteger bGap = labs([b[@"interval"] integerValue] - query.seconds);
            return aGap < bGap ? NSOrderedAscending : aGap > bGap ? NSOrderedDescending : NSOrderedSame;
        }];
        tryTranslations(candidates, 0, query, target, done);
    });
}
