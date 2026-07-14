import Foundation
import Testing
@testable import BirdMenu

private func historyMetadataPacket(
    count: Int,
    minute: Int = 34,
    hour: Int = 14,
    weekday: Int = 5,
    day: Int = 3,
    month: Int = 7,
    year: Int = 2026
) -> InkbirdHistoryPacket {
    let bytes = [
        count & 0xff,
        (count >> 8) & 0xff,
        (count >> 16) & 0xff,
        (count >> 24) & 0xff,
        minute,
        hour,
        weekday,
        day,
        month,
        year & 0xff,
        (year >> 8) & 0xff
    ]
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    return InkbirdHistoryPacket(
        command: "ith11b_history_command_02",
        characteristicUUID: "FFF6",
        timestamp: Date(timeIntervalSince1970: 999),
        hex: hex
    )
}

private func tokyoCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return calendar
}

private func historyBlockPacket(
    sequence: Int,
    payloadHex: String,
    command: String = "ith11b_history_command_01",
    timestamp: Date = Date(timeIntervalSince1970: 1_000)
) -> InkbirdHistoryPacket {
    var data = Data(hexString: payloadHex)!
    precondition(data.count <= InkbirdITH11BHistoryProtocol.historyBlockPayloadSize)
    precondition(data.count % InkbirdITH11BHistoryProtocol.historyRecordSize == 0)
    data.append(Data(
        repeating: 0,
        count: InkbirdITH11BHistoryProtocol.historyBlockPayloadSize - data.count
    ))
    data.append(UInt8(sequence & 0xff))
    data.append(UInt8((sequence >> 8) & 0xff))
    return InkbirdHistoryPacket(
        command: command,
        characteristicUUID: "FFF6",
        timestamp: timestamp,
        hex: data.hexString
    )
}

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

@Test func decodesITH11BHistoryAnchorInLocalCalendar() throws {
    let calendar = tokyoCalendar()
    let expectedAnchor = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 7,
        day: 14,
        hour: 9,
        minute: 48,
        second: 0
    )))
    let packets = [
        historyMetadataPacket(
            count: 1,
            minute: 48,
            hour: 9,
            weekday: 2,
            day: 14,
            month: 7,
            year: 2026
        ),
        historyBlockPacket(sequence: 1, payloadHex: "48017702")
    ]

    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: packets,
        intervalSeconds: 300,
        latestReading: nil,
        calendar: calendar
    )

    #expect(records.count == 1)
    #expect(records[0].timestamp == expectedAnchor)
    #expect(records[0].temperatureCelsius == 32.8)
    #expect(records[0].humidityPercent == 63.1)
}

@Test func decodesITH11BConfigIntervalFromFFF5() {
    let config = Data(hexString: "00000000002c010000000058029cff200364000401c8")

    #expect(InkbirdHistoryExportWriter.intervalSeconds(from: config) == 300)
}

@Test func decodesITH11BHistoryPayload() throws {
    let calendar = tokyoCalendar()
    let anchor = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 7,
        day: 3,
        hour: 14,
        minute: 34,
        second: 0
    )))
    let packet = historyBlockPacket(
        sequence: 1,
        payloadHex: "fd006f02fd006f02fd006d02fd006f02fd007502fd007902fd007d02"
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
        packets: [historyMetadataPacket(count: 7), packet],
        intervalSeconds: 60,
        latestReading: latest,
        calendar: calendar
    )

    #expect(records.count == 7)
    #expect(records.first?.temperatureCelsius == 25.3)
    #expect(records.first?.humidityPercent == 62.3)
    #expect(records.last?.humidityPercent == 63.7)
    #expect(records.first?.timestamp == anchor.addingTimeInterval(-360))
    #expect(records.last?.timestamp == anchor)
}

@Test func decodesITH11BHistoryPayloadAnchoredByCommand02Metadata() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let anchor = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 7,
        day: 3,
        hour: 14,
        minute: 34,
        second: 0
    )))
    let packets = [
        historyMetadataPacket(count: 7),
        historyBlockPacket(
            sequence: 1,
            payloadHex: "fd006f02fd006f02fd006d02fd006f02fd007502fd007902fd007d02"
        )
    ]
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
        packets: packets,
        intervalSeconds: 60,
        latestReading: latest,
        calendar: calendar
    )

    #expect(records.count == 7)
    #expect(records.first?.timestamp == anchor.addingTimeInterval(-360))
    #expect(records.last?.timestamp == anchor)
}

