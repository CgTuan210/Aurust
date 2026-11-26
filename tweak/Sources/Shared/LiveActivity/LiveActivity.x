#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "LiveActivity.h"

API_AVAILABLE(ios(17.0))
@interface SGLiveActivityBridge : NSObject
@property (class, nonatomic, readonly) BOOL isShowing;
+ (void)showWithView:(NSInteger)view paused:(BOOL)paused line:(NSString *)line nextLine:(NSString *)nextLine
              titles:(NSArray<NSString *> *)titles artists:(NSArray<NSString *> *)artists uris:(NSArray<NSString *> *)uris
                 tab:(NSInteger)tab title:(NSString *)title artist:(NSString *)artist shuffle:(BOOL)shuffle repeatMode:(NSInteger)repeatMode
            timerEnd:(NSDate *)timerEnd timerEndOfTrack:(BOOL)timerEndOfTrack;
+ (void)end;
@end

// The control menu's tabs, SGLyricsAttributes.Tab's values.
typedef NS_ENUM(NSInteger, SGLiveActivityTab) {
    SGLiveActivityTabControls = 0,
    SGLiveActivityTabQueue,
    SGLiveActivityTabTimer,
};

static const NSInteger kBreakMs = 4000;
static const NSTimeInterval kStartRetry = 10;
static const NSTimeInterval kPanelRefresh = 3.0;
static const NSTimeInterval kMaxSleep = 15.0;
static const NSUInteger kUpNextQueue = 4;
static const NSUInteger kUpNextPanel = 3;
// The end of track timer pauses this close to the end, so the next track never starts.
static const NSInteger kEndOfTrackMs = 500;

static BOOL sg_enabled;
static dispatch_source_t sg_timer;
static NSString *sg_shown;
static NSString *sg_missingLyrics;
static NSDate *sg_lastStart;
static SGLiveActivityTab sg_tab;
static NSDate *sg_sleepEnd;
static NSString *sg_sleepTrack;

static void tick(void) API_AVAILABLE(ios(17.0));

static void cancelTimer(void) {
    if (!sg_timer) return;
    dispatch_source_cancel(sg_timer);
    sg_timer = nil;
}

// Strict GCD timer so lock-screen lyric transitions are not throttled with the main run loop while locked.
static void scheduleAfter(NSTimeInterval seconds) API_AVAILABLE(ios(17.0)) {
    if (!sg_enabled || !(seconds > 0) || !isfinite(seconds)) {
        cancelTimer();
        return;
    }
    NSTimeInterval clamped = MIN(MAX(seconds, 0.05), kMaxSleep);
    if (!sg_timer) {
        sg_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sg_timer, ^{ tick(); });
        dispatch_resume(sg_timer);
    }
    uint64_t delta = (uint64_t)(clamped * NSEC_PER_SEC);
    dispatch_source_set_timer(sg_timer, dispatch_time(DISPATCH_TIME_NOW, delta), DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
}

static void send(NSString *shown, void (^show)(void)) API_AVAILABLE(ios(17.0)) {
    if (SGLiveActivityBridge.isShowing) {
        if ([shown isEqualToString:sg_shown]) return;
    } else {
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        if (sg_lastStart && -sg_lastStart.timeIntervalSinceNow < kStartRetry) return;
        sg_lastStart = [NSDate date];
    }
    sg_shown = shown;
    show();
}

static NSString *uriOf(SPTPlayerTrack *track) {
    id uri = track.URI;
    if ([uri isKindOfClass:NSURL.class]) return [(NSURL *)uri absoluteString];
    return [uri isKindOfClass:NSString.class] ? uri : nil;
}

static NSArray<SPTPlayerTrack *> *upNext(SPTPlayerState *state) {
    NSMutableArray<SPTPlayerTrack *> *tracks = [NSMutableArray array];
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    for (id track in [future isKindOfClass:NSArray.class] ? future : @[]) {
        if (![track isKindOfClass:objc_getClass("SPTPlayerTrack")]) continue;
        if (![(SPTPlayerTrack *)track trackTitle].length || !uriOf(track)) continue;
        [tracks addObject:track];
    }
    return tracks;
}

