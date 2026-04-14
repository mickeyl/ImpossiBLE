import Foundation

final class ForwarderController: ObservableObject {
    enum Status: Equatable {
        case unknown
        case stopped
        case running([String])
        case unavailable(String)
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var isBusy = false

    private let queue = DispatchQueue(label: "impossible.forwarder.control")
    private var pollTimer: Timer?

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
    }

    deinit {
        pollTimer?.invalidate()
    }

    func refresh() {
        queue.async { [weak self] in
            self?.refreshSync()
        }
    }

    func start() {
        perform {
            if self.currentPIDs().isEmpty {
                if let wrapper = self.locateWrapper() {
                    let result = self.run(wrapper.path, ["start"])
                    if result.exitCode != 0, let app = self.locateApp() {
                        _ = self.run("/usr/bin/open", [app.path])
                    } else if result.exitCode != 0 {
                        self.publish(
                            status: .unavailable(result.output.isEmpty ? "Cannot start impossible-helper" : result.output)
                        )
                        return
                    }
                } else if let app = self.locateApp() {
                    _ = self.run("/usr/bin/open", [app.path])
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
            appContainerDirectory().appendingPathComponent("impossible-helper.app"),
            homeDirectory().appendingPathComponent(".local/bin/impossible-helper.app"),
            URL(fileURLWithPath: "/opt/homebrew/opt/impossible/libexec/impossible-helper.app"),
            URL(fileURLWithPath: "/usr/local/opt/impossible/libexec/impossible-helper.app")
        ]

        candidates.append(contentsOf: ancestorDirectories().map {
            $0.appendingPathComponent("impossible-helper.app")
        })

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
