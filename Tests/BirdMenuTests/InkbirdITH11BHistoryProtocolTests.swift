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

@Test func decodesITH11BHistoryPayloadAcrossNotificationBoundaries() {
    let packets = [
        InkbirdHistoryPacket(
            command: "ith11b_history_command_01",
            characteristicUUID: "FFF6",
            timestamp: Date(timeIntervalSince1970: 1_000),
            hex: "fd006f02fd"
        ),
        InkbirdHistoryPacket(
            command: "ith11b_history_command_01",
            characteristicUUID: "FFF6",
            timestamp: Date(timeIntervalSince1970: 1_001),
            hex: "006d0200000000"
        )
    ]

    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: packets,
        intervalSeconds: nil,
        latestReading: nil
    )

    #expect(records.count == 2)
    #expect(records[0].temperatureCelsius == 25.3)
    #expect(records[0].humidityPercent == 62.3)
    #expect(records[1].temperatureCelsius == 25.3)
    #expect(records[1].humidityPercent == 62.1)
}

@Test func decodesITH11BHistoryPacketsWithTwoByteTrailers() {
    let packets = [
        InkbirdHistoryPacket(
            command: "ith11b_history_command_01",
            characteristicUUID: "FFF6",
            timestamp: Date(timeIntervalSince1970: 1_000),
            hex: String(repeating: "e400b103", count: 45) + "0100"
        ),
        InkbirdHistoryPacket(
            command: "ith11b_history_command_01",
            characteristicUUID: "FFF6",
            timestamp: Date(timeIntervalSince1970: 1_001),
            hex: String(repeating: "e500e303", count: 45) + "0200"
        )
    ]

    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: packets,
        intervalSeconds: nil,
        latestReading: nil
    )

    #expect(records.count == 90)
    #expect(records[44].temperatureCelsius == 22.8)
    #expect(records[44].humidityPercent == 94.5)
    #expect(records[45].temperatureCelsius == 22.9)
    #expect(records[45].humidityPercent == 99.5)
}

@Test func chartTimeDomainRoundsOutToHalfHoursInJST() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let start = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
        hour: 11,
        minute: 34
    )))
    let end = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
        hour: 13,
        minute: 22
    )))

    let domain = InkbirdHistoryChartRenderer.roundedTimeDomain(for: [start, end], timeZone: calendar.timeZone)

    #expect(domain.start == calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
        hour: 11,
        minute: 30
    )))
    #expect(domain.end == calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
        hour: 13,
        minute: 30
    )))
}

@Test func decodesITH11BInitialRTDTHHistoryWithFallbackIntervalAndDeduplication() {
    let rtdthHex = "7274647468de00e703610084080000000000e703"
        + String(repeating: "e500e703", count: 14)
        + String(repeating: "0000", count: 50)
        + "0300"
    let packets = [
        InkbirdHistoryPacket(
            command: "initial_or_unsolicited",
            characteristicUUID: "FFF6",
            timestamp: Date(timeIntervalSince1970: 1_000),
            hex: rtdthHex
        ),
        InkbirdHistoryPacket(
            command: "initial_or_unsolicited",
            characteristicUUID: "FFF6",
            timestamp: Date(timeIntervalSince1970: 1_001),
            hex: rtdthHex
        )
    ]
    let latest = InkbirdReading(
        model: "ITH-11-B",
        deviceName: "ITH-11-B",
        peripheralID: UUID(),
        temperatureCelsius: 22.2,
        humidityPercent: 99.9,
        batteryPercent: 97,
        rssi: -86,
        date: Date(timeIntervalSince1970: 10_000),
        advertisementHex: ""
    )

    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: packets,
        intervalSeconds: nil,
        latestReading: latest
    )

    #expect(records.count == 14)
    #expect(records.first?.temperatureCelsius == 22.9)
    #expect(records.first?.humidityPercent == 99.9)
    #expect(records.first?.timestamp == Date(timeIntervalSince1970: 9_220))
    #expect(records.last?.timestamp == Date(timeIntervalSince1970: 10_000))
}

@Test func chartHumidityAxisFixesUpperBoundAtOneHundredPercent() {
    let range = InkbirdHistoryChartRenderer.humidityAxisRange(values: [99.9, 99.9, 99.9])

    #expect(range.lower == 99.7)
    #expect(range.upper == 100.0)
}

@Test func chartTemperatureAxisUsesPaddedNiceRange() {
    let range = InkbirdHistoryChartRenderer.temperatureAxisRange(values: [22.9, 24.1])

    #expect(range.lower == 22.6)
    #expect(abs(range.upper - 24.4) < 0.0001)
}

@Test func rendersHistoryPNG() throws {
    let records = [
        InkbirdHistoryRecord(timestamp: Date(timeIntervalSince1970: 1_000), index: 0, temperatureCelsius: 24.1, humidityPercent: 99.9),
        InkbirdHistoryRecord(timestamp: Date(timeIntervalSince1970: 1_060), index: 1, temperatureCelsius: 24.0, humidityPercent: 99.9),
        InkbirdHistoryRecord(timestamp: Date(timeIntervalSince1970: 1_120), index: 2, temperatureCelsius: 23.9, humidityPercent: 99.9)
    ]

    let data = try #require(try InkbirdHistoryChartRenderer.pngData(for: records))

    #expect(data.starts(with: Data([0x89, 0x50, 0x4e, 0x47])))
}
