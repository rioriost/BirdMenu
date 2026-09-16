import CoreBluetooth
import Foundation
import Testing
@testable import BirdMenu

@Suite struct HistoryTransferStateTests {
    private func header(_ count: Int) -> Data {
        Data([
            UInt8(count & 255), UInt8((count >> 8) & 255),
            UInt8((count >> 16) & 255), UInt8((count >> 24) & 255),
            34, 14, 5, 3, 7, 234, 7
        ])
    }

    private func block(_ sequence: Int, count: Int = 45) -> Data {
        var data = Data()
        for _ in 0..<count { data.append(contentsOf: [0x1c, 1, 0xfa, 2]) }
        data.append(Data(repeating: 0, count: 180 - data.count))
        data.append(contentsOf: [UInt8(sequence & 255), UInt8(sequence >> 8)])
        return data
    }

    private func receiving(_ count: Int) -> ITH11BTransferState {
        var state = ITH11BTransferState()
        #expect(state.start(clock: Data([0]), at: 0) == [.write(.clock(Data([0])))])
        #expect(state.didWrite(characteristicUUID: "FFF7", at: 0) == [.write(.header)])
        #expect(state.didWrite(characteristicUUID: "FFF4", at: 0).isEmpty)
        #expect(state.receive(header(count), characteristicUUID: "FFF6", at: 0) == [.write(.history)])
        #expect(state.didWrite(characteristicUUID: "FFF4", at: 0) == (count == 0 ? [.save] : []))
        return state
    }

    private func packet(_ data: Data, command: String, characteristic: String = "FFF6") -> InkbirdHistoryPacket {
        InkbirdHistoryPacket(command: command, characteristicUUID: characteristic, timestamp: Date(), hex: data.hexString)
    }

    @Test func headerNotificationDoesNotConsumeWriteAcknowledgement() {
        var state = ITH11BTransferState()
        _ = state.start(clock: Data(), at: 0)
        _ = state.didWrite(characteristicUUID: "FFF7", at: 0)
        #expect(state.receive(header(45), characteristicUUID: "FFF6", at: 1).isEmpty)
        #expect(state.command == .header)
        #expect(state.didWrite(characteristicUUID: "FFF3", at: 2).isEmpty)
        #expect(state.didWrite(characteristicUUID: "FFF4", at: 3) == [.write(.history)])
        #expect(state.receive(block(1), characteristicUUID: "FFF6", at: 4).isEmpty)
        #expect(state.didWrite(characteristicUUID: "FFF4", at: 5) == [.save])
    }

    @Test(arguments: [6.0, 12.0, 30.0])
    func notificationGapsDoNotAbortTransfer(gap: TimeInterval) {
        var state = receiving(90)
        #expect(state.receive(block(1), characteristicUUID: "FFF6", at: 1).isEmpty)
        for now in 2...Int(gap) {
            let actions = state.tick(at: Double(now))
            if case .write(.missing) = actions.first {
                #expect(state.didWrite(characteristicUUID: "FFF3", at: Double(now)) == [.write(.retry)])
                #expect(state.didWrite(characteristicUUID: "FFF4", at: Double(now)).isEmpty)
            } else {
                #expect(actions.isEmpty)
            }
        }
        #expect(state.receive(block(2), characteristicUUID: "FFF6", at: gap + 1) == [.save])
    }

    @Test func lateBlocksDuringMissingWriteAreRetainedWithoutAdvancingWrite() {
        var state = receiving(90)
        _ = state.receive(block(1), characteristicUUID: "FFF6", at: 1)
        #expect(state.tick(at: 16) == [.write(.missing([2]))])
        #expect(state.receive(block(2), characteristicUUID: "FFF6", at: 17).isEmpty)
        #expect(state.status?.isComplete == true)
        #expect(state.command == .missing([2]))
        #expect(state.didWrite(characteristicUUID: "FFF4", at: 18).isEmpty)
        #expect(state.didWrite(characteristicUUID: "FFF3", at: 19) == [.write(.retry)])
        #expect(state.didWrite(characteristicUUID: "FFF4", at: 20) == [.save])
    }

