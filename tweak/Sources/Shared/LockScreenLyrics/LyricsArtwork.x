// The lock screen's full-screen artwork as the lyrics, a clip per cue (SGLyricsClip.h draws it). An
// event-driven strict timer wakes at each exact transition rather than polling, groups rapid-fire lines
// into readable couplets, and cancels superseded encodes mid-clip so fast songs never backlog CPU work.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "LockScreenLyrics.h"
#import "SGLyricsClip.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/NowPlayingExtras.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"

static const NSInteger kBreakMs = 4000;
static const double kShortest = 0.8, kLongest = 6.0;
static const NSTimeInterval kMaxSleep = 15.0;

@interface SGLockLine : NSObject
@property (nonatomic, copy) NSString *previous, *line, *next;
@property (nonatomic) UIImage *cover;
@property (nonatomic) SGLyricsClipStyle style;
@property (nonatomic) NSURL *motion;
@property (nonatomic) double from, seconds;
@end

@implementation SGLockLine
@end

static dispatch_source_t sg_timer;
static NSString *sg_motionURI;
static NSURL *sg_motion;
static NSMutableSet<NSString *> *sg_failedMotion;
static NSString *sg_track;
static UIImage *sg_cover;
static NSString *sg_shownID, *sg_aheadID;
static NSObject *sg_lock;
static dispatch_queue_t sg_queue;
static dispatch_queue_t sg_previewQueue;
static CFAbsoluteTime sg_askedAt, sg_previewAskedAt;
static NSCache<NSString *, UIImage *> *sg_previews;

static void tick(void);
static void cancelTimer(void);
static void scheduleAfter(NSTimeInterval seconds);

static BOOL motionFailed(NSURL *file) {
    @synchronized (sg_failedMotion) {
        return [sg_failedMotion containsObject:file.path];
    }
}

static void markMotionFailed(NSURL *file, NSString *artworkID) {
    @synchronized (sg_failedMotion) {
        if ([sg_failedMotion containsObject:file.path]) return;
        [sg_failedMotion addObject:file.path];
    }
    SGLog(@"lock lyrics: %@ could not be composited for %@; using the cover", file.lastPathComponent, artworkID);
}

static NSURL *folder(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:@"spoti.pw/Lyrics" isDirectory:YES];
}

// The blurred cover, made once per cover and shared by both queues; the caller releases it.
static CGImageRef copyBackdropFor(UIImage *cover, CGSize size) {
    static id made;
    static CGImageRef backdrop;
    static CGSize madeSize;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        id key = cover ?: NSNull.null;
        if (!backdrop || made != key || !CGSizeEqualToSize(madeSize, size)) {
            CGImageRelease(backdrop);
            backdrop = SGLyricsClipBackdrop(cover.CGImage, size);
            made = key;
            madeSize = size;
        }
        return CGImageRetain(backdrop);
    }
}

static BOOL stillShown(NSString *artworkID) {
    @synchronized (sg_lock) {
        return artworkID && [artworkID isEqualToString:sg_shownID];
    }
}

static BOOL stillWanted(NSString *artworkID) {
    @synchronized (sg_lock) {
        return artworkID && ([artworkID isEqualToString:sg_shownID] || [artworkID isEqualToString:sg_aheadID]);
    }
}

static void setWanted(NSString *shownID, NSString *aheadID) {
    @synchronized (sg_lock) {
        sg_shownID = shownID;
        sg_aheadID = aheadID;
    }
}

static NSURL *clipFile(NSString *artworkID) {
    return [folder() URLByAppendingPathComponent:[artworkID stringByAppendingPathExtension:@"mp4"]];
}

