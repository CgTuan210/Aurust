#import "Core/SGCore.h"
#import "SGRField.h"
#import "SGRFlow.h"
#import "SGRFluid.h"
#import "SGRBridges.h"
#import "SGRPalette.h"
#import "SGRTokens.h"

NSNotificationName const SGRFieldColorDidChangeNotification = @"spotifyglass.redesign.fieldColorDidChange";

static const CGFloat kFallbackHeight = 874;   // a window-less field sizes for an iPhone 17 Pro

static const CGFloat kBlackFrom = 0.55, kBlackTo = 1;

static CGFloat windowHeight(UIView *view) {
    CGFloat height = view.window.bounds.size.height;
    return height > 0 ? height : kFallbackHeight;
}

static NSDictionary *noActions(void) {
    static NSDictionary *none;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNull *off = NSNull.null;
        none = @{@"bounds": off, @"position": off, @"frame": off, @"contents": off, @"backgroundColor": off,
                @"hidden": off, @"locations": off, @"opacity": off};
    });
    return none;
}

static NSArray<NSNumber *> *fillFadeLocations(void) {
    static NSArray<NSNumber *> *locations;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSNumber *> *stops = [NSMutableArray arrayWithCapacity:15];
        [stops addObject:@0];
        for (NSUInteger index = 0; index <= 12; index++) {
            CGFloat progress = (CGFloat)index / 12;
            [stops addObject:@(0.76 + (0.985 - 0.76) * progress)];
        }
        [stops addObject:@1];
        locations = [stops copy];
    });
    return locations;
}

static NSArray *fillFadeColorsFor(CGColorRef base) {
    UIColor *color = base ? [UIColor colorWithCGColor:base] : UIColor.blackColor;
    NSMutableArray *colors = [NSMutableArray arrayWithCapacity:15];
    [colors addObject:(id)[color colorWithAlphaComponent:0].CGColor];
    for (NSUInteger index = 0; index <= 12; index++) {
        CGFloat progress = (CGFloat)index / 12;
        CGFloat smooth = progress * progress * (3 - 2 * progress);
        [colors addObject:(id)[color colorWithAlphaComponent:smooth].CGColor];
    }
    [colors addObject:(id)[color colorWithAlphaComponent:1].CGColor];
    return colors;
}

// Subtle dark frosting added over the pre-blurred Fill cover when lyrics open.
static const float kLyricsDimOpacity = 0.24f;

@implementation SGRArtworkField {
    BOOL _lyricsBlurred;
    CALayer *_solid;
    CAGradientLayer *_black;
    CALayer *_backdrop;
    CALayer *_fillBackground;
    CALayer *_fill;
    CALayer *_fillBlur;
    CALayer *_fillLyricsBlur;
    CAGradientLayer *_fillFade;
    CALayer *_fillLyricsDim;
    SGRFlowLayer *_flow;
    SGRFluidLayer *_fluidLayer;
    BOOL _watching;
    BOOL _covered;
    UIColor *_color;
    UIColor *_preferred;   // the page's own colour, made fit; wins over the artwork's
    UIImage *_image;
    NSString *_identity;
    NSUInteger _generation;
    BOOL _read;
    BOOL _colored;   // a colour of the page's own is showing
    NSMutableArray<void (^)(void)> *_whenColored;
}

- (void)readPaletteForImage:(UIImage *)image animated:(BOOL)animated {
    if (_fluid) [_fluidLayer setArtwork:image animated:animated && self.window != nil];
    NSUInteger generation = ++_generation;
    SGRPaletteRequest request = {CGSizeZero, NO, YES, _flows, _fills};
    if (_showsBackdrop && !_flows && !_fluid && !_fills) request.backdropSize = CGSizeMake(self.bounds.size.width > 0 ? self.bounds.size.width : 402, [self backdropHeightNow]);
    __weak SGRArtworkField *weakSelf = self;
    [SGRPalette paletteForImage:image request:request completion:^(SGRPalette *palette) {
        SGRArtworkField *field = weakSelf;
        if (!field || !palette || generation != field->_generation) return;
        [field applyPalette:palette animated:animated && field.window != nil];
    }];
}