static NSInteger repeatModeOf(SPTPlayerOptions *options) {
    return options.repeatingTrack ? 2 : options.repeatingContext ? 1 : 0;
}

static NSString *lyricsLine(NSString *trackID, NSString **next, NSInteger *outPosition, NSInteger *outNextMs) {
    if (outNextMs) *outNextMs = NSIntegerMax;
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
    NSInteger rawPos = SGKaraokePositionMs();
    NSInteger position = rawPos >= 0 ? rawPos - SGKaraokeDelayMs() : -1;
    if (outPosition) *outPosition = position;

    if (!lines) {
        SGKaraokeRequestLyrics(trackID);
        if (trackID && ![trackID isEqualToString:sg_missingLyrics]) {
            sg_missingLyrics = trackID;
            SGLog(@"live activity: no lyrics yet for %@", trackID);
        }
        if (outNextMs && position >= 0) *outNextMs = position + 500;
        *next = @"";
        return @"♪";
    }
    NSArray<SGLockLyricsCue *> *cues = SGLockLyricsCues(lines);
    if (!cues.count || position < 0) {
        if (outNextMs && position < 0) *outNextMs = 250;
        *next = @"";
        return @"♪";
    }

    BOOL resting = NO;
    NSInteger nextMs = NSIntegerMax;
    NSInteger index = SGLockLyricsCueAt(cues, position, kBreakMs, &resting, &nextMs);
    if (outNextMs) *outNextMs = nextMs;
    *next = (index + 1 >= 0 && index + 1 < (NSInteger)cues.count) ? cues[(NSUInteger)(index + 1)].firstLineText : @"";
    if (index < 0 || resting) return @"♪";
    return cues[(NSUInteger)index].text;
}

static void clearSleepTimer(void) {
    sg_sleepEnd = nil;
    sg_sleepTrack = nil;
}

static void checkSleepTimer(id<SPTPlayer> player, SPTPlayerState *state, NSString *trackID) {
    BOOL up = NO;
    if (sg_sleepEnd) {
        up = sg_sleepEnd.timeIntervalSinceNow <= 0;
    } else if (sg_sleepTrack) {
        double duration = [state respondsToSelector:@selector(duration)] ? state.duration : 0;
        NSInteger position = SGKaraokePositionMs();
        up = ![trackID isEqualToString:sg_sleepTrack]
            || (duration > 0 && position >= 0 && duration * 1000 - position < kEndOfTrackMs);
    }
    if (!up) return;
    clearSleepTimer();
    if (!state.isPaused) [player pause:nil];
    SGLog(@"live activity: sleep timer up, paused");
}

