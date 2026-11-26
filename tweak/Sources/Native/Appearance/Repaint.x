// Keeps the areas the native look's tweaks stripped transparent when Spotify repaints them.
#import "Core/SGCore.h"
#import "Repaint.h"

__weak UIView *sg_lyricsCardRoot = nil;
__weak UIView *sg_lyricsPageRoot = nil;
__weak UIView *sg_homeRoot = nil;
__weak UIView *sg_npvBackdropRoot = nil;

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    if (color) {
        UIView *card = sg_lyricsCardRoot;
        UIView *page = sg_lyricsPageRoot;
        UIView *home = sg_homeRoot;
        UIView *npv = sg_npvBackdropRoot;
        if (card || page || home || npv) {
            UIView *view = (UIView *)self.delegate;
            if ([view isKindOfClass:UIView.class] && view.layer == self && !SGKeepsColor(view)) {
                for (UIView *v = view; v; v = v.superview) {
                    if ([v isKindOfClass:UIVisualEffectView.class]) break;
                    if (v == card || v == page || v == npv) {
                        // The album colour arrives on the plane per track, outside any layout pass.
                        color = NULL;
                        break;
                    }
                    if (v == home) {
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
    if (!SGNativeUI()) return;
    %init;
}
