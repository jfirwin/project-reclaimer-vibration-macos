#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDManager.h>
#import <objc/runtime.h>
#include <pthread.h>

static IOHIDDeviceRef g_8bitdo_device = NULL;
static pthread_mutex_t g_device_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t g_left_motor = 0;
static uint8_t g_right_motor = 0;

static void send_8bitdo_rumble(uint8_t left, uint8_t right) {
    pthread_mutex_lock(&g_device_lock);
    IOHIDDeviceRef dev = g_8bitdo_device;
    if (dev) {
        uint8_t pkt[5] = { 0x05, left, right, 0x00, 0x00 };
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x05, pkt, sizeof(pkt));
    }
    pthread_mutex_unlock(&g_device_lock);
}

// HID device matching callbacks for 8BitDo (VID 0x2DC8)
static void device_matched(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    pthread_mutex_lock(&g_device_lock);
    if (g_8bitdo_device) {
        CFRelease(g_8bitdo_device);
    }
    g_8bitdo_device = (IOHIDDeviceRef)CFRetain(device);
    NSLog(@"[rumble_bridge] 8BitDo controller discovered & retained: %p", g_8bitdo_device);
    pthread_mutex_unlock(&g_device_lock);
}

static void device_removed(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    pthread_mutex_lock(&g_device_lock);
    if (g_8bitdo_device == device) {
        CFRelease(g_8bitdo_device);
        g_8bitdo_device = NULL;
        NSLog(@"[rumble_bridge] 8BitDo controller disconnected: %p", device);
    }
    pthread_mutex_unlock(&g_device_lock);
}

static void init_hid_manager(void) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    int vid = 0x2DC8;
    CFNumberRef vidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), vidNum);
    IOHIDManagerSetDeviceMatching(mgr, match);
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, device_matched, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(mgr, device_removed, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    CFRelease(match);
    CFRelease(vidNum);

    // Initial check in case device is already attached
    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    if (set) {
        CFIndex count = CFSetGetCount(set);
        if (count > 0) {
            IOHIDDeviceRef devs[count];
            CFSetGetValues(set, (const void**)devs);
            pthread_mutex_lock(&g_device_lock);
            g_8bitdo_device = (IOHIDDeviceRef)CFRetain(devs[0]);
            NSLog(@"[rumble_bridge] 8BitDo controller matched on startup: %p", g_8bitdo_device);
            pthread_mutex_unlock(&g_device_lock);
        }
        CFRelease(set);
    }
}

// Mock player conforming to CHHapticAdvancedPatternPlayer
@interface Reclaimer8BitDoPlayer : NSObject <CHHapticAdvancedPatternPlayer>
@property (nonatomic, strong) NSString *locality;
@end

@implementation Reclaimer8BitDoPlayer
@synthesize isMuted = _isMuted;
@synthesize loopEnabled = _loopEnabled;
@synthesize loopEnd = _loopEnd;
@synthesize playbackRate = _playbackRate;
@synthesize completionHandler = _completionHandler;

- (BOOL)startAtTime:(NSTimeInterval)time error:(NSError **)error {
    if (error) *error = nil;
    return YES;
}

- (BOOL)stopAtTime:(NSTimeInterval)time error:(NSError **)error {
    if (error) *error = nil;
    if ([self.locality isEqualToString:GCHapticsLocalityLeftHandle]) {
        g_left_motor = 0;
    } else {
        g_right_motor = 0;
    }
    send_8bitdo_rumble(g_left_motor, g_right_motor);
    return YES;
}

- (BOOL)sendParameters:(NSArray<CHHapticDynamicParameter *> *)parameters atTime:(NSTimeInterval)time error:(NSError **)error {
    if (error) *error = nil;
    for (CHHapticDynamicParameter *p in parameters) {
        if ([p.parameterID isEqualToString:CHHapticDynamicParameterIDHapticIntensityControl]) {
            float val = p.value;
            if (val < 0.0f) val = 0.0f;
            if (val > 1.0f) val = 1.0f;
            uint8_t byteVal = (uint8_t)(val * 255.0f);
            if ([self.locality isEqualToString:GCHapticsLocalityLeftHandle]) {
                if (g_left_motor != byteVal) {
                    g_left_motor = byteVal;
                    send_8bitdo_rumble(g_left_motor, g_right_motor);
                }
            } else {
                if (g_right_motor != byteVal) {
                    g_right_motor = byteVal;
                    send_8bitdo_rumble(g_left_motor, g_right_motor);
                }
            }
        }
    }
    return YES;
}