    @Test func confirmationRequiresSuccessfulLocalSaveAndItsOwnWriteResponse() {
        var state = receiving(45)
        #expect(state.receive(block(1), characteristicUUID: "FFF6", at: 1) == [.save])
        #expect(state.tick(at: 500).isEmpty)
        #expect(state.didWrite(characteristicUUID: "FFF4", at: 500).isEmpty)
        #expect(!state.locallySaved)
        #expect(state.didSave(at: 501) == [.write(.confirm)])
        #expect(state.didSave(at: 502).isEmpty)
        #expect(state.receive(block(1), characteristicUUID: "FFF6", at: 503).isEmpty)
        #expect(state.command == .confirm)
        #expect(state.didWrite(characteristicUUID: "FFF4", at: 504) == [.write(.close)])
        #expect(state.receive(block(1), characteristicUUID: "FFF6", at: 505).isEmpty)
        #expect(state.didWrite(characteristicUUID: "FFF4", at: 506) == [.finish])
        #expect(state.didWrite(characteristicUUID: "FFF4", at: 507).isEmpty)
        #expect(state.didSave(at: 508).isEmpty)
    }

    @Test func cancelledSaveNeverSendsConfirmation() {
        var state = receiving(45)
        _ = state.receive(block(1), characteristicUUID: "FFF6", at: 1)
        state.stop()
        #expect(state.didSave(at: 2).isEmpty)
        #expect(state.receive(block(1), characteristicUUID: "FFF6", at: 3).isEmpty)
        #expect(state.tick(at: 5_000).isEmpty)
    }

    @Test func emptyHeaderIsSuccessfulWithoutHistoryPackets() {
        var state = receiving(0)
        #expect(state.phase == .saving)
        #expect(state.status?.isComplete == true)
        #expect(state.didSave(at: 1) == [.write(.confirm)])
        #expect(state.didWrite(characteristicUUID: "FFF4", at: 2) == [.write(.close)])
        #expect(state.didWrite(characteristicUUID: "FFF4", at: 3) == [.finish])
    }

    @Test func recoverySurvivesOld120And300SecondLimitsWithProgress() {
        var state = receiving(180)
        #expect(state.tick(at: 15) == [.write(.missing([1, 2, 3, 4]))])
        _ = state.didWrite(characteristicUUID: "FFF3", at: 15)
        _ = state.didWrite(characteristicUUID: "FFF4", at: 15)
        for (sequence, time) in [(1, 100.0), (2, 200.0), (3, 301.0)] {
            #expect(state.receive(block(sequence), characteristicUUID: "FFF6", at: time).isEmpty)
            #expect(state.tick(at: time).isEmpty)
        }
        #expect(state.receive(block(4), characteristicUUID: "FFF6", at: 401) == [.save])
    }

    @Test func duplicateAndUnrelatedNotificationsDoNotExtendNoProgressDeadline() {
        var state = receiving(90)
        _ = state.receive(block(1), characteristicUUID: "FFF6", at: 1)
        for time in [100.0, 150.0, 180.0] {
            #expect(state.receive(block(1), characteristicUUID: "FFF6", at: time).isEmpty)
            #expect(state.receive(block(2), characteristicUUID: "FFF5", at: time).isEmpty)
        }
        let actions = state.tick(at: 181)
        guard case let .fail(reason) = actions.first else {
            Issue.record("Expected an explicit no-progress failure")
            return
        }
        #expect(reason.contains("180 seconds"))
        #expect(reason.contains("[2]"))
    }

    @Test func missingRequestsAreBatchedAtNinetyOneSequences() {
        var state = receiving(92 * 45)
        #expect(state.tick(at: 15) == [.write(.missing(Array(1...91)))])
        _ = state.didWrite(characteristicUUID: "FFF3", at: 16)
        _ = state.didWrite(characteristicUUID: "FFF4", at: 16)
        for sequence in 1...91 {
            _ = state.receive(block(sequence), characteristicUUID: "FFF6", at: 20)
        }
        #expect(state.tick(at: 45) == [.write(.missing([92]))])
    }

