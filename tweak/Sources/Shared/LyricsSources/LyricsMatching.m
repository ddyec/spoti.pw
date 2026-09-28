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

NSUInteger SGLyricsArtistMatchCount(NSString *candidate, NSString *wanted) {
    NSArray<NSString *> *candidateParts = artistParts(candidate);
    NSUInteger matches = 0;
    for (NSString *wantedPart in artistParts(wanted)) {
        NSString *name = comparable(wantedPart);
        if (name.length < 4) continue;
        for (NSString *candidatePart in candidateParts) {
            NSString *other = comparable(candidatePart);
            if (other.length >= 4 && ([name isEqualToString:other] ||
                                      (MIN(name.length, other.length) >= 6 &&
                                       ([name containsString:other] || [other containsString:name])))) {
                matches++;
                break;
            }
        }
    }
    return matches;
}

BOOL SGLyricsTimedCredit(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return NO;
    static NSRegularExpression *credit;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        credit = [NSRegularExpression regularExpressionWithPattern:
            @"^\\s*(?:作词|作曲|编曲|演唱|原唱|歌手|混音(?:师)?|录音(?:师)?|母带(?:处理工程师)?|制作(?:人)?|出品|策划|监制|发行|合声|和声|原声吉他|电吉他|乐队|词|曲|Lyrics? by|Composed by|Arranged by|Produced by|Vocal(?:ist)?|OP|SP)(?:\\s+[A-Za-z][A-Za-z&/ ]{0,30})?\\s*[:：]"
            options:NSRegularExpressionCaseInsensitive error:nil];
    });
    return [credit firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}

BOOL SGLyricsTitleMatches(NSString *candidate, NSString *wanted) {
    NSString *a = comparable(candidate), *b = comparable(wanted);
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
    for (NSString *version in @[@"现场", @"伴奏", @"翻唱", @"混音", @"加速", @"降速"]) {
        if ([rest containsString:version]) return NO;
    }
    return YES;
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
static NSDictionary<NSNumber *, NSNumber *> *aligned(NSArray<SGKaraokeLine *> *target, NSArray<SGKaraokeLine *> *original) {
    NSDictionary *targetIndex = textIndex(target), *originalIndex = textIndex(original);
    NSInteger offset = recordingOffset(target, original, targetIndex, originalIndex);
    NSMutableDictionary *pairs = [NSMutableDictionary dictionary];
    NSMutableIndexSet *used = [NSMutableIndexSet indexSet];
    [original enumerateObjectsUsingBlock:^(SGKaraokeLine *source, NSUInteger i, BOOL *stop) {
        NSString *text = comparable(SGKaraokeLineText(source));
        NSArray<NSNumber *> *candidates = targetIndex[text];
        NSInteger bestDistance = 2501;
        NSNumber *best = nil;
        for (NSNumber *candidate in candidates) {
            NSUInteger j = candidate.unsignedIntegerValue;
            if ([used containsIndex:j]) continue;
            NSInteger distance = labs(target[j].start - source.start - offset);
            if (distance < bestDistance) { best = candidate; bestDistance = distance; }
        }
        if (best) { pairs[@(i)] = best; [used addIndex:best.unsignedIntegerValue]; }
    }];
    return pairs;
}

NSUInteger SGLyricsOriginalOverlap(NSArray<SGKaraokeLine *> *target, NSString *originalLRC) {
    return aligned(target, SGLyricsLinesFromLRC(originalLRC)).count;
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
    if (!target.count || !translated.count || pairs.count < MIN((NSUInteger)2, target.count)) return updates;
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
        updates[pairs[@(i)]] = text;
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
