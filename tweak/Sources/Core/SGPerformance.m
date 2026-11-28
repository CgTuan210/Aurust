#import <sys/sysctl.h>
#import <stdatomic.h>
#import "SGPerformance.h"
#import "SGPrefs.h"
#import "SGLog.h"

NSNotificationName const SGPerformanceDidChangeNotification = @"spotifyglass.performance.didChange";

static _Atomic int sg_cachedChoice = -1;
static _Atomic bool sg_lowPower = false;
static _Atomic bool sg_thermalHot = false;
static BOOL sg_olderHardware = NO;

static BOOL detectOlderHardware(void) {
    // Devices with <= 4.5 GB physical RAM (iPhone 13, SE 3, 12, 11, XS, XR, X, 8 and older iPads).
    unsigned long long memory = NSProcessInfo.processInfo.physicalMemory;
    if (memory > 0 && memory <= (4608ULL * 1024ULL * 1024ULL)) return YES;

    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) == 0 && size > 1 && size < 64) {
        char machine[64] = {0};
        if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == 0) {
            // iPhone14,x is A15 (iPhone 13 / 13 Pro / SE 3, plus 14 / 14 Plus); anything <= 14 benefits from Smooth Mode.
            int major = 0;
            if (sscanf(machine, "iPhone%d,", &major) == 1 && major > 0 && major <= 14) return YES;
            if (sscanf(machine, "iPad%d,", &major) == 1 && major > 0 && major <= 12) return YES;
        }
    }
    return NO;
}

static void refreshDynamicStates(void) {
    NSProcessInfo *info = NSProcessInfo.processInfo;
    atomic_store_explicit(&sg_lowPower, info.lowPowerModeEnabled, memory_order_relaxed);
    NSProcessInfoThermalState thermal = info.thermalState;
    atomic_store_explicit(&sg_thermalHot,
        thermal == NSProcessInfoThermalStateSerious || thermal == NSProcessInfoThermalStateCritical,
        memory_order_relaxed);
}

static BOOL computeSmooth(void) {
    int choice = atomic_load_explicit(&sg_cachedChoice, memory_order_relaxed);
    if (choice == SGSmoothModeOn) return YES;
    if (choice == SGSmoothModeOff) return NO;
    return sg_olderHardware
        || atomic_load_explicit(&sg_lowPower, memory_order_relaxed)
        || atomic_load_explicit(&sg_thermalHot, memory_order_relaxed);
}

static void ensurePerformanceInitialized(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_olderHardware = detectOlderHardware();
        NSInteger stored = SGInt(SGKeySmoothMode, SGSmoothModeAuto);
        if (stored < SGSmoothModeAuto || stored > SGSmoothModeOff) stored = SGSmoothModeAuto;
        atomic_store_explicit(&sg_cachedChoice, (int)stored, memory_order_relaxed);
        refreshDynamicStates();

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[NSProcessInfoPowerStateDidChangeNotification,
                                          NSProcessInfoThermalStateDidChangeNotification]) {
            [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                BOOL before = computeSmooth();
                refreshDynamicStates();
                BOOL after = computeSmooth();
                if (before != after) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [NSNotificationCenter.defaultCenter postNotificationName:SGPerformanceDidChangeNotification object:nil];
                    });
                }
            }];
        }
        SGLog(@"performance: olderHardware=%d smooth=%d (choice=%ld)", sg_olderHardware, computeSmooth(), (long)stored);
    });
}

BOOL SGDeviceIsOlderHardware(void) {
    ensurePerformanceInitialized();
    return sg_olderHardware;
}

BOOL SGPerformanceSmooth(void) {
    ensurePerformanceInitialized();
    return computeSmooth();
}

void SGSetSmoothModeChoice(SGSmoothModeChoice choice) {
    ensurePerformanceInitialized();
    if (choice < SGSmoothModeAuto || choice > SGSmoothModeOff) choice = SGSmoothModeAuto;
    SGSetInt(SGKeySmoothMode, choice);
    atomic_store_explicit(&sg_cachedChoice, (int)choice, memory_order_relaxed);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SGPerformanceDidChangeNotification object:nil];
    });
}

NSArray<NSString *> *SGSmoothModeNames(void) {
    return @[@"Auto", @"On", @"Off"];
}
