#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDManager.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <stdatomic.h>

static IOHIDDeviceRef g_8bitdo_device = NULL;
static pthread_mutex_t g_device_lock = PTHREAD_MUTEX_INITIALIZER;

// Non-blocking coalescing state for low-latency Bluetooth rumble
static atomic_uchar g_target_left = 0;
static atomic_uchar g_target_right = 0;
static uint8_t g_last_sent_left = 0xFF;
static uint8_t g_last_sent_right = 0xFF;
static atomic_bool g_dispatch_pending = false;
static dispatch_queue_t g_rumble_queue = NULL;

static void flush_rumble_to_device(void) {
    uint8_t left = atomic_load_explicit(&g_target_left, memory_order_relaxed);
    uint8_t right = atomic_load_explicit(&g_target_right, memory_order_relaxed);

    pthread_mutex_lock(&g_device_lock);
    IOHIDDeviceRef dev = g_8bitdo_device;
    if (dev && (left != g_last_sent_left || right != g_last_sent_right)) {
        uint8_t pkt[5] = { 0x05, left, right, 0x00, 0x00 };
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x05, pkt, sizeof(pkt));
        g_last_sent_left = left;
        g_last_sent_right = right;
    }
    pthread_mutex_unlock(&g_device_lock);
}

static inline void schedule_rumble_update(void) {
    if (!atomic_exchange_explicit(&g_dispatch_pending, true, memory_order_acq_rel)) {
        dispatch_async(g_rumble_queue, ^{
            atomic_store_explicit(&g_dispatch_pending, false, memory_order_release);
            flush_rumble_to_device();
        });
    }
}

// HID device matching callbacks for 8BitDo (VID 0x2DC8)
static void device_matched(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    pthread_mutex_lock(&g_device_lock);
    if (g_8bitdo_device) {
        CFRelease(g_8bitdo_device);
    }
    g_8bitdo_device = (IOHIDDeviceRef)CFRetain(device);
    g_last_sent_left = 0xFF;
    g_last_sent_right = 0xFF;
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
    g_rumble_queue = dispatch_queue_create("dev.projectreclaimer.8bitdo_rumble", DISPATCH_QUEUE_SERIAL);

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
            g_last_sent_left = 0xFF;
            g_last_sent_right = 0xFF;
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
        atomic_store_explicit(&g_target_left, 0, memory_order_relaxed);
    } else {
        atomic_store_explicit(&g_target_right, 0, memory_order_relaxed);
    }
    schedule_rumble_update();
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
                atomic_store_explicit(&g_target_left, byteVal, memory_order_relaxed);
            } else {
                atomic_store_explicit(&g_target_right, byteVal, memory_order_relaxed);
            }
            schedule_rumble_update();
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
    NSLog(@"[rumble_bridge] Initializing 8BitDo Native Rumble Bridge (low-latency coalesced)...");
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
