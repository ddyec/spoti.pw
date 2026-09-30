// NetEase word-timed YRC with line-timed LRC fallback and translations from the same recording.
#import "Core/SGCore.h"
#import "LyricsSources.h"

static const NSTimeInterval kTimeout = 3;
// A NetEase recording is only taken when its length is this close to the track's, so the words fall
// on the same beat.
static const NSInteger kLengthSlack = 3;
static const NSUInteger kTriedSongs = 3;

static NSString *artistsOf(NSDictionary *song) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSArray *artists = [song[@"artists"] isKindOfClass:NSArray.class] ? song[@"artists"] : @[];
    for (NSDictionary *artist in artists) {
        NSString *name = [artist isKindOfClass:NSDictionary.class] ? artist[@"name"] : nil;
        if ([name isKindOfClass:NSString.class] && name.length) [names addObject:name];
    }
    return [names componentsJoinedByString:@", "];
}

static BOOL titleMatches(NSDictionary *song, SGLyricsQuery *query) {
    if (SGLyricsTitleMatches(song[@"name"], query.title)) return YES;
    for (NSString *key in @[@"alias", @"transNames", @"tns"]) {
        for (id alias in [song[key] isKindOfClass:NSArray.class] ? song[key] : @[])
            if ([alias isKindOfClass:NSString.class] && SGLyricsTitleMatches(alias, query.title)) return YES;
    }
    return NO;
}

static void get(NSString *path, NSDictionary<NSString *, NSString *> *query, void (^done)(NSDictionary *root)) {
    NSURLComponents *url = [NSURLComponents componentsWithString:[@"https://music.163.com/api/" stringByAppendingString:path]];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    [query enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [items addObject:[NSURLQueryItem queryItemWithName:name value:value]];
    }];
    url.queryItems = items;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kTimeout];
    [request setValue:@"https://music.163.com" forHTTPHeaderField:@"Referer"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        SGLyricsNoteReply(response, error);
        id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (error || !root) SGLyricsLog(@"netease: %@ failed: status %ld, error %@/%ld", path, (long)[(NSHTTPURLResponse *)response statusCode], error.domain ?: @"none", (long)error.code);
        dispatch_async(dispatch_get_main_queue(), ^{ done([root isKindOfClass:NSDictionary.class] ? root : nil); });
    }] resume];
}

// [43060,3600](43060,120,0)To (43180,330,0)seize (43510,420,0)everything …
// A line's start and length in ms, then each piece's start and length before its text. A piece not
// ending in a space runs on into the next one ("wanted" "…"), as in richsync.
static NSArray<SGKaraokeLine *> *linesFromYrc(NSString *yrc) {
    static NSRegularExpression *header, *piece;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        header = [NSRegularExpression regularExpressionWithPattern:@"^\\[(\\d+),(\\d+)\\]" options:0 error:nil];
        piece = [NSRegularExpression regularExpressionWithPattern:@"\\((\\d+),(\\d+),-?\\d+\\)" options:0 error:nil];
    });
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (NSString *row in [yrc componentsSeparatedByString:@"\n"]) {
        NSTextCheckingResult *head = [header firstMatchInString:row options:0 range:NSMakeRange(0, row.length)];
        if (!head) continue;
        NSArray<NSTextCheckingResult *> *pieces = [piece matchesInString:row options:0 range:NSMakeRange(NSMaxRange(head.range), row.length - NSMaxRange(head.range))];
        NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
        SGKaraokeWord *open = nil;
        BOOL spaced = YES;   // a space has gone by, so the next word is not joined to the last
        for (NSUInteger i = 0; i < pieces.count; i++) {
            NSUInteger from = NSMaxRange(pieces[i].range), to = i + 1 < pieces.count ? pieces[i + 1].range.location : row.length;
            NSString *raw = [row substringWithRange:NSMakeRange(from, to - from)];
            NSString *text = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSInteger start = [row substringWithRange:[pieces[i] rangeAtIndex:1]].integerValue;
            NSInteger end = start + [row substringWithRange:[pieces[i] rangeAtIndex:2]].integerValue;
            // yrc times a Chinese or Japanese syllable a piece at a time and never spaces them, so
            // each one is a word of its own; only a spaced script runs its pieces together.
            BOOL unspaced = SGKaraokeUnspacedScript(text);
            if (text.length && open && !unspaced) {
                open.text = [open.text stringByAppendingString:text];
                open.end = end;
            } else if (text.length) {
                SGKaraokeWord *word = [SGKaraokeWord new];
                word.text = text;
                word.start = start;
                word.end = end;
                word.joined = !spaced;
                [words addObject:word];
                open = unspaced ? nil : word;
                spaced = NO;
            }
            if (raw.length > text.length || !text.length) {
                open = nil;
                spaced = YES;
            }
        }
        if (!words.count) continue;
        SGKaraokeLine *line = [SGKaraokeLine new];
        line.words = words;
        line.start = [row substringWithRange:[head rangeAtIndex:1]].integerValue;
        line.end = line.start + [row substringWithRange:[head rangeAtIndex:2]].integerValue;
        line.timing = SGKaraokeTimingWords;
        NSString *text = SGKaraokeLineText(line);
        if (SGLyricsTimedCredit(text)) continue;
        [lines addObject:line];
    }
    return lines.count ? lines : nil;
}

