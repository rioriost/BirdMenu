import Foundation

enum InkbirdITH11BHistoryProtocol {
    struct HistoryHeader: Equatable, Sendable {
        let recordCount: Int
        let minute: Int
        let hour: Int
        let weekday: Int
        let day: Int
        let month: Int
        let year: Int

        var hasZeroTimestamp: Bool {
            minute == 0 && hour == 0 && weekday == 0 && day == 0 && month == 0 && year == 0
        }
    }

    struct HistoryBlock: Equatable, Sendable {
        let sequence: Int
        let payload: Data
    }

    struct HistoryBlockStatus: Equatable, Sendable {
        let expectedRecordCount: Int
        let expectedBlockCount: Int
        let receivedSequences: [Int]
        let missingSequences: [Int]
        let decodedRecordCount: Int

        var isComplete: Bool {
            missingSequences.isEmpty && decodedRecordCount == expectedRecordCount
        }
    }

    struct MissingBlockRecoveryTracker {
        enum Decision: Equatable {
            case retry(round: Int)
            case complete
            case wait(TimeInterval)
            case timedOut(retryRounds: Int, missingSequences: [Int])
        }

        let timeout: TimeInterval
        let retryInterval: TimeInterval
        private(set) var retryRound = 0
        private var receivedBlockCount = 0
        private var lastProgressAt: TimeInterval?
        private var lastRequestAt: TimeInterval?

        init(
            timeout: TimeInterval = 180,
            retryInterval: TimeInterval = 15
        ) {
            precondition(timeout > 0)
            precondition(retryInterval > 0)
            self.timeout = timeout
            self.retryInterval = retryInterval
        }

        mutating func observe(status: HistoryBlockStatus, at now: TimeInterval) {
            if lastProgressAt == nil || status.receivedSequences.count > receivedBlockCount {
                lastProgressAt = now
                receivedBlockCount = status.receivedSequences.count
            }
        }

        mutating func nextDecision(
            status: HistoryBlockStatus,
            at now: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) -> Decision {
            observe(status: status, at: now)
            if status.isComplete {
                return .complete
            }
            if let lastProgressAt, now - lastProgressAt >= timeout {
                return .timedOut(
                    retryRounds: retryRound,
                    missingSequences: status.missingSequences
                )
            }
            let backoff = min(retryInterval * pow(2, Double(min(retryRound, 2))), 60)
            let eligibleAt = max(
                (lastProgressAt ?? now) + retryInterval,
                (lastRequestAt ?? (now - backoff)) + backoff
            )
            if now < eligibleAt {
                return .wait(eligibleAt - now)
            }
            retryRound += 1
            lastRequestAt = now
            return .retry(round: retryRound)
        }
    }

    static let historyRecordSize = 4
    static let historyBlockPayloadSize = 180
    static let historyRecordsPerBlock = historyBlockPayloadSize / historyRecordSize
    static let historyBlockSize = historyBlockPayloadSize + 2

    static func timestampCommand(for date: Date = Date(), calendar: Calendar = .current) -> Data {

        let second = UInt8(calendar.component(.second, from: date))
        let minute = UInt8(calendar.component(.minute, from: date))
        let hour = UInt8(calendar.component(.hour, from: date))
        let day = UInt8(calendar.component(.day, from: date))
        let month = UInt8(calendar.component(.month, from: date))
        let year = UInt16(calendar.component(.year, from: date))
        let isoWeekday = UInt8(((calendar.component(.weekday, from: date) + 5) % 7) + 1)

        var payload = Data([
            second,
            minute,
            hour,
            isoWeekday,
            day,
            month,
            UInt8(year & 0x00ff),
            UInt8(year >> 8)
        ])
        let crc = crc16Modbus(payload)
        payload.append(UInt8(crc & 0x00ff))
        payload.append(UInt8(crc >> 8))
        return payload
    }

    static func historyHeader(from data: Data) -> HistoryHeader? {
        guard data.count >= 11 else {
            return nil
        }
        let header = HistoryHeader(
            recordCount: Int(data[0])
                | (Int(data[1]) << 8)
                | (Int(data[2]) << 16)
                | (Int(data[3]) << 24),
            minute: Int(data[4]),
            hour: Int(data[5]),
            weekday: Int(data[6]),
            day: Int(data[7]),
            month: Int(data[8]),
            year: Int(data[9]) | (Int(data[10]) << 8)
        )
        guard header.recordCount <= historyRecordsPerBlock * Int(UInt16.max),
              header.hasZeroTimestamp || (
                (0...59).contains(header.minute) && (0...23).contains(header.hour)
                && (1...7).contains(header.weekday) && (1...31).contains(header.day)
                && (1...12).contains(header.month) && (2000...2099).contains(header.year)
              )
        else {
            return nil
        }
        return header
    }

    static func historyBlock(from data: Data) -> HistoryBlock? {
        guard data.count >= historyRecordSize + 2,
              data.count <= historyBlockSize,
              data.count % historyRecordSize == 2
        else {
            return nil
        }
        let sequence = Int(data[data.count - 2]) | (Int(data[data.count - 1]) << 8)
        guard sequence > 0 else {
            return nil
        }
        return HistoryBlock(sequence: sequence, payload: Data(data.dropLast(2)))
    }