    @Test func incompleteBlocksRemainMissingAndOutOfRangeCannotFillTheirDeficit() throws {
        var accumulator = InkbirdITH11BHistoryProtocol.BlockAccumulator(expectedRecordCount: 90)
        #expect(accumulator.accept(try #require(InkbirdITH11BHistoryProtocol.historyBlock(from: block(1, count: 44)))) == false)
        #expect(accumulator.accept(try #require(InkbirdITH11BHistoryProtocol.historyBlock(from: block(2)))) == true)
        #expect(accumulator.accept(try #require(InkbirdITH11BHistoryProtocol.historyBlock(from: block(3, count: 1)))) == false)
        #expect(accumulator.status.missingSequences == [1])
        #expect(accumulator.status.decodedRecordCount == 45)
        #expect(!accumulator.status.isComplete)
        #expect(accumulator.accept(try #require(InkbirdITH11BHistoryProtocol.historyBlock(from: block(1)))) == true)
        #expect(accumulator.accept(try #require(InkbirdITH11BHistoryProtocol.historyBlock(from: block(1, count: 44)))) == false)
        #expect(accumulator.status.isComplete)
        #expect(accumulator.records.count == 90)
    }

    @Test func exportRecognizesLateBlocksAndRejectsUnrelatedCharacteristics() {
        let metadata = packet(header(90), command: "ith11b_history_command_02")
        let first = packet(block(1), command: "ith11b_history_command_01")
        let late = packet(block(2), command: "ith11b_missing_blocks_round_1")
        #expect(InkbirdHistoryExportWriter.ith11BHistoryBlockStatus(from: [metadata, first, late])?.isComplete == true)
        let unrelated = packet(block(2), command: "ith11b_history_command_01", characteristic: "FFF5")
        #expect(InkbirdHistoryExportWriter.ith11BHistoryBlockStatus(from: [metadata, first, unrelated])?.missingSequences == [2])
    }