// On sg_previewQueue.
static UIImage *previewFor(NSString *artworkID, SGLockLine *line, CGSize size) {
    UIImage *preview = [sg_previews objectForKey:artworkID];
    if (preview) return preview;
    BOOL tryMotion = line.motion && !motionFailed(line.motion);
    CGImageRef frame = tryMotion ? SGLyricsClipMotionFrame(line.motion, line.previous, line.line, line.next, line.from) : NULL;
    if (tryMotion && !frame) markMotionFailed(line.motion, artworkID);
    if (!frame) {
        CGImageRef backdrop = copyBackdropFor(line.cover, size);
        frame = SGLyricsClipFrame(backdrop, line.line, line.next, size);
        CGImageRelease(backdrop);
    }
    if (frame) [sg_previews setObject:(preview = [UIImage imageWithCGImage:frame]) forKey:artworkID];
    CGImageRelease(frame);
    return preview;
}

static BOOL writeClip(NSString *artworkID, SGLockLine *line, CGSize size) {
    if (!stillWanted(artworkID)) return NO;
    NSURL *file = clipFile(artworkID);
    if ([NSFileManager.defaultManager fileExistsAtPath:file.path]) return YES;

    SGLyricsClipCancelBlock cancel = ^BOOL { return !stillWanted(artworkID); };
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    BOOL tryMotion = line.motion && !motionFailed(line.motion);
    BOOL over = tryMotion && SGLyricsClipWriteOverMotion(file, line.motion, line.previous, line.line, line.next,
                                                         line.from, line.seconds, cancel);
    if (cancel()) return NO;
    if (tryMotion && !over) markMotionFailed(line.motion, artworkID);
    BOOL ok = over;
    if (!ok) {
        UIImage *cachedStill = line.style == SGLyricsClipStill ? [sg_previews objectForKey:artworkID] : nil;
        if (cachedStill.CGImage) {
            ok = SGLyricsClipWriteImage(file, cachedStill.CGImage, size);
        } else {
            CGImageRef backdrop = copyBackdropFor(line.cover, size);
            ok = SGLyricsClipWrite(file, backdrop, line.line, line.next, size, line.style, cancel);
            CGImageRelease(backdrop);
        }
    }
    if (cancel()) return NO;
    static NSUInteger told;
    if (!ok || told++ < 5) SGLog(@"lock lyrics: %@ %@ in %.0f ms", artworkID, ok ? @"written" : @"not written",
                                  (CFAbsoluteTimeGetCurrent() - start) * 1000);
    return ok;
}

// Pre-draws the next cue's preview (and video only when the current cue has enough runway that speculative
// encoding won't contend with an imminent transition).
static void drawAhead(NSString *artworkID, SGLockLine *line, double runwaySeconds) {
    CFAbsoluteTime time = CFAbsoluteTimeGetCurrent();
    CGSize size = SGLyricsClipTargetSize(SGMotionPixels());
    if (time - sg_previewAskedAt <= 20) {
        dispatch_async(sg_previewQueue, ^{
            if (stillWanted(artworkID)) previewFor(artworkID, line, size);
        });
    }
    if (runwaySeconds >= 0.85 && time - sg_askedAt <= 20) {
        dispatch_async(sg_queue, ^{
            if (stillWanted(artworkID)) writeClip(artworkID, line, size);
        });
    }
}

API_AVAILABLE(ios(26.0))
static MPMediaItemAnimatedArtwork *artworkFor(NSString *artworkID, SGLockLine *line, double remainingSeconds) {
    CGSize size = SGLyricsClipTargetSize(SGMotionPixels());
    return [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:artworkID
        previewImageRequestHandler:^(CGSize wanted, void (^completion)(UIImage *)) {
            sg_previewAskedAt = CFAbsoluteTimeGetCurrent();
            UIImage *ready = [sg_previews objectForKey:artworkID];
            if (ready) {
                completion(ready);
                return;
            }
            dispatch_async(sg_previewQueue, ^{
                completion(previewFor(artworkID, line, size));
            });
        }
        videoAssetFileURLRequestHandler:^(CGSize wanted, void (^completion)(NSURL *)) {
            sg_askedAt = CFAbsoluteTimeGetCurrent();
            // If only a sliver of this cue remains (e.g. right after a scrub), wait briefly so we don't spin up
            // AVAssetWriter for a line that vanishes immediately; the preview image is already on screen.
            NSTimeInterval debounce = remainingSeconds < 0.55 ? 0.18 : 0;
            dispatch_block_t work = ^{
                if (!stillShown(artworkID)) {
                    completion(nil);
                    return;
                }
                completion(writeClip(artworkID, line, size) && stillShown(artworkID) ? clipFile(artworkID) : nil);
            };
            if (debounce > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(debounce * NSEC_PER_SEC)), sg_queue, work);
            } else {
                dispatch_async(sg_queue, work);
            }
        }];
}

