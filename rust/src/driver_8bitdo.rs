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

/// 8BitDo Vendor ID
pub const VENDOR_8BITDO: u16 = 0x2DC8;

/// Known verified 8BitDo Product IDs with rumble over Bluetooth
pub const PRODUCT_8BITDO_ULTIMATE_3E: u16 = 0x202F;

pub struct EightBitDoDriver;

impl EightBitDoDriver {
    /// Returns true if the vendor ID matches 8BitDo.
    #[inline]
    pub fn is_match(vendor_id: u16, _product_id: u16) -> bool {
        vendor_id == VENDOR_8BITDO
    }

    /// Builds the 5-byte HID Output report for 8BitDo controllers.
    ///
    /// - Byte 0: Report ID (0x05)
    /// - Byte 1: Left Heavy Palm Motor (low-frequency concussive rumble, 0..=255)
    /// - Byte 2: Right Light Palm Motor (high-frequency weapon cycle buzz, 0..=255)
    /// - Bytes 3-4: 0x00 (reserved)
    #[inline]
    pub fn build_report(left: u8, right: u8) -> [u8; 5] {
        [0x05, left, right, 0x00, 0x00]
    }

    /// Sends a rumble packet directly to the controller via IOKit.
    pub fn send_rumble(device: IOHIDDeviceRef, left: u8, right: u8) -> Result<(), IOReturn> {
        if device.is_null() {
            return Err(-1);
        }
        let pkt = Self::build_report(left, right);
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

    /// Stops rumble immediately.
    #[inline]
    pub fn stop_rumble(device: IOHIDDeviceRef) -> Result<(), IOReturn> {
        Self::send_rumble(device, 0, 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_vendor_match() {
        assert!(EightBitDoDriver::is_match(0x2DC8, 0x202F));
        assert!(!EightBitDoDriver::is_match(0x045E, 0x028E)); // Xbox
    }

    #[test]
    fn test_report_format() {
        let pkt = EightBitDoDriver::build_report(0xFF, 0x80);
        assert_eq!(pkt, [0x05, 0xFF, 0x80, 0x00, 0x00]);

        let stop = EightBitDoDriver::build_report(0x00, 0x00);
        assert_eq!(stop, [0x05, 0x00, 0x00, 0x00, 0x00]);
    }

    #[test]
    fn test_null_device_err() {
        let res = EightBitDoDriver::send_rumble(std::ptr::null_mut(), 100, 100);
        assert!(res.is_err());
    }
}
