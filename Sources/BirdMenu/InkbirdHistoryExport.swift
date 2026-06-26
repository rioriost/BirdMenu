import Foundation

struct InkbirdHistoryResult {
    let folderURL: URL
    let rawURL: URL
    let csvURL: URL?
    let recordCount: Int
    let packetCount: Int
    let warnings: [String]
}

struct InkbirdHistoryPacket: Codable {
    let command: String
    let characteristicUUID: String
    let timestamp: Date
    let hex: String
}

struct InkbirdGATTCharacteristicInfo: Codable {
    let serviceUUID: String
    let characteristicUUID: String
    let properties: [String]
    let valueHex: String?
}

struct InkbirdHistoryRawDump: Codable {
    let deviceName: String
    let peripheralID: String
    let fetchedAt: Date
    let mode: String
    let latestReading: LatestReadingSnapshot?
    let configHex: String?
    let intervalSeconds: Int?
    let characteristics: [InkbirdGATTCharacteristicInfo]
    let packets: [InkbirdHistoryPacket]
    let warnings: [String]

    struct LatestReadingSnapshot: Codable {
        let temperatureCelsius: Double
        let humidityPercent: Double?
        let batteryPercent: Int
        let rssi: Int
        let date: Date
    }
}

struct InkbirdHistoryRecord {
    let timestamp: Date?
    let index: Int
    let temperatureCelsius: Double?
    let humidityPercent: Double?
}

