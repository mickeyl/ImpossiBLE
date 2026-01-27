<p align="center">
  <img src="logo.png" alt="ImpossiBLE logo" width="256">
</p>

# ImpossiBLE

**Use real Bluetooth Low Energy hardware from the iOS Simulator.**

Apple's `CoreBluetooth` framework does not function inside the iOS Simulator -- peripherals cannot be discovered, connections fail silently, and the `CBCentralManager` state never reaches `poweredOn`. ImpossiBLE makes the impossible possible by transparently bridging BLE operations from your simulated app to actual Bluetooth hardware on the host Mac.

## How It Works

ImpossiBLE is a two-process architecture:

1. **Library** (linked into your iOS app) -- Uses Objective-C runtime swizzling to intercept all `CBCentralManager` calls at load time. Instead of talking to the (non-functional) simulated Bluetooth stack, it forwards every operation as JSON messages over a Unix domain socket.

2. **Helper** (runs natively on macOS) -- A lightweight background app that listens on `/tmp/impossible.sock`, translates the JSON messages into real `CoreBluetooth` API calls, and sends results back.

Your app code remains unchanged -- `CBCentralManager`, `CBPeripheral`, delegate callbacks, and all other CoreBluetooth types work as expected.

## Features

- Scan for peripherals with service filters
- Connect and disconnect
- Discover services and characteristics
- Read, write (with/without response), and notify
- L2CAP channel support
- Automatic `+load` activation -- no setup code required

## Requirements

- macOS with Bluetooth hardware
- Xcode 15+ (Swift Package Manager)
- Apple Development codesigning certificate in your login keychain (or set `CODESIGN_MATCH` to another identity substring)
- `fswatch` (optional, for `make watch` auto-rebuild)

## Quick Start

```bash
# Clone and build the helper
cd ImpossiBLE
make install

# Start the helper (runs as a background app)
make run

# In Xcode: add ImpossiBLE as a local Swift package dependency,
# then build and run your app in the iOS Simulator.
```

## Makefile Targets

| Target    | Description                                        |
|-----------|----------------------------------------------------|
| `helper`  | Build the helper `.app` bundle                     |
| `install` | Build and copy to `~/.local/bin/`                  |
| `run`     | Install and start (if not already running)         |
| `restart` | Install, kill existing helper, and relaunch         |
| `watch`   | Install, start, and auto-rebuild on source changes |
| `clean`   | Remove local build artifacts                       |

## Integration

Add ImpossiBLE as a **local Swift package** in your Xcode project pointing to the cloned directory. Then import it:

```swift
import ImpossiBLE
```

That is all. The library activates automatically via `+load` on simulator builds. On device builds, all ImpossiBLE code compiles to no-ops.

## Limitations

- **Central role only** -- peripheral/broadcaster mode is not supported.
- **Single client** -- only one simulator app can connect to the helper at a time.
- **Helper must be running** -- start it before launching your app in the simulator.

## License

MIT -- see [LICENSE](LICENSE) for details.
