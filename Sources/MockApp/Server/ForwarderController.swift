import Darwin
import Foundation

private let passthroughActivityPath = "/tmp/impossible-passthrough-activity.json"

struct PassthroughDeviceActivity: Identifiable, Equatable {
    let id: String
    let name: String
    let lastOperation: String
    let lastDetail: String
    let lastAt: Date
    let count: Int
    let isActive: Bool

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return id.count > 8 ? String(id.prefix(8)) : id
    }
}

private struct PassthroughActivitySnapshot: Decodable {
    struct Client: Decodable {
        let pid: Int32
        let processName: String
    }

    struct Device: Decodable {
        let id: String
        let name: String?
        let lastOperation: String
        let lastDetail: String?
        let lastAt: TimeInterval
        let activeUntil: TimeInterval
        let count: Int?
    }

    let client: Client?
    let devices: [Device]
}

final class ForwarderController: ObservableObject {
    enum Status: Equatable {
        case unknown
        case stopped
        case running([String])
        case unavailable(String)
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var isBusy = false
    @Published private(set) var passthroughDevices: [PassthroughDeviceActivity] = []
    @Published private(set) var trafficActive = false
    @Published private(set) var lastActivity = ""
    @Published private(set) var activityUnavailableMessage: String?
    @Published private(set) var connectedClient: SocketClientInfo?

    private let queue = DispatchQueue(label: "impossible.forwarder.control")
    private var pollTimer: Timer?
    private var activityPollTimer: Timer?

    var isRunning: Bool {
        if case .running = status {
            return true
        }
        return false
    }

    var canStart: Bool {
        switch status {
            case .running, .stopped, .unknown:
                return locateWrapper() != nil || locateApp() != nil
            case .unavailable:
                return false
        }
    }

