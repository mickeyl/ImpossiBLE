#import <Foundation/Foundation.h>

// ImpossiBLE — transparent BLE bridge for iOS Simulator.
//
// Link this library into your iOS app. On simulator builds, it automatically
// swizzles CBCentralManager to forward BLE operations to a macOS helper
// process that uses real Bluetooth hardware.
//
// Bridging itself needs no API — activation is automatic via +load. The
// functions below exist only for tests that want to supply their own virtual
// peripherals instead of relying on the menu bar app's selection.

NS_ASSUME_NONNULL_BEGIN

/// Uploads a mock configuration for this app's session.
///
/// `configurationJSON` has the same shape as a saved configuration file, so an
/// exported configuration can be handed over verbatim:
///
///     { "id": "…", "name": "…", "devices": [ … ] }
///
/// This is what lets a test own its fixture instead of depending on whatever
/// happens to be selected in the menu bar app — which matters as soon as the
/// service UUIDs under test are computed rather than fixed.
///
/// The uploaded configuration is **ephemeral**: it is never written to the
/// user's saved configurations, and it is discarded when this app disconnects.
///
/// Returns NO when no provider is connected. Always NO on device builds, where
/// the bridge is inactive.
BOOL ImpossiBLESetMockConfiguration(NSData *configurationJSON);

/// Hands control back to whatever the menu bar app has selected.
void ImpossiBLEClearMockConfiguration(void);

/// Whether a provider (mock or forwarding helper) is currently reachable.
/// Tests should wait for this before uploading a configuration.
BOOL ImpossiBLEIsProviderConnected(void);

/// Receives the far end of an L2CAP channel the app just opened.
///
/// `psm` is a `CBL2CAPPSM`, typed here as `uint16_t` so this header stays free
/// of CoreBluetooth. The streams are already open; the handler owns scheduling
/// them and closing them when done.
typedef void (^ImpossiBLEL2CAPPeerHandler)(uint16_t psm,
                                           NSInputStream *input,
                                           NSOutputStream *output);

/// Serves L2CAP channels locally, so an app can talk to itself over one.
///
/// A mock peripheral cannot answer an L2CAP channel: nothing on the provider
/// side knows what bytes your protocol expects. Only the app does — so instead
/// of inventing a peer, ImpossiBLE hands the app the other end of the channel
/// and lets it play both roles. For an app whose peripheral role cannot run in
/// the Simulator at all, this is the only way to exercise the bulk-transfer
/// path without hardware.
///
/// Applies only while a client-supplied configuration is active. In Passthrough
/// mode the real channel is used, so a registered handler is ignored rather
/// than shadowing the hardware.
///
/// Pass nil to stop serving channels locally.
void ImpossiBLESetMockL2CAPHandler(ImpossiBLEL2CAPPeerHandler _Nullable handler);

NS_ASSUME_NONNULL_END