static void tick(void) API_AVAILABLE(ios(17.0)) {
    if (!sg_enabled) {
        cancelTimer();
        return;
    }
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = player.state ?: SGPlayerState();
    SPTPlayerTrack *track = state.track;
    if (!track.trackTitle.length) {
        cancelTimer();
        return;
    }
    NSString *trackID = SGKaraokePlayingTrack();
    checkSleepTimer(player, state, trackID);
    state = player.state ?: state;

    NSInteger view = SGInt(SGKeyLiveActivityView, SGLiveActivityLyrics);
    BOOL paused = state.isPaused;
    double speed = SGPlayerPlaybackSpeed(state);

    NSString *line = @"", *next = @"";
    NSInteger lyricPos = -1, nextLyricMs = NSIntegerMax;
    if (view == SGLiveActivityLyrics) {
        line = lyricsLine(trackID, &next, &lyricPos, &nextLyricMs);
    }

    NSMutableArray<NSString *> *titles = [NSMutableArray array], *artists = [NSMutableArray array], *uris = [NSMutableArray array];
    if (view != SGLiveActivityLyrics) {
        NSUInteger limit = view == SGLiveActivityQueue ? kUpNextQueue : kUpNextPanel;
        for (SPTPlayerTrack *upcoming in upNext(state)) {
            if (titles.count == limit) break;
            [titles addObject:upcoming.trackTitle];
            [artists addObject:upcoming.artistName ?: @""];
            [uris addObject:uriOf(upcoming)];
        }
    }

    BOOL panel = view == SGLiveActivityPanel;
    NSString *title = panel ? track.trackTitle : @"", *artist = panel ? track.artistName ?: @"" : @"";
    BOOL shuffle = panel && state.options.shufflingContext;
    NSInteger repeatMode = panel ? repeatModeOf(state.options) : 0;
    NSInteger tab = panel ? sg_tab : 0;
    NSDate *sleepEnd = sg_sleepEnd;
    BOOL endOfTrack = sg_sleepTrack != nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObjects:@(view).stringValue, paused ? @"1" : @"0", line, next,
        @(tab).stringValue, title, artist, shuffle ? @"1" : @"0", @(repeatMode).stringValue,
        @((long long)sleepEnd.timeIntervalSince1970).stringValue, endOfTrack ? @"1" : @"0", nil];
    for (NSUInteger i = 0; i < titles.count; i++) [parts addObject:[NSString stringWithFormat:@"%@\t%@\t%@", titles[i], artists[i], uris[i]]];
    send([parts componentsJoinedByString:@"\n"], ^{
        [SGLiveActivityBridge showWithView:view paused:paused line:line nextLine:next titles:titles artists:artists uris:uris
                                        tab:tab title:title artist:artist shuffle:shuffle repeatMode:repeatMode
                                   timerEnd:sleepEnd timerEndOfTrack:endOfTrack];
    });

    // Compute exact next wake interval instead of polling continuously.
    NSTimeInterval nextWake = INFINITY;
    if (sg_sleepEnd) {
        nextWake = MIN(nextWake, MAX(sg_sleepEnd.timeIntervalSinceNow + 0.02, 0.05));
    } else if (sg_sleepTrack && !paused) {
        double duration = [state respondsToSelector:@selector(duration)] ? state.duration : 0;
        NSInteger rawPos = SGKaraokePositionMs();
        if (duration > 0 && rawPos >= 0) {
            double untilEnd = (duration * 1000.0 - kEndOfTrackMs - rawPos) / (1000.0 * speed);
            nextWake = MIN(nextWake, MAX(untilEnd, 0.1));
        } else {
            nextWake = MIN(nextWake, 1.0);
        }
    }
    if (!paused) {
        if (view == SGLiveActivityLyrics) {
            if (lyricPos < 0) {
                nextWake = MIN(nextWake, 0.25);
            } else if (nextLyricMs != NSIntegerMax) {
                double wait = MAX((nextLyricMs - lyricPos) / (1000.0 * speed), 0) + 0.01;
                nextWake = MIN(nextWake, MAX(wait, 0.05));
            }
        } else {
            nextWake = MIN(nextWake, kPanelRefresh);
        }
    }
    if (!SGLiveActivityBridge.isShowing && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        nextWake = MIN(nextWake, kStartRetry);
    }
    scheduleAfter(nextWake);
}

static void playQueued(NSString *uri) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerTrack *target = nil;
    for (SPTPlayerTrack *track in upNext(player.state)) {
        if ([uriOf(track) isEqualToString:uri]) { target = track; break; }
    }
    if (!target || ![player respondsToSelector:@selector(skipToNextTrackWithOptions:track:)]) {
        SGLog(@"live activity: cannot play %@ (in the queue: %@, player %@)", uri, target ? @"yes" : @"no", player ? NSStringFromClass([player class]) : @"nil");
        return;
    }
    id result = [player skipToNextTrackWithOptions:nil track:target];
    SGLog(@"live activity: play %@ -> %@", uri, result);
}

