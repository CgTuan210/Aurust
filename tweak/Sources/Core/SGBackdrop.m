#import <Accelerate/Accelerate.h>
#import "SGBackdrop.h"

static const size_t kCoverSample = 96;
static const uint32_t kBlurKernel = 19;

@interface SGScrimView : UIView
@end

@implementation SGScrimView
+ (Class)layerClass {
    return CAGradientLayer.class;
}
@end

// Pre-blurs the sampled cover once on CPU via SIMD tent convolution (~0.1 ms) instead of placing a
// full-screen live UIVisualEffectView over a static image on every scroll frame.
UIImage *SGBackdropSample(UIImage *cover) {
    if (!cover.CGImage) return cover;
    static NSMapTable<UIImage *, UIImage *> *cache;
    if (NSThread.isMainThread) {
        if (!cache) cache = [NSMapTable weakToStrongObjectsMapTable];
        UIImage *cached = [cache objectForKey:cover];
        if (cached) return cached;
    }

    size_t rowBytes = kCoverSample * 4;
    uint8_t *bufA = malloc(kCoverSample * rowBytes);
    uint8_t *bufB = malloc(kCoverSample * rowBytes);
    if (!bufA || !bufB) {
        free(bufA);
        free(bufB);
        return cover;
    }

    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(bufA, kCoverSample, kCoverSample, 8, rowBytes, space,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef src = cover.CGImage;
    CGFloat iw = CGImageGetWidth(src), ih = CGImageGetHeight(src);
    CGFloat scale = MAX((CGFloat)kCoverSample / MAX(iw, 1), (CGFloat)kCoverSample / MAX(ih, 1));
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake((kCoverSample - iw * scale) / 2, (kCoverSample - ih * scale) / 2,
                                       iw * scale, ih * scale), src);
    CGContextRelease(ctx);

    vImage_Buffer vA = {bufA, kCoverSample, kCoverSample, rowBytes};
    vImage_Buffer vB = {bufB, kCoverSample, kCoverSample, rowBytes};
    // Two tent passes yield a smooth 4th-order B-spline blur with zero 48px pixel seams.
    vImageTentConvolve_ARGB8888(&vA, &vB, NULL, 0, 0, kBlurKernel, kBlurKernel, NULL, kvImageEdgeExtend | kvImageDoNotTile);
    vImageTentConvolve_ARGB8888(&vB, &vA, NULL, 0, 0, kBlurKernel, kBlurKernel, NULL, kvImageEdgeExtend | kvImageDoNotTile);

    CGContextRef outCtx = CGBitmapContextCreate(bufA, kCoverSample, kCoverSample, 8, rowBytes, space,
                                                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef blurredCG = CGBitmapContextCreateImage(outCtx);
    CGContextRelease(outCtx);
    CGColorSpaceRelease(space);
    free(bufA);
    free(bufB);

    UIImage *result = blurredCG ? [UIImage imageWithCGImage:blurredCG scale:1 orientation:UIImageOrientationUp] : cover;
    if (blurredCG) CGImageRelease(blurredCG);
    if (NSThread.isMainThread && result) [cache setObject:result forKey:cover];
    return result;
}

UIView *SGBackdropMake(CGRect frame, CGFloat bottomAlpha) {
    UIViewAutoresizing fill = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIView *backdrop = [[UIView alloc] initWithFrame:frame];
    backdrop.userInteractionEnabled = NO;
    backdrop.clipsToBounds = YES;
    backdrop.autoresizingMask = fill;

    UIImageView *cover = [[UIImageView alloc] initWithFrame:backdrop.bounds];
    cover.contentMode = UIViewContentModeScaleAspectFill;
    cover.autoresizingMask = fill;
    cover.layer.magnificationFilter = kCAFilterTrilinear;
    [backdrop addSubview:cover];

    SGScrimView *scrim = [[SGScrimView alloc] initWithFrame:backdrop.bounds];
    scrim.autoresizingMask = fill;
    CAGradientLayer *fade = (CAGradientLayer *)scrim.layer;
    fade.colors = @[
        (id)[UIColor colorWithWhite:0 alpha:0.40].CGColor,
        (id)[UIColor colorWithWhite:0 alpha:0.60].CGColor,
        (id)[UIColor colorWithWhite:0 alpha:bottomAlpha].CGColor,
    ];
    fade.locations = @[@0, @0.5, @1];
    [backdrop addSubview:scrim];
    return backdrop;
}

UIImageView *SGBackdropImageView(UIView *backdrop) {
    return (UIImageView *)backdrop.subviews.firstObject;
}
