import Foundation

// MARK: - Security

enum SecurityLevel: Int, Codable, Hashable, CaseIterable {
    case none = 0
    case encryptionRequired = 1
}

extension SecurityLevel {
    var label: String {
        switch self {
            case .none:                "None"
            case .encryptionRequired:  "Encryption Required"
        }
    }
}

enum PairingMode: Int, Codable, Hashable, CaseIterable {
    case none = 0
    case justWorks = 1
    case passkey = 2
}

extension PairingMode {
    var label: String {
        switch self {
            case .none:      "None"
            case .justWorks: "Just Works"
            case .passkey:   "Passkey"
        }
    }
}

// MARK: - GATT Model

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
    var securityLevel: SecurityLevel = .none
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
    var pairingMode: PairingMode = .none
    var passkey: String = ""
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
        denseSensorEnvironment,
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
                            value: "2.1.1".data(using: .utf8)
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

    // MARK: - Dense Sensor Environment

    static let denseSensorEnvironment = MockConfiguration(
        name: "Dense Sensor Environment",
        devices: [
            // 1 — Indoor climate station
            MockDevice(
                name: "Climate Station A1",
                rssi: -38,
                isConnectable: true,
                isEnabled: true,
                advertisedServiceUUIDs: ["181A"],
                services: [
                    MockService(uuid: "181A", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A6E", properties: 0x12,
                            value: Data([0x98, 0x08]), // 22.0 °C
                            descriptors: [
                                MockDescriptor(uuid: "2902", value: Data([0x00, 0x00])),
                                MockDescriptor(uuid: "2901", value: "Temperature".data(using: .utf8)),
                            ]
                        ),
                        MockCharacteristic(
                            uuid: "2A6F", properties: 0x12,
                            value: Data([0x84, 0x11]), // 45.0 %
                            descriptors: [
                                MockDescriptor(uuid: "2902", value: Data([0x00, 0x00])),
                                MockDescriptor(uuid: "2901", value: "Humidity".data(using: .utf8)),
                            ]
                        ),
                        MockCharacteristic(
                            uuid: "2A6D", properties: 0x12,
                            value: Data([0x10, 0x27, 0x00, 0x00]), // 1013.0 hPa
                            descriptors: [
                                MockDescriptor(uuid: "2902", value: Data([0x00, 0x00])),
                                MockDescriptor(uuid: "2901", value: "Pressure".data(using: .utf8)),
                            ]
                        ),
                    ]),
                    MockService(uuid: "180F", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A19", properties: 0x12,
                            value: Data([0x5F]), // 95 %
                            descriptors: [MockDescriptor(uuid: "2902", value: Data([0x00, 0x00]))]
                        ),
                    ]),
                    MockService(uuid: "180A", isPrimary: true, characteristics: [
                        MockCharacteristic(uuid: "2A29", properties: 0x02, value: "SensorCorp".data(using: .utf8)),
                        MockCharacteristic(uuid: "2A24", properties: 0x02, value: "CS-400".data(using: .utf8)),
                        MockCharacteristic(uuid: "2A26", properties: 0x02, value: "3.2.1".data(using: .utf8)),
                    ]),
                ]
            ),
            // 2 — Second climate station (different floor)
            MockDevice(
                name: "Climate Station B3",
                rssi: -62,
                isConnectable: true,
                isEnabled: true,
                advertisedServiceUUIDs: ["181A"],
                services: [
                    MockService(uuid: "181A", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A6E", properties: 0x12,
                            value: Data([0x30, 0x07]), // 18.4 °C
                            descriptors: [
                                MockDescriptor(uuid: "2902", value: Data([0x00, 0x00])),
                                MockDescriptor(uuid: "2901", value: "Temperature".data(using: .utf8)),
                            ]
                        ),
                        MockCharacteristic(
                            uuid: "2A6F", properties: 0x12,
                            value: Data([0xE8, 0x0E]), // 38.0 %
                            descriptors: [
                                MockDescriptor(uuid: "2902", value: Data([0x00, 0x00])),
                            ]
                        ),
                    ]),
                    MockService(uuid: "180F", isPrimary: true, characteristics: [
                        MockCharacteristic(uuid: "2A19", properties: 0x02, value: Data([0x4B])), // 75 %
                    ]),
                ]
            ),
            // 3 — Heart rate chest strap
            MockDevice(
                name: "Polar H10 #217",
                rssi: -44,
                isConnectable: true,
                isEnabled: true,
                advertisedServiceUUIDs: ["180D"],
                services: [
                    MockService(uuid: "180D", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A37", properties: 0x10,
                            value: Data([0x00, 0x44]), // HR 68 bpm
                            descriptors: [MockDescriptor(uuid: "2902", value: Data([0x00, 0x00]))]
                        ),
                        MockCharacteristic(uuid: "2A38", properties: 0x02, value: Data([0x01])),
                    ]),
                    MockService(uuid: "180F", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A19", properties: 0x12,
                            value: Data([0x52]), // 82 %
                            descriptors: [MockDescriptor(uuid: "2902", value: Data([0x00, 0x00]))]
                        ),
                    ]),
                ]
            ),
            // 4 — Blood pressure monitor
            MockDevice(
                name: "BP Monitor Pro",
                rssi: -51,
                isConnectable: true,
                isEnabled: true,
                advertisedServiceUUIDs: ["1810"],
                services: [
                    MockService(uuid: "1810", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A35", properties: 0x20, // indicate
                            value: Data([0x00, 0x78, 0x00, 0x50, 0x00, 0x5A, 0x00]),
                            descriptors: [MockDescriptor(uuid: "2902", value: Data([0x00, 0x00]))]
                        ),
                    ]),
                    MockService(uuid: "180A", isPrimary: true, characteristics: [
                        MockCharacteristic(uuid: "2A29", properties: 0x02, value: "MedTech".data(using: .utf8)),
                        MockCharacteristic(uuid: "2A24", properties: 0x02, value: "BPM-200".data(using: .utf8)),
                        MockCharacteristic(uuid: "2A25", properties: 0x02, value: "MT-90812".data(using: .utf8)),
                        MockCharacteristic(uuid: "2A26", properties: 0x02, value: "1.4.0".data(using: .utf8)),
                        MockCharacteristic(uuid: "2A28", properties: 0x02, value: "2.0.3".data(using: .utf8)),
                    ]),
                    MockService(uuid: "180F", isPrimary: true, characteristics: [
                        MockCharacteristic(uuid: "2A19", properties: 0x02, value: Data([0x64])), // 100 %
                    ]),
                ]
            ),
            // 5 — Cycling power meter
            MockDevice(
                name: "Stages LR",
                rssi: -57,
                isConnectable: true,
                isEnabled: true,
                advertisedServiceUUIDs: ["1818"],
                services: [
                    MockService(uuid: "1818", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A63", properties: 0x10, // notify – cycling power measurement
                            value: Data([0x00, 0x00, 0xB8, 0x00]),
                            descriptors: [MockDescriptor(uuid: "2902", value: Data([0x00, 0x00]))]
                        ),
                        MockCharacteristic(
                            uuid: "2A65", properties: 0x02, // read – cycling power feature
                            value: Data([0x00, 0x00, 0x00, 0x00])
                        ),
                        MockCharacteristic(
                            uuid: "2A5D", properties: 0x02, // read – sensor location
                            value: Data([0x0D]) // left crank
                        ),
                    ]),
                    MockService(uuid: "180F", isPrimary: true, characteristics: [
                        MockCharacteristic(uuid: "2A19", properties: 0x02, value: Data([0x2D])), // 45 %
                    ]),
                    MockService(uuid: "180A", isPrimary: true, characteristics: [
                        MockCharacteristic(uuid: "2A29", properties: 0x02, value: "Stages Cycling".data(using: .utf8)),
                        MockCharacteristic(uuid: "2A26", properties: 0x02, value: "4.1.7".data(using: .utf8)),
                    ]),
                ]
            ),
            // 6 — Speed/cadence sensor
            MockDevice(
                name: "Wahoo SC v2",
                rssi: -63,
                isConnectable: true,
                isEnabled: true,
                advertisedServiceUUIDs: ["1816"],
                services: [
                    MockService(uuid: "1816", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A5B", properties: 0x10, // notify – CSC measurement
                            value: Data([0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
                            descriptors: [MockDescriptor(uuid: "2902", value: Data([0x00, 0x00]))]
                        ),
                        MockCharacteristic(
                            uuid: "2A5C", properties: 0x02, // read – CSC feature
                            value: Data([0x03, 0x00])
                        ),
                        MockCharacteristic(
                            uuid: "2A5D", properties: 0x02, // sensor location
                            value: Data([0x06]) // rear wheel
                        ),
                    ]),
                    MockService(uuid: "180F", isPrimary: true, characteristics: [
                        MockCharacteristic(uuid: "2A19", properties: 0x02, value: Data([0x58])), // 88 %
                    ]),
                ]
            ),
            // 7 — Pulse oximeter
            MockDevice(
                name: "PulseOx Ring",
                rssi: -48,
                isConnectable: true,
                isEnabled: true,
                advertisedServiceUUIDs: ["1822"],
                services: [
                    MockService(uuid: "1822", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "2A5E", properties: 0x10, // notify – PLX spot-check
                            value: Data([0x00, 0x00, 0x62, 0x00, 0x42, 0x00]),
                            descriptors: [MockDescriptor(uuid: "2902", value: Data([0x00, 0x00]))]
                        ),
                        MockCharacteristic(
                            uuid: "2A60", properties: 0x02, // read – PLX features
                            value: Data([0x00, 0x00])
                        ),
                    ]),
                    MockService(uuid: "180F", isPrimary: true, characteristics: [
                        MockCharacteristic(uuid: "2A19", properties: 0x02, value: Data([0x37])), // 55 %
                    ]),
                ]
            ),
            // 8 — Custom IoT gateway with proprietary services (pairing required)
            MockDevice(
                name: "SmartHub GW-01",
                rssi: -35,
                isConnectable: true,
                isEnabled: true,
                advertisedServiceUUIDs: ["0000FFF0-0000-1000-8000-00805F9B34FB"],
                pairingMode: .justWorks,
                services: [
                    MockService(uuid: "0000FFF0-0000-1000-8000-00805F9B34FB", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "0000FFF1-0000-1000-8000-00805F9B34FB",
                            properties: 0x12, // read + notify – gateway status (open)
                            value: Data([0x01, 0x07, 0x00]),
                            descriptors: [
                                MockDescriptor(uuid: "2902", value: Data([0x00, 0x00])),
                                MockDescriptor(uuid: "2901", value: "Gateway Status".data(using: .utf8)),
                            ]
                        ),
                        MockCharacteristic(
                            uuid: "0000FFF2-0000-1000-8000-00805F9B34FB",
                            properties: 0x0A, // read + write – config (encrypted)
                            value: Data([0x00, 0x3C]),
                            securityLevel: .encryptionRequired,
                            descriptors: [
                                MockDescriptor(uuid: "2901", value: "Config".data(using: .utf8)),
                            ]
                        ),
                        MockCharacteristic(
                            uuid: "0000FFF3-0000-1000-8000-00805F9B34FB",
                            properties: 0x14, // write w/o response + notify – data channel (encrypted)
                            value: nil,
                            securityLevel: .encryptionRequired,
                            descriptors: [
                                MockDescriptor(uuid: "2902", value: Data([0x00, 0x00])),
                                MockDescriptor(uuid: "2901", value: "Data Channel".data(using: .utf8)),
                            ]
                        ),
                    ]),
                    MockService(uuid: "180A", isPrimary: true, characteristics: [
                        MockCharacteristic(uuid: "2A29", properties: 0x02, value: "SmartHub Inc.".data(using: .utf8)),
                        MockCharacteristic(uuid: "2A24", properties: 0x02, value: "GW-01".data(using: .utf8)),
                        MockCharacteristic(uuid: "2A26", properties: 0x02, value: "5.0.0-rc2".data(using: .utf8)),
                        MockCharacteristic(uuid: "2A27", properties: 0x02, value: "Rev C".data(using: .utf8)),
                    ]),
                    MockService(uuid: "180F", isPrimary: true, characteristics: [
                        MockCharacteristic(uuid: "2A19", properties: 0x02, value: Data([0x64])), // 100 % (mains-powered)
                    ]),
                ]
            ),
            // 9 — iBeacon (non-connectable)
            MockDevice(
                name: "Beacon Lobby",
                rssi: -72,
                isConnectable: false,
                isEnabled: true,
                advertisedServiceUUIDs: [],
                manufacturerData: Data([
                    0x4C, 0x00, 0x02, 0x15,
                    0xFD, 0xA5, 0x06, 0x93, 0xA4, 0xE2, 0x4F, 0xB1,
                    0xAF, 0xCF, 0xC6, 0xEB, 0x07, 0x64, 0x78, 0x25,
                    0x00, 0x01, 0x00, 0x0A, 0xC5,
                ]),
                services: []
            ),
            // 10 — iBeacon (non-connectable)
            MockDevice(
                name: "Beacon Hallway 2F",
                rssi: -85,
                isConnectable: false,
                isEnabled: true,
                advertisedServiceUUIDs: [],
                manufacturerData: Data([
                    0x4C, 0x00, 0x02, 0x15,
                    0xFD, 0xA5, 0x06, 0x93, 0xA4, 0xE2, 0x4F, 0xB1,
                    0xAF, 0xCF, 0xC6, 0xEB, 0x07, 0x64, 0x78, 0x25,
                    0x00, 0x02, 0x00, 0x14, 0xC5,
                ]),
                services: []
            ),
            // 11 — Light controller
            MockDevice(
                name: "LIFX Bulb #3",
                rssi: -67,
                isConnectable: true,
                isEnabled: true,
                advertisedServiceUUIDs: ["0000FE25-0000-1000-8000-00805F9B34FB"],
                services: [
                    MockService(uuid: "0000FE25-0000-1000-8000-00805F9B34FB", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "0000FE26-0000-1000-8000-00805F9B34FB",
                            properties: 0x0A, // read + write – on/off + brightness
                            value: Data([0x01, 0xFF]),
                            descriptors: [
                                MockDescriptor(uuid: "2901", value: "Power & Brightness".data(using: .utf8)),
                            ]
                        ),
                        MockCharacteristic(
                            uuid: "0000FE27-0000-1000-8000-00805F9B34FB",
                            properties: 0x0A, // read + write – color temperature
                            value: Data([0xF4, 0x01]), // 500 (= 5000K mapped)
                            descriptors: [
                                MockDescriptor(uuid: "2901", value: "Color Temperature".data(using: .utf8)),
                            ]
                        ),
                    ]),
                ]
            ),
            // 12 — Door sensor
            MockDevice(
                name: "Door Sensor Main",
                rssi: -74,
                isConnectable: true,
                isEnabled: true,
                advertisedServiceUUIDs: ["0000FFF0-0000-1000-8000-00805F9B34FB"],
                services: [
                    MockService(uuid: "0000FFF0-0000-1000-8000-00805F9B34FB", isPrimary: true, characteristics: [
                        MockCharacteristic(
                            uuid: "0000FFF1-0000-1000-8000-00805F9B34FB",
                            properties: 0x12, // read + notify – door state
                            value: Data([0x00]), // closed
                            descriptors: [
                                MockDescriptor(uuid: "2902", value: Data([0x00, 0x00])),
                                MockDescriptor(uuid: "2901", value: "Door State".data(using: .utf8)),
                            ]
                        ),
                    ]),
                    MockService(uuid: "180F", isPrimary: true, characteristics: [
                        MockCharacteristic(uuid: "2A19", properties: 0x02, value: Data([0x1E])), // 30 %
                    ]),
                ]
            ),
        ],
        isBuiltIn: true
    )
}