static void clear(void) {
    cancelTimer();
    NSString *had;
    @synchronized (sg_lock) {
        had = sg_shownID;
        sg_shownID = nil;
        sg_aheadID = nil;
    }
    if (had) SGNowPlayingSetExtras(@"lyrics", nil, nil);
}

static NSString *lastLineOfCue(SGLockLyricsCue *cue) {
    if (!cue.text.length) return nil;
    NSRange newline = [cue.text rangeOfString:@"\n" options:NSBackwardsSearch];
    return newline.location == NSNotFound ? cue.text : [cue.text substringFromIndex:newline.location + 1];
}

void SGLyricsArtworkSetMotion(NSString *uri, NSURL *file) {
    @synchronized (sg_failedMotion) {
        if (file) [sg_failedMotion removeObject:file.path];
    }
    sg_motionURI = uri;
    sg_motion = file;
    dispatch_async(dispatch_get_main_queue(), ^{ tick(); });
}

static SGLockLine *lineAt(NSArray<SGLockLyricsCue *> *cues, NSInteger index, BOOL resting, NSURL *motion,
                          UIImage *cover, SGLyricsClipStyle style) {
    SGLockLyricsCue *current = (index >= 0 && index < (NSInteger)cues.count) ? cues[(NSUInteger)index] : nil;
    SGLockLyricsCue *upcoming = (index + 1 >= 0 && index + 1 < (NSInteger)cues.count) ? cues[(NSUInteger)(index + 1)] : nil;
    SGLockLyricsCue *prior = (index > 0 && index - 1 < (NSInteger)cues.count) ? cues[(NSUInteger)(index - 1)] : nil;

    SGLockLine *shown = [SGLockLine new];
    shown.line = resting ? nil : current.text;
    shown.next = upcoming.firstLineText;
    shown.previous = (motion && !resting) ? lastLineOfCue(prior) : nil;
    shown.cover = cover;
    shown.style = style;
    shown.motion = motion;
    NSInteger start = !current ? 0 : resting ? MAX(current.sungEnd, current.start) + kBreakMs : current.start;
    NSInteger end = upcoming ? upcoming.start : (!current ? start : MAX(current.sungEnd, current.start) + kBreakMs);
    shown.from = start / 1000.0;
    shown.seconds = MIN(MAX((end - start) / 1000.0 + 0.35, kShortest), kLongest);
    return shown;
}

static void cancelTimer(void) {
    if (!sg_timer) return;
    dispatch_source_cancel(sg_timer);
    sg_timer = nil;
}

// Main thread: arms a strict timer to fire right when the next lyric cue or rest state begins.
static void scheduleAfter(NSTimeInterval seconds) {
    if (!(seconds > 0) || !isfinite(seconds)) {
        cancelTimer();
        return;
    }
    NSTimeInterval clamped = MIN(MAX(seconds, 0.025), kMaxSleep);
    if (!sg_timer) {
        sg_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sg_timer, ^{ tick(); });
        dispatch_resume(sg_timer);
    }
    uint64_t delta = (uint64_t)(clamped * NSEC_PER_SEC);
    dispatch_source_set_timer(sg_timer, dispatch_time(DISPATCH_TIME_NOW, delta), DISPATCH_TIME_FOREVER, 8 * NSEC_PER_MSEC);
}