- (BOOL)scheduleParameterCurve:(CHHapticParameterCurve *)parameterCurve atTime:(NSTimeInterval)time error:(NSError **)error {
    if (error) *error = nil;
    return YES;
}

- (BOOL)cancelAndReturnError:(NSError **)error {
    return [self stopAtTime:0 error:error];
}

- (BOOL)pauseAtTime:(NSTimeInterval)time error:(NSError **)error {
    return [self stopAtTime:time error:error];
}

- (BOOL)resumeAtTime:(NSTimeInterval)time error:(NSError **)error {
    return [self startAtTime:time error:error];
}

- (BOOL)seekToOffset:(NSTimeInterval)offsetTime error:(NSError **)error {
    if (error) *error = nil;
    return YES;
}
@end

// Mock engine returning mock player
@interface Reclaimer8BitDoEngine : NSObject
@property (nonatomic, strong) NSString *locality;
@end

@implementation Reclaimer8BitDoEngine
- (BOOL)startAndReturnError:(NSError **)error {
    if (error) *error = nil;
    return YES;
}

- (id<CHHapticPatternPlayer>)createPlayerWithPattern:(CHHapticPattern *)pattern error:(NSError **)error {
    if (error) *error = nil;
    Reclaimer8BitDoPlayer *player = [[Reclaimer8BitDoPlayer alloc] init];
    player.locality = self.locality;
    return player;
}

- (id<CHHapticAdvancedPatternPlayer>)createAdvancedPlayerWithPattern:(CHHapticPattern *)pattern error:(NSError **)error {
    if (error) *error = nil;
    Reclaimer8BitDoPlayer *player = [[Reclaimer8BitDoPlayer alloc] init];
    player.locality = self.locality;
    return player;
}
@end

// Mock GCDeviceHaptics
@interface Reclaimer8BitDoHaptics : NSObject
@property (nonatomic, weak) GCController *controller;
@end

@implementation Reclaimer8BitDoHaptics
- (CHHapticEngine *)createEngineWithLocality:(GCHapticsLocality)locality {
    NSLog(@"[rumble_bridge] createEngineWithLocality: %@", locality);
    Reclaimer8BitDoEngine *engine = [[Reclaimer8BitDoEngine alloc] init];
    engine.locality = locality;
    return (CHHapticEngine *)engine;
}
@end

// Swizzling -[GCController haptics]
static IMP original_haptics_imp = NULL;

static GCDeviceHaptics *swizzled_haptics(GCController *self, SEL _cmd) {
    GCDeviceHaptics *realHaptics = ((GCDeviceHaptics *(*)(id, SEL))original_haptics_imp)(self, _cmd);
    if (realHaptics != nil) {
        return realHaptics;
    }

    NSString *name = [self vendorName];
    pthread_mutex_lock(&g_device_lock);
    BOOL has8BitDo = (g_8bitdo_device != NULL);
    pthread_mutex_unlock(&g_device_lock);

    if (has8BitDo || (name && [name localizedCaseInsensitiveContainsString:@"Ultimate"]) ||
                     (name && [name localizedCaseInsensitiveContainsString:@"8BitDo"])) {
        NSLog(@"[rumble_bridge] Providing synthetic haptics bridge for %@", name);
        Reclaimer8BitDoHaptics *mock = objc_getAssociatedObject(self, "reclaimer_8bitdo_haptics");
        if (!mock) {
            mock = [[Reclaimer8BitDoHaptics alloc] init];
            mock.controller = self;
            objc_setAssociatedObject(self, "reclaimer_8bitdo_haptics", mock, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return (GCDeviceHaptics *)mock;
    }

    return nil;
}

__attribute__((constructor)) static void setup_rumble_bridge(void) {
    NSLog(@"[rumble_bridge] Initializing 8BitDo Native Rumble Bridge...");
    init_hid_manager();

    Class gcClass = objc_getClass("GCController");
    if (!gcClass) {
        NSLog(@"[rumble_bridge] GCController class not found!");
        return;
    }

    Method m = class_getInstanceMethod(gcClass, @selector(haptics));
    if (m) {
        original_haptics_imp = method_setImplementation(m, (IMP)swizzled_haptics);
        NSLog(@"[rumble_bridge] Successfully swizzled -[GCController haptics]");
    } else {
        NSLog(@"[rumble_bridge] Failed to find -[GCController haptics]");
    }
}
