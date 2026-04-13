import Foundation
import Combine

final class MockStore: ObservableObject {
    @Published var devices: [MockDevice] = []
    @Published var configurations: [MockConfiguration] = []
    @Published var activeConfigurationName: String = "" {
        didSet { UserDefaults.standard.set(activeConfigurationName, forKey: "ActiveConfigurationName") }
    }

    private let devicesURL: URL
    private let configsURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ImpossiBLE", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.devicesURL = dir.appendingPathComponent("mock-devices.json")
        self.configsURL = dir.appendingPathComponent("mock-configurations.json")
        loadConfigurations()
        loadDevices()
        activeConfigurationName = UserDefaults.standard.string(forKey: "ActiveConfigurationName") ?? ""
    }

    // MARK: - Active Devices

    func loadDevices() {
        guard FileManager.default.fileExists(atPath: devicesURL.path) else { return }
        do {
            let data = try Data(contentsOf: devicesURL)
            devices = try JSONDecoder().decode([MockDevice].self, from: data)
        } catch {
            NSLog("ImpossiBLE-Mock: failed to load devices: %@", error.localizedDescription)
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(devices)
            try data.write(to: devicesURL, options: .atomic)
        } catch {
            NSLog("ImpossiBLE-Mock: failed to save devices: %@", error.localizedDescription)
        }
    }

    func addDevice() {
        var device = MockDevice()
        device.name = "Mock Device \(devices.count + 1)"
        devices.append(device)
        save()
    }

    func deleteDevice(at offsets: IndexSet) {
        devices.remove(atOffsets: offsets)
        save()
    }

    func deleteDevice(id: UUID) {
        devices.removeAll { $0.id == id }
        save()
    }

    func duplicateDevice(id: UUID) {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        var copy = device
        copy.id = UUID()
        copy.name = device.name + " Copy"
        copy.services = copy.services.map { svc in
            var s = svc
            s.id = UUID()
            s.characteristics = s.characteristics.map { ch in
                var c = ch
                c.id = UUID()
                c.descriptors = c.descriptors.map { d in
                    var desc = d
                    desc.id = UUID()
                    return desc
                }
                return c
            }
            return s
        }
        devices.append(copy)
        save()
    }

    var enabledDevices: [MockDevice] {
        devices.filter(\.isEnabled)
    }

    // MARK: - Configurations

    func loadConfigurations() {
        guard FileManager.default.fileExists(atPath: configsURL.path) else { return }
        do {
            let data = try Data(contentsOf: configsURL)
            configurations = try JSONDecoder().decode([MockConfiguration].self, from: data)
        } catch {
            NSLog("ImpossiBLE-Mock: failed to load configs: %@", error.localizedDescription)
        }
    }

    func saveConfigurations() {
        do {
            let data = try JSONEncoder().encode(configurations)
            try data.write(to: configsURL, options: .atomic)
        } catch {
            NSLog("ImpossiBLE-Mock: failed to save configs: %@", error.localizedDescription)
        }
    }

    func saveCurrentAsConfiguration(name: String) {
        let config = MockConfiguration(name: name, devices: devices)
        if let idx = configurations.firstIndex(where: { $0.name == name }) {
            configurations[idx] = config
        } else {
            configurations.append(config)
        }
        saveConfigurations()
    }

    func loadConfiguration(_ config: MockConfiguration) {
        // Deep copy with fresh IDs so multiple loads don't share identifiers
        devices = config.devices.map { device in
            var d = device
            d.id = UUID()
            d.services = d.services.map { svc in
                var s = svc
                s.id = UUID()
                s.characteristics = s.characteristics.map { ch in
                    var c = ch
                    c.id = UUID()
                    c.descriptors = c.descriptors.map { desc in
                        var dd = desc
                        dd.id = UUID()
                        return dd
                    }
                    return c
                }
                return s
            }
            return d
        }
        activeConfigurationName = config.name
        save()
    }

    func deleteConfiguration(id: UUID) {
        configurations.removeAll { $0.id == id }
        saveConfigurations()
    }

    var allConfigurations: [MockConfiguration] {
        StockConfigurations.all + configurations
    }
}
