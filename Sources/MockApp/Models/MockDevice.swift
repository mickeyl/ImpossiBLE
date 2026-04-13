import Foundation

struct MockDescriptor: Identifiable, Codable, Hashable {
    var id = UUID()
    var uuid: String = "2902"
    var value: Data?
}

struct MockCharacteristic: Identifiable, Codable, Hashable {
    var id = UUID()
    var uuid: String = "2A00"
    var properties: UInt = 0x02 // read
    var value: Data?
    var descriptors: [MockDescriptor] = []
}

struct MockService: Identifiable, Codable, Hashable {
    var id = UUID()
    var uuid: String = "180A"
    var isPrimary: Bool = true
    var characteristics: [MockCharacteristic] = []
}

struct MockDevice: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = "Mock Device"
    var rssi: Int = -50
    var isConnectable: Bool = true
    var isEnabled: Bool = true
    var advertisedServiceUUIDs: [String] = []
    var manufacturerData: Data?
    var services: [MockService] = []
}

// MARK: - Named Configuration

struct MockConfiguration: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var devices: [MockDevice]
    var isBuiltIn: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, name, devices
    }
}

// MARK: - CBCharacteristicProperties bitmask helpers

struct CharacteristicProperty: Identifiable, Hashable {
    let name: String
    let rawValue: UInt

    var id: UInt { rawValue }

    static let all: [CharacteristicProperty] = [
        .init(name: "Broadcast",            rawValue: 0x01),
        .init(name: "Read",                 rawValue: 0x02),
        .init(name: "Write w/o Response",   rawValue: 0x04),
        .init(name: "Write",                rawValue: 0x08),
        .init(name: "Notify",               rawValue: 0x10),
        .init(name: "Indicate",             rawValue: 0x20),
        .init(name: "Signed Write",         rawValue: 0x40),
        .init(name: "Extended Properties",  rawValue: 0x80),
    ]
}

// MARK: - Well-known BLE UUIDs

struct WellKnownUUID: Identifiable, Hashable {
    let uuid: String
    let name: String

    var id: String { uuid }
}

enum WellKnownUUIDs {
    static let services: [WellKnownUUID] = [
        .init(uuid: "1800", name: "Generic Access"),
        .init(uuid: "1801", name: "Generic Attribute"),
        .init(uuid: "180A", name: "Device Information"),
        .init(uuid: "180D", name: "Heart Rate"),
        .init(uuid: "180F", name: "Battery Service"),
        .init(uuid: "1810", name: "Blood Pressure"),
        .init(uuid: "1816", name: "Cycling Speed and Cadence"),
        .init(uuid: "1818", name: "Cycling Power"),
        .init(uuid: "181C", name: "User Data"),
        .init(uuid: "1822", name: "Pulse Oximeter"),
    ]

    static let characteristics: [WellKnownUUID] = [
        .init(uuid: "2A00", name: "Device Name"),
        .init(uuid: "2A01", name: "Appearance"),
        .init(uuid: "2A19", name: "Battery Level"),
        .init(uuid: "2A24", name: "Model Number String"),
        .init(uuid: "2A25", name: "Serial Number String"),
        .init(uuid: "2A26", name: "Firmware Revision String"),
        .init(uuid: "2A27", name: "Hardware Revision String"),
        .init(uuid: "2A28", name: "Software Revision String"),
        .init(uuid: "2A29", name: "Manufacturer Name String"),
        .init(uuid: "2A37", name: "Heart Rate Measurement"),
    ]

    static let descriptors: [WellKnownUUID] = [
        .init(uuid: "2900", name: "Characteristic Extended Properties"),
        .init(uuid: "2901", name: "Characteristic User Description"),
        .init(uuid: "2902", name: "Client Characteristic Configuration"),
        .init(uuid: "2903", name: "Server Characteristic Configuration"),
        .init(uuid: "2904", name: "Characteristic Presentation Format"),
    ]
}

// MARK: - Stock Configurations

enum StockConfigurations {
    static let all: [MockConfiguration] = [
        heartRateMonitor,
        deviceInfoPeripheral,
        multiServiceSensor,
    ]

