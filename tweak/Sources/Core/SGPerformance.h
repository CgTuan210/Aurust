#import <UIKit/UIKit.h>

// Smooth mode for older or thermally/power-constrained iPhones:
// 0 = Auto (on for <= 4 GB RAM / A15-and-older devices, Low Power Mode, or thermal throttling),
// 1 = On (always prioritize frame rate and battery),
// 2 = Off (always render full effects unless Reduce Motion/Transparency is on).
#define SGKeySmoothMode @"spotifyglass.performance.smoothMode"

typedef NS_ENUM(NSInteger, SGSmoothModeChoice) {
    SGSmoothModeAuto = 0,
    SGSmoothModeOn = 1,
    SGSmoothModeOff = 2,
};

extern NSNotificationName const SGPerformanceDidChangeNotification;

// YES on older iPhone hardware (<= 4.5 GB RAM or iPhone14,* and earlier).
BOOL SGDeviceIsOlderHardware(void);
// YES when heavy per-frame blurs, multi-layer overdraw and uncached text shadows should step down.
BOOL SGPerformanceSmooth(void);
void SGSetSmoothModeChoice(SGSmoothModeChoice choice);
NSArray<NSString *> *SGSmoothModeNames(void);