    init() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        activityPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshPassthroughActivity()
        }
    }

    deinit {
        pollTimer?.invalidate()
        activityPollTimer?.invalidate()
    }

    func refresh() {
        queue.async { [weak self] in
            self?.refreshSync()
        }
    }

    func start(completion: (() -> Void)? = nil) {
        perform(completion: completion) {
            if self.currentPIDs().isEmpty {
                if let app = self.locateApp() {
                    _ = self.run("/usr/bin/open", [app.path])
                } else if let wrapper = self.locateWrapper() {
                    let result = self.run(wrapper.path, ["start"])
                    if result.exitCode != 0 {
                        self.publish(
                            status: .unavailable(result.output.isEmpty ? "Cannot start impossible-helper" : result.output)
                        )
                        return
                    }
                } else {
                    self.publish(status: .unavailable("Install impossible-helper first"))
                    return
                }
            }

            Thread.sleep(forTimeInterval: 0.3)
            self.refreshSync()
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        perform(completion: completion) {
            let pids = self.currentPIDs()
            if !pids.isEmpty {
                if let wrapper = self.locateWrapper() {
                    let result = self.run(wrapper.path, ["stop"])
                    if result.exitCode != 0 {
                        _ = self.run("/bin/kill", pids)
                    }
                } else {
                    _ = self.run("/bin/kill", pids)
                }
            }

            self.refreshSync()
            DispatchQueue.main.async {
                self.clearPassthroughActivity()
            }
        }
    }

    func terminateConnectedClient() {
        guard let pid = connectedClient?.pid, pid > 0 else { return }
        queue.async { [weak self] in
            if Darwin.kill(pid, SIGTERM) != 0 {
                NSLog("ImpossiBLE-Mock: failed to terminate passthrough client pid=%d errno=%d", pid, errno)
            }
            Thread.sleep(forTimeInterval: 0.2)
            self?.refreshSync()
        }
    }

    private func perform(completion: (() -> Void)? = nil, _ work: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.isBusy = true
        }

        queue.async {
            work()
            DispatchQueue.main.async {
                self.isBusy = false
                completion?()
            }
        }
    }

    private func refreshSync() {
        let pids = currentPIDs()
        if !pids.isEmpty {
            publish(status: .running(pids))
        } else if locateWrapper() != nil || locateApp() != nil {
            publish(status: .stopped)
        } else {
            publish(status: .unavailable("Install impossible-helper first"))
        }
    }

    private func refreshPassthroughActivity() {
        guard isRunning else {
            clearPassthroughActivity()
            return
        }

        let url = URL(fileURLWithPath: passthroughActivityPath)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PassthroughActivitySnapshot.self, from: data)
        else {
            clearPassthroughActivity(
                unavailableMessage: "Restart impossible-helper to enable activity tracking"
            )
            return
        }

        let now = Date().timeIntervalSinceReferenceDate
        let devices = snapshot.devices
            .map { device in
                PassthroughDeviceActivity(
                    id: device.id,
                    name: device.name ?? "",
                    lastOperation: device.lastOperation,
                    lastDetail: device.lastDetail ?? "",
                    lastAt: Date(timeIntervalSinceReferenceDate: device.lastAt),
                    count: device.count ?? 1,
                    isActive: device.activeUntil >= now
                )
            }
            .sorted { $0.lastAt > $1.lastAt }

        passthroughDevices = devices
        trafficActive = devices.contains { $0.isActive }
        if let client = snapshot.client, client.pid > 0 {
            connectedClient = SocketClientInfo(pid: client.pid, processName: client.processName)
        } else {
            connectedClient = nil
        }
        activityUnavailableMessage = nil
        if let latest = devices.first {
            let detail = latest.lastDetail.isEmpty ? "" : " \(latest.lastDetail)"
            lastActivity = "\(latest.displayName): \(latest.lastOperation)\(detail)"
        } else {
            lastActivity = ""
        }
    }

    private func clearPassthroughActivity(unavailableMessage: String? = nil) {
        if !passthroughDevices.isEmpty {
            passthroughDevices = []
        }
        trafficActive = false
        lastActivity = ""
        connectedClient = nil
        activityUnavailableMessage = unavailableMessage
    }

    private func currentPIDs() -> [String] {
        let result = run("/usr/bin/pgrep", ["-f", "[i]mpossible-helper.app/Contents/MacOS"])
        guard result.exitCode == 0 else { return [] }
        return result.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func locateWrapper() -> URL? {
        let fileManager = FileManager.default
        for url in wrapperCandidates() where fileManager.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    private func locateApp() -> URL? {
        let fileManager = FileManager.default
        for url in appCandidates() where fileManager.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private func wrapperCandidates() -> [URL] {
        var candidates = [
            appContainerDirectory().appendingPathComponent("impossible-helper"),
            homeDirectory().appendingPathComponent(".local/bin/impossible-helper"),
            URL(fileURLWithPath: "/opt/homebrew/bin/impossible-helper"),
            URL(fileURLWithPath: "/usr/local/bin/impossible-helper")
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("impossible-helper")
            })
        }

        return unique(candidates)
    }

    private func appCandidates() -> [URL] {
        var candidates = [
            appContainerDirectory().appendingPathComponent("impossible-helper.app")
        ]

        candidates.append(contentsOf: ancestorDirectories().map {
            $0.appendingPathComponent("impossible-helper.app")
        })

        candidates.append(contentsOf: [
            homeDirectory().appendingPathComponent(".local/bin/impossible-helper.app"),
            URL(fileURLWithPath: "/opt/homebrew/opt/impossible/libexec/impossible-helper.app"),
            URL(fileURLWithPath: "/usr/local/opt/impossible/libexec/impossible-helper.app")
        ])

        return unique(candidates)
    }

    private func appContainerDirectory() -> URL {
        Bundle.main.bundleURL.deletingLastPathComponent()
    }

    private func ancestorDirectories() -> [URL] {
        var directories: [URL] = []
        var current = appContainerDirectory()

        for _ in 0..<8 {
            directories.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }

        return directories
    }

    private func homeDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            return seen.insert(path).inserted
        }
    }

    private func run(_ launchPath: String, _ arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, output)
        } catch {
            NSLog("ImpossiBLE-Mock: failed to run %@: %@", launchPath, error.localizedDescription)
            return (127, error.localizedDescription)
        }
    }

    private func publish(status: Status) {
        DispatchQueue.main.async {
            self.status = status
        }
    }
}
