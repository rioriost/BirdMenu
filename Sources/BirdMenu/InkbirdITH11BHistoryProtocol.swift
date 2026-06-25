import Foundation

enum InkbirdITH11BHistoryProtocol {
    static func timestampCommand(for date: Date = Date(), calendar inputCalendar: Calendar = .current) -> Data {
        let calendar = inputCalendar

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
