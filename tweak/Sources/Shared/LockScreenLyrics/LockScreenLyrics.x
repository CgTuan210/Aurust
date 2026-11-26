// Spotify's now playing info passes through with the artist swapped for the current lyric segment, and an
// event-driven strict timer wakes at the exact next transition rather than polling four times a second.
// Spotify itself only ever sees its own dictionary back.
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "LockScreenLyrics.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/NowPlayingExtras.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Headers/SPTPlayer.h"

static const NSInteger kBreakMs = 4000;
static const NSInteger kRapidMergeMs = 750;
static const NSInteger kMinSegmentMs = 450;
static const NSUInteger kMaxChars = 32;
static const NSTimeInterval kMaxSleep = 15.0;

@interface SGArtistLyricSegment : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSInteger start, end;
@end

@implementation SGArtistLyricSegment
@end

static char kArtistSegmentsKey;
static NSObject *sg_lock;
static NSDictionary *sg_spotifyInfo;
static CFAbsoluteTime sg_spotifyInfoAt;
static NSString *sg_shownLine;
static BOOL sg_resending;
static dispatch_source_t sg_timer;

static BOOL artistLyricsOn(void);
static void tick(void);
static void cancelTimer(void);
static void scheduleAfter(NSTimeInterval seconds);

static NSString *textOf(NSArray<SGKaraokeWord *> *words) {
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    return SGKaraokeLineText(line);
}

// Splits a line longer than the artist row holds into balanced pieces rather than a full one and a stub.
static NSArray<NSArray<SGKaraokeWord *> *> *piecesOf(SGKaraokeLine *line) {
    NSUInteger length = textOf(line.words).length;
    NSUInteger count = MAX((length + kMaxChars - 1) / kMaxChars, 1);
    NSUInteger target = (length + count - 1) / count;
    NSMutableArray<NSArray<SGKaraokeWord *> *> *pieces = [NSMutableArray array];
    NSMutableArray<SGKaraokeWord *> *piece = [NSMutableArray array];
    NSUInteger pieceLength = 0;
    for (SGKaraokeWord *word in line.words) {
        NSUInteger gap = pieceLength && !word.joined ? 1 : 0;
        NSUInteger withWord = pieceLength ? pieceLength + gap + word.text.length : word.text.length;
        if (pieceLength && (withWord > kMaxChars || (withWord > target && pieces.count + 1 < count))) {
            [pieces addObject:piece];
            piece = [NSMutableArray array];
            withWord = word.text.length;
        }
        [piece addObject:word];
        pieceLength = withWord;
    }
    if (piece.count) [pieces addObject:piece];
    return pieces;
}

