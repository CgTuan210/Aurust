#import "Lyrics.h"
#import "Shared/AdBlock/Protobuf.h"
#import <objc/runtime.h>

@implementation SGKaraokeWord
@end

@implementation SGLockLyricsCue
@end

@implementation SGKaraokeLine
- (id)copyWithZone:(NSZone *)zone {
    SGKaraokeLine *copy = [SGKaraokeLine new];
    copy.words = _words;
    copy.start = _start;
    copy.end = _end;
    copy.voice = _voice;
    copy.align = _align;
    copy.timing = _timing;
    copy.backing = _backing;
    copy.pronunciation = _pronunciation;
    copy.translation = _translation;
    copy.translationMade = _translationMade;
    return copy;
}
@end

// A line is sung at about this pace and never takes longer than the gap to the next one. A slow
// line gets at least 60 % of its gap, but not more than 1.8x the estimate, so a long instrumental
// after it does not stretch its last word across the break.
static const NSInteger kLineBaseMs = 350, kMsPerLetter = 75;
static const double kMinGapShare = 0.6, kMaxStretch = 1.8;
// Added to every word's letters, for the breath between words and so a one-letter word still shows.
static const NSUInteger kWordWeight = 2;
// A syllable of an unspaced script is one character but a whole beat, so it counts for this many
// letters; without it a Japanese line reads as a handful of letters and its sweep finishes early.
static const NSUInteger kSyllableLetters = 3;

static const NSInteger kLockFastGapMs = 1100, kLockOverlapGapMs = 350, kLockMaxSpanMs = 2200;
static const NSUInteger kLockMaxChars = 84, kLockOverlapMaxChars = 112;
static char kLockCuesKey;

#pragma mark - the model

NSString *SGKaraokeLineText(SGKaraokeLine *line) {
    NSMutableString *text = [NSMutableString string];
    for (SGKaraokeWord *word in line.words) {
        if (text.length && !word.joined) [text appendString:@" "];
        [text appendString:word.text ?: @""];
    }
    return text;
}

NSInteger SGKaraokeSungEnd(SGKaraokeLine *line) {
    return line.backing ? MAX(line.end, line.backing.end) : line.end;
}

NSInteger SGKaraokeLeadLine(NSArray<SGKaraokeLine *> *lines, NSInteger ms) {
    NSInteger last = -1;
    while (last + 1 < (NSInteger)lines.count && lines[(NSUInteger)last + 1].start <= ms) last++;
    for (NSInteger i = 0; i < last; i++) {
        if (SGKaraokeSungEnd(lines[(NSUInteger)i]) > ms) return i;
    }
    return last;
}

NSArray<SGLockLyricsCue *> *SGLockLyricsCues(NSArray<SGKaraokeLine *> *lines) {
    if (!lines.count || SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) return nil;
    NSArray<SGLockLyricsCue *> *cached = objc_getAssociatedObject(lines, &kLockCuesKey);
    if (cached) return cached;

    NSMutableArray<SGLockLyricsCue *> *cues = [NSMutableArray arrayWithCapacity:lines.count];
    NSUInteger count = lines.count, i = 0;
    while (i < count) {
        NSString *firstText = SGKaraokeLineText(lines[i]);
        if (!firstText.length) {
            i++;
            continue;
        }
        NSUInteger first = i, last = i;
        NSInteger start = lines[first].start;
        NSInteger sungEnd = MAX(SGKaraokeSungEnd(lines[first]), start);
        NSMutableString *joined = [firstText mutableCopy];

        if (last + 1 < count) {
            SGKaraokeLine *next = lines[last + 1];
            NSString *nextText = SGKaraokeLineText(next);
            if (nextText.length) {
                NSInteger gap = next.start - start;
                NSInteger nextEnd = MAX(SGKaraokeSungEnd(next), next.start);
                NSInteger afterSpan = (last + 2 < count ? lines[last + 2].start : nextEnd) - start;
                NSUInteger mergedLength = joined.length + 1 + nextText.length;
                BOOL overlap = gap < kLockOverlapGapMs && mergedLength <= kLockOverlapMaxChars;
                BOOL rapid = gap < kLockFastGapMs && afterSpan <= kLockMaxSpanMs && mergedLength <= kLockMaxChars;
                if (overlap || rapid) {
                    [joined appendFormat:@"\n%@", nextText];
                    sungEnd = MAX(sungEnd, nextEnd);
                    last++;
                }
            }
        }

        SGLockLyricsCue *cue = [SGLockLyricsCue new];
        cue.text = joined;
        cue.firstLineText = firstText;
        cue.start = start;
        cue.sungEnd = sungEnd;
        cue.firstIndex = first;
        cue.lastIndex = last;
        [cues addObject:cue];
        i = last + 1;
    }

    NSArray<SGLockLyricsCue *> *result = [cues copy];
    objc_setAssociatedObject(lines, &kLockCuesKey, result, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

NSInteger SGLockLyricsCueAt(NSArray<SGLockLyricsCue *> *cues, NSInteger ms, NSInteger breakMs,
                            BOOL *resting, NSInteger *nextMs) {
    if (!cues.count) {
        if (resting) *resting = YES;
        if (nextMs) *nextMs = NSIntegerMax;
        return -1;
    }
    if (ms < cues[0].start) {
        if (resting) *resting = YES;
        if (nextMs) *nextMs = cues[0].start;
        return -1;
    }

    NSUInteger lo = 0, hi = cues.count - 1;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo + 1) / 2;
        if (cues[mid].start <= ms) lo = mid;
        else hi = mid - 1;
    }

    NSInteger idx = (NSInteger)lo;
    for (NSInteger k = MAX((NSInteger)0, (NSInteger)lo - 3); k < (NSInteger)lo; k++) {
        if (cues[(NSUInteger)k].sungEnd > ms) {
            idx = k;
            break;
        }
    }

    SGLockLyricsCue *cue = cues[(NSUInteger)idx];
    if (idx < (NSInteger)lo) {
        if (resting) *resting = NO;
        if (nextMs) *nextMs = cue.sungEnd;
        return idx;
    }

    BOOL hasNext = (idx + 1 < (NSInteger)cues.count);
    NSInteger nextStart = hasNext ? cues[(NSUInteger)(idx + 1)].start : NSIntegerMax;
    NSInteger restStart = MAX(cue.sungEnd, cue.start) + breakMs;
    BOOL hasBreak = !hasNext || (nextStart - MAX(cue.sungEnd, cue.start) >= 2 * breakMs);
    if (hasBreak) {
        if (ms < restStart) {
            if (resting) *resting = NO;
            if (nextMs) *nextMs = restStart;
        } else {
            if (resting) *resting = YES;
            if (nextMs) *nextMs = nextStart;
        }
    } else {
        if (resting) *resting = NO;
        if (nextMs) *nextMs = nextStart;
    }
    return idx;
}

