import Foundation
import Testing
@testable import BirdMenu

@Test func buildsTimestampCommandLikeOfficialTrace() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let date = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 25,
        hour: 21,
        minute: 56,
        second: 3
    )))

    let command = InkbirdITH11BHistoryProtocol.timestampCommand(for: date, calendar: calendar)

    #expect(command.hexString == "033815041906ea07a327")
}

@Test func decodesITH11BConfigIntervalFromFFF5() {
    let config = Data(hexString: "00000000002c010000000058029cff200364000401c8")

    #expect(InkbirdHistoryExportWriter.intervalSeconds(from: config) == 300)
}

@Test func decodesITH11BHistoryPayload() throws {
    let packet = InkbirdHistoryPacket(
        command: "ith11b_history_command_01",
        characteristicUUID: "FFF6",
        timestamp: Date(timeIntervalSince1970: 1_000),
        hex: "fd006f02fd006f02fd006d02fd006f02fd007502fd007902fd007d0200000000"
    )
    let latest = InkbirdReading(
        model: "ITH-11-B",
        deviceName: "ITH-11-B",
        peripheralID: UUID(),
        temperatureCelsius: 25.3,
        humidityPercent: 63.7,
        batteryPercent: 100,
        rssi: -50,
        date: Date(timeIntervalSince1970: 10_000),
        advertisementHex: ""
    )

    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: [packet],
        intervalSeconds: 60,
        latestReading: latest
    )

    #expect(records.count == 7)
    #expect(records.first?.temperatureCelsius == 25.3)
    #expect(records.first?.humidityPercent == 62.3)
    #expect(records.last?.humidityPercent == 63.7)
    #expect(records.first?.timestamp == Date(timeIntervalSince1970: 9_640))
    #expect(records.last?.timestamp == Date(timeIntervalSince1970: 10_000))
}
