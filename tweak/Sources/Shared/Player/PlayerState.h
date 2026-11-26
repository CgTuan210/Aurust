#import <UIKit/UIKit.h>
#import "Headers/SPTPlayer.h"

// A URI Spotify types as id (NSURL or NSString) as a string; nil for anything else.
NSString *SGURIString(id uri);

@protocol SGPlayerStateObserver <NSObject>
// Called when the track, context, Canvas metadata, paused, playing, loading or shuffle changed, not for position.
- (void)playerStateDidChange:(SPTPlayerState *)state;
@end
// Observers are held weakly and need no removal.
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer);
// Posted on the main queue when playback seeks or changes rate within the current track.
extern NSNotificationName const SGPlayerClockDidJumpNotification;
// Safe playback speed (defaults to 1.0 when unreported or invalid).
double SGPlayerPlaybackSpeed(SPTPlayerState *state);
// The last state reported, nil before the player has reported one.
SPTPlayerState *SGPlayerState(void);
