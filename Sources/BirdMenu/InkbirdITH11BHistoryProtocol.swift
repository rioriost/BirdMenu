import Foundation

enum InkbirdITH11BHistoryProtocol {
    struct HistoryHeader: Equatable {
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

    struct HistoryBlock: Equatable {
        let sequence: Int
        let payload: Data
    }

    struct HistoryBlockStatus: Equatable {
        let expectedRecordCount: Int
        let expectedBlockCount: Int
        let receivedSequences: [Int]
        let missingSequences: [Int]
        let decodedRecordCount: Int

        var isComplete: Bool {
            missingSequences.isEmpty && decodedRecordCount >= expectedRecordCount
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
        return HistoryHeader(
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
    }

    static func historyBlock(from data: Data) -> HistoryBlock? {
        guard data.count >= historyRecordSize + 2,
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
        blocks: [HistoryBlock],
        decodedRecordCount: Int
    ) -> HistoryBlockStatus {
        let expectedBlockCount = expectedRecordCount > 0
            ? Int(ceil(Double(expectedRecordCount) / Double(historyRecordsPerBlock)))
            : 0
        let expectedSequences: Set<Int> = expectedBlockCount > 0
            ? Set(1...expectedBlockCount)
            : []
        let receivedSequences = Set(blocks.map(\.sequence)).intersection(expectedSequences)
        return HistoryBlockStatus(
            expectedRecordCount: expectedRecordCount,
            expectedBlockCount: expectedBlockCount,
            receivedSequences: receivedSequences.sorted(),
            missingSequences: expectedSequences.subtracting(receivedSequences).sorted(),
            decodedRecordCount: decodedRecordCount
        )
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
