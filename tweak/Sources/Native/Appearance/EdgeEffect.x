#import <objc/runtime.h>
#import "Core/SGCore.h"

static void soften(UIScrollView *scrollView) {
    if (@available(iOS 26.0, *)) {
        static UIScrollEdgeEffectStyle *soft;
        static dispatch_once_t styleOnce;
        dispatch_once(&styleOnce, ^{ soft = UIScrollEdgeEffectStyle.softStyle; });
        UIScrollEdgeEffect *top = scrollView.topEdgeEffect;
        if (!top || top.style == soft) return;
        top.style = soft;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"soft top edge: first scroll view %@", NSStringFromClass(scrollView.class)); });
    }
}

%hook UIScrollView
- (void)didMoveToWindow {
    %orig;
    if (self.window) soften(self);
}

- (void)layoutSubviews {
    %orig;
    if (self.window) soften(self);
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
}
