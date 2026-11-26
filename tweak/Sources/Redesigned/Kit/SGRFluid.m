#import <CoreImage/CoreImage.h>
#import "Core/SGCore.h"
#import "SGRFluid.h"
#import "SGRTokens.h"

// Each copy: its side as a share of the visible rect's longer side, its center as shares of that rect, and
// one turn's length in seconds (negative turns the other way).
static const struct { CGFloat side, x, y; CFTimeInterval turn; } kCopy[] = {
    {2.2, 0.25, 0.20, 46},
    {2.0, 0.80, 0.35, -61},
    {2.4, 0.30, 0.75, 73},
    {1.8, 0.70, 0.85, -54},
};
enum { kCopies = sizeof(kCopy) / sizeof(kCopy[0]) };
static const CGFloat kBlurSide = 128, kBlurPerStep = 1.25, kBrightness = -0.08;
static const float kOverOpacity = 0.7;
static const CGFloat kShadeFrom = 0.45, kShadeAlpha = 0.55;

NSNotificationName const SGRFluidSettingsDidChangeNotification = @"spotifyglass.redesign.fluidSettingsDidChange";

static const struct { __unsafe_unretained NSString *key; SGRFluidLimits limits; } kSetting[] = {
    {@"spotifyglass.redesign.fluid.speed", {25, 300, 25, 100}},
    {@"spotifyglass.redesign.fluid.warp", {0, 100, 5, 100}},
    {@"spotifyglass.redesign.fluid.blur", {2, 24, 1, 8}},
    {@"spotifyglass.redesign.fluid.saturation", {0, 250, 10, 150}},
    {@"spotifyglass.redesign.fluid.brightness", {40, 150, 5, 100}},
};

SGRFluidLimits SGRFluidLimitsOf(SGRFluidSetting setting) {
    return kSetting[setting].limits;
}

NSInteger SGRFluidValue(SGRFluidSetting setting) {
    SGRFluidLimits l = kSetting[setting].limits;
    return MIN(l.most, MAX(l.least, SGInt(kSetting[setting].key, l.standard)));
}

void SGRSetFluidValue(SGRFluidSetting setting, NSInteger value) {
    SGSetInt(kSetting[setting].key, value);
    [NSNotificationCenter.defaultCenter postNotificationName:SGRFluidSettingsDidChangeNotification object:nil];
}

void SGRResetFluidSettings(void) {
    for (NSInteger i = 0; i < SGRFluidSettingCount; i++) [NSUserDefaults.standardUserDefaults removeObjectForKey:kSetting[i].key];
    [NSNotificationCenter.defaultCenter postNotificationName:SGRFluidSettingsDidChangeNotification object:nil];
}

static void initFluidLUTs(float byteToLinear[256], uint8_t linearToByte[4097]) {
    for (int i = 0; i < 256; i++) {
        double v = i / 255.0;
        byteToLinear[i] = (float)(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4));
    }
    for (int i = 0; i <= 4096; i++) {
        double v = i / 4096.0;
        double enc = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
        int byte = (int)floor(255.0 * MIN(1.0, MAX(0.0, enc)));
        linearToByte[i] = (uint8_t)byte;
    }
}

