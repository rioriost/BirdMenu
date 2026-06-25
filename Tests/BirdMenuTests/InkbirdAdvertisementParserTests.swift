import CoreBluetooth
import Foundation
import Testing
@testable import BirdMenu

@Test func parsesITH11BAdvertisement() throws {
    let data = Data([0x49, 0x24, 0x08, 0x12, 0x00, 0x5e, 0xfe, 0xff, 0x48, 0x03, 0x64, 0x00, 0x64, 0x08, 0x00, 0x00, 0x00, 0x00])
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let date = Date(timeIntervalSince1970: 1_234)

    let reading = try #require(InkbirdAdvertisementParser.parse(
        advertisedName: "ITH-11-B",
        serviceUUIDs: [InkbirdAdvertisementParser.serviceUUID],
        manufacturerData: data,
        rssi: -34,
        peripheralID: id,
        date: date
    ))

    #expect(reading.model == "ITH-11-B")
    #expect(reading.deviceName == "ITH-11-B")
    #expect(reading.peripheralID == id)
    #expect(reading.temperatureCelsius == -0.2)
    #expect(reading.humidityPercent == 84.0)
    #expect(reading.batteryPercent == 100)
    #expect(reading.rssi == -34)
    #expect(reading.date == date)
}

@Test func dropsCorruptHumidity() {
    let data = Data([0x49, 0x24, 0x08, 0x12, 0x00, 0x5e, 0x00, 0x00, 0xff, 0xff, 0x64, 0x00, 0x64, 0x08, 0x00, 0x00, 0x00, 0x00])

    let reading = InkbirdAdvertisementParser.parse(
        advertisedName: "ITH-11-B",
        serviceUUIDs: [InkbirdAdvertisementParser.serviceUUID],
        manufacturerData: data,
        rssi: -50,
        peripheralID: UUID()
    )

    #expect(reading == nil)
}

@Test func ignoresOtherManufacturer() {
    let data = Data([0x00, 0x00, 0x08, 0x12, 0x00, 0x5e, 0xfe, 0xff, 0x48, 0x03, 0x64, 0x00, 0x64, 0x08, 0x00, 0x00, 0x00, 0x00])

    let reading = InkbirdAdvertisementParser.parse(
        advertisedName: "ITH-11-B",
        serviceUUIDs: [InkbirdAdvertisementParser.serviceUUID],
        manufacturerData: data,
        rssi: -50,
        peripheralID: UUID()
    )

    #expect(reading == nil)
}