static void tryLyrics(NSArray<NSDictionary *> *songs, NSUInteger index, SGLyricsQuery *query, void (^done)(NSArray<SGKaraokeLine *> *)) {
    if (index >= songs.count) {
        done(nil);
        return;
    }
    NSDictionary *song = songs[index];
    get(@"song/lyric/v1", @{@"id": [song[@"id"] description], @"lv": @"1", @"yv": @"1", @"tv": @"-1", @"rv": @"-1", @"yrv": @"-1"}, ^(NSDictionary *root) {
        id yrc = [root[@"yrc"] isKindOfClass:NSDictionary.class] ? root[@"yrc"][@"lyric"] : nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSArray<SGKaraokeLine *> *lines = [yrc isKindOfClass:NSString.class] ? linesFromYrc(yrc) : nil;
            if (!lines.count) {
                id lrc = [root[@"lrc"] isKindOfClass:NSDictionary.class] ? root[@"lrc"][@"lyric"] : nil;
                lines = [lrc isKindOfClass:NSString.class] ? SGLyricsLinesFromLRC(lrc) : nil;
            }
            NSString *lrc = [root[@"lrc"] isKindOfClass:NSDictionary.class] && [root[@"lrc"][@"lyric"] isKindOfClass:NSString.class] ? root[@"lrc"][@"lyric"] : nil;
            NSString *translated = [root[@"tlyric"] isKindOfClass:NSDictionary.class] && [root[@"tlyric"][@"lyric"] isKindOfClass:NSString.class] ? root[@"tlyric"][@"lyric"] : nil;
            NSString *language = SGLyricsTranslationLanguage() ?: NSLocale.preferredLanguages.firstObject;
            NSDictionary<NSNumber *, NSString *> *updates = [language.lowercaseString hasPrefix:@"zh"]
                ? SGLyricsChineseTranslationMap(lines, lrc, translated) : @{};
            for (NSNumber *index in updates) lines[index.unsignedIntegerValue].translation = updates[index];
            SGLyricsLog(@"netease: song %@ translation payload %@, attached %lu Chinese translations", song[@"id"],
                        translated.length ? @"present" : @"absent", (unsigned long)updates.count);
            NSString *yroma = [root[@"yromalrc"] isKindOfClass:NSDictionary.class] && [root[@"yromalrc"][@"lyric"] isKindOfClass:NSString.class] ? root[@"yromalrc"][@"lyric"] : nil;
            NSString *roma = [root[@"romalrc"] isKindOfClass:NSDictionary.class] && [root[@"romalrc"][@"lyric"] isKindOfClass:NSString.class] ? root[@"romalrc"][@"lyric"] : nil;
            NSMutableDictionary<NSNumber *, SGKaraokeLine *> *spoken = [SGLyricsPronunciationMap(lines, lines, SGLyricsLinesFromLRC(yroma)) mutableCopy];
            NSDictionary *fallback = SGLyricsPronunciationMap(lines, SGLyricsLinesFromLRC(lrc), SGLyricsLinesFromLRC(roma));
            for (NSNumber *index in fallback) if (!spoken[index]) spoken[index] = fallback[index];
            for (NSNumber *index in spoken) lines[index.unsignedIntegerValue].pronunciation = spoken[index];
            SGLyricsLog(@"netease: song %@ pronunciation payload %@, attached %lu lines", song[@"id"], (yroma.length || roma.length) ? @"present" : @"absent", (unsigned long)spoken.count);
            BOOL verified = lines.count && ((titleMatches(song, query) && SGLyricsArtistMatchCount(artistsOf(song), query.artist)) || SGLyricsRecordingMatches(query.referenceLines, lines));
            dispatch_async(dispatch_get_main_queue(), ^{
                SGLyricsLog(@"netease: song %@ has %lu lines (word timing %@), evidence %@", song[@"id"], (unsigned long)lines.count,
                            SGKaraokeLinesTiming(lines) == SGKaraokeTimingWords ? @"yes" : @"no", verified ? @"accepted" : @"rejected");
                if (verified) done(lines);
                else tryLyrics(songs, index + 1, query, done);
            });
        });
    });
}

