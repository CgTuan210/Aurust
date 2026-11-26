#import "Core/SGCore.h"

static CGColorRef sgr_opaqueBlack;
static CFTypeID sgr_colorTypeID;

// Neutral and darker than #1A1A1A, but not already black.
static inline BOOL isBaseGrey(CGColorRef color) {
    if (!color || CFGetTypeID(color) != sgr_colorTypeID) return NO;
    size_t n = CGColorGetNumberOfComponents(color);
    const CGFloat *c = CGColorGetComponents(color);
    if (n == 2) return c[0] > 0.01 && c[0] <= 0.10;
    if (n < 3) return NO;
    return c[0] > 0.01 && c[0] <= 0.10 && fabs(c[0] - c[1]) < 0.02 && fabs(c[1] - c[2]) < 0.02;
}

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    if (!isBaseGrey(color)) {
        %orig;
        return;
    }
    CGFloat alpha = CGColorGetAlpha(color);
    if (alpha >= 0.999) {
        %orig(sgr_opaqueBlack);
        return;
    }
    CGColorRef black = CGColorCreateGenericGray(0, alpha);
    %orig(black);
    CGColorRelease(black);
}
%end

%hook CAGradientLayer
- (void)setColors:(NSArray *)colors {
    NSMutableArray *mapped = nil;
    NSUInteger count = colors.count;
    for (NSUInteger i = 0; i < count; i++) {
        id entry = colors[i];
        CGColorRef color = (__bridge CGColorRef)entry;
        if (!isBaseGrey(color)) continue;
        if (!mapped) mapped = [colors mutableCopy];
        CGFloat alpha = CGColorGetAlpha(color);
        if (alpha >= 0.999) {
            mapped[i] = (__bridge id)sgr_opaqueBlack;
        } else {
            CGColorRef black = CGColorCreateGenericGray(0, alpha);
            mapped[i] = (__bridge id)black;
            CGColorRelease(black);
        }
    }
    %orig(mapped ?: colors);
}
%end

%hook _TtC21Settings_PlatformImpl26SettingsListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    for (UIView *sub in ((UIViewController *)self).view.subviews) {
        if ([sub isKindOfClass:UICollectionView.class]) sub.backgroundColor = UIColor.blackColor;
    }
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    sgr_colorTypeID = CGColorGetTypeID();
    sgr_opaqueBlack = CGColorCreateGenericGray(0, 1);
    %init;
}
