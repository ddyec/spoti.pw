// Text identity and translation alignment, independent of provider ordering and UI state.
#import "LyricsSources.h"

static NSString *comparable(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @"";
    NSString *value = [[text precomposedStringWithCompatibilityMapping] lowercaseString];
    NSMutableString *out = [NSMutableString string];
    NSCharacterSet *letters = NSCharacterSet.alphanumericCharacterSet;
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if ([letters characterIsMember:c]) [out appendFormat:@"%C", c];
    }
    return out;
}

BOOL SGLyricsContainsHan(NSString *text) {
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c >= 0x3400 && c <= 0x9fff) return YES;
    }
    return NO;
}

static NSArray<NSString *> *artistParts(NSString *artists) {
    if (![artists isKindOfClass:NSString.class] || !artists.length) return @[];
    static NSRegularExpression *separator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        separator = [NSRegularExpression regularExpressionWithPattern:@"\\s*(?:,|，|、|/|&|;|；)\\s*|\\s+(?:feat\\.?|ft\\.?|featuring)\\s+"
                                                            options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSString *separated = [separator stringByReplacingMatchesInString:artists options:0
                                                               range:NSMakeRange(0, artists.length) withTemplate:@"\n"];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [separated componentsSeparatedByString:@"\n"]) {
        NSString *name = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length) [parts addObject:name];
    }
    return parts;
}

NSString *SGLyricsLeadArtist(NSString *artists) {
    return artistParts(artists).firstObject;
}

static NSString *kanaArtistKey(NSString *artist) {
    if (!artist.length) return @"";
    // Only bridge kana spellings to romanisation; do not guess kanji readings.
    BOOL kana = NO;
    for (NSUInteger i = 0; i < artist.length; i++) {
        unichar c = [artist characterAtIndex:i];
        if ((c >= 0x3040 && c <= 0x30ff) || (c >= 0xff66 && c <= 0xff9d)) kana = YES;
        if (c >= 0x3400 && c <= 0x9fff) return @"";
    }
    return kana ? comparable([artist stringByApplyingTransform:NSStringTransformToLatin reverse:NO]) : @"";
}

NSArray<NSString *> *SGLyricsSearchArtists(NSString *artists) {
    NSArray *parts = artistParts(artists);
    NSMutableOrderedSet *result = [NSMutableOrderedSet orderedSet];
    // Labels may be first or last in the international release. Bound fallback requests.
    if (parts.count) [result addObject:parts.firstObject];
    if (parts.count > 1) [result addObject:parts.lastObject];
    if (parts.count > 2) [result addObject:parts[1]];
    return result.array;
}

NSUInteger SGLyricsArtistMatchCount(NSString *candidate, NSString *wanted) {
    NSArray<NSString *> *candidateParts = artistParts(candidate);
    NSUInteger matches = 0;
    for (NSString *wantedPart in artistParts(wanted)) {
        NSString *name = comparable(wantedPart);
        if (name.length < 2) continue;
        for (NSString *candidatePart in candidateParts) {
            NSString *other = comparable(candidatePart);
            if (other.length >= 2 && ([name isEqualToString:other] ||
                                      (MIN(name.length, other.length) >= 6 &&
                                       ([name containsString:other] || [other containsString:name])) ||
                                      (name.length >= 4 && [[kanaArtistKey(candidatePart) lowercaseString] isEqualToString:name]) ||
                                      (other.length >= 4 && [[kanaArtistKey(wantedPart) lowercaseString] isEqualToString:other]))) {
                matches++;
                break;
            }
        }
    }
    return matches;
}