@Test func rejectsITH11BCommand02MetadataWhenRecordCountDoesNotMatch() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let packet = historyBlockPacket(
        sequence: 1,
        payloadHex: "fd006f02fd006f02fd006d02fd006f02fd007502fd007902fd007d02"
    )
    let mismatchedMetadata = InkbirdHistoryPacket(
        command: "ith11b_history_command_02",
        characteristicUUID: "FFF6",
        timestamp: Date(timeIntervalSince1970: 999),
        hex: "08000000220e050307ea079bdb00000000000000"
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
        packets: [mismatchedMetadata, packet],
        intervalSeconds: 60,
        latestReading: latest,
        calendar: calendar
    )

    #expect(records.isEmpty)
}

@Test func rejectsITH11BHistoryPayloadWithoutBlockTrailer() {
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
        packets: [historyMetadataPacket(count: 2)] + packets,
        intervalSeconds: nil,
        latestReading: nil,
        calendar: tokyoCalendar()
    )

    #expect(records.isEmpty)
}

@Test func decodesITH11BHistoryPacketsWithTwoByteTrailers() {
    let packets = [
        historyBlockPacket(
            sequence: 1,
            payloadHex: String(repeating: "e400b103", count: 45)
        ),
        historyBlockPacket(
            sequence: 2,
            payloadHex: String(repeating: "e500e303", count: 45),
            timestamp: Date(timeIntervalSince1970: 1_001)
        )
    ]

    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: [historyMetadataPacket(count: 90)] + packets,
        intervalSeconds: 60,
        latestReading: nil,
        calendar: tokyoCalendar()
    )

    #expect(records.count == 90)
    #expect(records[44].temperatureCelsius == 22.8)
    #expect(records[44].humidityPercent == 94.5)
    #expect(records[45].temperatureCelsius == 22.9)
    #expect(records[45].humidityPercent == 99.5)
}

@Test func countsDecodedITH11BRecordsAgainstExpectedMetadata() {
    let packets = [
        historyMetadataPacket(count: 90),
        historyBlockPacket(
            sequence: 1,
            payloadHex: String(repeating: "e400b103", count: 45)
        ),
        historyBlockPacket(
            sequence: 2,
            payloadHex: String(repeating: "e500e303", count: 45),
            timestamp: Date(timeIntervalSince1970: 1_001)
        )
    ]

    #expect(InkbirdHistoryExportWriter.ith11BExpectedRecordCount(from: packets) == 90)
    #expect(InkbirdHistoryExportWriter.decodedITH11BRecordCount(from: packets) == 90)
}

@Test func detectsMissingITH11BBlocksAndBuildsOfficialRetryRequest() throws {
    let packets = [
        historyMetadataPacket(count: 135),
        historyBlockPacket(
            sequence: 3,
            payloadHex: String(repeating: "e600e403", count: 45)
        ),
        historyBlockPacket(
            sequence: 1,
            payloadHex: String(repeating: "e400b103", count: 45)
        )
    ]

    let status = try #require(InkbirdHistoryExportWriter.ith11BHistoryBlockStatus(from: packets))
    let request = try #require(InkbirdITH11BHistoryProtocol.missingBlockRequest(
        sequences: status.missingSequences
    ))

    #expect(status.expectedBlockCount == 3)
    #expect(status.receivedSequences == [1, 3])
    #expect(status.missingSequences == [2])
    #expect(!status.isComplete)
    #expect(request.count == 182)
    #expect(request.prefix(4) == Data([0x02, 0x00, 0x00, 0x00]))
}

