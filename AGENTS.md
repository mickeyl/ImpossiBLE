# Agent Notes

## Project Shape

- `Sources/ImpossiBLE` is the simulator-side Swift package library. It swizzles CoreBluetooth APIs at `+load` time and sends newline-delimited JSON to `/tmp/impossible.sock`. The socket is opened lazily on the first `CBCentralManager` instantiation (via a `dispatch_once` in `cbs_post_init`), so linking ImpossiBLE without using CoreBluetooth does not contact the provider. The connection layer (`CBSConnection`) auto-reconnects, sends a `hello {clientVersion, bundleId, pid}` handshake on connect (`kCBSLibraryVersion` — bump on release), and drives `CBManagerState` transitions (`poweredOn`/`poweredOff`) based on socket connectivity.
- `Sources/ImpossiBLE-Mac` builds `ImpossiBLE-Mac.app`, the host-side menu bar provider and **single owner of the socket in both modes**. It has its own `Package.swift` with three targets: **`ImpossiBLEProviderKit`** (library product `ProviderKit/` — server, models, panel/editor views, the FontAwesome resource; this is what the Simsalabim suite app will embed), the thin **`ImpossiBLE-Mac`** executable (`App/` — app lifecycle plus the shell wiring in `StatusBarController`), and `ImpossiBLEPassthroughCore`, an ObjC library target containing `CBSPassthroughBridge` — the former `impossible-helper` daemon minus its socket server. The ProviderKit's public surface is deliberately small: `MockServer` (facade with `transport` and `passthroughActivity`), `MockStore`, the panel and editor entry views, and `FontAwesome`; everything else is internal. The transport (socket lifecycle, NDJSON framing, hello handshake, last-connection-wins takeover, client-socket hardening, socket-ownership guard) is SimBridgeKit's `ProtocolServer` (`MockServer.transport`, URL dependency on github.com/mickeyl/SimBridgeKit); `MockServer` is the domain layer on top and routes by `serveMode`: Mock answers from `MockStore`/client fixtures, Passthrough forwards every message to the bridge, which translates to real CoreBluetooth calls and emits replies through its `messageHandler`. All `MockServer` handlers run on the transport's I/O queue, which also guards its mutable state. There is no separate helper process anymore (removed in 3.0.0). Font resources (FontAwesome Brands) are bundled via SPM resource rules. The status item is implemented with AppKit (`StatusBarController`) rather than SwiftUI `MenuBarExtra` so the control panel can remain open while other apps are active.
- Passthrough needs `NSBluetoothAlwaysUsageDescription` (in `Resources/Info.plist`) and — under the Hardened Runtime of release builds — `com.apple.security.device.bluetooth` in `Resources/entitlements.plist`. Missing entitlement is the classic "works in debug (ad-hoc, Hardened Runtime not enforced), denied in release" trap. Ad-hoc dev builds get a fresh identity each rebuild, so macOS re-prompts for Bluetooth consent.
- `SampleApp` is an iOS sample Xcode project that imports the local package and uses normal CoreBluetooth APIs.
- `Sources/ImpossiBLE/CBSMockConfiguration.m` is the only client-side file with a public API. Everything else activates itself; these three functions exist so a test can supply its own virtual peripherals.

## Socket discipline & takeover

Both live in SimBridgeKit's `ProtocolServer` since the adoption — see that
repo's AGENTS.md for the invariants (SO_NOSIGPIPE + send-timeout hardening,
last-connection-wins takeover, socket-ownership guard). What matters on this
side:

- `MockServer` never touches fds. Replies go through `transport.send(_:)`,
  domain events surface via `transport.note(_:)`, and
  `transport.onClientTeardown` drives `tearDownClientState()` — mock state,
  client-supplied configuration, and the bridge's scans/connections/L2CAP
  channels are dropped on disconnect, takeover, and stop alike.
- The ownership guard means a second provider instance shows **Blocked** in
  the panel (orange) instead of stealing `/tmp/impossible.sock` from a
  running one.
- The wire code for takeover stays `clientBusy`, so pre-3.0 libraries handle
  eviction identically; the evicted library stops auto-reconnecting — to use
  an older simulator again, relaunch its app.

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

The iOS app does not switch modes directly. It always talks to `/tmp/impossible.sock`; the Mac app's selected mode determines behavior.

The segmented **Off / Mock / Passthrough** picker is owned by `ProviderModeController` (the single source of truth the picker binds to) so it reflects the choice immediately instead of inferring it from mid-transition server state; transitions are serialized and always bounce through a `server.stop`, so a connected client observes a disconnect instead of a silent behavior change. The menu bar icon reflects the active mode: strikethrough when off, plain Bluetooth when forwarding, dot-badged when mocking. The control panel is a borderless AppKit panel centered under the status item. It is persistent by default. The footer carries label-less icon toggles with tooltips: **Launch at Login** (`power`) and **Dismiss on Switch** (`eye.slash`, restores popover-style hiding on app deactivation). Changing a toggle shows a brief inline confirmation between the toggles and the Quit button.