BOOL SGLyricsTimedCredit(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return NO;
    text = [[text stringByReplacingOccurrencesOfString:@"\uFEFF" withString:@""]
                 stringByReplacingOccurrencesOfString:@"\u200B" withString:@""];
    static NSRegularExpression *credit;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        credit = [NSRegularExpression regularExpressionWithPattern:
            @"^\\s*(?:作词|作曲|编曲|演唱|原唱|歌手|词曲|混音(?:师)?|录音(?:师)?|母带(?:处理工程师)?|制作(?:人)?|出品|策划|监制|发行|合声|和声|人声|吉他|原声吉他|电吉他|贝斯|貝斯|鼓|弦乐|弦樂|钢琴|鋼琴|乐队|音乐制作|词|曲|Lyrics?(?: by)?|Composer|Composed by|Arranged by|Produced by|Vocals?(?:ist)?|Singer|Artist|OP|SP)(?:\\s*[/／&、]\\s*(?:作词|作曲|编曲|词|曲))?(?:\\s*[（(][^）)]{0,40}[）)])?(?:\\s+[A-Za-z][A-Za-z&/ ]{0,30})?\\s*[:：]"
            options:NSRegularExpressionCaseInsensitive error:nil];
    });
    return [credit firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}

// Catalogue titles often append the film/game and the kind of theme. Only remove a
// delimited description with a recognised theme marker; recording versions stay intact.
NSString *SGLyricsSearchTitle(NSString *title) {
    if (![title isKindOfClass:NSString.class]) return @"";
    NSString *value = [title precomposedStringWithCompatibilityMapping];
    static NSRegularExpression *suffix, *theme, *version, *featured;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        featured = [NSRegularExpression regularExpressionWithPattern:
            @"\\s*[\\(\\[（【](?:feat\\.?|ft\\.?|featuring)\\s+[^)\\]）】]+[)\\]）】]\\s*$"
            options:NSRegularExpressionCaseInsensitive error:nil];
        suffix = [NSRegularExpression regularExpressionWithPattern:
            @"\\s+(?:[-–—:]\\s+)(.+)$|\\s*[\\(\\[（【](.+)[\\)\\]）】]\\s*$" options:0 error:nil];
        theme = [NSRegularExpression regularExpressionWithPattern:
            @"\\b(?:theme|soundtrack|OST)\\b|主题曲|主題曲|片头曲|片頭曲|片尾曲|插曲|印象曲"
            options:NSRegularExpressionCaseInsensitive error:nil];
        version = [NSRegularExpression regularExpressionWithPattern:
            @"\\b(?:live|remix|mix|bootleg|cover|instrumental|acoustic|karaoke|demo|remaster(?:ed)?|piano|sped[ -]+up|slowed)\\b|现场|現場|伴奏|翻唱|混音|加速|降速|重制|重製|片段|剪辑|剪輯|钢琴|鋼琴|纯音乐|純音樂|摇滚|搖滾|爵士|重金属|重金屬|翻奏|演绎|演繹"
            options:NSRegularExpressionCaseInsensitive error:nil];
    });
    // Featured performers are credits, often absent from another catalogue's title.
    // Strip only a trailing feature-credit bracket; live/remix markers stay intact.
    NSString *withoutFeature = [featured stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@""];
    BOOL removedFeature = ![withoutFeature isEqualToString:value];
    value = withoutFeature;
    // Check the whole suffix, including a nested version such as
    // Song - Soundtrack Theme (Instrumental), before removing anything.
    NSTextCheckingResult *match = [suffix firstMatchInString:value options:0 range:NSMakeRange(0, value.length)];
    if (match && match.range.location > 0) {
        NSString *description = [value substringWithRange:match.range];
        if ([theme firstMatchInString:description options:0 range:NSMakeRange(0, description.length)] &&
            ![version firstMatchInString:description options:0 range:NSMakeRange(0, description.length)]) {
            return [[value substringToIndex:match.range.location]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
    }
    return removedFeature ? [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : title;
}

BOOL SGLyricsTitleMatches(NSString *candidate, NSString *wanted) {
    NSString *a = comparable(SGLyricsSearchTitle(candidate)), *b = comparable(SGLyricsSearchTitle(wanted));
    if (!a.length || !b.length) return NO;
    if ([a isEqualToString:b]) return YES;
    // Do not turn "Love" into "Love Story", or a studio recording into a live/remix.
    // A translated prefix/suffix is allowed only when the rest is entirely Han text.
    NSString *longer = a.length > b.length ? a : b, *shorter = a.length > b.length ? b : a;
    NSRange match = [longer rangeOfString:shorter];
    if (match.location == NSNotFound) return NO;
    NSString *rest = [longer stringByReplacingCharactersInRange:match withString:@""];
    if (!rest.length) return YES;
    for (NSUInteger i = 0; i < rest.length; i++) {
        unichar c = [rest characterAtIndex:i];
        if (c < 0x3400 || c > 0x9fff) return NO;
    }
    // Chinese-only substrings are not evidence of a bilingual alias.
    if (SGLyricsContainsHan(shorter)) return NO;
    for (NSString *version in @[@"现场", @"現場", @"伴奏", @"翻唱", @"混音", @"加速", @"降速",
                                @"片段", @"剪辑", @"剪輯", @"演绎", @"演繹", @"钢琴", @"鋼琴", @"纯音乐", @"純音樂", @"重制", @"重製", @"摇滚", @"搖滾", @"爵士", @"重金属", @"重金屬", @"翻奏"]) {
        if ([rest containsString:version]) return NO;
    }
    return YES;
}

BOOL SGLyricsTranslatedTitleCandidate(NSString *candidate, SGLyricsQuery *query) {
    if (!query.referenceLines.count || ![candidate isKindOfClass:NSString.class]) return NO;
    NSString *a = SGLyricsSearchTitle(candidate), *b = SGLyricsSearchTitle(query.title);
    if (SGLyricsContainsHan(a) == SGLyricsContainsHan(b)) return NO;
    static NSRegularExpression *version;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        version = [NSRegularExpression regularExpressionWithPattern:
            @"\\b(?:live|remix|mix|edit|extended|bootleg|cover|instrumental|acoustic|karaoke|demo|piano|remaster(?:ed)?|sped[ -]+up|slowed)\\b|现场|現場|伴奏|翻唱|混音|加速|降速|片段|剪辑|剪輯|重制|重製|钢琴|鋼琴|纯音乐|純音樂|摇滚|搖滾|爵士|重金属|重金屬|翻奏|演绎|演繹"
            options:NSRegularExpressionCaseInsensitive error:nil];
    });
    for (NSString *title in @[a, b]) if ([version firstMatchInString:title options:0 range:NSMakeRange(0, title.length)]) return NO;
    return YES; // Tentative only: the downloaded original lyrics MUST validate it.
}

