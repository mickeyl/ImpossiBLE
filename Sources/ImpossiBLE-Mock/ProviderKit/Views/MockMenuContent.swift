import SwiftUI
import AppKit
import SimBridgeServer
import SimBridgeShell

/// The standalone app's control panel: a title header and an app footer
/// wrapped around `ImpossiBLESection`, which carries the actual provider UI.
public struct MockMenuContent: View {
    @ObservedObject var store: MockStore
    @ObservedObject var server: MockServer
    @ObservedObject var transport: ProtocolServer
    @ObservedObject var activity: PassthroughActivityMonitor
    @ObservedObject var controller: ModeTransitionController<ProviderMode>
    var onDismiss: (() -> Void)?
    var onOpenCapture: (() -> Void)?
    var onOpenDevice: ((UUID) -> Void)?
    @State private var dismissOnDeactivate = ShellPreferences.dismissControlWindowOnDeactivate
    // Launch-at-login lives in a launchd plist, not UserDefaults. Mirror it in
    // view state so the toggle reflects taps immediately instead of re-reading
    // the (non-observable) filesystem.
    @State private var launchAtLogin = MockMenuContent.launchAgent.isEnabled
    @State private var settingsAck = ""
    @State private var ackClear: DispatchWorkItem?
    private static let launchAgent = LaunchAtLogin(label: "com.impossible.ble-mock")

    public init(
        store: MockStore,
        server: MockServer,
        transport: ProtocolServer,
        activity: PassthroughActivityMonitor,
        controller: ModeTransitionController<ProviderMode>,
        onDismiss: (() -> Void)? = nil,
        onOpenCapture: (() -> Void)? = nil,
        onOpenDevice: ((UUID) -> Void)? = nil
    ) {
        self.store = store
        self.server = server
        self.transport = transport
        self.activity = activity
        self.controller = controller
        self.onDismiss = onDismiss
        self.onOpenCapture = onOpenCapture
        self.onOpenDevice = onOpenDevice
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ImpossiBLESection(
                store: store,
                server: server,
                transport: transport,
                activity: activity,
                controller: controller,
                onDismiss: onDismiss,
                onOpenCapture: onOpenCapture,
                onOpenDevice: onOpenDevice
            )
            Divider()
            footer
        }
        .background(Color.clear)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(nsImage: FontAwesome.brandImage(FontAwesome.bluetoothB, size: 18))
                .foregroundStyle(statusColor)
                .frame(width: ImpossiBLESection.statusIconColumnWidth, alignment: .center)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("ImpossiBLE Mock")
                    .font(.headline)
                if !appVersion.isEmpty {
                    Text(appVersion)
                        .font(.caption)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var statusColor: Color {
        ImpossiBLESection.statusColor(mode: controller.mode, status: transport.status)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppVersion.current
    }

    // MARK: - Footer

    /// Briefly shows a one-line receipt in the footer after a preference changes.
    private func acknowledge(_ message: String) {
        ackClear?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) {
            settingsAck = message
        }
        let item = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.3)) {
                settingsAck = ""
            }
        }
        ackClear = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            IconToggle(
                systemImage: "power",
                help: "Launch ImpossiBLE Mock automatically at login",
                isOn: $launchAtLogin
            )
            .onChange(of: launchAtLogin) { _, newValue in
                Self.launchAgent.setEnabled(newValue)
                acknowledge(newValue ? "Will launch at login" : "Won’t launch at login")
            }

            IconToggle(
                systemImage: "eye.slash",
                help: "Hide this panel when you switch to another app",
                isOn: $dismissOnDeactivate
            )
            .onChange(of: dismissOnDeactivate) { _, newValue in
                ShellPreferences.dismissControlWindowOnDeactivate = newValue
                acknowledge(newValue ? "Panel auto-hides" : "Panel stays open")
            }

            Spacer()

            if !settingsAck.isEmpty {
                Text(settingsAck)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            Spacer()

            // The app delegate stops the server on any quit path.
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}
