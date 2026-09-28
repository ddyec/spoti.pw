// QQ Music's public musicu search and line-timed LRC. QRC uses QQ's own nonstandard cipher;
// request the unencrypted LRC variant so this source can run inside the tweak without a decoder.
#import "Core/SGCore.h"
#import "LyricsSources.h"

static NSString *const kMusicu = @"https://u.y.qq.com/cgi-bin/musicu.fcg";

static NSDictionary<NSString *, NSString *> *headers(void) {
    return @{@"Referer": @"https://y.qq.com/", @"User-Agent": @"Mozilla/5.0", @"Accept": @"application/json"};
}

static NSString *normalized(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @"";
    NSMutableString *out = [NSMutableString string];
    NSCharacterSet *skip = [NSCharacterSet characterSetWithCharactersInString:@" -_.,:;!?()[]{}'\"·，。！？（）【】—　\t\n"];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (![skip characterIsMember:c]) [out appendFormat:@"%C", c];
    }
    return out.lowercaseString;
}

static BOOL matchesRecording(NSDictionary *song, SGLyricsQuery *query) {
    if (query.seconds > 0 && [song[@"interval"] respondsToSelector:@selector(integerValue)] &&
        labs([song[@"interval"] integerValue] - query.seconds) > 6) return NO;
    NSString *wanted = normalized([query.artist componentsSeparatedByString:@" feat"].firstObject);
    for (NSDictionary *singer in [song[@"singer"] isKindOfClass:NSArray.class] ? song[@"singer"] : @[]) {
        NSString *name = normalized([singer isKindOfClass:NSDictionary.class] ? singer[@"name"] : nil);
        if (name.length && wanted.length && ([name containsString:wanted] || [wanted containsString:name])) return YES;
    }
    return NO;
}

static void lyricReply(NSNumber *songID, BOOL translation, void (^done)(NSDictionary *data)) {
    NSDictionary *request = @{@"music.musichallSong.PlayLyricInfo.GetPlayLyricInfo": @{
        @"method": @"GetPlayLyricInfo", @"module": @"music.musichallSong.PlayLyricInfo",
        @"param": @{@"crypt": @0, @"qrc": @0, @"trans": translation ? @1 : @0, @"songID": songID}}};
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

static NSString *decoded(NSDictionary *data, NSString *key) {
    NSString *encoded = [data[key] isKindOfClass:NSString.class] ? data[key] : nil;
    NSData *bytes = encoded.length ? [[NSData alloc] initWithBase64EncodedString:encoded options:0] : nil;
    return bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
}

static void lyricsForSong(NSNumber *songID, void (^done)(SGLyricsResult *)) {
    lyricReply(songID, NO, ^(NSDictionary *data) {
        NSString *lrc = decoded(data, @"lyric");
        NSArray<SGKaraokeLine *> *lines = lrc ? SGLyricsLinesFromLRC(lrc) : nil;
        if (!lines.count) { done(nil); return; }
        SGLyricsResult *result = [SGLyricsResult new];
        result.synced = YES;
        result.karaokeLines = lines;
        NSArray<NSNumber *> *starts;
        NSArray<NSString *> *texts;
        SGLyricsPageLines(lines, &starts, &texts);
        result.starts = starts;
        result.texts = texts;
        done(result);
    });
}

static void search(SGLyricsQuery *query, void (^done)(NSArray<NSDictionary *> *list)) {
    if (!query.title.length || !query.artist.length) { done(@[]); return; }
    NSDictionary *request = @{
        @"comm": @{@"ct": @"19", @"cv": @"1859", @"uin": @"0"},
        @"req": @{@"method": @"DoSearchForQQMusicDesktop", @"module": @"music.search.SearchCgiService",
                  @"param": @{@"grp": @1, @"num_per_page": @15, @"page_num": @1,
                               @"query": [NSString stringWithFormat:@"%@ %@", query.title, query.artist], @"search_type": @0}}
    };
    SGLyricsPostJSON([NSURL URLWithString:kMusicu], headers(), request, ^(id root) {
        id value = [root isKindOfClass:NSDictionary.class] ? root[@"req"] : nil;
        NSDictionary *requestReply = [value isKindOfClass:NSDictionary.class] ? value : nil;
        NSDictionary *data = [requestReply[@"data"] isKindOfClass:NSDictionary.class] ? requestReply[@"data"] : nil;
        NSDictionary *body = [data[@"body"] isKindOfClass:NSDictionary.class] ? data[@"body"] : nil;
        NSDictionary *song = [body[@"song"] isKindOfClass:NSDictionary.class] ? body[@"song"] : nil;
        NSArray *list = [song[@"list"] isKindOfClass:NSArray.class] ? song[@"list"] : @[];
        done(list);
    });
}

static void findSong(SGLyricsQuery *query, void (^done)(NSNumber *songID)) {
    search(query, ^(NSArray<NSDictionary *> *list) {
        for (NSDictionary *candidate in list) {
            if (![candidate isKindOfClass:NSDictionary.class] || !matches(candidate, query)) continue;
            NSNumber *songID = [candidate[@"id"] isKindOfClass:NSNumber.class] ? candidate[@"id"] : nil;
            if (songID) { done(songID); return; }
        }
        SGLog(@"qqmusic: no matching recording for %@ by %@", query.title, query.artist);
        done(nil);
    });
}

SGLyricsAsk SGQQMusicAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *)) {
    findSong(query, ^(NSNumber *songID) {
        if (!songID) { done(nil); return; }
        lyricsForSong(songID, done);
    });
};