// An identical/bilingual title can bridge different regional artist credits only
// tentatively. Callers must also check duration and validate the downloaded original.
BOOL SGLyricsTitleEvidenceCandidate(NSString *candidate, SGLyricsQuery *query) {
    return query.referenceLines.count && SGLyricsTitleMatches(candidate, query.title);
}

static NSDictionary<NSString *, NSArray<NSNumber *> *> *textIndex(NSArray<SGKaraokeLine *> *lines) {
    NSMutableDictionary *index = [NSMutableDictionary dictionary];
    [lines enumerateObjectsUsingBlock:^(SGKaraokeLine *line, NSUInteger i, BOOL *stop) {
        NSString *text = comparable(SGKaraokeLineText(line));
        if (!text.length) return;
        NSMutableArray *positions = index[text];
        if (!positions) index[text] = positions = [NSMutableArray array];
        [positions addObject:@(i)];
    }];
    return index;
}

// Infer a small constant offset only from distinct, unique original lines. Repeated chorus
// lines cannot vote for a different verse. Timings are never changed on the displayed lyrics.
static NSInteger recordingOffset(NSArray<SGKaraokeLine *> *target, NSArray<SGKaraokeLine *> *original,
                                 NSDictionary *targetIndex, NSDictionary *originalIndex) {
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    for (NSString *text in originalIndex) {
        NSArray<NSNumber *> *a = originalIndex[text], *b = targetIndex[text];
        if (text.length < 4 || a.count != 1 || b.count != 1) continue;
        NSInteger delta = target[b.firstObject.unsignedIntegerValue].start - original[a.firstObject.unsignedIntegerValue].start;
        if (labs(delta) <= 10000) [offsets addObject:@(delta)];
    }
    if (offsets.count < 2) return 0;
    [offsets sortUsingSelector:@selector(compare:)];
    NSInteger median = offsets[offsets.count / 2].integerValue;
    NSUInteger agreeing = 0;
    for (NSNumber *offset in offsets) if (labs(offset.integerValue - median) <= 750) agreeing++;
    return agreeing >= 2 && agreeing * 2 > offsets.count ? median : 0;
}