    @Test func savedRawCanBeRedecodedBeforeDeviceConfirmation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BirdMenuTransferTests-\(UUID())")
        defer {
            do { try FileManager.default.removeItem(at: folder) }
            catch { Issue.record("Could not clean test folder: \(error)") }
        }
        let packets = [packet(header(45), command: "ith11b_history_command_02"), packet(block(1), command: "ith11b_history_data")]
        let result = try InkbirdHistoryExportWriter.write(
            deviceName: "Test", peripheralID: UUID(), latestReading: nil,
            config: Data([0, 0, 0, 0, 0, 44, 1, 0, 0]), characteristics: [],
            packets: packets, warnings: [], mode: "ith11b-official-trace",
            folderURL: folder, transferState: "saved_before_device_confirmation"
        )
        #expect(result.isComplete)
        #expect(result.recordCount == 45)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dump = try decoder.decode(InkbirdHistoryRawDump.self, from: Data(contentsOf: result.rawURL))
        #expect(dump.transferState == "saved_before_device_confirmation")
        #expect(InkbirdHistoryExportWriter.decodeITH11BRecords(
            packets: dump.packets, intervalSeconds: dump.intervalSeconds, latestReading: nil
        ).count == 45)
        #expect(try InkbirdHistoryChartRenderer.records(fromCSVAt: #require(result.csvURL)).count == 45)
    }

    @Test func savingFailureLeavesStateBeforeConfirmation() throws {
        var state = receiving(45)
        _ = state.receive(block(1), characteristicUUID: "FFF6", at: 1)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("BirdMenuBlockedExport-\(UUID())")
        try Data([1]).write(to: file)
        defer {
            do { try FileManager.default.removeItem(at: file) }
            catch { Issue.record("Could not clean test file: \(error)") }
        }
        #expect(throws: (any Error).self) {
            try InkbirdHistoryExportWriter.write(
                deviceName: "Test", peripheralID: UUID(), latestReading: nil, config: nil,
                characteristics: [], packets: [], warnings: [], folderURL: file
            )
        }
        state.stop()
        #expect(state.didSave(at: 2).isEmpty)
        #expect(!state.locallySaved)
    }

    @Test func reconnectionIsBoundedAndDoesNotRetryPermanentErrors() {
        let transient = NSError(domain: CBErrorDomain, code: CBError.connectionTimeout.rawValue)
        #expect(HistoryReconnectPolicy.shouldRestart(error: transient, previousRestarts: 0))
        #expect(HistoryReconnectPolicy.shouldRestart(error: HistoryFetchError.disconnected, previousRestarts: 1))
        #expect(!HistoryReconnectPolicy.shouldRestart(error: transient, previousRestarts: 2))
        #expect(!HistoryReconnectPolicy.shouldRestart(error: HistoryFetchError.cancelled, previousRestarts: 0))
        #expect(!HistoryReconnectPolicy.shouldRestart(error: HistoryFetchError.bluetoothUnavailable, previousRestarts: 0))
        #expect(!HistoryReconnectPolicy.shouldRestart(error: NSError(domain: CBATTErrorDomain, code: 5), previousRestarts: 0))
        let restarted = receiving(90)
        #expect(restarted.status?.receivedSequences.isEmpty == true)
    }

    @Test func delayedTransportCompletes620RecordsExactlyOnce() {
        var state = ITH11BTransferState()
        var acknowledgements: [(time: Int, characteristic: String)] = []
        var headerTimes: [Int] = []
        var saveTime: Int?
        var saved = false
        var finishes = 0
        var retryWrites = 0
        var now = 0

        func apply(_ actions: [ITH11BTransferState.Action]) {
            for action in actions {
                switch action {
                case let .write(command):
                    if command == .confirm { #expect(saved) }
                    if case .missing = command { retryWrites += 1 }
                    acknowledgements.append((now + 2, command.characteristicUUID))
                    if command == .header { headerTimes.append(now + 1) }
                case .save:
                    #expect(state.status?.decodedRecordCount == 620)
                    saveTime = now + 3
                case .finish:
                    finishes += 1
                case let .fail(reason):
                    Issue.record("Unexpected transfer failure at \(now): \(reason)")
                }
            }
        }

        apply(state.start(clock: Data(), at: 0))
        for second in 1...600 {
            now = second
            for acknowledgement in acknowledgements.filter({ $0.time == second }) {
                apply(state.didWrite(characteristicUUID: acknowledgement.characteristic, at: Double(second)))
            }
            if headerTimes.contains(second) {
                apply(state.receive(header(620), characteristicUUID: "FFF6", at: Double(second)))
            }
            for sequence in 1...14 {
                let arrival = sequence == 2 ? 26 : (sequence - 1) * 40 + 10
                if second == arrival {
                    apply(state.receive(block(sequence, count: sequence == 14 ? 35 : 45),
                                        characteristicUUID: "FFF6", at: Double(second)))
                }
            }
            if second.isMultiple(of: 3), second > 10 {
                apply(state.receive(block(1), characteristicUUID: "FFF6", at: Double(second)))
            }
            if second.isMultiple(of: 11) {
                apply(state.receive(block(14, count: 35), characteristicUUID: "FFF5", at: Double(second)))
            }
            if saveTime == second {
                saved = true
                apply(state.didSave(at: Double(second)))
            }
            apply(state.tick(at: Double(second)))
        }
        #expect(retryWrites > 3)
        #expect(state.status?.decodedRecordCount == 620)
        #expect(state.status?.receivedSequences == Array(1...14))
        #expect(state.phase == .finished)
        #expect(finishes == 1)
    }

    @Test func missingHeaderAndWriteResponsesHaveExplicitDeadlines() {
        var state = ITH11BTransferState()
        _ = state.start(clock: Data(), at: 0)
        #expect(state.tick(at: 29).isEmpty)
        #expect(state.tick(at: 30) == [.fail("Timed out waiting for ith11b_set_clock.")])
        #expect(state.didWrite(characteristicUUID: "FFF7", at: 31).isEmpty)
        var waitingForHeader = ITH11BTransferState()
        _ = waitingForHeader.start(clock: Data(), at: 0)
        _ = waitingForHeader.didWrite(characteristicUUID: "FFF7", at: 1)
        _ = waitingForHeader.didWrite(characteristicUUID: "FFF4", at: 2)
        #expect(waitingForHeader.receive(Data([0]), characteristicUUID: "FFF6", at: 3).isEmpty)
        #expect(waitingForHeader.tick(at: 31) == [.fail("Timed out waiting for ith11b_history_command_02.")])
    }

    @Test func slowInitialWriteDoesNotConsumeTheFirstNotificationGracePeriod() {
        var state = ITH11BTransferState()
        _ = state.start(clock: Data(), at: 0)
        _ = state.didWrite(characteristicUUID: "FFF7", at: 0)
        _ = state.didWrite(characteristicUUID: "FFF4", at: 0)
        _ = state.receive(header(45), characteristicUUID: "FFF6", at: 0)
        _ = state.didWrite(characteristicUUID: "FFF4", at: 29)
        #expect(state.tick(at: 30).isEmpty)
        #expect(state.tick(at: 43).isEmpty)
        #expect(state.tick(at: 44) == [.write(.missing([1]))])
    }
}
