@preconcurrency import CoreBluetooth
import Foundation

struct InkbirdReading: Equatable {
    let model: String
    let deviceName: String
    let peripheralID: UUID
    let temperatureCelsius: Double
    let humidityPercent: Double?
    let batteryPercent: Int
    let rssi: Int
    let date: Date
    let advertisementHex: String
}

enum InkbirdAdvertisementParser {
    static let serviceUUIDString = "0000FFF0-0000-1000-8000-00805F9B34FB"
    static var serviceUUID: CBUUID { CBUUID(string: serviceUUIDString) }
    static let modelName = "ITH-11-B"

    private static let manufacturerID = 9289
    private static let messageLength = 18
    private static let maxHumidity = 100.0
    private static let maxBattery = 100

    static func parse(
        advertisedName: String?,
        serviceUUIDs: [CBUUID],
        manufacturerData: Data,
        rssi: Int,
        peripheralID: UUID,
        date: Date = Date()
    ) -> InkbirdReading? {
        guard manufacturerData.count == messageLength else {
            return nil
        }

        let lowerName = advertisedName?.lowercased()
        let hasInkbirdService = serviceUUIDs.contains { $0 == serviceUUID }
        guard lowerName == modelName.lowercased() || hasInkbirdService else {
            return nil
        }

        let manufacturer = Int(manufacturerData[0]) | (Int(manufacturerData[1]) << 8)
        guard manufacturer == manufacturerID else {
            return nil
        }

        let tempRaw = Int16(bitPattern: UInt16(manufacturerData[6]) | (UInt16(manufacturerData[7]) << 8))
        let humidityRaw = UInt16(manufacturerData[8]) | (UInt16(manufacturerData[9]) << 8)
        let battery = Int(manufacturerData[10])

        let humidity = Double(humidityRaw) / 10.0
        guard humidity <= maxHumidity, battery <= maxBattery else {
            return nil
        }

        return InkbirdReading(
            model: modelName,
            deviceName: advertisedName ?? modelName,
            peripheralID: peripheralID,
            temperatureCelsius: Double(tempRaw) / 10.0,
            humidityPercent: humidityRaw == 0 ? nil : humidity,
            batteryPercent: battery,
            rssi: rssi,
            date: date,
            advertisementHex: manufacturerData.hexString
        )
    }
}