    static func historyBlockStatus(
        expectedRecordCount: Int,
        blocks: [HistoryBlock]
    ) -> HistoryBlockStatus {
        let expectedBlockCount = expectedRecordCount > 0
            ? Int(ceil(Double(expectedRecordCount) / Double(historyRecordsPerBlock)))
            : 0
        let expectedSequences: Set<Int> = expectedBlockCount > 0
            ? Set(1...expectedBlockCount)
            : []
        let validBlocks = blocks.filter { samples(in: $0, expectedRecordCount: expectedRecordCount) != nil }
        let receivedSequences = Set(validBlocks.map(\.sequence)).intersection(expectedSequences)
        return HistoryBlockStatus(
            expectedRecordCount: expectedRecordCount,
            expectedBlockCount: expectedBlockCount,
            receivedSequences: receivedSequences.sorted(),
            missingSequences: expectedSequences.subtracting(receivedSequences).sorted(),
            decodedRecordCount: receivedSequences.reduce(0) {
                $0 + min(historyRecordsPerBlock, expectedRecordCount - ($1 - 1) * historyRecordsPerBlock)
            }
        )
    }

    struct Sample: Equatable, Sendable {
        let temperatureCelsius: Double
        let humidityPercent: Double
    }

    struct BlockAccumulator: Sendable {
        let expectedRecordCount: Int
        private(set) var blocksBySequence: [Int: HistoryBlock] = [:]

        @discardableResult
        mutating func accept(_ block: HistoryBlock) -> Bool {
            guard blocksBySequence[block.sequence] == nil,
                  samples(in: block, expectedRecordCount: expectedRecordCount) != nil
            else {
                return false
            }
            blocksBySequence[block.sequence] = block
            return true
        }

        var status: HistoryBlockStatus {
            historyBlockStatus(expectedRecordCount: expectedRecordCount, blocks: Array(blocksBySequence.values))
        }

        var records: [Sample] {
            blocksBySequence.values.sorted { $0.sequence < $1.sequence }.flatMap {
                samples(in: $0, expectedRecordCount: expectedRecordCount) ?? []
            }
        }
    }

    static func samples(in block: HistoryBlock, expectedRecordCount: Int) -> [Sample]? {
        let firstRecord = (block.sequence - 1) * historyRecordsPerBlock
        guard block.sequence > 0, firstRecord >= 0, firstRecord < expectedRecordCount else {
            return nil
        }
        let count = min(historyRecordsPerBlock, expectedRecordCount - firstRecord)
        guard block.payload.count >= count * historyRecordSize,
              block.payload.count <= historyBlockPayloadSize,
              block.payload.count.isMultiple(of: historyRecordSize),
              block.payload.dropFirst(count * historyRecordSize).allSatisfy({ $0 == 0 })
        else {
            return nil
        }
        var records: [Sample] = []
        for index in stride(from: 0, to: count * historyRecordSize, by: historyRecordSize) {
            let temperatureRaw = Int16(bitPattern: UInt16(block.payload[index]) | (UInt16(block.payload[index + 1]) << 8))
            let humidityRaw = UInt16(block.payload[index + 2]) | (UInt16(block.payload[index + 3]) << 8)
            let temperature = Double(temperatureRaw) / 10
            let humidity = Double(humidityRaw) / 10
            guard temperatureRaw != 0 || humidityRaw != 0,
                  (-60.0...100.0).contains(temperature), (0.0...100.0).contains(humidity)
            else {
                return nil
            }
            records.append(Sample(temperatureCelsius: temperature, humidityPercent: humidity))
        }
        return records
    }

    static func isHistoryNotification(_ uuid: String) -> Bool {
        let uuid = uuid.uppercased()
        return uuid == "FFF6" || uuid == "0000FFF6-0000-1000-8000-00805F9B34FB"
    }

    static func isExpectedSessionCloseDisconnect(
        issuedCommandNames: Set<String>,
        status: HistoryBlockStatus?
    ) -> Bool {
        let requiredCommands: Set<String> = [
            "ith11b_history_command_01",
            "ith11b_history_command_04",
            "ith11b_session_command_05"
        ]
        guard requiredCommands.isSubset(of: issuedCommandNames),
              let status,
              status.isComplete
        else {
            return false
        }
        return status.decodedRecordCount == status.expectedRecordCount
    }

    static func missingBlockRequest(sequences: [Int]) -> Data? {
        guard !sequences.isEmpty, sequences.count <= historyBlockSize / 2,
              sequences.allSatisfy({ (1...Int(UInt16.max)).contains($0) })
        else {
            return nil
        }
        var request = Data(capacity: historyBlockSize)
        for sequence in sequences {
            request.append(UInt8(sequence & 0xff))
            request.append(UInt8((sequence >> 8) & 0xff))
        }
        request.append(Data(repeating: 0, count: historyBlockSize - request.count))
        return request
    }

    static func roundedDownToInterval(_ date: Date, intervalSeconds: Int) -> Date? {
        guard intervalSeconds > 0 else {
            return nil
        }
        let interval = Double(intervalSeconds)
        return Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / interval) * interval)
    }

    static func crc16Modbus(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 0x0001 == 0x0001 {
                    crc = (crc >> 1) ^ 0xa001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }
}