- (void)syncFillFadeColor {
    // Read back _fillBackground.backgroundColor so AMOLED black overrides stay matched seamlessly.
    _fillFade.colors = fillFadeColorsFor(_fillBackground.backgroundColor);
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = NO;
    self.accessibilityElementsHidden = YES;
    _color = SGRNeutralField();

    _solid = [CALayer layer];
    _solid.actions = noActions();
    _solid.backgroundColor = _color.CGColor;
    [self.layer addSublayer:_solid];

    _black = [CAGradientLayer layer];
    _black.actions = noActions();
    _black.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)UIColor.blackColor.CGColor];
    [self.layer addSublayer:_black];

    _backdrop = [CALayer layer];
    _backdrop.actions = noActions();
    _backdrop.contentsGravity = kCAGravityResize;
    _backdrop.hidden = YES;
    [self.layer addSublayer:_backdrop];
    _backdropOpacity = _fillOpacity = _fluidOpacity = 1;

    _fillBackground = [CALayer layer];
    _fillBackground.actions = noActions();
    _fillBackground.backgroundColor = UIColor.blackColor.CGColor;
    _fillBackground.hidden = YES;
    [self.layer addSublayer:_fillBackground];

    _fill = [CALayer layer];
    _fill.actions = noActions();
    _fill.contentsGravity = kCAGravityResizeAspectFill;
    _fill.masksToBounds = YES;
    _fill.hidden = YES;
    [self.layer addSublayer:_fill];

    // Progressive 4-band blur is pre-composited into one premultiplied RGBA8 texture (SGRPalette.m),
    // and _fillFade blends the bottom edge into _fillBackground with zero offscreen CALayer.mask passes.
    _fillBlur = [CALayer layer];
    _fillBlur.actions = noActions();
    _fillBlur.contentsGravity = kCAGravityResizeAspectFill;
    [_fill addSublayer:_fillBlur];

    // Pre-blurred Fill artwork shown while lyrics are open: 0 ms live GPU blur shader vs UIVisualEffectView.
    _fillLyricsBlur = [CALayer layer];
    _fillLyricsBlur.actions = noActions();
    _fillLyricsBlur.contentsGravity = kCAGravityResizeAspectFill;
    _fillLyricsBlur.opacity = 0;
    _fillLyricsBlur.hidden = YES;
    [_fill addSublayer:_fillLyricsBlur];

    _fillFade = [CAGradientLayer layer];
    _fillFade.actions = noActions();
    _fillFade.startPoint = CGPointMake(0.5, 0);
    _fillFade.endPoint = CGPointMake(0.5, 1);
    _fillFade.locations = fillFadeLocations();
    _fillFade.hidden = YES;
    [self syncFillFadeColor];
    [self.layer addSublayer:_fillFade];

    _fillLyricsDim = [CALayer layer];
    _fillLyricsDim.actions = noActions();
    _fillLyricsDim.backgroundColor = UIColor.blackColor.CGColor;
    _fillLyricsDim.opacity = 0;
    _fillLyricsDim.hidden = YES;
    [self.layer addSublayer:_fillLyricsDim];
    return self;
}

- (UIColor *)fieldColor {
    return _color;
}

- (CGFloat)backdropHeightNow {
    return _backdropHeight > 0 ? _backdropHeight : windowHeight(self);
}

- (void)setBleed:(UIEdgeInsets)bleed {
    _bleed = bleed;
    [self setNeedsLayout];
}