// Original source index -> displayed line index, with one-to-one matching and the same
// tolerance for validation and application. Normalize each line once, not in a nested loop.
static NSArray<NSDictionary *> *alignedGroups(NSArray<SGKaraokeLine *> *target, NSArray<SGKaraokeLine *> *original) {
    NSDictionary *targetIndex = textIndex(target), *originalIndex = textIndex(original);
    NSInteger offset = recordingOffset(target, original, targetIndex, originalIndex);
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *spans = [NSMutableDictionary dictionary];
    for (NSUInteger j = 0; j < target.count; j++) {
        NSMutableString *text = [NSMutableString string];
        for (NSUInteger count = 1; count <= 4 && j + count <= target.count; count++) {
            NSString *part = comparable(SGKaraokeLineText(target[j + count - 1]));
            if (!part.length || SGLyricsTimedCredit(SGKaraokeLineText(target[j + count - 1]))) break;
            if (count > 1 && target[j + count - 1].start - target[j + count - 2].start > 15000) break;
            [text appendString:part];
            if (!spans[text]) spans[[text copy]] = [NSMutableArray array];
            [spans[text] addObject:@{@"target": @(j), @"targets": @(count)}];
        }
    }
    NSMutableArray *groups = [NSMutableArray array];
    NSMutableIndexSet *used = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < original.count; i++) {
        NSMutableString *text = [NSMutableString string];
        NSInteger bestDistance = 2501;
        NSDictionary *best = nil;
        for (NSUInteger count = 1; count <= 4 && i + count <= original.count; count++) {
            NSString *part = comparable(SGKaraokeLineText(original[i + count - 1]));
            if (!part.length || SGLyricsTimedCredit(SGKaraokeLineText(original[i + count - 1]))) break;
            if (count > 1 && original[i + count - 1].start - original[i + count - 2].start > 15000) break;
            [text appendString:part];
            for (NSDictionary *span in spans[text]) {
                NSUInteger j = [span[@"target"] unsignedIntegerValue], n = [span[@"targets"] unsignedIntegerValue];
                if ([used intersectsIndexesInRange:NSMakeRange(j, n)]) continue;
                // A group may cross line boundaries, never a different verse or chorus.
                NSInteger distance = labs(target[j].start - original[i].start - offset);
                if (distance < bestDistance) {
                    bestDistance = distance;
                    best = @{@"source": @(i), @"sources": @(count), @"target": @(j), @"targets": @(n), @"characters": @(text.length)};
                }
            }
        }
        if (best) {
            [groups addObject:best];
            [used addIndexesInRange:NSMakeRange([best[@"target"] unsignedIntegerValue], [best[@"targets"] unsignedIntegerValue])];
            i += [best[@"sources"] unsignedIntegerValue] - 1;
        }
    }
    return groups;
}

static NSDictionary<NSNumber *, NSNumber *> *aligned(NSArray<SGKaraokeLine *> *target, NSArray<SGKaraokeLine *> *original) {
    NSMutableDictionary *pairs = [NSMutableDictionary dictionary];
    for (NSDictionary *group in alignedGroups(target, original)) {
        NSUInteger start = [group[@"source"] unsignedIntegerValue], count = [group[@"sources"] unsignedIntegerValue];
        for (NSUInteger i = start; i < start + count; i++) pairs[@(i)] = group[@"target"];
    }
    return pairs;
}

BOOL SGLyricsRecordingMatches(NSArray<SGKaraokeLine *> *target, NSArray<SGKaraokeLine *> *candidate) {
    NSUInteger matched = 0, total = 0;
    for (SGKaraokeLine *line in target) total += comparable(SGKaraokeLineText(line)).length;
    for (NSDictionary *group in alignedGroups(target, candidate)) matched += [group[@"characters"] unsignedIntegerValue];
    // Shared words or two generic chorus lines alone must not establish an alias.
    return matched >= 40 && total > 0 && matched * 2 >= total;
}

NSUInteger SGLyricsOriginalOverlap(NSArray<SGKaraokeLine *> *target, NSString *originalLRC) {
    NSUInteger count = 0;
    for (NSDictionary *group in alignedGroups(target, SGLyricsLinesFromLRC(originalLRC)))
        count += MAX([group[@"sources"] unsignedIntegerValue], [group[@"targets"] unsignedIntegerValue]);
    return count;
}