// Japanese, Chinese and Korean, and the punctuation set with them. Kana and Hangul are listed as
// well as the ideographs: a line of either is written without spaces just the same.
static NSCharacterSet *unspacedScript(void) {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *building = [NSMutableCharacterSet new];
        [building addCharactersInRange:NSMakeRange(0x3000, 0x40)];    // CJK punctuation
        [building addCharactersInRange:NSMakeRange(0x3040, 0xC0)];    // hiragana and katakana
        [building addCharactersInRange:NSMakeRange(0x3400, 0x9C0)];   // ideographs, extension A
        [building addCharactersInRange:NSMakeRange(0x4E00, 0x5200)];  // ideographs
        [building addCharactersInRange:NSMakeRange(0xAC00, 0x2BA4)];  // hangul syllables
        [building addCharactersInRange:NSMakeRange(0xF900, 0x200)];   // compatibility ideographs
        [building addCharactersInRange:NSMakeRange(0xFF66, 0x38)];    // halfwidth katakana
        set = [building copy];
    });
    return set;
}

BOOL SGKaraokeUnspacedScript(NSString *text) {
    return text.length && [text rangeOfCharacterFromSet:unspacedScript()].location != NSNotFound;
}

// Thai, Lao, Burmese and Khmer, which leave no space between words either, but whose syllables are a
// letter with marks around it: they are split where the system's dictionary finds a word, not a
// character at a time.
static BOOL dictionaryScript(NSString *text) {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *building = [NSMutableCharacterSet new];
        [building addCharactersInRange:NSMakeRange(0x0E00, 0x100)];   // Thai and Lao
        [building addCharactersInRange:NSMakeRange(0x1000, 0xA0)];    // Myanmar
        [building addCharactersInRange:NSMakeRange(0x1780, 0x80)];    // Khmer
        set = [building copy];
    });
    return [text rangeOfCharacterFromSet:set].location != NSNotFound;
}

void SGKaraokeAlignVoices(NSArray<SGKaraokeLine *> *lines) {
    NSMutableArray<NSString *> *heard = [NSMutableArray array];
    for (SGKaraokeLine *line in lines) {
        if (!line.voice.length || [heard containsObject:line.voice]) continue;
        [heard addObject:line.voice];
    }
    if (heard.count < 2) return;   // one voice, or none named: every line leads, as it already does
    NSString *trailing = heard[1];
    for (SGKaraokeLine *line in lines) {
        line.align = [line.voice isEqualToString:trailing] ? SGKaraokeAlignTrailing : SGKaraokeAlignLeading;
        line.backing.align = line.align;
    }
}

#pragma mark - estimating the words inside a line