static void tick(void) {
    if (@available(iOS 26.0, *)) {
        SPTPlayerState *state = SGPlayerState();
        NSString *trackID = SGKaraokePlayingTrack();
        if (!trackID || !state) {
            clear();
            return;
        }
        if (![trackID isEqualToString:sg_track]) {
            sg_track = trackID;
            sg_cover = nil;
            [sg_previews removeAllObjects];
            dispatch_async(sg_queue, ^{
                [NSFileManager.defaultManager removeItemAtURL:folder() error:nil];
                [NSFileManager.defaultManager createDirectoryAtURL:folder() withIntermediateDirectories:YES attributes:nil error:nil];
            });
        }

        SGLockArtwork artworkChoice = SGLockScreenEffectiveArtwork();
        BOOL overMotion = SGLockScreenCanvasLyricsEnabled() && SGLockArtworkHasMotion(artworkChoice);
        BOOL lyricsOn = SGLockScreenLyricsViewEnabled() && (artworkChoice == SGLockArtworkLyrics || overMotion);
        if (!lyricsOn) {
            clear();
            SGLockMotionShowPlain(NO);
            return;
        }

        NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
        if (!lines) {
            SGKaraokeRequestLyrics(trackID);
            if (!state.isPaused) scheduleAfter(0.5);
            else cancelTimer();
            return;
        }
        NSArray<SGLockLyricsCue *> *cues = SGLockLyricsCues(lines);
        if (!cues.count) {
            static NSString *told;
            if (![told isEqualToString:trackID]) {
                told = trackID;
                SGLog(@"lock lyrics: %@ has no synced lines, the lock screen keeps its artwork", trackID);
            }
            clear();
            SGLockMotionShowPlain(YES);
            return;
        }

        NSInteger rawPosition = SGKaraokePositionMs();
        if (rawPosition < 0) {
            if (!state.isPaused) scheduleAfter(0.25);
            else cancelTimer();
            return;
        }
        NSInteger position = rawPosition - SGKaraokeDelayMs();
        BOOL resting = NO;
        NSInteger nextMs = NSIntegerMax;
        NSInteger index = SGLockLyricsCueAt(cues, position, kBreakMs, &resting, &nextMs);

        double speed = SGPlayerPlaybackSpeed(state);
        double remainingSeconds = nextMs == NSIntegerMax ? kLongest : MAX((nextMs - position) / (1000.0 * speed), 0);
        if (!state.isPaused && nextMs != NSIntegerMax) {
            scheduleAfter(remainingSeconds + 0.008);
        } else {
            cancelTimer();
        }

        SGLyricsClipStyle style = (SGLyricsClipStyle)SGInt(SGKeyLockScreenLyricsStyle, SGLyricsClipStill);
        NSURL *motion = overMotion && [sg_motionURI isEqualToString:SGURIString(state.track.URI)] ? sg_motion : nil;
        if (motion && motionFailed(motion)) motion = nil;
        NSString *look = SGLyricsClipLook(motion, style);
        NSString *artworkID = [NSString stringWithFormat:@"%@-%ld%@-%@", trackID, (long)index, resting ? @"r" : @"", look];
        NSString *aheadID = (index + 1 < (NSInteger)cues.count)
            ? [NSString stringWithFormat:@"%@-%ld-%@", trackID, (long)(index + 1), look] : nil;

        if (stillShown(artworkID)) return;

        if (!sg_cover) {
            NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
            MPMediaItemArtwork *artwork = info[MPMediaItemPropertyArtwork];
            if (SGNowPlayingTitlesMatch(info[MPMediaItemPropertyTitle], state.track.trackTitle)
                && [artwork isKindOfClass:MPMediaItemArtwork.class]) {
                sg_cover = [artwork imageWithSize:CGSizeMake(600, 600)];
            }
        }
        if (![sg_shownID hasPrefix:trackID]) SGLog(@"lock lyrics: lines offered for %@", trackID);
        if (motion && ![sg_shownID hasSuffix:[@"-" stringByAppendingString:look]])
            SGLog(@"lock lyrics: lines over moving artwork %@", motion.lastPathComponent);

        setWanted(artworkID, aheadID);
        SGLockMotionShowPlain(NO);
        SGLockLine *currentLine = lineAt(cues, index, resting, motion, sg_cover, style);
        MPMediaItemAnimatedArtwork *animatedArtwork = artworkFor(artworkID, currentLine, remainingSeconds);
        if (animatedArtwork) {
            SGNowPlayingSetExtras(@"lyrics", @{MPNowPlayingInfoProperty3x4AnimatedArtwork: animatedArtwork},
                                  state.track.trackTitle);
        }
        if (aheadID) {
            drawAhead(aheadID, lineAt(cues, index + 1, NO, motion, sg_cover, style), remainingSeconds);
        }
    }
}