@Test func sortsAndDeduplicatesRetransmittedITH11BBlocks() throws {
    let packets = [
        historyMetadataPacket(count: 90),
        historyBlockPacket(
            sequence: 2,
            payloadHex: String(repeating: "e500e303", count: 45)
        ),
        historyBlockPacket(
            sequence: 1,
            payloadHex: String(repeating: "e400b103", count: 45)
        ),
        historyBlockPacket(
            sequence: 2,
            payloadHex: String(repeating: "e500e303", count: 45),
            command: "ith11b_history_command_03"
        )
    ]

    let status = try #require(InkbirdHistoryExportWriter.ith11BHistoryBlockStatus(from: packets))
    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: packets,
        intervalSeconds: 60,
        latestReading: nil,
        calendar: tokyoCalendar()
    )

    #expect(status.isComplete)
    #expect(status.receivedSequences == [1, 2])
    #expect(status.decodedRecordCount == 90)
    #expect(records.count == 90)
    #expect(records[44].temperatureCelsius == 22.8)
    #expect(records[45].temperatureCelsius == 22.9)
}

@Test func anchorsZeroTimestampHeaderToSessionClockInterval() throws {
    let calendar = tokyoCalendar()
    let clockSetAt = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 7,
        day: 14,
        hour: 9,
        minute: 43,
        second: 37
    )))
    let expectedAnchor = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 7,
        day: 14,
        hour: 9,
        minute: 40
    )))
    let packets = [
        historyMetadataPacket(
            count: 1,
            minute: 0,
            hour: 0,
            weekday: 0,
            day: 0,
            month: 0,
            year: 0
        ),
        historyBlockPacket(sequence: 1, payloadHex: "1c01fa02")
    ]

    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: packets,
        intervalSeconds: 300,
        latestReading: nil,
        calendar: calendar,
        clockSetAt: clockSetAt
    )

    #expect(records.count == 1)
    #expect(records[0].timestamp == expectedAnchor)
    #expect(records[0].temperatureCelsius == 28.4)
    #expect(records[0].humidityPercent == 76.2)
}

@Test func rejectsZeroTimestampHeaderWithoutSessionClock() {
    let packets = [
        historyMetadataPacket(
            count: 1,
            minute: 0,
            hour: 0,
            weekday: 0,
            day: 0,
            month: 0,
            year: 0
        ),
        historyBlockPacket(sequence: 1, payloadHex: "1c01fa02")
    ]

    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: packets,
        intervalSeconds: 300,
        latestReading: nil,
        calendar: tokyoCalendar()
    )

    #expect(records.isEmpty)
}

@Test func decodesFull590RecordRingBufferWithZeroTimestampHeader() throws {
    let calendar = tokyoCalendar()
    let clockSetAt = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 7,
        day: 14,
        hour: 9,
        minute: 43,
        second: 37
    )))
    let expectedAnchor = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 7,
        day: 14,
        hour: 9,
        minute: 40
    )))
    var packets = [historyMetadataPacket(
        count: 590,
        minute: 0,
        hour: 0,
        weekday: 0,
        day: 0,
        month: 0,
        year: 0
    )]
    for sequence in 1...14 {
        let recordCount = sequence == 14 ? 5 : 45
        packets.append(historyBlockPacket(
            sequence: sequence,
            payloadHex: String(repeating: "1c01fa02", count: recordCount)
        ))
    }

    let status = try #require(InkbirdHistoryExportWriter.ith11BHistoryBlockStatus(from: packets))
    let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
        packets: packets,
        intervalSeconds: 300,
        latestReading: nil,
        calendar: calendar,
        clockSetAt: clockSetAt
    )

    #expect(status.expectedBlockCount == 14)
    #expect(status.isComplete)
    #expect(records.count == 590)
    #expect(records.last?.timestamp == expectedAnchor)
    #expect(records.first?.timestamp == expectedAnchor.addingTimeInterval(-589 * 300))
}