// Translation LRCs sometimes shift every timestamp by the same amount. Estimate that shift
// from well-separated lines only, where the nearest translated timestamp has one clear owner.
static NSInteger translationOffset(NSArray<SGKaraokeLine *> *original, NSArray<SGKaraokeLine *> *translated,
                                   NSDictionary<NSNumber *, NSNumber *> *pairs) {
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    for (NSUInteger i = 0; i < original.count; i++) {
        if (!pairs[@(i)]) continue;
        NSInteger start = original[i].start;
        if ((i && start - original[i - 1].start < 2500) ||
            (i + 1 < original.count && original[i + 1].start - start < 2500)) continue;
        NSInteger nearest = 2501;
        for (SGKaraokeLine *line in translated) nearest = MIN(nearest, labs(line.start - start));
        if (nearest > 2000) continue;
        for (SGKaraokeLine *line in translated) {
            if (labs(line.start - start) == nearest) { [offsets addObject:@(line.start - start)]; break; }
        }
    }
    if (offsets.count < 2) return 0;
    [offsets sortUsingSelector:@selector(compare:)];
    NSInteger median = offsets[offsets.count / 2].integerValue;
    NSUInteger agreeing = 0;
    for (NSNumber *offset in offsets) if (labs(offset.integerValue - median) <= 350) agreeing++;
    return agreeing >= 2 && agreeing * 2 > offsets.count ? median : 0;
}

NSDictionary<NSNumber *, NSString *> *SGLyricsChineseTranslationMap(NSArray<SGKaraokeLine *> *target,
                                                                   NSString *originalLRC, NSString *translatedLRC) {
    NSArray<SGKaraokeLine *> *original = SGLyricsLinesFromLRC(originalLRC);
    NSArray<SGKaraokeLine *> *translated = SGLyricsLinesFromLRC(translatedLRC);
    NSDictionary<NSNumber *, NSNumber *> *pairs = aligned(target, original);
    NSMutableDictionary *updates = [NSMutableDictionary dictionary];
    NSUInteger matchingLines = 0;
    for (NSDictionary *group in alignedGroups(target, original))
        matchingLines += MAX([group[@"sources"] unsignedIntegerValue], [group[@"targets"] unsignedIntegerValue]);
    if (!target.count || !translated.count || matchingLines < MIN((NSUInteger)2, target.count)) return updates;
    NSInteger offset = translationOffset(original, translated, pairs);
    NSMutableIndexSet *used = [NSMutableIndexSet indexSet];
    NSMutableDictionary<NSString *, NSString *> *repeated = [NSMutableDictionary dictionary];
    NSMutableSet *ambiguous = [NSMutableSet set];
    // Walk in source order so even equally near timestamps have a deterministic owner.
    for (NSUInteger i = 0; i < original.count; i++) {
        if (!pairs[@(i)]) continue;
        SGKaraokeLine *source = original[i];
        NSString *sourceText = comparable(SGKaraokeLineText(source));
        NSInteger distance = offset ? 1201 : 801;
        NSUInteger best = NSNotFound;
        for (NSUInteger j = 0; j < translated.count; j++) {
            if ([used containsIndex:j]) continue;
            NSInteger adjusted = translated[j].start - offset;
            NSInteger gap = labs(adjusted - source.start);
            NSString *text = SGKaraokeLineText(translated[j]);
            // Do not borrow a neighbouring line's translation just because this line is absent.
            BOOL closest = YES;
            if (i && labs(adjusted - original[i - 1].start) < gap) closest = NO;
            if (i + 1 < original.count && labs(adjusted - original[i + 1].start) < gap) closest = NO;
            if (closest && gap < distance && SGLyricsContainsHan(text) && ![comparable(text) isEqualToString:sourceText]) {
                distance = gap; best = j;
            }
        }
        if (best == NSNotFound) continue;
        [used addIndex:best];
        NSString *text = SGKaraokeLineText(translated[best]);
        NSNumber *destination = pairs[@(i)];
        // Several source lines can form one displayed sentence. Keep their translations
        // in source order; never overwrite the earlier half with the later half.
        updates[destination] = updates[destination] ? [updates[destination] stringByAppendingFormat:@"\n%@", text] : text;
        if (repeated[sourceText] && ![repeated[sourceText] isEqualToString:text]) [ambiguous addObject:sourceText];
        repeated[sourceText] = text;
    }
    // Some translation files write a repeated chorus only once. Reuse only unambiguous
    // translations of identical full original lines, never nearby unrelated lines.
    [target enumerateObjectsUsingBlock:^(SGKaraokeLine *line, NSUInteger i, BOOL *stop) {
        NSString *text = comparable(SGKaraokeLineText(line));
        if (!updates[@(i)] && ![ambiguous containsObject:text] && repeated[text]) updates[@(i)] = repeated[text];
    }];
    return updates;
}


