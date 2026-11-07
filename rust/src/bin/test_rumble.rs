use std::ffi::c_void;
use std::ptr::null_mut;

use reclaimer_rumble::{FallbackHaptics, IOHIDDeviceRef, VENDOR_8BITDO};

type IOHIDManagerRef = *mut c_void;
type CFAllocatorRef = *mut c_void;
type CFDictionaryRef = *mut c_void;
type CFMutableDictionaryRef = *mut c_void;
type CFNumberRef = *mut c_void;
type CFStringRef = *mut c_void;
type CFSetRef = *mut c_void;
type CFIndex = isize;
type IOReturn = i32;

const K_CF_NUMBER_INT_TYPE: CFIndex = 9;

#[link(name = "IOKit", kind = "framework")]
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn IOHIDManagerCreate(allocator: CFAllocatorRef, options: u32) -> IOHIDManagerRef;
    fn IOHIDManagerSetDeviceMatching(manager: IOHIDManagerRef, matching: CFDictionaryRef);
    fn IOHIDManagerOpen(manager: IOHIDManagerRef, options: u32) -> IOReturn;
    fn IOHIDManagerCopyDevices(manager: IOHIDManagerRef) -> CFSetRef;
    fn CFNumberCreate(allocator: CFAllocatorRef, the_type: CFIndex, value_ptr: *const c_void) -> CFNumberRef;
    fn CFDictionaryCreateMutable(
        allocator: CFAllocatorRef,
        capacity: CFIndex,
        key_call_backs: *const c_void,
        value_call_backs: *const c_void,
    ) -> CFMutableDictionaryRef;
    fn CFDictionarySetValue(the_dict: CFMutableDictionaryRef, key: *const c_void, value: *const c_void);
    fn CFSetGetCount(the_set: CFSetRef) -> CFIndex;
    fn CFSetGetValues(the_set: CFSetRef, values: *mut *const c_void);
    fn CFRelease(cf: *mut c_void);
    fn __CFStringMakeConstantString(c_str: *const u8) -> CFStringRef;

    static kCFTypeDictionaryKeyCallBacks: c_void;
    static kCFTypeDictionaryValueCallBacks: c_void;
}

fn main() {
    println!("=== Testing Project Reclaimer Rust Rumble Module ===");
    unsafe {
        let mgr = IOHIDManagerCreate(null_mut(), 0);
        let vid: i32 = VENDOR_8BITDO as i32;
        let vid_num = CFNumberCreate(null_mut(), K_CF_NUMBER_INT_TYPE, &vid as *const i32 as *const c_void);
        let match_dict = CFDictionaryCreateMutable(
            null_mut(),
            1,
            &kCFTypeDictionaryKeyCallBacks as *const c_void,
            &kCFTypeDictionaryValueCallBacks as *const c_void,
        );
        let vid_key = __CFStringMakeConstantString(b"VendorID\0".as_ptr());
        CFDictionarySetValue(match_dict, vid_key as *const c_void, vid_num as *const c_void);
        IOHIDManagerSetDeviceMatching(mgr, match_dict as CFDictionaryRef);
        IOHIDManagerOpen(mgr, 0);

        let devices = IOHIDManagerCopyDevices(mgr);
        if devices.is_null() || CFSetGetCount(devices) == 0 {
            println!("No 8BitDo controller currently detected on Bluetooth/USB.");
            println!("Unit tests still run and verify the driver logic.");
            return;
        }

        let count = CFSetGetCount(devices);
        let mut dev_ptrs: Vec<*const c_void> = vec![null_mut(); count as usize];
        CFSetGetValues(devices, dev_ptrs.as_mut_ptr());

        let dev = dev_ptrs[0] as IOHIDDeviceRef;
        println!("Discovered 8BitDo gamepad at {:p}", dev);

        let haptics = FallbackHaptics::for_device(dev, VENDOR_8BITDO, 0x202F);
        println!("Dispatching test rumble pulse (left: 1.0, right: 0.5)...");
        haptics.send_rumble(1.0, 0.5).expect("send_rumble succeeded");

        std::thread::sleep(std::time::Duration::from_millis(350));

        println!("Stopping rumble...");
        haptics.stop().expect("stop succeeded");
        println!("Rust test completed successfully!");

        CFRelease(match_dict as *mut c_void);
        CFRelease(vid_num as *mut c_void);
        CFRelease(devices as *mut c_void);
        CFRelease(mgr as *mut c_void);
    }
}
