#import "Core/SGCore.h"
#import "SGRRepaint.h"

__weak UIView *sgr_nowPlayingRoot = nil;
__weak UIView *sgr_nowPlayingCard = nil;
__weak UIView *sgr_lyricsPageRoot = nil;
__weak UIView *sgr_playlistRoot = nil;
__weak UIView *sgr_albumRoot = nil;
__weak UIView *sgr_artistRoot = nil;

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    if (color) {
        UIView *npb = sgr_nowPlayingRoot;
        UIView *lyrics = sgr_lyricsPageRoot;
        UIView *playlist = sgr_playlistRoot;
        UIView *album = sgr_albumRoot;
        UIView *artist = sgr_artistRoot;
        if (npb || lyrics || playlist || album || artist) {
            UIView *view = (UIView *)self.delegate;
            if ([view isKindOfClass:UIView.class] && view.layer == self && !SGKeepsColor(view)) {
                for (UIView *v = view; v; v = v.superview) {
                    if ([v isKindOfClass:UIVisualEffectView.class]) break;
                    if (v == npb) {
                        if (SGLooksLikeCard(view, color) && sgr_nowPlayingCard != view) {
                            sgr_nowPlayingCard = view;
                            dispatch_async(dispatch_get_main_queue(), ^{ [npb.superview setNeedsLayout]; });
                        }
                        color = NULL;
                        break;
                    }
                    if (v == lyrics) {
                        color = NULL;
                        break;
                    }
                    if (v == playlist || v == album || v == artist) {
                        if (SGIsBaseSurface(color)) color = NULL;
                        break;
                    }
                }
            }
        }
    }
    %orig(color);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
}
