import Foundation

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

/// Aggregates the passthrough bridge's per-operation activity callbacks into
/// the device list the panel shows. In-process successor of the daemon's
/// `/tmp/impossible-passthrough-activity.json` snapshot polling.
/// All members must be called on the main thread.
final class PassthroughActivityMonitor: ObservableObject {
    @Published private(set) var devices: [PassthroughDeviceActivity] = []
    @Published private(set) var trafficActive = false
    @Published private(set) var lastActivity = ""

    private struct Entry {
        var name: String
        var lastOperation: String
        var lastDetail: String
        var lastAt: Date
        var activeUntil: Date
        var count: Int
    }

    private var entriesById: [String: Entry] = [:]
    private var expiryTimer: Timer?

    private static let activeWindow: TimeInterval = 1.5

    func record(id: String, name: String, operation: String, detail: String) {
        let now = Date()
        var entry = entriesById[id] ?? Entry(
            name: name,
            lastOperation: operation,
            lastDetail: detail,
            lastAt: now,
            activeUntil: now,
            count: 0
        )
        if !name.isEmpty {
            entry.name = name
        }
        entry.lastOperation = operation
        entry.lastDetail = detail
        entry.lastAt = now
        entry.activeUntil = now.addingTimeInterval(Self.activeWindow)
        entry.count += 1
        entriesById[id] = entry

        publish()
        scheduleExpiry()
    }

    func clear() {
        entriesById.removeAll()
        expiryTimer?.invalidate()
        expiryTimer = nil
        if !devices.isEmpty { devices = [] }
        if trafficActive { trafficActive = false }
        if !lastActivity.isEmpty { lastActivity = "" }
    }

    private func publish() {
        let now = Date()
        let next = entriesById
            .map { id, entry in
                PassthroughDeviceActivity(
                    id: id,
                    name: entry.name,
                    lastOperation: entry.lastOperation,
                    lastDetail: entry.lastDetail,
                    lastAt: entry.lastAt,
                    count: entry.count,
                    isActive: entry.activeUntil >= now
                )
            }
            .sorted { $0.lastAt > $1.lastAt }

        if devices != next {
            devices = next
        }
        let nextTrafficActive = next.contains { $0.isActive }
        if trafficActive != nextTrafficActive {
            trafficActive = nextTrafficActive
        }
        let nextLastActivity: String
        if let latest = next.first {
            let detail = latest.lastDetail.isEmpty ? "" : " \(latest.lastDetail)"
            nextLastActivity = "\(latest.displayName): \(latest.lastOperation)\(detail)"
        } else {
            nextLastActivity = ""
        }
        if lastActivity != nextLastActivity {
            lastActivity = nextLastActivity
        }
    }

    /// The "active" highlight has to fade even when no further callback arrives.
    private func scheduleExpiry() {
        guard expiryTimer == nil else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.publish()
            if !self.trafficActive {
                self.expiryTimer?.invalidate()
                self.expiryTimer = nil
            }
        }
    }
}