static UIImage *blurred(UIImage *image, BOOL contrast, CGFloat radius, CGFloat saturation, CGFloat gain) {
    CGImageRef source = image.CGImage;
    if (!source) return nil;
    CIImage *input = [CIImage imageWithCGImage:source];
    CGFloat scale = kBlurSide / MAX(input.extent.size.width, input.extent.size.height);
    input = [input imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect extent = input.extent;
    CIImage *output = [[[input imageByClampingToExtent]
        imageByApplyingFilter:@"CIGaussianBlur" withInputParameters:@{kCIInputRadiusKey: @(radius)}]
        imageByApplyingFilter:@"CIColorControls" withInputParameters:@{kCIInputSaturationKey: @(saturation), kCIInputBrightnessKey: @(kBrightness)}];
    static CIContext *context;
    static float sByteToLinear[256];
    static uint8_t sLinearToByte[4097];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO}];
        initFluidLUTs(sByteToLinear, sLinearToByte);
    });
    CGImageRef cg = [context createCGImage:[output imageByCroppingToRect:extent] fromRect:extent];
    if (!cg) return nil;

    size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!bitmap) { CGImageRelease(cg); return nil; }
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), cg);
    CGImageRelease(cg);
    unsigned char *pixels = CGBitmapContextGetData(bitmap);
    float ceiling = contrast ? 0.04f : 0.07f;
    float fGain = (float)gain;
    size_t total = width * height;
    for (size_t i = 0; i < total; i++) {
        unsigned char *p = pixels + i * 4;
        float r = fGain * sByteToLinear[p[0]];
        float g = fGain * sByteToLinear[p[1]];
        float b = fGain * sByteToLinear[p[2]];
        float light = 0.2126f * r + 0.7152f * g + 0.0722f * b;
        float cap = light > ceiling ? ceiling / light : 1.0f;
        int ir = (int)(MIN(1.0f, r * cap) * 4096.0f + 0.5f);
        int ig = (int)(MIN(1.0f, g * cap) * 4096.0f + 0.5f);
        int ib = (int)(MIN(1.0f, b * cap) * 4096.0f + 0.5f);
        p[0] = sLinearToByte[ir];
        p[1] = sLinearToByte[ig];
        p[2] = sLinearToByte[ib];
        p[3] = 255;
    }
    cg = CGBitmapContextCreateImage(bitmap);
    UIImage *result = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg) CGImageRelease(cg);
    CGContextRelease(bitmap);
    return result;
}

@implementation SGRFluidLayer {
    CALayer *_copies[kCopies];
    CAGradientLayer *_shade;
    UIImage *_source;
    NSUInteger _generation;
    BOOL _moving;
    CFTimeInterval _since, _elapsed;
    CGFloat _rate, _warp;
    CGRect _laidOutFor;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.masksToBounds = YES;
    self.backgroundColor = UIColor.blackColor.CGColor;
    for (int i = 0; i < kCopies; i++) {
        _copies[i] = [CALayer layer];
        _copies[i].contentsGravity = kCAGravityResizeAspectFill;
        if (i == 0) _copies[i].opaque = YES;
        [self addSublayer:_copies[i]];
    }
    [self applyWarp];
    _shade = [CAGradientLayer layer];
    _shade.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:kShadeAlpha].CGColor];
    [self addSublayer:_shade];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(contrastChanged)
        name:UIAccessibilityDarkerSystemColorsStatusDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(settingsChanged)
        name:SGRFluidSettingsDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(performanceChanged)
        name:SGPerformanceDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)contrastChanged {
    dispatch_async(dispatch_get_main_queue(), ^{ [self reblur]; });
}

- (void)performanceChanged {
    BOOL moving = _moving;
    if (moving) [self stop];
    [self applyWarp];
    if (moving) [self start];
}

- (void)reblur {
    UIImage *source = _source;
    _source = nil;
    [self setArtwork:source animated:NO];
}

// In Smooth Mode, keep 3 counter-rotating layers so multi-directional interference stays rich while trimming full-screen overdraw.
- (void)applyWarp {
    _warp = SGRFluidValue(SGRFluidWarp) / 100.0;
    BOOL smooth = SGPerformanceSmooth();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 1; i < kCopies; i++) {
        BOOL hideExtra = smooth && i >= 3;
        _copies[i].hidden = hideExtra;
        _copies[i].opacity = hideExtra ? 0 : kOverOpacity * (float)_warp;
    }
    [CATransaction commit];
}

- (void)settingsChanged {
    BOOL moving = _moving;
    if (moving) [self stop];
    [self applyWarp];
    _laidOutFor = CGRectNull;
    [self setNeedsLayout];
    if (moving) [self start];
    [self reblur];
}

- (BOOL)moving {
    return _moving;
}

- (void)setVisibleRect:(CGRect)rect {
    if (CGRectEqualToRect(rect, _visibleRect)) return;
    _visibleRect = rect;
    [self setNeedsLayout];
}