static NSUInteger lettersIn(NSString *text) {
    __block NSUInteger count = 0;
    NSCharacterSet *letters = NSCharacterSet.alphanumericCharacterSet, *unspaced = unspacedScript();
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *piece, NSRange a, NSRange b, BOOL *stop) {
        if ([unspaced characterIsMember:[piece characterAtIndex:0]]) count += kSyllableLetters;
        else if ([letters characterIsMember:[piece characterAtIndex:0]]) count++;
    }];
    return count;
}

static void appendPiece(NSMutableArray<SGKaraokeWord *> *pieces, NSString *text) {
    if (!text.length) return;
    SGKaraokeWord *word = [SGKaraokeWord new];
    word.text = text;
    [pieces addObject:word];
}

// A token cut at the start of every word the system finds in it, so the pieces still make up the
// whole token: whatever comes between two words stays with the first, whatever comes before the
// first word with it.
static void appendWords(NSMutableArray<SGKaraokeWord *> *pieces, NSString *token) {
    NSMutableArray<NSNumber *> *cuts = [NSMutableArray arrayWithObject:@0];
    __block BOOL first = YES;
    [token enumerateSubstringsInRange:NSMakeRange(0, token.length)
                              options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
                           usingBlock:^(NSString *word, NSRange range, NSRange enclosing, BOOL *stop) {
        if (!first && range.location > cuts.lastObject.unsignedIntegerValue) [cuts addObject:@(range.location)];
        first = NO;
    }];
    [cuts addObject:@(token.length)];
    for (NSUInteger i = 0; i + 1 < cuts.count; i++) {
        NSUInteger from = cuts[i].unsignedIntegerValue;
        appendPiece(pieces, [token substringWithRange:NSMakeRange(from, cuts[i + 1].unsignedIntegerValue - from)]);
    }
}

// The line split into what the sweep lights one at a time: words where the script spaces them, a
// syllable at a time where it does not, so a Japanese line sweeps instead of lighting up whole, and
// the dictionary's words in Thai and its neighbors, so a long line wraps between them.
// Everything a token holds past its first piece is joined to the one before it.
static NSArray<SGKaraokeWord *> *piecesOf(NSString *line) {
    NSMutableArray<SGKaraokeWord *> *pieces = [NSMutableArray array];
    for (NSString *token in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (!token.length) continue;
        NSUInteger first = pieces.count;
        if (!SGKaraokeUnspacedScript(token)) {
            if (dictionaryScript(token)) appendWords(pieces, token);
            else appendPiece(pieces, token);
        } else {
            // Latin letters or digits caught between two syllables stay together as one piece.
            NSMutableString *run = [NSMutableString string];
            NSCharacterSet *unspaced = unspacedScript();
            [token enumerateSubstringsInRange:NSMakeRange(0, token.length)
                                      options:NSStringEnumerationByComposedCharacterSequences
                                   usingBlock:^(NSString *piece, NSRange a, NSRange b, BOOL *stop) {
                if (![unspaced characterIsMember:[piece characterAtIndex:0]]) {
                    [run appendString:piece];
                    return;
                }
                appendPiece(pieces, [run copy]);
                [run setString:@""];
                appendPiece(pieces, piece);
            }];
            appendPiece(pieces, [run copy]);
        }
        for (NSUInteger i = first + 1; i < pieces.count; i++) pieces[i].joined = YES;
    }
    return pieces;
}

static BOOL isBreak(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length == 0 || [trimmed isEqualToString:@"♪"];
}

// gap is the time to the next line, 0 for the last one.
static SGKaraokeLine *timedLine(NSString *text, NSInteger start, NSInteger gap) {
    NSArray<SGKaraokeWord *> *words = piecesOf(text);
    NSUInteger weight = 0, letters = 0;
    for (SGKaraokeWord *word in words) {
        NSUInteger count = lettersIn(word.text);
        letters += count;
        weight += count + kWordWeight;
    }
    NSInteger estimate = kLineBaseMs + (NSInteger)letters * kMsPerLetter;
    NSInteger sung = estimate;
    if (gap > 0) {
        sung = MAX((NSInteger)(gap * kMinGapShare), estimate);
        sung = MIN(sung, (NSInteger)(estimate * kMaxStretch));
        sung = MIN(sung, gap);
    }

    double at = start;
    for (SGKaraokeWord *word in words) {
        word.start = (NSInteger)at;
        at += weight ? (double)sung * (lettersIn(word.text) + kWordWeight) / weight : 0;
        word.end = (NSInteger)at;
    }
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    line.start = start;
    line.end = start + sung;
    line.timing = SGKaraokeTimingLine;
    return line;
}

