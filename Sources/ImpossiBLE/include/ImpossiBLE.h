#import <Foundation/Foundation.h>

// ImpossiBLE — transparent BLE bridge for iOS Simulator.
//
// Link this library into your iOS app. On simulator builds, it automatically
// swizzles CBCentralManager to forward BLE operations to a macOS helper
// process that uses real Bluetooth hardware.
//
// No API to call — activation is automatic via +load.
