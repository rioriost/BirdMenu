import Foundation

struct HistoryFetchProgress: Sendable {
    enum Phase: Sendable {
        case connecting, discovering, receiving, recovering, reconnecting, saving, finalizing
    }

    let phase: Phase
    let receivedRecords: Int
    let expectedRecords: Int?
    let receivedBlocks: Int
    let expectedBlocks: Int?
    let elapsed: TimeInterval
}

struct ITH11BTransferState {
    enum Command: Equatable {
        case clock(Data)
        case header
        case history
        case missing([Int])
        case retry
        case confirm
        case close

        var name: String {
            switch self {
            case .clock: "ith11b_set_clock"
            case .header: "ith11b_history_command_02"
            case .history: "ith11b_history_command_01"
            case .missing: "ith11b_missing_blocks"
            case .retry: "ith11b_history_command_03"
            case .confirm: "ith11b_history_command_04"
            case .close: "ith11b_session_command_05"
            }
        }

        var characteristicUUID: String {
            switch self {
            case .clock: "FFF7"
            case .missing: "FFF3"
            default: "FFF4"
            }
        }

        var value: Data {
            switch self {
            case let .clock(data): data
            case .header: Data([0x02])
            case .history: Data([0x01])
            case let .missing(sequences):
                // Only bounded, validated sequence batches are constructed by tick().
                InkbirdITH11BHistoryProtocol.missingBlockRequest(sequences: sequences)!
            case .retry: Data([0x03])
            case .confirm: Data([0x04])
            case .close: Data([0x05])
            }
        }
    }

    enum Action: Equatable {
        case write(Command)
        case save
        case finish
        case fail(String)
    }

    enum Phase: Equatable {
        case idle, transferring, saving, finalizing, finished
    }

    private(set) var phase: Phase = .idle
    private(set) var command: Command?
    private(set) var writeAcknowledged = false
    private(set) var header: InkbirdITH11BHistoryProtocol.HistoryHeader?
    private(set) var accumulator: InkbirdITH11BHistoryProtocol.BlockAccumulator?
    private(set) var locallySaved = false
    private(set) var recovery: InkbirdITH11BHistoryProtocol.MissingBlockRecoveryTracker
    private var commandStartedAt: TimeInterval = 0
    let responseTimeout: TimeInterval

    init(responseTimeout: TimeInterval = 30, noProgressTimeout: TimeInterval = 180, retryInterval: TimeInterval = 15) {
        self.responseTimeout = responseTimeout
        recovery = .init(timeout: noProgressTimeout, retryInterval: retryInterval)
    }

    var status: InkbirdITH11BHistoryProtocol.HistoryBlockStatus? { accumulator?.status }

    var acceptsHistoryBlocks: Bool {
        guard phase == .transferring else { return false }
        switch command {
        case .history, .missing, .retry: return true
        default: return false
        }
    }

    mutating func start(clock: Data, at now: TimeInterval) -> [Action] {
        guard phase == .idle else { return [] }
        phase = .transferring
        return issue(.clock(clock), at: now)
    }

    mutating func didWrite(characteristicUUID: String, at now: TimeInterval) -> [Action] {
        guard phase == .transferring || phase == .finalizing,
              let command, command.characteristicUUID == characteristicUUID,
              !writeAcknowledged
        else {
            return []
        }
        writeAcknowledged = true
        return advance(at: now)
    }

    mutating func receive(_ data: Data, characteristicUUID: String, at now: TimeInterval) -> [Action] {
        guard InkbirdITH11BHistoryProtocol.isHistoryNotification(characteristicUUID),
              phase == .transferring
        else {
            return []
        }
        if command == .header {
            if header == nil, let received = InkbirdITH11BHistoryProtocol.historyHeader(from: data) {
                header = received
                accumulator = .init(expectedRecordCount: received.recordCount)
            }
        } else if acceptsHistoryBlocks, let block = InkbirdITH11BHistoryProtocol.historyBlock(from: data),
                  accumulator?.accept(block) == true, let status {
            recovery.observe(status: status, at: now)
        }
        return advance(at: now)
    }

    mutating func tick(at now: TimeInterval) -> [Action] {
        guard phase == .transferring || phase == .finalizing, let command else { return [] }
        if !writeAcknowledged || command == .header {
            let timeout = command == .confirm ? max(60, responseTimeout) : responseTimeout
            if now - commandStartedAt >= timeout {
                return fail("Timed out waiting for \(command.name).")
            }
            return []
        }
        guard command == .history || command == .retry, let status else { return [] }
        switch recovery.nextDecision(status: status, at: now) {
        case .complete:
            return advance(at: now)
        case .wait:
            return []
        case .retry:
            return issue(.missing(Array(status.missingSequences.prefix(91))), at: now)
        case let .timedOut(rounds, missing):
            return fail("No new valid history blocks for \(Int(recovery.timeout)) seconds after \(rounds) retries; missing: \(missing).")
        }
    }

    mutating func didSave(at now: TimeInterval) -> [Action] {
        guard phase == .saving else { return [] }
        locallySaved = true
        phase = .finalizing
        return issue(.confirm, at: now)
    }

    mutating func stop() {
        phase = .finished
        command = nil
    }

    private mutating func advance(at now: TimeInterval) -> [Action] {
        guard writeAcknowledged, let command else { return [] }
        switch command {
        case .clock:
            return issue(.header, at: now)
        case .header:
            guard header != nil else { return [] }
            return issue(.history, at: now)
        case .history, .retry:
            if command == .history, let status {
                recovery.observe(status: status, at: now)
            }
            guard status?.isComplete == true else { return [] }
            phase = .saving
            self.command = nil
            return [.save]
        case .missing:
            // Late blocks are retained, but the FFF3 response is consumed before proceeding.
            return issue(.retry, at: now)
        case .confirm:
            guard locallySaved else { return fail("History was not saved before confirmation.") }
            return issue(.close, at: now)
        case .close:
            stop()
            return [.finish]
        }
    }

    private mutating func issue(_ command: Command, at now: TimeInterval) -> [Action] {
        self.command = command
        writeAcknowledged = false
        commandStartedAt = now
        return [.write(command)]
    }

    private mutating func fail(_ reason: String) -> [Action] {
        stop()
        return [.fail(reason)]
    }
}