// Precomputes non-overlapping [start, end) display segments once per track: merges rapid short phrases
// ("A · B") and enforces a minimum dwell per piece so MPNowPlayingInfoCenter is never spammed during rap.
static NSArray<SGArtistLyricSegment *> *segmentsForLines(NSArray<SGKaraokeLine *> *lines) {
    if (!lines.count || SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) return nil;
    NSArray<SGArtistLyricSegment *> *cached = objc_getAssociatedObject(lines, &kArtistSegmentsKey);
    if (cached) return cached;

    NSMutableArray<SGArtistLyricSegment *> *raw = [NSMutableArray arrayWithCapacity:lines.count];
    NSUInteger count = lines.count, i = 0;
    while (i < count) {
        SGKaraokeLine *line = lines[i];
        NSString *full = SGKaraokeLineText(line);
        if (!full.length) {
            i++;
            continue;
        }
        NSInteger lineStart = line.start;
        NSInteger sungEnd = MAX(SGKaraokeSungEnd(line), lineStart);
        NSUInteger lastIdx = i;

        // Combine two rapid short lines into one compact artist-row phrase when they fit together.
        if (i + 1 < count) {
            SGKaraokeLine *next = lines[i + 1];
            NSString *nextText = SGKaraokeLineText(next);
            if (nextText.length && next.start - lineStart < kRapidMergeMs
                && full.length + 3 + nextText.length <= kMaxChars) {
                full = [NSString stringWithFormat:@"%@ · %@", full, nextText];
                sungEnd = MAX(sungEnd, MAX(SGKaraokeSungEnd(next), next.start));
                lastIdx = i + 1;
            }
        }

        BOOL hasNext = (lastIdx + 1 < count);
        NSInteger nextLineStart = hasNext ? lines[lastIdx + 1].start : NSIntegerMax;
        NSInteger restEnd = sungEnd + kBreakMs;
        NSInteger windowEnd = (!hasNext || nextLineStart - sungEnd >= 2 * kBreakMs)
            ? restEnd : MAX(nextLineStart, lineStart + kMinSegmentMs);

        if (full.length <= kMaxChars || lastIdx > i) {
            SGArtistLyricSegment *seg = [SGArtistLyricSegment new];
            seg.text = full;
            seg.start = lineStart;
            seg.end = windowEnd;
            [raw addObject:seg];
        } else {
            NSArray<NSArray<SGKaraokeWord *> *> *pieces = piecesOf(line);
            for (NSUInteger p = 0; p < pieces.count; p++) {
                NSString *pieceText = textOf(pieces[p]);
                if (!pieceText.length) continue;
                SGArtistLyricSegment *seg = [SGArtistLyricSegment new];
                seg.text = pieceText;
                seg.start = p == 0 ? lineStart : MAX(pieces[p].firstObject.start, lineStart);
                seg.end = (p + 1 < pieces.count) ? MAX(pieces[p + 1].firstObject.start, seg.start + kMinSegmentMs) : windowEnd;
                [raw addObject:seg];
            }
        }
        i = lastIdx + 1;
    }

    // Enforce strictly non-overlapping intervals [start, end) with minimum dwell.
    NSMutableArray<SGArtistLyricSegment *> *clean = [NSMutableArray arrayWithCapacity:raw.count];
    for (NSUInteger k = 0; k < raw.count; k++) {
        SGArtistLyricSegment *cur = raw[k];
        if (clean.count) {
            SGArtistLyricSegment *prev = clean.lastObject;
            if (cur.start < prev.start + kMinSegmentMs) cur.start = prev.start + kMinSegmentMs;
            if (prev.end > cur.start) prev.end = cur.start;
            if (prev.end <= prev.start) [clean removeLastObject];
        }
        if (cur.end <= cur.start) cur.end = cur.start + kMinSegmentMs;
        [clean addObject:cur];
    }

    NSArray<SGArtistLyricSegment *> *result = [clean copy];
    objc_setAssociatedObject(lines, &kArtistSegmentsKey, result, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

static double playbackRate(NSDictionary *info) {
    NSNumber *reported = info[MPNowPlayingInfoPropertyPlaybackRate];
    return reported ? reported.doubleValue : 1.0;
}

static double elapsedAt(NSDictionary *info, CFAbsoluteTime reportedAt, CFAbsoluteTime now) {
    return [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue] + playbackRate(info) * (now - reportedAt);
}

static BOOL playingBy(NSDictionary *info) {
    NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate];
    return !rate || rate.doubleValue > 0;
}

static NSString *lineFor(NSDictionary *info, double elapsed, NSInteger *nextMs) {
    if (nextMs) *nextMs = NSIntegerMax;
    SPTPlayerState *state = [(id<SPTPlayer>)SGKaraokePlayer() state];
    NSInteger position = (NSInteger)(elapsed * 1000) - SGKaraokeDelayMs();
    if (!SGNowPlayingTitlesMatch(state.track.trackTitle, info[MPMediaItemPropertyTitle])) {
        if (nextMs) *nextMs = position + 400;
        return nil;
    }
    NSString *trackID = SGKaraokePlayingTrack();
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
    if (!lines) {
        SGKaraokeRequestLyrics(trackID);
        if (nextMs) *nextMs = position + 500;
        return nil;
    }
    NSArray<SGArtistLyricSegment *> *segs = segmentsForLines(lines);
    if (!segs.count) return nil;

    if (position < segs[0].start) {
        if (nextMs) *nextMs = segs[0].start;
        return nil;
    }

    NSUInteger lo = 0, hi = segs.count - 1;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo + 1) / 2;
        if (segs[mid].start <= position) lo = mid;
        else hi = mid - 1;
    }

    SGArtistLyricSegment *seg = segs[lo];
    if (position < seg.end) {
        if (nextMs) *nextMs = seg.end;
        return seg.text;
    }
    if (lo + 1 < segs.count && nextMs) {
        *nextMs = segs[lo + 1].start;
    }
    return nil;
}

static NSDictionary *withLine(NSDictionary *info, NSString *line, double elapsed) {
    NSMutableDictionary *shown = [info mutableCopy];
    if (line) shown[MPMediaItemPropertyArtist] = line;
    shown[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed);
    return shown;
}

static void cancelTimer(void) {
    if (!sg_timer) return;
    dispatch_source_cancel(sg_timer);
    sg_timer = nil;
}

static void scheduleAfter(NSTimeInterval seconds) {
    if (!(seconds > 0) || !isfinite(seconds)) {
        cancelTimer();
        return;
    }
    NSTimeInterval clamped = MIN(MAX(seconds, 0.03), kMaxSleep);
    if (!sg_timer) {
        sg_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sg_timer, ^{ tick(); });
        dispatch_resume(sg_timer);
    }
    uint64_t delta = (uint64_t)(clamped * NSEC_PER_SEC);
    dispatch_source_set_timer(sg_timer, dispatch_time(DISPATCH_TIME_NOW, delta), DISPATCH_TIME_FOREVER, 8 * NSEC_PER_MSEC);
}

