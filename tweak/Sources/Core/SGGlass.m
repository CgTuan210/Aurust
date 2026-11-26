#import "SGGlass.h"
#import "SGRuntime.h"

UIVisualEffect *SGGlassEffect(void) {
    Class glass = NSClassFromString(@"UIGlassEffect");
    if ([glass respondsToSelector:@selector(effectWithStyle:)]) return [glass effectWithStyle:0];
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
}

static UIVisualEffectView *newPane(void) {
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:SGGlassEffect()];
    glass.userInteractionEnabled = NO;
    glass.layer.zPosition = -1;
    return glass;
}

UIVisualEffectView *SGGlassFor(UIView *host, const void *key) {
    UIVisualEffectView *glass = objc_getAssociatedObject(host, key);
    if (!glass) {
        glass = newPane();
        objc_setAssociatedObject(host, key, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != host) [host insertSubview:glass atIndex:0];
    return glass;
}

static char kPanesKey;

UIVisualEffectView *SGGlassAt(UIView *host, NSUInteger index) {
    NSMutableArray<UIVisualEffectView *> *panes = objc_getAssociatedObject(host, &kPanesKey);
    if (!panes) {
        panes = [NSMutableArray array];
        objc_setAssociatedObject(host, &kPanesKey, panes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    while (panes.count <= index) [panes addObject:newPane()];
    UIVisualEffectView *glass = panes[index];
    glass.hidden = NO;
    if (glass.superview != host) [host insertSubview:glass atIndex:0];
    return glass;
}

void SGHideGlassFrom(UIView *host, NSUInteger count) {
    NSArray<UIVisualEffectView *> *panes = objc_getAssociatedObject(host, &kPanesKey);
    for (NSUInteger i = count; i < panes.count; i++) panes[i].hidden = YES;
}

static char kGlassShapeKey;

void SGShapeGlass(UIView *glass, CGFloat radius, BOOL capsule) {
    if (!glass) return;
    static Class config, cornerRadius;
    static BOOL supportsConfig, supportsCapsule, supportsUniform;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        config = NSClassFromString(@"UICornerConfiguration");
        cornerRadius = NSClassFromString(@"UICornerRadius");
        supportsConfig = config && [UIView instancesRespondToSelector:@selector(setCornerConfiguration:)];
        supportsCapsule = config && [config respondsToSelector:@selector(capsuleConfiguration)];
        supportsUniform = config && [config respondsToSelector:@selector(configurationWithUniformRadius:)]
            && [cornerRadius respondsToSelector:@selector(fixedRadius:)];
    });
    CGFloat effective = capsule && !supportsConfig ? glass.bounds.size.height / 2 : radius;
    NSNumber *last = objc_getAssociatedObject(glass, &kGlassShapeKey);
    // Pack capsule bit + 0.25pt-quantized radius so unchanged layout passes return in O(1).
    NSInteger stamp = ((NSInteger)llround(effective * 4.0) << 1) | (capsule ? 1 : 0);
    if (last && last.integerValue == stamp) return;

    id shape = nil;
    if (supportsConfig && [glass respondsToSelector:@selector(setCornerConfiguration:)]) {
        if (capsule && supportsCapsule) {
            shape = [config capsuleConfiguration];
        } else if (supportsUniform) {
            shape = [config configurationWithUniformRadius:[cornerRadius fixedRadius:radius]];
        }
    }
    if (shape) {
        [glass setCornerConfiguration:shape];
        glass.clipsToBounds = NO;
    } else {
        glass.layer.cornerRadius = effective;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.clipsToBounds = YES;
    }
    objc_setAssociatedObject(glass, &kGlassShapeKey, @(stamp), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