- (void)layoutSublayers {
    [super layoutSublayers];
    CGRect bounds = self.bounds;
    CGRect visible = CGRectIsEmpty(_visibleRect) ? bounds : _visibleRect;
    CGFloat total = MAX(1, bounds.size.height);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shade.frame = bounds;
    _shade.locations = @[@(MIN(1, (CGRectGetMinY(visible) + visible.size.height * kShadeFrom) / total)),
                         @(MIN(1, CGRectGetMaxY(visible) / total))];
    if (!CGRectEqualToRect(visible, _laidOutFor) && visible.size.width >= 1) {
        _laidOutFor = visible;
        BOOL moving = _moving;
        if (moving) [self stop];
        CGFloat longer = MAX(visible.size.width, visible.size.height);
        for (int i = 0; i < kCopies; i++) {
            CGFloat side = round(longer * kCopy[i].side);
            _copies[i].bounds = CGRectMake(0, 0, side, side);
            _copies[i].position = CGPointMake(CGRectGetMidX(visible) + visible.size.width * (kCopy[i].x - 0.5) * _warp,
                                              CGRectGetMidY(visible) + visible.size.height * (kCopy[i].y - 0.5) * _warp);
        }
        if (moving) [self start];
    }
    [CATransaction commit];
}

- (void)setArtwork:(UIImage *)image animated:(BOOL)animated {
    if (!image || image == _source) return;
    _source = image;
    NSUInteger generation = ++_generation;
    BOOL contrast = SGRIncreaseContrast();
    CGFloat radius = kBlurPerStep * SGRFluidValue(SGRFluidBlur), saturation = SGRFluidValue(SGRFluidSaturation) / 100.0;
    CGFloat gain = SGRFluidValue(SGRFluidBrightness) / 100.0;
    __weak SGRFluidLayer *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *blur = blurred(image, contrast, radius, saturation, gain);
        dispatch_async(dispatch_get_main_queue(), ^{
            SGRFluidLayer *layer = weakSelf;
            if (!blur || !layer || generation != layer->_generation) return;
            [layer show:blur animated:animated];
        });
    });
}

- (void)show:(UIImage *)blur animated:(BOOL)animated {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < kCopies; i++) {
        if (animated && !_copies[i].hidden) {
            CATransition *fade = [CATransition animation];
            fade.type = kCATransitionFade;
            fade.duration = SGRCrossfade;
            [_copies[i] addAnimation:fade forKey:@"contents"];
        }
        _copies[i].contents = (__bridge id)blur.CGImage;
    }
    [CATransaction commit];
}

#pragma mark - moving

- (void)setMoving:(BOOL)moving {
    if (moving == _moving) return;
    _moving = moving;
    if (moving) [self start];
    else [self stop];
}

- (void)start {
    if (self.bounds.size.width < 1) return;
    _since = CACurrentMediaTime();
    _rate = SGRFluidValue(SGRFluidSpeed) / 100.0;
    BOOL smooth = SGPerformanceSmooth();
    CAFrameRateRange rate = smooth ? CAFrameRateRangeMake(20, 60, 30) : CAFrameRateRangeMake(24, 60, 30);
    int activeCopies = smooth ? 3 : kCopies;
    for (int i = 0; i < activeCopies; i++) {
        CFTimeInterval length = fabs(kCopy[i].turn);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _copies[i].transform = CATransform3DIdentity;
        [CATransaction commit];
        CABasicAnimation *turn = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        turn.byValue = @(kCopy[i].turn > 0 ? 2 * M_PI : -2 * M_PI);
        turn.duration = length / _rate;
        turn.repeatCount = HUGE_VALF;
        turn.additive = YES;
        turn.timeOffset = fmod(_elapsed, length) / _rate;
        turn.preferredFrameRateRange = rate;
        [_copies[i] addAnimation:turn forKey:@"turn"];
    }
}

- (void)stop {
    if (_since > 0) _elapsed += (CACurrentMediaTime() - _since) * _rate;
    _since = 0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < kCopies; i++) {
        CFTimeInterval length = fabs(kCopy[i].turn);
        CGFloat angle = (kCopy[i].turn > 0 ? 1 : -1) * 2 * M_PI * fmod(_elapsed, length) / length;
        [_copies[i] removeAnimationForKey:@"turn"];
        _copies[i].transform = CATransform3DMakeRotation(angle, 0, 0, 1);
    }
    [CATransaction commit];
}

@end