enum InkbirdHistoryExportWriter {
    static func write(
        deviceName: String,
        peripheralID: UUID,
        latestReading: InkbirdReading?,
        config: Data?,
        characteristics: [InkbirdGATTCharacteristicInfo],
        packets: [InkbirdHistoryPacket],
        warnings: [String],
        mode: String = "fff8-history",
        decodeHistory: Bool = true
    ) throws -> InkbirdHistoryResult {
        let folder = try outputFolder(deviceName: deviceName, peripheralID: peripheralID)
        let interval = intervalSeconds(from: config)
        let rawDump = InkbirdHistoryRawDump(
            deviceName: deviceName,
            peripheralID: peripheralID.uuidString,
            fetchedAt: Date(),
            mode: mode,
            latestReading: latestReading.map {
                InkbirdHistoryRawDump.LatestReadingSnapshot(
                    temperatureCelsius: $0.temperatureCelsius,
                    humidityPercent: $0.humidityPercent,
                    batteryPercent: $0.batteryPercent,
                    rssi: $0.rssi,
                    date: $0.date
                )
            },
            configHex: config?.hexString,
            intervalSeconds: interval,
            characteristics: characteristics,
            packets: packets,
            warnings: warnings
        )

        let rawURL = folder.appendingPathComponent("raw-history.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(rawDump).write(to: rawURL, options: .atomic)

        let records = decodeHistory
            ? decodeRecords(
                packets: packets,
                intervalSeconds: interval,
                latestReading: latestReading,
                mode: mode
            )
            : []
        let csvURL: URL?
        if records.contains(where: { $0.temperatureCelsius != nil || $0.humidityPercent != nil }) {
            let url = folder.appendingPathComponent("history.csv")
            try csv(for: records).write(to: url, atomically: true, encoding: .utf8)
            csvURL = url
        } else {
            csvURL = nil
        }

        return InkbirdHistoryResult(
            folderURL: folder,
            rawURL: rawURL,
            csvURL: csvURL,
            recordCount: records.count,
            packetCount: packets.count,
            warnings: warnings
        )
    }

    static func intervalSeconds(from config: Data?) -> Int? {
        guard let config, config.count >= 9 else {
            return nil
        }
        for offset in [5, 7] where offset + 1 < config.count {
            let value = Int(config[offset]) | (Int(config[offset + 1]) << 8)
            if (1...86_400).contains(value) {
                return value
            }
        }
        return nil
    }

    private static func outputFolder(deviceName: String, peripheralID: UUID) throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("BirdMenu Logs", isDirectory: true)
        let stamp = ISO8601DateFormatter.fileSafe.fileSafeString(from: Date())
        let shortID = peripheralID.uuidString.replacingOccurrences(of: "-", with: "").suffix(6).uppercased()
        let sanitizedName = deviceName.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        let folder = root.appendingPathComponent("\(stamp)-\(sanitizedName)-\(shortID)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func decodeRecords(
        packets: [InkbirdHistoryPacket],
        intervalSeconds: Int?,
        latestReading: InkbirdReading?,
        mode: String
    ) -> [InkbirdHistoryRecord] {
        if mode == "ith11b-official-trace" {
            return decodeITH11BRecords(
                packets: packets,
                intervalSeconds: intervalSeconds,
                latestReading: latestReading
            )
        }

        let tempData = packets
            .filter { $0.command == "temp_content" }
            .compactMap { Data(hexString: $0.hex) }
            .reduce(Data(), +)
        let humData = packets
            .filter { $0.command == "hum_content" }
            .compactMap { Data(hexString: $0.hex) }
            .reduce(Data(), +)

        let temperatures = decodeSignedSeries(
            tempData,
            candidates: [10.0, 100.0],
            plausible: -60.0...100.0,
            target: latestReading?.temperatureCelsius
        )
        let humidities = decodeUnsignedSeries(
            humData,
            candidates: [10.0, 100.0],
            plausible: 0.0...100.0,
            target: latestReading?.humidityPercent
        )

        let count = max(temperatures.count, humidities.count)
        guard count > 0 else {
            return []
        }

        let anchor = Date()
        return (0..<count).map { index in
            let timestamp = intervalSeconds.map { interval in
                anchor.addingTimeInterval(-Double(count - 1 - index) * Double(interval))
            }
            return InkbirdHistoryRecord(
                timestamp: timestamp,
                index: index,
                temperatureCelsius: index < temperatures.count ? temperatures[index] : nil,
                humidityPercent: index < humidities.count ? humidities[index] : nil
            )
        }
    }

    static func decodeITH11BRecords(
        packets: [InkbirdHistoryPacket],
        intervalSeconds: Int?,
        latestReading: InkbirdReading?
    ) -> [InkbirdHistoryRecord] {
        let data = packets
            .filter { $0.command == "ith11b_history_command_01" }
            .compactMap { Data(hexString: $0.hex) }
            .reduce(Data(), +)
        let records = decodeITH11BPayload(data)

        guard !records.isEmpty else {
            return []
        }

        let anchor = latestReading?.date ?? Date()
        return records.enumerated().map { index, pair in
            let timestamp = intervalSeconds.map { interval in
                anchor.addingTimeInterval(-Double(records.count - 1 - index) * Double(interval))
            }
            return InkbirdHistoryRecord(
                timestamp: timestamp,
                index: index,
                temperatureCelsius: pair.temperatureCelsius,
                humidityPercent: pair.humidityPercent
            )
        }
    }

    private static func decodeITH11BPayload(_ data: Data) -> [(temperatureCelsius: Double, humidityPercent: Double)] {
        guard data.count >= 4 else {
            return []
        }

        var records: [(temperatureCelsius: Double, humidityPercent: Double)] = []
        var index = 0
        while index + 3 < data.count {
            let temperatureRaw = Int16(bitPattern: UInt16(data[index]) | (UInt16(data[index + 1]) << 8))
            let humidityRaw = UInt16(data[index + 2]) | (UInt16(data[index + 3]) << 8)

            if temperatureRaw == 0, humidityRaw == 0 {
                break
            }

            let temperature = Double(temperatureRaw) / 10.0
            let humidity = Double(humidityRaw) / 10.0
            guard (-60.0...100.0).contains(temperature), (0.0...100.0).contains(humidity) else {
                break
            }

            records.append((temperature, humidity))
            index += 4
        }
        return records
    }

    private static func decodeSignedSeries(
        _ data: Data,
        candidates: [Double],
        plausible: ClosedRange<Double>,
        target: Double?
    ) -> [Double] {
        candidates
            .map { scale in
                decodePairs(data) { pair in
                    let raw = Int16(bitPattern: UInt16(pair.0) | (UInt16(pair.1) << 8))
                    return Double(raw) / scale
                }
            }
            .max { score($0, plausible: plausible, target: target) < score($1, plausible: plausible, target: target) } ?? []
    }

    private static func decodeUnsignedSeries(
        _ data: Data,
        candidates: [Double],
        plausible: ClosedRange<Double>,
        target: Double?
    ) -> [Double] {
        candidates
            .map { scale in
                decodePairs(data) { pair in
                    let raw = UInt16(pair.0) | (UInt16(pair.1) << 8)
                    return Double(raw) / scale
                }
            }
            .max { score($0, plausible: plausible, target: target) < score($1, plausible: plausible, target: target) } ?? []
    }

    private static func decodePairs(_ data: Data, transform: ((UInt8, UInt8)) -> Double) -> [Double] {
        guard data.count >= 2 else {
            return []
        }
        var values: [Double] = []
        var index = 0
        while index + 1 < data.count {
            values.append(transform((data[index], data[index + 1])))
            index += 2
        }
        return values
    }

    private static func score(_ values: [Double], plausible: ClosedRange<Double>, target: Double?) -> Double {
        guard !values.isEmpty else {
            return -Double.greatestFiniteMagnitude
        }
        let plausibleValues = values.filter { plausible.contains($0) }
        var score = Double(plausibleValues.count) / Double(values.count)
        if let target, let last = plausibleValues.last {
            score += max(0, 1.0 - abs(last - target) / 20.0)
        }
        return score
    }

    private static func csv(for records: [InkbirdHistoryRecord]) -> String {
        var lines = ["timestamp,index,temperature_c,humidity_percent"]
        let formatter = ISO8601DateFormatter()
        for record in records {
            lines.append([
                record.timestamp.map { formatter.string(from: $0) } ?? "",
                String(record.index),
                record.temperatureCelsius.map { String(format: "%.2f", $0) } ?? "",
                record.humidityPercent.map { String(format: "%.2f", $0) } ?? ""
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else {
            return nil
        }
        var bytes = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}

private extension ISO8601DateFormatter {
    static var fileSafe: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    func fileSafeString(from date: Date) -> String {
        string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }
}