static void scheduleNext(NSDictionary *info, double elapsed, NSInteger nextMs) {
    if (!info || !playingBy(info) || !info[MPNowPlayingInfoPropertyElapsedPlaybackTime] || nextMs == NSIntegerMax) {
        cancelTimer();
        return;
    }
    NSInteger position = (NSInteger)(elapsed * 1000) - SGKaraokeDelayMs();
    double rate = MAX(playbackRate(info), 0.1);
    double wait = MAX((nextMs - position) / (1000.0 * rate), 0) + 0.008;
    scheduleAfter(wait);
}

static void tick(void) {
    if (!artistLyricsOn()) {
        sg_shownLine = nil;
        cancelTimer();
        return;
    }
    NSDictionary *info;
    CFAbsoluteTime reportedAt;
    @synchronized (sg_lock) {
        info = sg_spotifyInfo;
        reportedAt = sg_spotifyInfoAt;
    }
    if (!info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) {
        cancelTimer();
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double elapsed = elapsedAt(info, reportedAt, now);
    NSInteger nextMs = NSIntegerMax;
    NSString *line = lineFor(info, elapsed, &nextMs);
    scheduleNext(info, elapsed, nextMs);
    if (line == sg_shownLine || [line isEqualToString:sg_shownLine]) return;
    sg_shownLine = line;
    sg_resending = YES;
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = withLine(info, line, elapsed);
    sg_resending = NO;
}

static void refreshArtistLyrics(void) {
    NSDictionary *info;
    CFAbsoluteTime reportedAt;
    @synchronized (sg_lock) {
        info = sg_spotifyInfo;
        reportedAt = sg_spotifyInfoAt;
    }
    BOOL enabled = artistLyricsOn();
    BOOL playing = info && playingBy(info) && info[MPNowPlayingInfoPropertyElapsedPlaybackTime] != nil;
    if (!enabled) {
        cancelTimer();
        sg_shownLine = nil;
        if (info) {
            sg_resending = YES;
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo =
                withLine(info, nil, elapsedAt(info, reportedAt, CFAbsoluteTimeGetCurrent()));
            sg_resending = NO;
        }
    } else if (playing) {
        tick();
    } else {
        cancelTimer();
    }
}

static BOOL artistLyricsOn(void) {
    BOOL enabled = SGFlag(SGKeyLockScreenLyrics, NO);
    if (enabled && SGLockScreenCanvasLyricsEnabled() && SGEnabled(SGKeyLockScreenExclusiveLyrics)) return NO;
    return enabled;
}

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    if (sg_resending) {
        %orig;
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @synchronized (sg_lock) {
        sg_spotifyInfo = info;
        sg_spotifyInfoAt = now;
    }
    BOOL playing = playingBy(info) && info[MPNowPlayingInfoPropertyElapsedPlaybackTime] != nil;
    if (!artistLyricsOn()) {
        if (!NSThread.isMainThread) {
            dispatch_async(dispatch_get_main_queue(), ^{
                sg_shownLine = nil;
                cancelTimer();
            });
        } else {
            sg_shownLine = nil;
            cancelTimer();
        }
        %orig;
        return;
    }
    if (!NSThread.isMainThread || !info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_shownLine = nil;
            if (playing) tick();
            else cancelTimer();
        });
        %orig;
        return;
    }
    double elapsed = elapsedAt(info, now, now);
    NSInteger nextMs = NSIntegerMax;
    NSString *line = lineFor(info, elapsed, &nextMs);
    sg_shownLine = line;
    scheduleNext(info, elapsed, nextMs);
    %orig(withLine(info, line, elapsed));
}

- (NSDictionary *)nowPlayingInfo {
    NSDictionary *info;
    @synchronized (sg_lock) {
        info = sg_spotifyInfo;
    }
    return info ?: %orig;
}
%end

%ctor {
    sg_lock = [NSObject new];
    %init;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ refreshArtistLyrics(); });
    }];
    [center addObserverForName:SGKaraokeLinesDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
        if (artistLyricsOn()) tick();
    }];
    [center addObserverForName:SGPlayerClockDidJumpNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
        if (artistLyricsOn()) tick();
    }];
    [center addObserverForName:SGSpeedPitchChangedNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
        if (artistLyricsOn()) tick();
    }];
    if (artistLyricsOn()) SGLog(@"lock screen lyrics: artist name replaced");
}