- (void)setBackdropHeight:(CGFloat)height {
    _backdropHeight = height;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    UIEdgeInsets bleed = _bleed;
    CGRect painted = CGRectMake(-bleed.left, -bleed.top, bounds.size.width + bleed.left + bleed.right, bounds.size.height + bleed.top + bleed.bottom);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _solid.frame = painted;
    CGFloat height = windowHeight(self), total = MAX(1, painted.size.height);
    CGFloat from = height * kBlackFrom + bleed.top;
    CGFloat to = MAX(from + 1, height * kBlackTo + bleed.top);
    _black.frame = painted;
    _black.locations = @[@(MIN(1, from / total)), @(MIN(1, to / total))];
    _backdrop.frame = CGRectMake(0, 0, bounds.size.width, [self backdropHeightNow]);
    CGFloat fillHeight = MIN(bounds.size.height, round(windowHeight(self) * 0.625));
    CGRect fillFrame = CGRectMake(0, 0, bounds.size.width, fillHeight);
    _fillBackground.frame = painted;
    _fill.frame = fillFrame;
    _fillBlur.frame = _fill.bounds;
    _fillBlur.contentsGravity = bounds.size.width > fillHeight ? kCAGravityResize : kCAGravityResizeAspectFill;
    _fillLyricsBlur.frame = _fill.bounds;
    _fillFade.frame = fillFrame;
    _fillLyricsDim.frame = painted;
    _flow.frame = CGRectMake(0, 0, bounds.size.width, [self backdropHeightNow]);
    _fluidLayer.frame = painted;
    // The screen's part of it, so the copies turn about it and the shade ends at the screen's foot.
    _fluidLayer.visibleRect = CGRectMake(bleed.left, bleed.top, bounds.size.width, height);
    [CATransaction commit];
}

#pragma mark - the moving field

- (void)setFluid:(BOOL)fluid {
    if (fluid == _fluid) return;
    _fluid = fluid;
    if (fluid) self.flows = NO;
    if (fluid && !_fluidLayer) {
        _fluidLayer = [SGRFluidLayer layer];
        [self.layer insertSublayer:_fluidLayer above:_solid];
    }
    // The fluid field is the whole picture, as the moving one is.
    _fluidLayer.hidden = !fluid || _covered;
    _fluidLayer.opacity = (float)_fluidOpacity;
    _black.hidden = fluid || _flows || _fills;
    _backdrop.hidden = fluid || _flows || _fills;
    _fillBackground.hidden = !_fills || fluid || _flows;
    _fill.hidden = fluid || _flows || !_fills || !_image.CGImage;
    _fillFade.hidden = _fill.hidden;
    if (fluid && _image) [_fluidLayer setArtwork:_image animated:NO];
    [self applyLyricsBlurAnimated:NO];
    [self watch];
    [self updateMotion];
    [self setNeedsLayout];
}

- (void)setFlows:(BOOL)flows {
    if (flows == _flows) return;
    _flows = flows;
    if (flows) self.fluid = NO;
    if (flows && !_flow) {
        _flow = [SGRFlowLayer layer];
        _flow.hidden = YES;
        [self.layer insertSublayer:_flow above:_solid];
    }
    // The moving field is the whole picture: no still backdrop over it, no fade to black under it.
    _black.hidden = flows || _fluid || _fills;
    _backdrop.hidden = flows || _fluid || _fills;
    _fillBackground.hidden = !_fills || flows || _fluid;
    _fill.hidden = flows || _fluid || !_fills || !_image.CGImage;
    _fillFade.hidden = _fill.hidden;
    if (!flows) _flow.hidden = YES;
    [self applyLyricsBlurAnimated:NO];
    [self watch];
    [self updateMotion];
    [self setNeedsLayout];
}

- (void)setLyricsBlurred:(BOOL)blurred animated:(BOOL)animated {
    if (_lyricsBlurred == blurred) return;
    _lyricsBlurred = blurred;
    [self applyLyricsBlurAnimated:animated];
}

- (void)animateLayerOpacity:(CALayer *)layer to:(float)target animated:(BOOL)animated {
    CALayer *shown = layer.presentationLayer ?: layer;
    float from = shown.opacity;
    layer.opacity = target;
    [layer removeAnimationForKey:@"opacity"];
    if (!animated || fabsf(from - target) < 0.005f) return;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(from);
    fade.toValue = @(target);
    fade.duration = 0.28;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [layer addAnimation:fade forKey:@"opacity"];
}