// A recording is only taken when its length is this close to the track's, so the words fall on the
// same beat as the recording Spotify is playing.
static void findSongsAt(SGLyricsQuery *query, BOOL requireTitle, NSUInteger attempt, void (^done)(NSArray<NSDictionary *> *ids)) {
    NSString *lead = SGLyricsLeadArtist(query.artist);
    NSString *title = SGLyricsSearchTitle(query.title);
    NSInteger seconds = query.seconds;
    if (!title.length || !lead.length || seconds <= 0) {
        done(@[]);
        return;
    }
    NSArray *artists = SGLyricsSearchArtists(query.artist);
    if (attempt && (!query.referenceLines.count || attempt > artists.count)) { done(@[]); return; }
    NSString *keyword = attempt ? artists[attempt - 1] : [NSString stringWithFormat:@"%@ %@", title, lead];
    get(@"search/get", @{@"s": keyword, @"type": @"1", @"limit": @"40"}, ^(NSDictionary *root) {
        id songs = [root[@"result"] isKindOfClass:NSDictionary.class] ? root[@"result"][@"songs"] : nil;
        NSMutableArray<NSDictionary *> *fitting = [NSMutableArray array];
        SGLyricsLog(@"netease: track %@ search '%@ %@' (original '%@'), status %@", query.trackID, title, lead, query.title, root[@"code"]);
        for (NSDictionary *song in [songs isKindOfClass:NSArray.class] ? songs : @[]) {
            if (SGLyricsDiagnosticsEnabled() && [song isKindOfClass:NSDictionary.class]) {
                SGLyricsDiagnosticCandidate(@"netease", query, song[@"name"], artistsOf(song),
                                            [song[@"duration"] integerValue] / 1000, kLengthSlack, requireTitle);
            }
            if (![song isKindOfClass:NSDictionary.class] || ![song[@"id"] isKindOfClass:NSNumber.class] || labs([song[@"duration"] integerValue] / 1000 - seconds) > kLengthSlack ||
                (requireTitle && !titleMatches(song, query) && !SGLyricsTranslatedTitleCandidate(song[@"name"], query))) continue;
            if (SGLyricsArtistMatchCount(artistsOf(song), query.artist) || (query.referenceLines.count && titleMatches(song, query))) {
                NSMutableDictionary *candidate = [song mutableCopy];
                candidate[@"sg_searchAttempt"] = @(attempt);
                [fitting addObject:candidate];
            }
        }
        [fitting sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL aTitle = titleMatches(a, query), bTitle = titleMatches(b, query);
            if (aTitle != bTitle) return aTitle ? NSOrderedAscending : NSOrderedDescending;
            NSUInteger aScore = SGLyricsArtistMatchCount(artistsOf(a), query.artist);
            NSUInteger bScore = SGLyricsArtistMatchCount(artistsOf(b), query.artist);
            if (aScore != bScore) return aScore > bScore ? NSOrderedAscending : NSOrderedDescending;
            return [@(labs([a[@"duration"] integerValue] / 1000 - seconds)) compare:@(labs([b[@"duration"] integerValue] / 1000 - seconds))];
        }];
        NSArray *ids = [fitting subarrayWithRange:NSMakeRange(0, MIN(fitting.count, kTriedSongs))];
        if (!ids.count && query.referenceLines.count && attempt < artists.count) {
            findSongsAt(query, requireTitle, attempt + 1, done);
            return;
        }
        if (!ids.count) SGLyricsLog(@"netease: no recording of %@ by %@ within %lds of %lds", title, lead, (long)kLengthSlack, (long)seconds);
        done(ids);
    });
}

