# Agent Notes

## Project Shape

- `Sources/ImpossiBLE` is the simulator-side Swift package library. It swizzles CoreBluetooth APIs at `+load` time and sends newline-delimited JSON to `/tmp/impossible.sock`. The socket is opened lazily on the first `CBCentralManager` instantiation (via a `dispatch_once` in `cbs_post_init`), so linking ImpossiBLE without using CoreBluetooth does not contact the daemon. The connection layer (`CBSConnection`) auto-reconnects and drives `CBManagerState` transitions (`poweredOn`/`poweredOff`) based on socket connectivity.
- `Sources/Helper` builds `impossible-helper.app`, the host-side forwarding provider that talks to real Mac Bluetooth hardware.
- `Sources/MockApp` builds `ImpossiBLE-Mock.app`, the host-side menu bar provider that serves configurable virtual BLE peripherals and controls Passthrough forwarding. It has its own `Package.swift` and is built via `swift build` (SPM). Font resources (FontAwesome Brands) are bundled via SPM resource rules. The status item is implemented with AppKit (`StatusBarController`) rather than SwiftUI `MenuBarExtra` so the control panel can remain open while other apps are active.
- `SampleApp` is an iOS sample Xcode project that imports the local package and uses normal CoreBluetooth APIs.
- `Sources/ImpossiBLE/CBSMockConfiguration.m` is the only client-side file with a public API. Everything else activates itself; these three functions exist so a test can supply its own virtual peripherals.

## Client-Supplied Mock Configurations

An app can upload a configuration over the same socket, which then replaces the menu bar selection for as long as that app is connected.

Wire protocol:

- Client sends `{"type": "setMockConfiguration", "configuration": {...}}` where the payload decodes as `MockConfiguration` (keys `id`, `name`, `devices`).
- Client sends `{"type": "clearMockConfiguration"}` to hand control back.
- Server replies `{"type": "didSetMockConfiguration", "ok": true}`, or `ok: false` with `error` when decoding fails. Failing loudly matters here: a malformed fixture is otherwise indistinguishable from an empty environment.

Invariants that must not be broken when touching this:

- **The uploaded configuration never reaches `MockStore`.** It lives in `MockServer.clientSuppliedDevices` (ioQueue) and `clientSuppliedConfiguration` (published for the UI). Routing it through the store would overwrite the user's working set and persist it, which is exactly what an ephemeral test fixture must not do.
- **It is cleared on both edges of a connection** — in `acceptClient()` and on disconnect in `readFromClient` — so a stale fixture can never outlive the app that supplied it.
- **`fetchEnabledDevices()` and `fetchDevice(uuid:)` are the only two read points.** Any new code path that reaches for devices must go through them, or it will serve the user's configuration while everything else serves the client's.
- **The panel shows what is served, not what is selected.** `MockMenuContent.mockBody` swaps in `clientConfigBanner` plus a read-only `clientDeviceList`. A banner alone, over the user's own device rows, would make the panel describe devices that do not exist.

Note that `MockServer.log()` only updates `lastActivity` for the UI; it does not write to os_log. Absence of console output from the server is not evidence that something failed.

### Loopback L2CAP

`cbs_try_local_l2cap` in `CBSActivator.m` serves a channel in process when a handler is registered *and* `CBSMockConfigurationActive()` is true. `CBSPeripheral.openL2CAPChannel:` calls it first and only falls through to the provider when it returns NO.

- The provider is deliberately not involved. The existing passthrough path already builds a `socketpair` per channel; this reuses the mechanism and simply hands `fds[1]` to the app instead of forwarding it over the Unix socket.
- Both gates matter. Without the handler there is nobody to talk to; without the active client configuration this would hijack Passthrough, where a real channel exists.
- Streams get `kCFStreamPropertyShouldCloseNativeSocket`, or the descriptors outlive the streams and the channel never reports end-of-stream.
- The handler is dispatched off the delegate queue, so a handler that blocks on reads cannot stall `didOpenL2CAPChannel:`.
- `cbs_try_local_l2cap` lives inside the file's `#if TARGET_OS_SIMULATOR` guard; it references simulator-only globals, so moving it out breaks device builds.

The mock *server* still has no L2CAP support (`handleOpenL2CAP` returns "L2CAP is not supported in mock mode"), and that path remains for clients that register no handler.

## Forwarding vs Mocking

The iOS app does not switch modes directly. It always talks to `/tmp/impossible.sock`; the active macOS provider determines behavior.

The mock menu bar app has a segmented **Off / Mock / Passthrough** picker that controls both providers. The selected mode is owned by `ProviderModeController` (the single source of truth the picker binds to) so it reflects the choice immediately instead of inferring it from mid-transition provider state; transitions are serialized and stop the other provider. The menu bar icon reflects the active mode: strikethrough when off, plain Bluetooth when forwarding, dot-badged when mocking. The control panel is a borderless AppKit panel centered under the status item. It is persistent by default. The footer carries label-less icon toggles with tooltips: **Launch at Login** (`power`), **Dismiss on Switch** (`eye.slash`, restores popover-style hiding on app deactivation), and — in Passthrough only — **Keep Helper on Quit** (`powerplug`, default off; applied via `applicationShouldTerminate` so it covers ⌘Q too). Changing a toggle shows a brief inline confirmation between the toggles and the Quit button.

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

## Debugging Passthrough

The helper has gated verbose tracing, off by default. Enable it with the `IMPOSSIBLE_HELPER_DEBUG` environment variable (works when running the binary directly) or by creating the `/tmp/impossible-helper.debug` sentinel file (works for the `open`/launchd launch path, where env vars don't propagate), then restart the helper. Traces cover the L2CAP lifecycle, stream events, write byte counts, and client connect/disconnect, prefixed with `DEBUG: ImpossiBLE-Helper:`. `NSLog` goes to both stderr (when run directly) and the unified log; the unified log redacts dynamic args as `<private>`, so capture the helper's stderr for full detail.

On a provider-connection drop the simulator-side shim closes open L2CAP channels and synthesizes `didDisconnectPeripheral` for every owned peripheral (`cbs_handle_daemon_disconnect`), so the host app re-establishes instead of hanging on a dead channel.

## Known Follow-ups

- **Single-instance lock for the helper.** Nothing stops two `impossible-helper.app` instances (or helper + mock) from running at once; whichever `bind`s `/tmp/impossible.sock` last does `unlink`+`bind` and steals it, so clients silently bounce between providers. The mock app guards via `pgrep`/LaunchServices and the `currentPIDs` check, but a LaunchAgent + manual launch — or a directly-exec'd helper alongside the LaunchServices-managed one — can still produce two. Add a pidfile `flock`, or refuse to start when a live listener already owns the socket.

## Release Checklist

When cutting a new ImpossiBLE release, update the Homebrew formula in
`mickeyl/homebrew-formulae` as part of the release. Bump
`Formula/impossible.rb` to the new tag, update the tarball SHA256, run
`brew audit --strict --online impossible` and `brew style
Formula/impossible.rb`, then commit and push the tap update.

## Generated Artifacts

Do not commit generated bundles or build output:

- `.build/`
- `.swiftpm/`
- `*.app`
- `ImpossiBLE-Mock.zip`
- Xcode `xcuserdata/`
