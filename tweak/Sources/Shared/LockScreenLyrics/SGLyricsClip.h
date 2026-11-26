// A line of lyrics as a short video for the lock screen's full-screen artwork (LyricsArtwork.x): the
// line, and the next one dimmed under it, over the cover blurred. Core Graphics, Core Text, Core Image,
// Accelerate and AVFoundation only, so it runs safely on the CPU while Spotify is in the background.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SGLyricsClipStyle) {
    SGLyricsClipStill = 0,   // one frame, held
    SGLyricsClipAnimated,    // the cover breathes behind the words, in a loop
};

typedef BOOL (^SGLyricsClipCancelBlock)(void);

// The 3:4 size of a clip `pixels` wide, both sides a multiple of 16 for the encoder.
CGSize SGLyricsClipSize(CGFloat pixels);
// Capped 3:4 size for lyric clips (~576x768 max): blurred art and large type look identical on the lock
// screen at a third of the pixel count and memory bandwidth.
CGSize SGLyricsClipTargetSize(CGFloat screenPixels);
// The cover blurred and darkened to fill `size`, made once per track; a dark field for a NULL cover.
CGImageRef SGLyricsClipBackdrop(CGImageRef cover, CGSize size) CF_RETURNS_RETAINED;
// The clip's first frame, for the lock screen's preview image. `line` or `next` may be nil.
CGImageRef SGLyricsClipFrame(CGImageRef backdrop, NSString *line, NSString *next, CGSize size) CF_RETURNS_RETAINED;
// Writes an already-rendered still frame as a 1-frame H.264 clip to `file`, avoiding duplicate layout/drawing.
BOOL SGLyricsClipWriteImage(NSURL *file, CGImageRef image, CGSize size);
// Writes the clip as H.264 to `file`, replacing it, and returns once it is written; NO if cancelled or failed.
BOOL SGLyricsClipWrite(NSURL *file, CGImageRef backdrop, NSString *line, NSString *next, CGSize size,
                       SGLyricsClipStyle style, SGLyricsClipCancelBlock cancel);
BOOL SGLyricsClipWriteOverMotion(NSURL *file, NSURL *motion, NSString *previous, NSString *line, NSString *next,
                                 double from, double seconds, SGLyricsClipCancelBlock cancel);
NSString *SGLyricsClipLook(NSURL *motion, SGLyricsClipStyle style);
CGImageRef SGLyricsClipMotionFrame(NSURL *motion, NSString *previous, NSString *line, NSString *next, double from) CF_RETURNS_RETAINED;