static void runAction(NSString *action) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = player.state;
    NSArray<NSString *> *parts = [action componentsSeparatedByString:@":"];
    NSString *name = parts.firstObject, *value = parts.count > 1 ? parts[1] : @"";
    id result = nil;
    if ([name isEqualToString:@"tab"]) {
        sg_tab = MAX(SGLiveActivityTabControls, MIN(SGLiveActivityTabTimer, value.integerValue));
    } else if ([name isEqualToString:@"toggle"]) {
        result = state.isPaused ? [player resume:nil] : [player pause:nil];
    } else if ([name isEqualToString:@"previous"]) {
        result = [player skipToPreviousTrackWithOptions:nil];
    } else if ([name isEqualToString:@"next"]) {
        result = [player skipToNextTrackWithOptions:nil];
    } else if ([name isEqualToString:@"shuffle"]) {
        result = [player setShufflingContext:!state.options.shufflingContext];
    } else if ([name isEqualToString:@"repeat"]) {
        switch (repeatModeOf(state.options)) {
            case 0: result = [player setRepeatingContext:YES]; break;
            case 1: result = [player setRepeatingTrack:YES]; break;
            default:
                [player setRepeatingTrack:NO];
                result = [player setRepeatingContext:NO];
        }
    } else if ([name isEqualToString:@"timer"]) {
        if ([value isEqualToString:@"cancel"]) {
            clearSleepTimer();
        } else if ([value isEqualToString:@"track"]) {
            clearSleepTimer();
            sg_sleepTrack = SGKaraokePlayingTrack();
        } else if ([value isEqualToString:@"add"]) {
            NSDate *from = sg_sleepEnd && sg_sleepEnd.timeIntervalSinceNow > 0 ? sg_sleepEnd : [NSDate date];
            sg_sleepEnd = [from dateByAddingTimeInterval:15 * 60];
        } else if (value.integerValue > 0) {
            clearSleepTimer();
            sg_sleepEnd = [NSDate dateWithTimeIntervalSinceNow:value.integerValue * 60];
        }
    } else {
        SGLog(@"live activity: unknown action %@", action);
        return;
    }
    SGLog(@"live activity: %@ -> %@", action, result);
}

@interface SGLiveActivityPlayerObserver : NSObject <SGPlayerStateObserver>
@end

@implementation SGLiveActivityPlayerObserver
- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (@available(iOS 17.0, *)) {
        if (sg_enabled) tick();
    }
}
@end

void SGSetLiveActivityEnabled(BOOL on) {
    if (@available(iOS 17.0, *)) {
        sg_enabled = on;
        cancelTimer();
        sg_shown = nil;
        sg_lastStart = nil;
        clearSleepTimer();
        if (!on) {
            [SGLiveActivityBridge end];
            SGLog(@"live activity: off");
            return;
        }
        static dispatch_once_t observing;
        dispatch_once(&observing, ^{
            static SGLiveActivityPlayerObserver *playerObserver;
            playerObserver = [SGLiveActivityPlayerObserver new];
            SGAddPlayerStateObserver(playerObserver);

            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            [center addObserverForName:@"SGLiveActivityPlay" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if ([note.object isKindOfClass:NSString.class]) playQueued(note.object);
            }];
            [center addObserverForName:@"SGLiveActivityAction" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if (![note.object isKindOfClass:NSString.class]) return;
                runAction(note.object);
                if (sg_enabled) tick();
            }];
            [center addObserverForName:SGPlayerClockDidJumpNotification object:nil queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification *note) {
                if (sg_enabled) tick();
            }];
            [center addObserverForName:SGSpeedPitchChangedNotification object:nil queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification *note) {
                if (sg_enabled) tick();
            }];
            [center addObserverForName:SGKaraokeLinesDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification *note) {
                if (sg_enabled && (!note.object || [note.object isEqual:SGKaraokePlayingTrack()])) tick();
            }];
            [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification *note) {
                if (sg_enabled) tick();
            }];
            static NSInteger lastView, lastDelay;
            lastView = SGInt(SGKeyLiveActivityView, SGLiveActivityLyrics);
            lastDelay = SGKaraokeDelayMs();
            [center addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                            usingBlock:^(NSNotification *note) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSInteger view = SGInt(SGKeyLiveActivityView, SGLiveActivityLyrics);
                    NSInteger delay = SGKaraokeDelayMs();
                    if (view == lastView && delay == lastDelay) return;
                    lastView = view;
                    lastDelay = delay;
                    if (sg_enabled) tick();
                });
            }];
        });
        SGLog(@"live activity: on");
        tick();
    }
}

%ctor {
    if (@available(iOS 17.0, *)) {
        SGMigrateKey(SGKeyLiveActivityWas, SGKeyLiveActivity);
        SGMigrateKey(SGKeyLiveActivityViewWas, SGKeyLiveActivityView);
        BOOL on = SGFlag(SGKeyLiveActivity, NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (on) SGSetLiveActivityEnabled(YES);
            else [SGLiveActivityBridge end];
        });
    }
}
