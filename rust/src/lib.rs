//! Project Reclaimer: Controller Rumble Fallback for macOS.
//!
//! Apple's `GameController.framework` only provides `GCController.haptics` for
//! certified first-party controllers (Xbox, PS4/PS5, Switch Pro).
//! For 8BitDo and other third-party Bluetooth gamepads, `controller.haptics()` returns
//! `None`, preventing rumble in game.
//!
//! This module provides a fallback path: sending raw HID output reports directly
//! to the controller's `IOHIDDeviceRef` via IOKit.

pub mod driver_8bitdo;

pub use driver_8bitdo::{EightBitDoDriver, IOHIDDeviceRef, IOReturn, VENDOR_8BITDO};

/// Fallback controller haptic dispatcher for Project Reclaimer's engine.
pub enum FallbackHaptics {
    /// 8BitDo Bluetooth controller (Report ID 0x05)
    EightBitDo(IOHIDDeviceRef),
    /// Controller has no custom HID rumble driver
    None,
}

impl FallbackHaptics {
    /// Detects appropriate fallback driver for a given Vendor ID and Product ID.
    pub fn for_device(device: IOHIDDeviceRef, vendor_id: u16, product_id: u16) -> Self {
        if device.is_null() {
            return Self::None;
        }
        if EightBitDoDriver::is_match(vendor_id, product_id) {
            Self::EightBitDo(device)
        } else {
            Self::None
        }
    }

    /// Dispatches left (heavy palm) and right (light palm) rumble (0.0 ..= 1.0)
    pub fn send_rumble(&self, left_intensity: f32, right_intensity: f32) -> Result<(), IOReturn> {
        match self {
            Self::EightBitDo(dev) => {
                let left = (left_intensity.clamp(0.0, 1.0) * 255.0) as u8;
                let right = (right_intensity.clamp(0.0, 1.0) * 255.0) as u8;
                EightBitDoDriver::send_rumble(*dev, left, right)
            }
            Self::None => Ok(()),
        }
    }

    /// Stops vibration.
    pub fn stop(&self) -> Result<(), IOReturn> {
        match self {
            Self::EightBitDo(dev) => EightBitDoDriver::stop_rumble(*dev),
            Self::None => Ok(()),
        }
    }
}