NSArray<SGKaraokeLine *> *SGKaraokeEstimatedLines(NSArray<NSNumber *> *starts, NSArray<NSString *> *texts) {
    // A line listed out of time order is given the gap to the line sung after it, not the one listed after
    // it. The lines stay in the order they were listed: a source pairs them up with its own by position, and
    // the lines are put in time order where they are kept (SGKaraokeInTimeOrder).
    NSUInteger count = MIN(texts.count, starts.count);
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        if (isBreak(texts[i])) continue;
        NSInteger start = starts[i].integerValue, gap = 0;
        for (NSUInteger j = 0; j < count; j++) {   // ponytail: quadratic, a song's few hundred lines at most
            NSInteger after = starts[j].integerValue - start;
            if (after > 0 && (!gap || after < gap)) gap = after;
        }
        [lines addObject:timedLine(texts[i], start, gap)];
    }
    return lines.count ? lines : nil;
}

NSArray<SGKaraokeLine *> *SGKaraokeStaticLines(NSArray<NSString *> *texts) {
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (NSString *text in texts) {
        if (![text isKindOfClass:NSString.class] || isBreak(text)) continue;
        NSArray<SGKaraokeWord *> *words = piecesOf(text);
        if (!words.count) continue;
        SGKaraokeLine *line = [SGKaraokeLine new];
        line.words = words;
        line.timing = SGKaraokeTimingNone;
        [lines addObject:line];
    }
    return lines.count ? lines : nil;
}

SGKaraokeTiming SGKaraokeLinesTiming(NSArray<SGKaraokeLine *> *lines) {
    SGKaraokeTiming finest = SGKaraokeTimingNone;
    for (SGKaraokeLine *line in lines) finest = MIN(finest, line.timing);
    return finest;
}

// Some sources list a line out of its place in time: a chorus written once with its repeats after it,
// or one voice's lines listed after the other's. Everything that reads lines takes them in time order.
NSArray<SGKaraokeLine *> *SGKaraokeInTimeOrder(NSArray<SGKaraokeLine *> *lines) {
    for (NSUInteger i = 1; i < lines.count; i++) {
        if (lines[i].start >= lines[i - 1].start) continue;
        return [lines sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(SGKaraokeLine *a, SGKaraokeLine *b) {
            return a.start < b.start ? NSOrderedAscending : a.start > b.start ? NSOrderedDescending : NSOrderedSame;
        }];
    }
    return lines;
}

#pragma mark - Spotify's own bodies

// Lyrics { 1 data: { 1 time_synchronized, 2 repeated line: { 1 offset_ms, 2 content } }, 2 colors }
// Not time_synchronized, the lines are plain text and their offsets all 0. The flag alone is not
// trusted: Spotify's page body has come without it for lines its JSON calls LINE_SYNCED, so any
// offset past 0 counts as timed too.
static NSArray<SGKaraokeLine *> *fromProtobuf(NSData *body) {
    SGPBField *data = SGPBFirst(SGPBParse(body), 1);
    if (data.wire != 2) return nil;
    NSArray<SGPBField *> *fields = SGPBParse(data.payload);
    BOOL synced = SGPBFirst(fields, 1).varint != 0;
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (SGPBField *field in fields) {
        if (field.number != 2 || field.wire != 2) continue;
        NSArray<SGPBField *> *line = SGPBParse(field.payload);
        int32_t start = (int32_t)SGPBFirst(line, 1).varint;
        if (start > 0) synced = YES;
        [starts addObject:@(start)];
        [texts addObject:SGPBText(SGPBFirst(line, 2)) ?: @""];
    }
    return synced ? SGKaraokeEstimatedLines(starts, texts) : SGKaraokeStaticLines(texts);
}

// { "lyrics": { "syncType": "LINE_SYNCED", "lines": [ { "startTimeMs": "1234", "words": "..." } ] } },
// or "UNSYNCED" with every start 0.
static NSArray<SGKaraokeLine *> *fromJSON(NSData *body) {
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSDictionary *lyrics = [root isKindOfClass:NSDictionary.class] ? root[@"lyrics"] : nil;
    if (![lyrics isKindOfClass:NSDictionary.class]) return nil;
    BOOL synced = [lyrics[@"syncType"] isEqual:@"LINE_SYNCED"];
    if (!synced && ![lyrics[@"syncType"] isEqual:@"UNSYNCED"]) return nil;
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *line in lyrics[@"lines"]) {
        if (![line isKindOfClass:NSDictionary.class]) continue;
        id words = line[@"words"];
        [starts addObject:@([line[@"startTimeMs"] integerValue])];
        [texts addObject:[words isKindOfClass:NSString.class] ? words : @""];
    }
    return synced ? SGKaraokeEstimatedLines(starts, texts) : SGKaraokeStaticLines(texts);
}

NSArray<SGKaraokeLine *> *SGKaraokeLinesFromBody(NSData *body) {
    if (!body.length) return nil;
    return ((const uint8_t *)body.bytes)[0] == '{' ? fromJSON(body) : fromProtobuf(body);
}