static void tryTranslations(NSArray<NSDictionary *> *songs, NSUInteger index, SGLyricsQuery *query,
                            NSArray<SGKaraokeLine *> *target, SGLyricsTranslationReply done) {
    if (index >= MIN(songs.count, 6)) { done(nil, nil); return; }
    NSDictionary *song = songs[index];
    NSNumber *songID = [song[@"id"] isKindOfClass:NSNumber.class] ? song[@"id"] : nil;
    if (!songID || !matchesRecording(song, query)) {
        tryTranslations(songs, index + 1, query, target, done);
        return;
    }
    lyricReply(songID, YES, ^(NSDictionary *data) {
        NSString *original = decoded(data, @"lyric");
        NSString *translated = decoded(data, @"trans");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSUInteger overlap = translated.length ? SGLyricsOriginalOverlap(target, original) : 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                SGLog(@"qqmusic: translation candidate %@ title %@, %lu original lines match",
                      songID, song[@"title"], (unsigned long)overlap);
                if (overlap >= MIN((NSUInteger)2, target.count)) done(original, translated);
                else tryTranslations(songs, index + 1, query, target, done);
            });
        });
    });
}

void SGQQMusicTranslationAsk(SGLyricsQuery *query, NSArray<SGKaraokeLine *> *target, SGLyricsTranslationReply done) {
    search(query, ^(NSArray<NSDictionary *> *list) {
        NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
        for (NSDictionary *song in list) {
            if ([song isKindOfClass:NSDictionary.class] && matchesRecording(song, query)) [candidates addObject:song];
        }
        [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL aTitle = SGLyricsTitleMatches(a[@"title"], query.title);
            BOOL bTitle = SGLyricsTitleMatches(b[@"title"], query.title);
            if (aTitle != bTitle) return aTitle ? NSOrderedAscending : NSOrderedDescending;
            NSInteger aGap = labs([a[@"interval"] integerValue] - query.seconds);
            NSInteger bGap = labs([b[@"interval"] integerValue] - query.seconds);
            return aGap < bGap ? NSOrderedAscending : aGap > bGap ? NSOrderedDescending : NSOrderedSame;
        }];
        tryTranslations(candidates, 0, query, target, done);
    });
}
