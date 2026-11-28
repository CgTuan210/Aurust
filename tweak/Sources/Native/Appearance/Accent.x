#import "Core/SGCore.h"
#import "Appearance.h"
#import "Settings/SGPageStyle.h"

static NSInteger sg_accent = -1;   // 0xRRGGBB once chosen, read at launch
static CGFloat sg_outR[2], sg_outG[2], sg_outB[2];
static CGColorRef sg_cachedCG[2];
static CFTypeID sg_colorTypeID;

static const CGFloat kGreenR[2] = {0x1E / 255.0, 0x1D / 255.0};
static const CGFloat kGreenG[2] = {0xD7 / 255.0, 0xB9 / 255.0};
static const CGFloat kGreenB[2] = {0x60 / 255.0, 0x54 / 255.0};

static NSInteger chosen(void) {
    NSInteger rgb = SGInt(SGKeyAccent, -1);
    return rgb >= 0 && rgb <= 0xFFFFFF ? rgb : -1;
}

static void unpack(uint32_t rgb, CGFloat *r, CGFloat *g, CGFloat *b) {
    *r = ((rgb >> 16) & 0xFF) / 255.0;
    *g = ((rgb >> 8) & 0xFF) / 255.0;
    *b = (rgb & 0xFF) / 255.0;
}

UIColor *SGAccentColor(void) {
    NSInteger rgb = chosen();
    if (rgb < 0) return nil;
    CGFloat r, g, b;
    unpack((uint32_t)rgb, &r, &g, &b);
    return [UIColor colorWithRed:r green:g blue:b alpha:1];
}

NSString *SGAccentLabel(void) {
    NSInteger rgb = chosen();
    return rgb < 0 ? @"Spotify green" : [NSString stringWithFormat:@"#%06lX", (long)rgb];
}

#pragma mark - picker

@interface SGAccentPicker : NSObject <UIColorPickerViewControllerDelegate>
@end

@implementation SGAccentPicker

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)picker {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [picker.selectedColor getRed:&r green:&g blue:&b alpha:&a];
    uint32_t rgb = ((uint32_t)lround(MIN(1, MAX(0, r)) * 255) << 16)
                 | ((uint32_t)lround(MIN(1, MAX(0, g)) * 255) << 8)
                 | (uint32_t)lround(MIN(1, MAX(0, b)) * 255);
    SGSetInt(SGKeyAccent, rgb);
}

@end

void SGPickAccent(void) {
    static SGAccentPicker *delegate;
    if (!delegate) delegate = [SGAccentPicker new];
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.supportsAlpha = NO;
    picker.selectedColor = SGAccentColor() ?: [UIColor colorWithRed:0x1E / 255.0 green:0xD7 / 255.0 blue:0x60 / 255.0 alpha:1];
    picker.delegate = delegate;
    [SGTopController() presentViewController:picker animated:YES completion:nil];
}

static inline int matchGreen(CGFloat *r, CGFloat *g, CGFloat *b) {
    if (*g < 0.71 || *g > 0.86) return -1;
    for (int i = 0; i < 2; i++) {
        if (fabs(*r - kGreenR[i]) > 0.01 || fabs(*g - kGreenG[i]) > 0.01 || fabs(*b - kGreenB[i]) > 0.01) continue;
        *r = sg_outR[i];
        *g = sg_outG[i];
        *b = sg_outB[i];
        return i;
    }
    return -1;
}

%hook UIColor
- (UIColor *)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    matchGreen(&r, &g, &b);
    return %orig(r, g, b, a);
}
+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    matchGreen(&r, &g, &b);
    return %orig(r, g, b, a);
}
%end

static CGColorRef swappedCopy(CGColorRef color) {
    if (!color || CFGetTypeID(color) != sg_colorTypeID || CGColorGetNumberOfComponents(color) != 4) return NULL;
    const CGFloat *c = CGColorGetComponents(color);
    if (!c) return NULL;
    CGFloat r = c[0], g = c[1], b = c[2];
    int idx = matchGreen(&r, &g, &b);
    if (idx < 0) return NULL;
    if (c[3] >= 0.999 && sg_cachedCG[idx]) return CGColorRetain(sg_cachedCG[idx]);
    CGFloat out[] = {r, g, b, c[3]};
    return CGColorCreate(CGColorGetColorSpace(color), out);
}

static inline id swappedValue(id value) {
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != sg_colorTypeID) return value;
    CGColorRef swapped = swappedCopy((__bridge CGColorRef)value);
    if (!swapped) return value;
    return (__bridge_transfer id)swapped;
}

%hook CAShapeLayer
- (void)setFillColor:(CGColorRef)color {
    CGColorRef swapped = swappedCopy(color);
    %orig(swapped ?: color);
    if (swapped) CGColorRelease(swapped);
}
- (void)setStrokeColor:(CGColorRef)color {
    CGColorRef swapped = swappedCopy(color);
    %orig(swapped ?: color);
    if (swapped) CGColorRelease(swapped);
}
%end

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    CGColorRef swapped = swappedCopy(color);
    %orig(swapped ?: color);
    if (swapped) CGColorRelease(swapped);
}
%end

%hook CABasicAnimation
- (void)setFromValue:(id)value {
    %orig(swappedValue(value));
}
- (void)setToValue:(id)value {
    %orig(swappedValue(value));
}
%end

%hook CAKeyframeAnimation
- (void)setValues:(NSArray *)values {
    NSMutableArray *mapped = nil;
    NSUInteger count = values.count;
    for (NSUInteger i = 0; i < count; i++) {
        id swapped = swappedValue(values[i]);
        if (swapped == values[i] && !mapped) continue;
        if (!mapped) mapped = [values mutableCopy];
        mapped[i] = swapped;
    }
    %orig(mapped ?: values);
}
%end

%ctor {
    if (!SGNativeUI()) return;
    sg_accent = chosen();
    if (sg_accent < 0) return;
    sg_colorTypeID = CGColorGetTypeID();
    CGFloat ar, ag, ab;
    unpack((uint32_t)sg_accent, &ar, &ag, &ab);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    for (int i = 0; i < 2; i++) {
        CGFloat factor = MAX(kGreenR[i], MAX(kGreenG[i], kGreenB[i])) / (0xD7 / 255.0);
        sg_outR[i] = MIN(1, ar * factor);
        sg_outG[i] = MIN(1, ag * factor);
        sg_outB[i] = MIN(1, ab * factor);
        CGFloat comps[] = {sg_outR[i], sg_outG[i], sg_outB[i], 1.0};
        sg_cachedCG[i] = CGColorCreate(srgb, comps);
    }
    CGColorSpaceRelease(srgb);
    %init;
}