    static let heartRateMonitor = MockConfiguration(
        name: "Heart Rate Monitor",
        devices: [
            MockDevice(
                name: "Polar H10",
                rssi: -45,
                isConnectable: true,
                isEnabled: true,
                advertisedServiceUUIDs: ["180D"],
                services: [
                    MockService(uuid: "180D", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A37",
                            properties: 0x10, // notify
                            value: Data([0x00, 0x48]), // flags=0, HR=72 bpm
                            descriptors: [
                                MockDescriptor(uuid: "2902", value: Data([0x00, 0x00])),
                            ]
                        ),
                        MockCharacteristic(
                            uuid: "2A38",
                            properties: 0x02, // read
                            value: Data([0x01]) // chest
                        ),
                    ]),
                    MockService(uuid: "180F", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A19",
                            properties: 0x12, // read + notify
                            value: Data([0x5A]), // 90%
                            descriptors: [
                                MockDescriptor(uuid: "2902", value: Data([0x00, 0x00])),
                                MockDescriptor(uuid: "2901", value: "Battery Level".data(using: .utf8)),
                            ]
                        ),
                    ]),
                ]
            ),
        ],
        isBuiltIn: true
    )

    static let deviceInfoPeripheral = MockConfiguration(
        name: "Device Information",
        devices: [
            MockDevice(
                name: "BLE Gadget",
                rssi: -60,
                isConnectable: true,
                isEnabled: true,
                advertisedServiceUUIDs: ["180A"],
                services: [
                    MockService(uuid: "1800", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A00",
                            properties: 0x02, // read
                            value: "BLE Gadget".data(using: .utf8)
                        ),
                        MockCharacteristic(
                            uuid: "2A01",
                            properties: 0x02, // read
                            value: Data([0x00, 0x00]) // unknown appearance
                        ),
                    ]),
                    MockService(uuid: "180A", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A29",
                            properties: 0x02,
                            value: "ImpossiBLE Inc.".data(using: .utf8)
                        ),
                        MockCharacteristic(
                            uuid: "2A24",
                            properties: 0x02,
                            value: "Mock-1000".data(using: .utf8)
                        ),
                        MockCharacteristic(
                            uuid: "2A25",
                            properties: 0x02,
                            value: "SN-00000001".data(using: .utf8)
                        ),
                        MockCharacteristic(
                            uuid: "2A26",
                            properties: 0x02,
                            value: "1.0.0".data(using: .utf8)
                        ),
                        MockCharacteristic(
                            uuid: "2A27",
                            properties: 0x02,
                            value: "Rev A".data(using: .utf8)
                        ),
                        MockCharacteristic(
                            uuid: "2A28",
                            properties: 0x02,
                            value: "2.1.0".data(using: .utf8)
                        ),
                    ]),
                ]
            ),
        ],
        isBuiltIn: true
    )

    static let multiServiceSensor = MockConfiguration(
        name: "Multi-Service Sensor",
        devices: [
            MockDevice(
                name: "Environment Sensor",
                rssi: -55,
                isConnectable: true,
                isEnabled: true,
                advertisedServiceUUIDs: ["181A"],
                services: [
                    MockService(uuid: "181A", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A6E",
                            properties: 0x12, // read + notify
                            value: Data([0xC8, 0x00]), // 20.0 C (little-endian, 0.01 resolution)
                            descriptors: [
                                MockDescriptor(uuid: "2902", value: Data([0x00, 0x00])),
                                MockDescriptor(uuid: "2901", value: "Temperature".data(using: .utf8)),
                            ]
                        ),
                        MockCharacteristic(
                            uuid: "2A6F",
                            properties: 0x12, // read + notify
                            value: Data([0xDC, 0x05]), // 15.00% (little-endian, 0.01 resolution)
                            descriptors: [
                                MockDescriptor(uuid: "2902", value: Data([0x00, 0x00])),
                                MockDescriptor(uuid: "2901", value: "Humidity".data(using: .utf8)),
                            ]
                        ),
                    ]),
                    MockService(uuid: "180F", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A19",
                            properties: 0x12,
                            value: Data([0x64]), // 100%
                            descriptors: [
                                MockDescriptor(uuid: "2902", value: Data([0x00, 0x00])),
                            ]
                        ),
                    ]),
                ]
            ),
            MockDevice(
                name: "Beacon",
                rssi: -80,
                isConnectable: false,
                isEnabled: true,
                advertisedServiceUUIDs: ["FE6F"],
                manufacturerData: Data([0x4C, 0x00, 0x02, 0x15, 0x01, 0x02, 0x03, 0x04]),
                services: []
            ),
        ],
        isBuiltIn: true
    )
}
