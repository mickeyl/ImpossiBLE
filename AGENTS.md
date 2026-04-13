# Agent Notes

## Project Shape

- `Sources/ImpossiBLE` is the simulator-side Swift package library. It swizzles CoreBluetooth APIs and sends newline-delimited JSON to `/tmp/impossible.sock`.
- `Sources/Helper` builds `impossible-helper.app`, the host-side forwarding provider that talks to real Mac Bluetooth hardware.
- `Sources/MockApp` builds `ImpossiBLE-Mock.app`, the host-side menu bar provider that serves configurable virtual BLE peripherals.
- `SampleApp` is an iOS sample Xcode project that imports the local package and uses normal CoreBluetooth APIs.

## Forwarding vs Mocking

The iOS app does not switch modes directly. It always talks to `/tmp/impossible.sock`; the active macOS provider determines behavior.

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

## Build And Verification

Use these checks before preparing changes for commit:

```bash
make mock-clean mock
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
