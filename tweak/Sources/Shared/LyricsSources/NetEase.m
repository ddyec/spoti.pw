// Word timing from NetEase Cloud Music, for the tracks the other sources only line-time, e.g. most
// of Eminem. It has no text of its own to offer Spotify's page, only the time of every word, so it
// earns its place at the end of the order rather than the front. Searched by title, artist and
// length; NetEase censors swear words with asterisks.
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
        if (error || !root) SGLog(@"netease: %@ failed: status %ld, error %@", path, (long)[(NSHTTPURLResponse *)response statusCode], error);
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
    BOOL singing = NO;
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
        NSString *text = SGKaraokeLineText(line);
        if (!singing && line.start < 30000 && SGLyricsTimedCredit(text)) continue;
        if (!singing && line.start < 2500 && [text containsString:@" - "]) continue;
        singing = YES;
        [lines addObject:line];
    }
    return lines.count ? lines : nil;
}

static void tryLyrics(NSArray<NSNumber *> *songs, NSUInteger index, void (^done)(NSArray<SGKaraokeLine *> *)) {
    if (index >= songs.count) {
        done(nil);
        return;
    }
    get(@"song/lyric/v1", @{@"id": songs[index].stringValue, @"lv": @"1", @"yv": @"1", @"tv": @"-1"}, ^(NSDictionary *root) {
        id yrc = [root[@"yrc"] isKindOfClass:NSDictionary.class] ? root[@"yrc"][@"lyric"] : nil;
        NSArray<SGKaraokeLine *> *lines = [yrc isKindOfClass:NSString.class] ? linesFromYrc(yrc) : nil;
        if (lines) {
            SGLog(@"netease: song %@ has %lu word timed lines", songs[index], (unsigned long)lines.count);
            done(lines);
        } else {
            tryLyrics(songs, index + 1, done);
        }
    });
}

// A recording is only taken when its length is this close to the track's, so the words fall on the
// same beat as the recording Spotify is playing.
static void findSongs(SGLyricsQuery *query, BOOL requireTitle, void (^done)(NSArray<NSNumber *> *ids)) {
    NSString *lead = SGLyricsLeadArtist(query.artist);
    NSString *title = query.title;
    NSInteger seconds = query.seconds;
    if (!title.length || !lead.length || seconds <= 0) {
        done(@[]);
        return;
    }
    get(@"search/get", @{@"s": [NSString stringWithFormat:@"%@ %@", title, lead], @"type": @"1", @"limit": @"10"}, ^(NSDictionary *root) {
        id songs = [root[@"result"] isKindOfClass:NSDictionary.class] ? root[@"result"][@"songs"] : nil;
        NSMutableArray<NSDictionary *> *fitting = [NSMutableArray array];
        for (NSDictionary *song in [songs isKindOfClass:NSArray.class] ? songs : @[]) {
            if (![song isKindOfClass:NSDictionary.class] || labs([song[@"duration"] integerValue] / 1000 - seconds) > kLengthSlack ||
                (requireTitle && !SGLyricsTitleMatches(song[@"name"], title))) continue;
            if (SGLyricsArtistMatchCount(artistsOf(song), query.artist)) [fitting addObject:song];
        }
        [fitting sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSUInteger aScore = SGLyricsArtistMatchCount(artistsOf(a), query.artist);
            NSUInteger bScore = SGLyricsArtistMatchCount(artistsOf(b), query.artist);
            if (aScore != bScore) return aScore > bScore ? NSOrderedAscending : NSOrderedDescending;
            return [@(labs([a[@"duration"] integerValue] / 1000 - seconds)) compare:@(labs([b[@"duration"] integerValue] / 1000 - seconds))];
        }];
        NSArray *ids = [[fitting valueForKey:@"id"] subarrayWithRange:NSMakeRange(0, MIN(fitting.count, kTriedSongs))];
        if (!ids.count) SGLog(@"netease: no recording of %@ by %@ within %lds of %lds", title, lead, (long)kLengthSlack, (long)seconds);
        done(ids);
    });
}

SGLyricsAsk SGNetEaseAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    findSongs(query, YES, ^(NSArray<NSNumber *> *ids) {
        tryLyrics(ids, 0, ^(NSArray<SGKaraokeLine *> *lines) {
            if (!lines.count) { done(nil); return; }
            SGLyricsResult *result = [SGLyricsResult new];
            result.wordTimed = result.synced = YES;
            result.karaokeLines = lines;
            done(result);
        });
    });
};

static void tryTranslations(NSArray<NSNumber *> *ids, NSUInteger index, NSArray<SGKaraokeLine *> *target,
                            SGLyricsTranslationReply done) {
    if (index >= ids.count) { done(nil, nil); return; }
    get(@"song/lyric/v1", @{@"id": ids[index].stringValue, @"lv": @"-1", @"tv": @"-1"}, ^(NSDictionary *root) {
        NSDictionary *original = [root[@"lrc"] isKindOfClass:NSDictionary.class] ? root[@"lrc"] : nil;
        NSDictionary *translated = [root[@"tlyric"] isKindOfClass:NSDictionary.class] ? root[@"tlyric"] : nil;
        NSString *lrc = [original[@"lyric"] isKindOfClass:NSString.class] ? original[@"lyric"] : nil;
        NSString *tlyric = [translated[@"lyric"] isKindOfClass:NSString.class] ? translated[@"lyric"] : nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSUInteger overlap = tlyric.length ? SGLyricsOriginalOverlap(target, lrc) : 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                SGLog(@"netease: translation candidate %@, %lu original lines match", ids[index], (unsigned long)overlap);
                if (overlap >= MIN((NSUInteger)2, target.count)) done(lrc, tlyric);
                else tryTranslations(ids, index + 1, target, done);
            });
        });
    });
}

void SGNetEaseTranslationAsk(SGLyricsQuery *query, NSArray<SGKaraokeLine *> *target, SGLyricsTranslationReply done) {
    findSongs(query, NO, ^(NSArray<NSNumber *> *ids) { tryTranslations(ids, 0, target, done); });
}