@Test func chartGroupsRecordsByLocalDayInProvidedTimeZone() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let june28 = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
        hour: 23,
        minute: 59
    )))
    let june29 = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 29,
        hour: 0,
        minute: 0
    )))
    let records = [
        InkbirdHistoryRecord(timestamp: june29, index: 1, temperatureCelsius: 24.1, humidityPercent: 70.0),
        InkbirdHistoryRecord(timestamp: june28, index: 0, temperatureCelsius: 24.0, humidityPercent: 69.0)
    ]

    let groups = InkbirdHistoryChartRenderer.recordsByLocalDay(records, timeZone: calendar.timeZone)

    #expect(groups.count == 2)
    #expect(groups[0].dayStart == calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
    )))
    #expect(groups[0].records.map(\.index) == [0])
    #expect(groups[1].dayStart == calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 29,
    )))
    #expect(groups[1].records.map(\.index) == [1])
    #expect(InkbirdHistoryChartRenderer.fileName(forDayStartingAt: groups[0].dayStart, timeZone: calendar.timeZone) == "history_20260628.png")
    #expect(InkbirdHistoryChartRenderer.fileName(forDayStartingAt: groups[1].dayStart, timeZone: calendar.timeZone) == "history_20260629.png")
}

@Test func chartDayDomainCoversWholeLocalDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let date = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
        hour: 11,
        minute: 34
    )))

    let domain = InkbirdHistoryChartRenderer.dayTimeDomain(startingAt: date, timeZone: calendar.timeZone)

    #expect(domain.start == calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28
    )))
    #expect(domain.end == calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
        hour: 23,
        minute: 59,
        second: 59
    )))
}

@Test func writesHistoryPNGsPerLocalDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let june28 = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 28,
        hour: 23,
        minute: 50
    )))
    let june29 = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 6,
        day: 29,
        hour: 0,
        minute: 10
    )))
    let records = [
        InkbirdHistoryRecord(timestamp: june28, index: 0, temperatureCelsius: 24.0, humidityPercent: 69.0),
        InkbirdHistoryRecord(timestamp: june29, index: 1, temperatureCelsius: 24.1, humidityPercent: 70.0)
    ]
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("BirdMenuTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: folder)
    }

    let urls = try InkbirdHistoryChartRenderer.writePNGs(for: records, to: folder, timeZone: calendar.timeZone)

    #expect(urls.map(\.lastPathComponent) == ["history_20260628.png", "history_20260629.png"])
    for url in urls {
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data([0x89, 0x50, 0x4e, 0x47])))
    }
}

@Test func writesHistoryPNGForSelectedLocalDayFromExistingCSVs() throws {
    let timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let selectedDate = try #require(calendar.date(from: DateComponents(
        timeZone: timeZone,
        year: 2026,
        month: 7,
        day: 2,
        hour: 12
    )))
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("BirdMenuTests-\(UUID().uuidString)", isDirectory: true)
    let firstFetch = folder.appendingPathComponent("2026-07-02T01-00-00Z-Sensor-AAAAAA", isDirectory: true)
    let secondFetch = folder.appendingPathComponent("2026-07-03T01-00-00Z-Sensor-AAAAAA", isDirectory: true)
    try FileManager.default.createDirectory(at: firstFetch, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondFetch, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: folder)
    }

    try """
    timestamp,index,temperature_c,humidity_percent
    2026-07-01T15:00:00Z,0,23.10,70.00
    2026-07-02T12:00:00Z,1,24.20,71.00
    """.write(to: firstFetch.appendingPathComponent("history.csv"), atomically: true, encoding: .utf8)
    try """
    timestamp,index,temperature_c,humidity_percent
    2026-07-02T13:00:00Z,0,24.40,72.00
    2026-07-03T01:00:00Z,1,25.00,73.00
    """.write(to: secondFetch.appendingPathComponent("history.csv"), atomically: true, encoding: .utf8)

    let result = try InkbirdHistoryChartRenderer.writePNGForLocalDay(
        containing: selectedDate,
        historyRoot: folder,
        timeZone: timeZone
    )

    #expect(result.dayStart == calendar.date(from: DateComponents(
        timeZone: timeZone,
        year: 2026,
        month: 7,
        day: 2
    )))
    #expect(result.recordCount == 3)
    #expect(result.csvURLs.count == 2)
    #expect(result.pngURL == folder.appendingPathComponent("history_20260702.png"))
    let data = try Data(contentsOf: result.pngURL)
    #expect(data.starts(with: Data([0x89, 0x50, 0x4e, 0x47])))
}

@Test func doesNotDecodeITH11BInitialRTDTHHistoryWithoutCommandFlow() {
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

    #expect(records.isEmpty)
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