@interface SGLyricsArtwork : NSObject <SGPlayerStateObserver>
@end

@implementation SGLyricsArtwork
- (void)playerStateDidChange:(SPTPlayerState *)state {
    SGLockArtwork choice = SGLockScreenEffectiveArtwork();
    BOOL on = SGLockScreenLyricsViewEnabled()
        && (choice == SGLockArtworkLyrics || (SGLockScreenCanvasLyricsEnabled() && SGLockArtworkHasMotion(choice)));
    if (on) tick();
    else {
        clear();
        SGLockMotionShowPlain(NO);
    }
}
@end

%ctor {
    if (@available(iOS 26.0, *)) {
        sg_lock = [NSObject new];
        sg_queue = dispatch_queue_create("spotifyglass.lockscreen.lyrics", DISPATCH_QUEUE_SERIAL);
        sg_previewQueue = dispatch_queue_create("spotifyglass.lockscreen.lyrics.preview", DISPATCH_QUEUE_SERIAL);
        sg_previews = [NSCache new];
        sg_failedMotion = [NSMutableSet set];
        sg_previews.countLimit = 6;
        static SGLyricsArtwork *observer;
        observer = [SGLyricsArtwork new];
        SGAddPlayerStateObserver(observer);

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:SGPlayerClockDidJumpNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) { tick(); }];
        [center addObserverForName:SGSpeedPitchChangedNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) { tick(); }];
        [center addObserverForName:SGKaraokeLinesDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            if (!note.object || [note.object isEqual:SGKaraokePlayingTrack()]) tick();
        }];

        static SGLockArtwork choice;
        static BOOL canvasLyrics, lyricsView;
        static NSInteger lyricsStyle, lyricsDelay;
        choice = SGLockScreenEffectiveArtwork();
        canvasLyrics = SGLockScreenCanvasLyricsEnabled();
        lyricsView = SGLockScreenLyricsViewEnabled();
        lyricsStyle = SGInt(SGKeyLockScreenLyricsStyle, SGLyricsClipStill);
        lyricsDelay = SGKaraokeDelayMs();
        [center addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                        usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL enabled = SGLockScreenCanvasLyricsEnabled();
                BOOL viewEnabled = SGLockScreenLyricsViewEnabled();
                NSInteger style = SGInt(SGKeyLockScreenLyricsStyle, SGLyricsClipStill);
                NSInteger delay = SGKaraokeDelayMs();
                if (SGLockScreenEffectiveArtwork() == choice && enabled == canvasLyrics
                    && viewEnabled == lyricsView && style == lyricsStyle && delay == lyricsDelay) return;
                choice = SGLockScreenEffectiveArtwork();
                canvasLyrics = enabled;
                lyricsView = viewEnabled;
                lyricsStyle = style;
                lyricsDelay = delay;
                SGLog(@"lock lyrics: artwork mode or lyrics settings changed");
                [observer playerStateDidChange:SGPlayerState()];
            });
        }];
        [center addObserverForName:SGNotificationLockScreenEffectiveArtworkChanged
                            object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            [observer playerStateDidChange:SGPlayerState()];
        }];
        BOOL lyricsOn = lyricsView && (choice == SGLockArtworkLyrics || (canvasLyrics && SGLockArtworkHasMotion(choice)));
        SGLog(@"lock lyrics: %@, the lock screen takes %@", lyricsOn ? @"on" : @"off",
              MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys);
    }
}
