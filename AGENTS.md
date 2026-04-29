# Agent Notes

## Project Shape

- `Sources/ImpossiBLE` is the simulator-side Swift package library. It swizzles CoreBluetooth APIs and sends newline-delimited JSON to `/tmp/impossible.sock`. The connection layer (`CBSConnection`) auto-reconnects and drives `CBManagerState` transitions (`poweredOn`/`poweredOff`) based on socket connectivity.
- `Sources/Helper` builds `impossible-helper.app`, the host-side forwarding provider that talks to real Mac Bluetooth hardware.
- `Sources/MockApp` builds `ImpossiBLE-Mock.app`, the host-side menu bar provider that serves configurable virtual BLE peripherals and controls Passthrough forwarding. It has its own `Package.swift` and is built via `swift build` (SPM). Font resources (FontAwesome Brands) are bundled via SPM resource rules. The status item is implemented with AppKit (`StatusBarController`) rather than SwiftUI `MenuBarExtra` so the control panel can remain open while other apps are active.
- `SampleApp` is an iOS sample Xcode project that imports the local package and uses normal CoreBluetooth APIs.

## Forwarding vs Mocking

The iOS app does not switch modes directly. It always talks to `/tmp/impossible.sock`; the active macOS provider determines behavior.

The mock menu bar app has a segmented **Off / Mock / Passthrough** picker that controls both providers. Selecting a mode automatically stops the other provider. The menu bar icon reflects the active mode: strikethrough when off, plain Bluetooth when forwarding, dot-badged when mocking. The control panel is a borderless AppKit panel centered under the status item. It is persistent by default; the footer **Dismiss on Switch** checkbox restores popover-style hiding on app deactivation.

In Passthrough mode, the helper writes `/tmp/impossible-passthrough-activity.json` with devices that have actual communication activity. The list intentionally ignores scan/discovery/connect activity and only records GATT/L2CAP operations: characteristic read/write, descriptor read/write, subscribe/unsubscribe, L2CAP open/read/write/close. The mock app polls that snapshot to show communicating devices and pulse the menu bar icon on Passthrough traffic.

Mock capture is a menu bar app workflow that temporarily uses the real forwarding helper. Opening **Capture** stops the mock server if needed, starts `impossible-helper.app`, connects to `/tmp/impossible.sock` as a helper client, scans live advertisements, and shows filtered capture results. Saving a capture runs a deep inspection pass for selected connectable devices: connect, discover services, discover characteristics, discover descriptors, read readable characteristic values, and read descriptor values. Non-connectable devices or devices that fail inspection are saved advertisement-only. After save, the app stops the helper, restarts Mock mode, and loads the captured configuration for tuning.

Capture rows hide unnamed devices by default, sort more "interesting" advertisements first (more advertised services, named, connectable, manufacturer data, RSSI), and use a factory icon to indicate manufacturer-specific advertisement data.

From the command line:

```bash
# Forwarding mode: simulator app -> real Mac Bluetooth
make mock-stop
make run
```

```bash
# Mocking mode: simulator app -> virtual BLE devices
make stop
make mock-run
```

Only one provider should run at a time because both `impossible-helper.app` and `ImpossiBLE-Mock.app` bind `/tmp/impossible.sock`.

For local development of the menu bar app, prefer:

```bash
make mock-relaunch
```

That target rebuilds the helper, packages the debug mock binary into `ImpossiBLE-Mock.app`, ad-hoc signs it, stops stale helper/mock processes, and opens the bundle. This avoids testing a new mock app against an older installed helper from `~/.local/bin`.

## Build And Verification

Use these checks before preparing changes for commit:

```bash
make mock-clean mock
cd Sources/MockApp && swift build   # standalone SPM check
xcodebuild -project SampleApp/SampleApp.xcodeproj -scheme SampleApp -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' build
plutil -lint Sources/MockApp/Resources/Info.plist Sources/MockApp/Resources/entitlements.plist Sources/Helper/Info.plist Sources/Helper/entitlements.plist
```

For Gatekeeper-related work:

```bash
make mock-assess
make mock-notarize NOTARY_PROFILE="impossible-notary"
```

`make mock-assess` will fail for ad-hoc signed local builds. A distributable mock app needs a `Developer ID Application` identity and notarization.

## Generated Artifacts

Do not commit generated bundles or build output:

- `.build/`
- `.swiftpm/`
- `*.app`
- `ImpossiBLE-Mock.zip`
- Xcode `xcuserdata/`