In Passthrough mode, the bridge reports actual communication activity through its `activityHandler`, aggregated by `PassthroughActivityMonitor` for the panel list and the icon pulse (the pre-3.0 `/tmp/impossible-passthrough-activity.json` snapshot file is gone). The list intentionally ignores scan/discovery/connect activity and only records GATT/L2CAP operations: characteristic read/write, descriptor read/write, subscribe/unsubscribe, L2CAP open/read/write/close.

Mock capture runs entirely in process: `CaptureSession` owns its **own** `CBSPassthroughBridge` instance (its own `CBCentralManager`), so capturing no longer stops or restarts whatever mode is currently serving the simulator. Opening **Capture** scans live advertisements and shows filtered capture results. Saving a capture runs a deep inspection pass for selected connectable devices: connect, discover services, discover characteristics, discover descriptors, read readable characteristic values, and read descriptor values. Non-connectable devices or devices that fail inspection are saved advertisement-only. After save, the captured configuration is loaded for tuning.

Capture rows hide unnamed devices by default, sort more "interesting" advertisements first (more advertised services, named, connectable, manufacturer data, RSSI), and use a factory icon to indicate manufacturer-specific advertisement data.

For local development of the menu bar app, prefer:

```bash
make mac-relaunch
```

That target packages the debug Mac binary into `ImpossiBLE-Mac.app`, ad-hoc signs it, stops stale Mac processes, and opens the bundle.

## Build And Verification

Use these checks before preparing changes for commit:

```bash
make mac-clean mac
cd Sources/ImpossiBLE-Mac && swift build   # standalone SPM check
xcodebuild -project SampleApp/SampleApp.xcodeproj -scheme SampleApp -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' build
plutil -lint Sources/ImpossiBLE-Mac/Resources/Info.plist Sources/ImpossiBLE-Mac/Resources/entitlements.plist
```

For Gatekeeper-related work:

```bash
make mac-assess
make mac-notarize NOTARY_PROFILE="impossible-notary"
```

`make mac-assess` will fail for ad-hoc signed local builds. A distributable Mac app needs a `Developer ID Application` identity and notarization.

## Debugging Passthrough

The passthrough bridge has gated verbose tracing, off by default. Enable it with the `IMPOSSIBLE_PASSTHROUGH_DEBUG` environment variable (works when running the Mac binary directly) or by creating the `/tmp/impossible-passthrough.debug` sentinel file (works for the `open`/launchd launch path, where env vars don't propagate), then restart the Mac app. Traces cover the L2CAP lifecycle, stream events, write byte counts, and message dispatch, prefixed with `DEBUG: ImpossiBLE-Passthrough:`. `NSLog` goes to both stderr (when run directly) and the unified log; the unified log redacts dynamic args as `<private>`, so capture stderr for full detail (`make mac-dev`).

On a provider-connection drop the simulator-side shim closes open L2CAP channels and synthesizes `didDisconnectPeripheral` for every owned peripheral (`cbs_handle_daemon_disconnect`), so the host app re-establishes instead of hanging on a dead channel.

## Known Follow-ups

- **Socket-ownership guard.** Nothing stops a second copy of the Mac app (or, later, the Simsalabim suite app) from `unlink`+`bind`ing `/tmp/impossible.sock` and stealing it from a running instance. Before binding, probe the existing socket with `connect()`; refuse to start the provider when a live listener answers, and only unlink a stale socket file. Planned as part of the shared SimBridgeKit extraction (see `../Simsalabim/PLAN.md`).

## Release Checklist

When cutting a new ImpossiBLE release:

- Bump the version in **three** places and keep them identical:
  `kCBSLibraryVersion` in `Sources/ImpossiBLE/CBSConnection.m`,
  `AppVersion.current` in `Sources/ImpossiBLE-Mac/Models/AppVersion.swift`, and
  `CFBundleShortVersionString` in `Sources/ImpossiBLE-Mac/Resources/Info.plist`.
- Update the Homebrew formula in `mickeyl/homebrew-formulae`. Bump
  `Formula/impossible.rb` to the new tag, update the tarball SHA256, run
  `brew audit --strict --online impossible` and `brew style
  Formula/impossible.rb`, then commit and push the tap update. Note: since
  3.0.0 there is no `impossible-helper` anymore — the formula must only build
  and install the Mac app.

## Generated Artifacts

Do not commit generated bundles or build output:

- `.build/`
- `.swiftpm/`
- `*.app`
- `ImpossiBLE-Mac.zip`
- Xcode `xcuserdata/`
