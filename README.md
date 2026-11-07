# Project Reclaimer - 8BitDo Controller Rumble for macOS

This repository contains the vibration (force-feedback) driver, native injection bridge, and upstream Rust implementation for **8BitDo controllers** (and other third-party Bluetooth gamepads) playing the native macOS build of **Project Reclaimer**.

---

## The Problem

When playing Project Reclaimer 0.10.0+ on macOS with an 8BitDo controller (such as the **8BitDo Ultimate 3 / 3E**, Vendor ID `0x2DC8`, Product ID `0x202F`), all inputs, sticks, and buttons work out of the box, but **vibration does not work at all**.

In `~/Library/Application Support/ProjectReclaimer/Logs/client.log`, the engine reports:
```text
[gamepad] Ultimate 3 Controller connected (controller 0)
[gamepad] no rumble on Ultimate 3 Controller: no haptics
```

### Root Cause

The native Project Reclaimer engine is written in Rust and links to Apple's `GameController.framework` and `CoreHaptics.framework` via `objc2-game-controller`.

When a controller connects, the game queries `[GCController haptics]`. On macOS, Apple only creates a `GCDeviceHaptics` / `CHHapticEngine` instance for first-party/Apple-certified gamepads:
- Sony DualShock 4 & DualSense
- Microsoft Xbox Wireless Controllers
- Nintendo Switch Pro Controller / Joy-Cons

For all third-party Bluetooth controllers (including 8BitDo in Bluetooth mode), Apple's framework assigns generic extended gamepad input profiles but returns `nil` for `controller.haptics`. The game sees `nil` and disables all rumble logic for that controller.

However, the hardware itself supports full dual-motor palm rumble over Bluetooth via raw **HID Output Report 0x05**.

---

## The Fix: What Was Done

We developed two solutions:
1. **A local native injection bridge (`bridge/`)**: Works right now on your installed `/Applications/Project Reclaimer.app` by swizzling `-[GCController haptics]` and dispatching 8BitDo output reports directly to the hardware via `IOKit`.
2. **A pure Rust crate (`rust/`)**: An idiomatic, zero-overhead implementation for the Project Reclaimer engine developers to integrate into the upstream codebase.

### The 8BitDo Haptic Protocol

- **Vendor ID:** `0x2DC8`
- **Output Report ID:** `0x05`
- **Report Length:** 5 bytes
  - **Byte 0:** `0x05` (Report ID)
  - **Byte 1:** Left Heavy Palm Motor (`0..=255`, low-frequency concussive vibration)
  - **Byte 2:** Right Light Palm Motor (`0..=255`, high-frequency buzz)
  - **Bytes 3–4:** `0x00` (reserved)

---

## When Project Reclaimer Updates

Project Reclaimer has an in-game self-updater. When a new release is downloaded, it will replace `/Applications/Project Reclaimer.app/Contents/MacOS/project-reclaimer`, which removes the local injection wrapper until the developers integrate the native Rust fix.

To re-apply the rumble bridge after any game update, simply run:

```bash
cd ~/Developer/reclaimer-rumble
./install.sh
```

To remove the patch and restore the original app bundle:
```bash
cd ~/Developer/reclaimer-rumble
./uninstall.sh
```

---

## Repository Contents

- **`bridge/`**: Objective-C runtime swizzling bridge and Mach-O wrapper:
  - `native_rumble_bridge.m`: Intercepts `-[GCController haptics]`, returns a proxy `CHHapticEngine` conforming to `<CHHapticAdvancedPatternPlayer>`, and translates intensity parameters into HID output reports via `IOHIDDeviceSetReport`.
  - `wrapper.c`: Minimal Mach-O executable entrypoint that sets `DYLD_INSERT_LIBRARIES` and launches the engine.
- **`rust/`**: The upstream Rust module:
  - `Cargo.toml`: Minimal standalone crate definition.
  - `src/driver_8bitdo.rs`: Low-level IOKit bindings and 8BitDo report builder with unit tests.
  - `src/lib.rs`: `FallbackHaptics` dispatcher for the game loop.
  - `src/bin/test_rumble.rs`: Standalone test executable that discovers the controller and tests vibration.
- **`UPSTREAM_PROPOSAL.md`**: Complete writeup and code snippets ready to share with the Project Reclaimer development team on Discord.

---

## Testing the Rust Implementation

To verify the Rust implementation and test vibration on your connected controller:

```bash
cd ~/Developer/reclaimer-rumble/rust
cargo test
cargo run --bin test-rumble
```
