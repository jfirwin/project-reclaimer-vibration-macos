# Upstream Proposal: 8BitDo Gamepad Haptics Fallback for macOS

## Background

On macOS, Project Reclaimer uses `objc2-game-controller` (`GCController`) for controller input and `objc2-core-haptics` (`CHHapticEngine`) for vibration.

When third-party Bluetooth controllers (such as the 8BitDo Ultimate 3 / 3E) connect, the engine logs:
```text
[gamepad] Ultimate 3 Controller connected (controller 0)
[gamepad] no rumble on Ultimate 3 Controller: no haptics
```

## Root Cause

Apple's `GameController.framework` only provides `GCController.haptics` (`GCDeviceHaptics`) for Apple-certified / first-party gamepads (Sony DualShock 4 / DualSense, Xbox Wireless, and Nintendo Switch Pro). For all other Bluetooth gamepads, `controller.haptics()` returns `None`.

However, the hardware itself supports full dual-motor palm rumble over Bluetooth via raw HID output reports.

## Solution

The engine already utilizes `IOKit` / `IOHIDManager` for input matching. By adding a small direct HID fallback when `controller.haptics()` is `None`, 8BitDo controllers get full vibration support with zero overhead.

### 8BitDo Bluetooth Haptic Protocol (Report ID `0x05`)

- **Vendor ID:** `0x2DC8` (8BitDo)
- **Report Type:** `kIOHIDReportTypeOutput` (1)
- **Report ID:** `0x05`
- **Payload (5 bytes):**
  - Byte 0: `0x05` (Report ID)
  - Byte 1: Left heavy palm motor (`0..=255`, low-frequency concussive rumble)
  - Byte 2: Right light palm motor (`0..=255`, high-frequency buzz)
  - Bytes 3–4: `0x00` (reserved)

### Rust Implementation

```rust
use std::ffi::c_void;

pub type IOHIDDeviceRef = *mut c_void;
pub type IOReturn = i32;

const K_IOHID_REPORT_TYPE_OUTPUT: u32 = 1;
const K_IORETURN_SUCCESS: IOReturn = 0;

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOHIDDeviceSetReport(
        device: IOHIDDeviceRef,
        report_type: u32,
        report_id: isize,
        report: *const u8,
        report_length: isize,
    ) -> IOReturn;
}

pub struct EightBitDoRumble;

impl EightBitDoRumble {
    pub const VENDOR_ID: u16 = 0x2DC8;

    /// Dispatches left and right rumble (0..=255).
    pub fn send_rumble(device: IOHIDDeviceRef, left: u8, right: u8) -> Result<(), IOReturn> {
        if device.is_null() {
            return Err(-1);
        }
        let pkt: [u8; 5] = [0x05, left, right, 0x00, 0x00];
        unsafe {
            let ret = IOHIDDeviceSetReport(
                device,
                K_IOHID_REPORT_TYPE_OUTPUT,
                0x05,
                pkt.as_ptr(),
                pkt.len() as isize,
            );
            if ret == K_IORETURN_SUCCESS {
                Ok(())
            } else {
                Err(ret)
            }
        }
    }

    /// Stops vibration.
    #[inline]
    pub fn stop(device: IOHIDDeviceRef) -> Result<(), IOReturn> {
        Self::send_rumble(device, 0, 0)
    }
}
```

### Performance Note: Bluetooth Bandwidth & Coalescing

`IOHIDDeviceSetReport` is a synchronous, blocking HID transaction over USB and Bluetooth. Over Bluetooth ACL/L2CAP, sending separate reports for left and right motors on every 60 Hz frame creates 120 packets/sec, which exceeds Bluetooth throughput and causes queue backlog (perceived as delayed, "sluggish" vibration).

**Best Practice:**
1. Update target motor intensities (`left` and `right`) in memory.
2. Coalesce both motors into a single 5-byte report (`0x05`).
3. Dispatch reports asynchronously off the main engine loop (or only when values actually change), dropping intermediate decay steps if the Bluetooth stack is busy transmitting the previous packet.

In the controller initialization routine (where `controller.haptics()` is queried):

```rust
let haptics_channel = if let Some(haptics) = controller.haptics() {
    // Existing CoreHaptics path (first-party controllers)
    Some(HapticsChannel::CoreHaptics(...))
} else if let Some(hid_dev) = find_matching_iohid_device(controller) {
    if EightBitDoRumble::VENDOR_ID == hid_dev.vendor_id() {
        Some(HapticsChannel::Direct8BitDo(hid_dev.raw_ref()))
    } else {
        None
    }
} else {
    None
};
```

And in the game tick:
```rust
match &controller.haptics {
    Some(HapticsChannel::CoreHaptics(player)) => {
        // Send CHHapticDynamicParameter
    }
    Some(HapticsChannel::Direct8BitDo(dev)) => {
        let left = (left_intensity * 255.0).clamp(0.0, 255.0) as u8;
        let right = (right_intensity * 255.0).clamp(0.0, 255.0) as u8;
        let _ = EightBitDoRumble::send_rumble(*dev, left, right);
    }
    None => {}
}
```