- (void)applyLyricsBlurAnimated:(BOOL)animated {
    BOOL on = _lyricsBlurred && _fills && !_fluid && !_flows;
    BOOL shouldAnimate = animated && self.window != nil && !SGRReduceMotion();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    BOOL hasBlurImage = _fillLyricsBlur.contents != nil;
    _fillLyricsBlur.hidden = !(on || shouldAnimate) || !hasBlurImage;
    _fillLyricsDim.hidden = !(on || shouldAnimate);
    [self animateLayerOpacity:_fillLyricsBlur to:(on && hasBlurImage) ? 1.0f : 0.0f animated:shouldAnimate && hasBlurImage];
    [self animateLayerOpacity:_fillLyricsDim to:on ? kLyricsDimOpacity : 0.0f animated:shouldAnimate];
    [CATransaction commit];
    if (!on && shouldAnimate) {
        __weak SGRArtworkField *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGRArtworkField *field = weakSelf;
            if (!field || (field->_lyricsBlurred && field->_fills && !field->_fluid && !field->_flows)) return;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            field->_fillLyricsBlur.hidden = YES;
            field->_fillLyricsDim.hidden = YES;
            [CATransaction commit];
        });
    }
}

- (void)setFills:(BOOL)fills {
    if (fills == _fills) return;
    _fills = fills;
    if (fills) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _fillBackground.backgroundColor = _color.CGColor;
        [self syncFillFadeColor];
        [CATransaction commit];
    }
    _black.hidden = fills || _fluid || _flows;
    _backdrop.hidden = fills || _fluid || _flows;
    _fillBackground.hidden = !fills || _fluid || _flows;
    _fill.hidden = !fills || _fluid || _flows || !_image.CGImage;
    _fillFade.hidden = _fill.hidden;
    [self applyLyricsBlurAnimated:NO];
}

- (void)setBackdropOpacity:(CGFloat)opacity {
    _backdropOpacity = MIN(1, MAX(0, opacity));
    _backdrop.opacity = (float)_backdropOpacity;
}

- (void)setFillOpacity:(CGFloat)opacity {
    _fillOpacity = MIN(1, MAX(0, opacity));
    _fill.opacity = (float)_fillOpacity;
}

- (void)setFluidOpacity:(CGFloat)opacity {
    _fluidOpacity = MIN(1, MAX(0, opacity));
    _fluidLayer.opacity = (float)_fluidOpacity;
}

- (void)setMotionHeld:(BOOL)held {
    if (held == _motionHeld) return;
    _motionHeld = held;
    [self updateMotion];
}

- (void)setCovered:(BOOL)covered {
    if (covered == _covered) return;
    _covered = covered;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fluidLayer.hidden = !_fluid || covered;
    [CATransaction commit];
}

- (void)watch {
    if (_watching || (!_flows && !_fluid)) return;
    _watching = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
                                      UIAccessibilityReduceMotionStatusDidChangeNotification]) {
        [center addObserver:self selector:@selector(updateMotionSoon) name:name object:nil];
    }
    SGRObservePlayerTransition(self, ^(id owner) { [owner updateMotion]; }, ^(id owner) { [owner updateMotion]; });
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// Accessibility notifications can arrive off the main thread.
- (void)updateMotionSoon {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateMotion]; });
}

- (void)updateMotion {
    if (!_flow && !_fluidLayer) return;
    // A locked phone keeps the player in its window, so being in front counts as much as being in one.
    // Both SGRFlow and SGRFluid are GPU-cached CoreAnimation layers (0% CPU) and automatically step down
    // via SGPerformanceSmooth() under Low Power Mode, so they stay gliding smoothly even when throttled.
    BOOL front = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL may = self.window && front && !SGRPlayerIsTransitioning() && !SGRReduceMotion() && !_motionHeld;
    _fluidLayer.moving = may && _fluid;
    BOOL moving = may && _flows && !_flow.hidden;
    if (!_flow || moving == _flow.moving) return;
    _flow.moving = moving;
    static NSUInteger logged;
    if (logged++ < 6) SGLog(@"redesign kit: moving field %@", moving ? @"moves" : @"holds still");
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateMotion];
}