NSDictionary<NSNumber *, SGKaraokeLine *> *SGLyricsPronunciationMap(NSArray<SGKaraokeLine *> *target,
    NSArray<SGKaraokeLine *> *original, NSArray<SGKaraokeLine *> *pronunciation) {
    NSMutableDictionary<NSNumber *, SGKaraokeLine *> *updates = [NSMutableDictionary dictionary];
    if (!target.count || !original.count || !pronunciation.count) return updates;
    NSDictionary<NSNumber *, NSNumber *> *pairs = aligned(target, original);
    NSMutableIndexSet *used = [NSMutableIndexSet indexSet];
    NSMutableDictionary<NSNumber *, NSNumber *> *offsets = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < original.count; i++) {
        NSNumber *destination = pairs[@(i)];
        if (!destination) continue;
        NSInteger nearest = 801;
        NSUInteger best = NSNotFound;
        for (NSUInteger j = 0; j < pronunciation.count; j++) {
            if ([used containsIndex:j]) continue;
            NSInteger gap = labs(pronunciation[j].start - original[i].start);
            if (i && labs(pronunciation[j].start - original[i - 1].start) < gap) continue;
            if (i + 1 < original.count && labs(pronunciation[j].start - original[i + 1].start) < gap) continue;
            NSString *text = SGKaraokeLineText(pronunciation[j]);
            BOOL latin = [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"]].location != NSNotFound;
            if (gap < nearest && latin && !SGLyricsContainsHan(text) &&
                ![comparable(text) isEqualToString:comparable(SGKaraokeLineText(original[i]))]) {
                nearest = gap; best = j;
            }
        }
        if (best == NSNotFound) continue;
        [used addIndex:best];
        SGKaraokeLine *of = target[destination.unsignedIntegerValue];
        SGKaraokeLine *spoken = pronunciation[best];
        SGKaraokeLine *attached = updates[destination];
        if (!attached) {
            attached = [SGKaraokeLine new];
            attached.start = of.start; attached.end = of.end; attached.align = of.align;
            attached.timing = spoken.timing;
            attached.words = @[];
            offsets[destination] = @(of.start - original[i].start);
            updates[destination] = attached;
        }
        NSMutableArray<SGKaraokeWord *> *words = [attached.words mutableCopy];
        // Keep timed syllables when available. LRC only supplies line starts, so
        // estimate over the displayed sentence instead of claiming word precision.
        if (spoken.timing != SGKaraokeTimingWords) {
            NSString *text = words.count ? [SGKaraokeLineText(attached) stringByAppendingFormat:@" %@", SGKaraokeLineText(spoken)] : SGKaraokeLineText(spoken);
            SGKaraokeLine *estimated = SGKaraokeEstimatedLines(@[@(of.start), @(MAX(of.end, of.start + 1))], @[text, @""]).firstObject;
            attached.words = estimated.words;
            attached.timing = SGKaraokeTimingLine;
        } else {
            NSInteger offset = offsets[destination].integerValue;
            for (SGKaraokeWord *source in spoken.words) {
                SGKaraokeWord *word = [SGKaraokeWord new];
                word.text = source.text; word.start = source.start + offset; word.end = source.end + offset;
                word.joined = source.joined;
                [words addObject:word];
            }
            attached.words = words;
            attached.end = MAX(of.end, words.lastObject.end);
        }
    }
    return updates;
}