static void askAt(SGLyricsQuery *query, NSUInteger attempt, void (^done)(SGLyricsResult *result)) {
    findSongsAt(query, YES, attempt, ^(NSArray<NSDictionary *> *ids) {
        tryLyrics(ids, 0, query, ^(NSArray<SGKaraokeLine *> *lines) {
            if (!lines.count) {
                NSUInteger searched = [ids.firstObject[@"sg_searchAttempt"] unsignedIntegerValue];
                if (ids.count && query.referenceLines.count && searched < SGLyricsSearchArtists(query.artist).count) askAt(query, searched + 1, done);
                else done(nil);
                return;
            }
            SGLyricsResult *result = [SGLyricsResult new];
            result.synced = YES;
            result.wordTimed = SGKaraokeLinesTiming(lines) == SGKaraokeTimingWords;
            result.karaokeLines = lines;
            NSArray<NSNumber *> *starts;
            NSArray<NSString *> *texts;
            SGLyricsPageLines(lines, &starts, &texts);
            result.starts = starts;
            result.texts = texts;
            done(result);
        });
    });
}

SGLyricsAsk SGNetEaseAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) { askAt(query, 0, done); };

static void tryTranslations(NSArray<NSDictionary *> *ids, NSUInteger index, NSArray<SGKaraokeLine *> *target, SGLyricsQuery *query,
                            SGLyricsTranslationReply done) {
    if (index >= ids.count) { done(nil, nil); return; }
    get(@"song/lyric/v1", @{@"id": [ids[index][@"id"] description], @"lv": @"-1", @"tv": @"-1", @"rv": @"-1", @"yrv": @"-1"}, ^(NSDictionary *root) {
        NSDictionary *original = [root[@"lrc"] isKindOfClass:NSDictionary.class] ? root[@"lrc"] : nil;
        NSDictionary *translated = [root[@"tlyric"] isKindOfClass:NSDictionary.class] ? root[@"tlyric"] : nil;
        NSString *lrc = [original[@"lyric"] isKindOfClass:NSString.class] ? original[@"lyric"] : nil;
        NSString *tlyric = [translated[@"lyric"] isKindOfClass:NSString.class] ? translated[@"lyric"] : nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSUInteger overlap = tlyric.length ? SGLyricsOriginalOverlap(target, lrc) : 0;
            BOOL identity = SGLyricsArtistMatchCount(artistsOf(ids[index]), query.artist) || SGLyricsRecordingMatches(target, SGLyricsLinesFromLRC(lrc));
            dispatch_async(dispatch_get_main_queue(), ^{
                SGLyricsLog(@"netease: translation candidate %@, %lu original lines match, recording identity %@", ids[index][@"id"], (unsigned long)overlap, identity ? @"accepted" : @"rejected");
                if (identity && overlap >= MIN((NSUInteger)2, target.count)) done(lrc, tlyric);
                else tryTranslations(ids, index + 1, target, query, done);
            });
        });
    });
}

void SGNetEaseTranslationAsk(SGLyricsQuery *query, NSArray<SGKaraokeLine *> *target, SGLyricsTranslationReply done) {
    findSongsAt(query, NO, 0, ^(NSArray<NSDictionary *> *songs) { tryTranslations(songs, 0, target, query, done); });
}