- (void)applyColor:(UIColor *)color animated:(BOOL)animated {
    if (!color || CGColorEqualToColor(color.CGColor, _color.CGColor)) return;
    CALayer *shown = _solid.presentationLayer ?: _solid;
    id from = (__bridge id)shown.backgroundColor;
    _color = color;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _solid.backgroundColor = color.CGColor;
    [CATransaction commit];
    if (animated && from) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
        fade.fromValue = from;
        // Read back rather than the colour asked for: SGRAmoled.x may have swapped it for black.
        fade.toValue = (__bridge id)_solid.backgroundColor;
        fade.duration = SGRCrossfade;
        fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_solid addAnimation:fade forKey:@"backgroundColor"];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:SGRFieldColorDidChangeNotification object:self userInfo:@{@"color": color}];
}

- (void)whenColored:(void (^)(void))colored {
    if (!colored) return;
    if (_colored) {
        colored();
        return;
    }
    if (!_whenColored) _whenColored = [NSMutableArray array];
    [_whenColored addObject:[colored copy]];
}

- (void)didColor {
    if (_colored) return;
    _colored = YES;
    NSArray<void (^)(void)> *pending = _whenColored;
    _whenColored = nil;
    for (void (^colored)(void) in pending) colored();
}

- (void)setProvisionalColor:(UIColor *)color {
    if (_read || !color) return;
    [self applyColor:SGRFieldColorFor(color) animated:self.window != nil];
}

- (void)setPreferredColor:(UIColor *)color {
    if (!color) return;
    UIColor *fit = SGRFieldColorFor(color);
    if (_preferred && CGColorEqualToColor(fit.CGColor, _preferred.CGColor)) return;
    _preferred = fit;
    [self applyColor:fit animated:self.window != nil];
    [self didColor];
}

- (void)setArtwork:(UIImage *)image identity:(NSString *)identity animated:(BOOL)animated {
    if (!image || image == _image || (identity && [identity isEqualToString:_identity])) return;
    _image = image;
    _identity = [identity copy];
    _fill.contents = (__bridge id)image.CGImage;
    _fill.hidden = !_fills || _fluid || _flows || !image.CGImage;
    _fillFade.hidden = _fill.hidden;
    [self readPaletteForImage:image animated:animated];
}

- (void)refreshStyleAnimated:(BOOL)animated {
    if (_image) [self readPaletteForImage:_image animated:animated];
}

- (void)applyPalette:(SGRPalette *)palette animated:(BOOL)animated {
    _read = YES;
    if (_flows && palette.flowColors) {
        [_flow setColors:palette.flowColors animated:animated && !_flow.hidden];
        _flow.hidden = NO;
        [self updateMotion];
        // Past the moving field's edges (the pull that dismisses the player) the colour under it goes on.
        [self applyColor:_preferred ?: _flow.baseColor animated:animated];
        [self didColor];
        return;
    }
    if (_showsBackdrop && !_flows && !_fluid && !_fills && palette.backdrop) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        if (animated) {
            CATransition *fade = [CATransition animation];
            fade.type = kCATransitionFade;
            fade.duration = SGRCrossfade;
            [_backdrop addAnimation:fade forKey:@"contents"];
        }
        _backdrop.contents = (__bridge id)palette.backdrop.CGImage;
        _backdrop.opacity = (float)_backdropOpacity;
        _backdrop.hidden = NO;
        [CATransaction commit];
    }
    if (_fills) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        if (palette.fillBackgroundColor) {
            _fillBackground.backgroundColor = palette.fillBackgroundColor.CGColor;
            [self syncFillFadeColor];
        }
        if (palette.fillBlur) _fillBlur.contents = (__bridge id)palette.fillBlur.CGImage;
        if (palette.fillLyricsBlur) _fillLyricsBlur.contents = (__bridge id)palette.fillLyricsBlur.CGImage;
        [CATransaction commit];
        [self applyLyricsBlurAnimated:NO];
    }
    [self applyColor:_preferred ?: palette.fieldColor animated:animated];
    [self didColor];
}

@end
