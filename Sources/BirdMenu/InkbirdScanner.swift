@preconcurrency import CoreBluetooth
import Foundation

enum BLEScannerStatus: Equatable {
    case starting
    case scanning
    case bluetoothUnavailable(BluetoothUnavailableReason)
}

enum BluetoothUnavailableReason: Equatable {
    case poweredOff
    case unauthorized
    case unsupported
    case unknown
}

final class InkbirdScanner: NSObject, CBCentralManagerDelegate {
    var onStatusChange: ((BLEScannerStatus) -> Void)?
    var onReading: ((InkbirdReading) -> Void)?
    var onHistoryProgress: ((HistoryFetchProgress) -> Void)?

    private var centralManager: CBCentralManager!
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var historyOperation: HistoryFetchOperation?
    private var stateCheckTimer: Timer?
    private var disconnectingPeripheralIDs: Set<UUID> = []

    override init() {
        super.init()
        BirdMenuLog.info("app.start debugLogging=\(BirdMenuLog.isDebugLoggingEnabled)")
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        scheduleStateCheck()
    }

    func restart() {
        guard historyOperation == nil else { return }
        guard centralManager.state == .poweredOn else {
            centralManagerDidUpdateState(centralManager)
            return
        }
        BirdMenuLog.debugData("scanner.restart")
        centralManager.stopScan()
        startScan()
    }

    func cancelHistory() {
        historyOperation?.fail(HistoryFetchError.cancelled)
    }

    func fetchHistory(
        for reading: InkbirdReading,
        completion: @escaping (Result<InkbirdHistoryResult, Error>) -> Void
    ) {
        guard centralManager.state == .poweredOn else {
            BirdMenuLog.debugData("history.fetch rejected bluetoothUnavailable")
            completion(.failure(HistoryFetchError.bluetoothUnavailable))
            return
        }
        guard historyOperation == nil else {
            BirdMenuLog.debugData("history.fetch rejected busy")
            completion(.failure(HistoryFetchError.busy))
            return
        }
        guard let peripheral = peripheralsByID[reading.peripheralID] else {
            BirdMenuLog.debugData("history.fetch rejected peripheralNotFound id=\(reading.peripheralID.uuidString)")
            completion(.failure(HistoryFetchError.peripheralNotFound))
            return
        }
        guard !disconnectingPeripheralIDs.contains(peripheral.identifier) else {
            completion(.failure(HistoryFetchError.busy))
            return
        }

        BirdMenuLog.debugData("history.fetch start device=\(reading.deviceName) id=\(reading.peripheralID.uuidString)")
        centralManager.stopScan()
        let operation = HistoryFetchOperation(
            centralManager: centralManager,
            peripheral: peripheral,
            peripheralDelegate: self,
            latestReading: reading,
            progress: { [weak self] progress in self?.onHistoryProgress?(progress) },
            completion: { [weak self] result in
                self?.historyOperation = nil
                if peripheral.state != .disconnected {
                    self?.disconnectingPeripheralIDs.insert(peripheral.identifier)
                    self?.centralManager.cancelPeripheralConnection(peripheral)
                }
                self?.startScan()
                switch result {
                case let .success(history):
                    BirdMenuLog.debugData("history.fetch complete packets=\(history.packetCount) records=\(history.recordCount) raw=\(history.rawURL.path) csv=\(history.csvURL?.path ?? "-") warnings=\(history.warnings.joined(separator: " | "))")
                case let .failure(error):
                    BirdMenuLog.debugData("history.fetch failed error=\(error.localizedDescription)")
                }
                completion(result)
            }
        )
        historyOperation = operation
        operation.start()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            BirdMenuLog.debugData("scanner.state poweredOn")
            startScan()
        case .poweredOff:
            historyOperation?.fail(HistoryFetchError.bluetoothUnavailable)
            BirdMenuLog.debugData("scanner.state poweredOff")
            onStatusChange?(.bluetoothUnavailable(.poweredOff))
        case .unauthorized:
            historyOperation?.fail(HistoryFetchError.bluetoothUnavailable)
            BirdMenuLog.debugData("scanner.state unauthorized")
            onStatusChange?(.bluetoothUnavailable(.unauthorized))
        case .unsupported:
            historyOperation?.fail(HistoryFetchError.bluetoothUnavailable)
            BirdMenuLog.debugData("scanner.state unsupported")
            onStatusChange?(.bluetoothUnavailable(.unsupported))
        case .resetting:
            historyOperation?.fail(HistoryFetchError.bluetoothUnavailable)
            BirdMenuLog.debugData("scanner.state resetting")
            onStatusChange?(.starting)
        case .unknown:
            BirdMenuLog.debugData("scanner.state unknown")
            onStatusChange?(.starting)
        @unknown default:
            BirdMenuLog.debugData("scanner.state unknownDefault")
            onStatusChange?(.bluetoothUnavailable(.unknown))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
            BirdMenuLog.debugData("advertisement.ignored reason=noManufacturerData name=\((advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "-") id=\(peripheral.identifier.uuidString) rssi=\(RSSI.intValue) keys=\(advertisementData.keys.sorted())")
            return
        }

        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard let reading = InkbirdAdvertisementParser.parse(
            advertisedName: advertisedName,
            serviceUUIDs: serviceUUIDs,
            manufacturerData: manufacturerData,
            rssi: RSSI.intValue,
            peripheralID: peripheral.identifier
        ) else {
            BirdMenuLog.debugData(
                "advertisement.ignored reason=parseRejected name=\(advertisedName ?? "-") id=\(peripheral.identifier.uuidString) rssi=\(RSSI.intValue) services=\(serviceUUIDs.map { $0.uuidString }.joined(separator: ",")) mfrLen=\(manufacturerData.count) mfr=\(manufacturerData.hexString)"
            )
            return
        }
        peripheralsByID[peripheral.identifier] = peripheral
        BirdMenuLog.debugData(
            "reading device=\(reading.deviceName) id=\(reading.peripheralID.uuidString) tempC=\(String(format: "%.2f", reading.temperatureCelsius)) humidity=\(reading.humidityPercent.map { String(format: "%.2f", $0) } ?? "-") battery=\(reading.batteryPercent) rssi=\(reading.rssi) adv=\(reading.advertisementHex)"
        )
        onReading?(reading)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        BirdMenuLog.debugData("central.didConnect id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "-")")
        historyOperation?.didConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        BirdMenuLog.debugData("central.didFailToConnect id=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "-")")
        disconnectingPeripheralIDs.remove(peripheral.identifier)
        historyOperation?.didFailToConnect(peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        BirdMenuLog.debugData("central.didDisconnect id=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "-")")
        disconnectingPeripheralIDs.remove(peripheral.identifier)
        historyOperation?.didDisconnect(peripheral, error: error)
    }

    private func startScan() {
        guard centralManager.state == .poweredOn, historyOperation == nil else { return }
        BirdMenuLog.debugData("scanner.startScan service=\(InkbirdAdvertisementParser.serviceUUIDString)")
        stateCheckTimer?.invalidate()
        stateCheckTimer = nil
        onStatusChange?(.scanning)
        centralManager.scanForPeripherals(
            withServices: [InkbirdAdvertisementParser.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func scheduleStateCheck() {
        stateCheckTimer?.invalidate()
        stateCheckTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(stateCheckTimerFired),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func stateCheckTimerFired() {
        checkCentralManagerState()
    }

    private func checkCentralManagerState() {
        guard let centralManager else {
            return
        }
        BirdMenuLog.debugData("scanner.stateCheck state=\(centralManager.state.rawValue)")
        switch centralManager.state {
        case .poweredOn:
            startScan()
        case .unknown, .resetting:
            scheduleStateCheck()
        default:
            centralManagerDidUpdateState(centralManager)
        }
    }
}

extension InkbirdScanner: CBPeripheralDelegate {
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        historyOperation?.peripheralIsReady(toSendWriteWithoutResponse: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        BirdMenuLog.debugData("peripheral.didDiscoverServices id=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "-")")
        historyOperation?.peripheral(peripheral, didDiscoverServices: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        BirdMenuLog.debugData("peripheral.didDiscoverCharacteristics service=\(service.uuid.uuidString) error=\(error?.localizedDescription ?? "-")")
        historyOperation?.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        BirdMenuLog.debugData("peripheral.didUpdateNotificationState char=\(characteristic.uuid.uuidString) notifying=\(characteristic.isNotifying) error=\(error?.localizedDescription ?? "-")")
        historyOperation?.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        BirdMenuLog.debugData("peripheral.didUpdateValue char=\(characteristic.uuid.uuidString) bytes=\(characteristic.value?.count ?? 0) hex=\(characteristic.value?.hexString ?? "-") error=\(error?.localizedDescription ?? "-")")
        historyOperation?.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        BirdMenuLog.debugData("peripheral.didWriteValue char=\(characteristic.uuid.uuidString) error=\(error?.localizedDescription ?? "-")")
        historyOperation?.peripheral(peripheral, didWriteValueFor: characteristic, error: error)
    }
}

enum HistoryFetchError: LocalizedError {
    case bluetoothUnavailable
    case busy
    case peripheralNotFound
    case connectionFailed
    case serviceNotFound
    case historyCharacteristicNotFound
    case disconnected
    case cancelled
    case historyFlowIncomplete(String)
    case historyDecodeFailed
    case timedOut(String)
    case partialDumpSaved(reason: String, rawPath: String, csvPath: String?)
    case failureDumpFailed(reason: String, rawPath: String?)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            "Bluetooth is not available."
        case .busy:
            "Another history fetch is already running."
        case .peripheralNotFound:
            "The selected sensor is not available. Wait for a fresh advertisement and try again."
        case .connectionFailed:
            "Could not connect to the selected sensor."
        case .serviceNotFound:
            "The expected Bluetooth service was not found."
        case .historyCharacteristicNotFound:
            "A supported history command characteristic was not found."
        case .disconnected:
            "The device disconnected during history fetch."
        case .cancelled:
            AppText.localized(en: "History fetch was cancelled.", ja: "履歴の取得をキャンセルしました。")
        case let .historyFlowIncomplete(detail):
            "History fetch did not complete the expected command flow: \(detail)."
        case .historyDecodeFailed:
            "History data was received, but it could not be decoded as a complete response."
        case let .timedOut(command):
            "Timed out while fetching \(command)."
        case let .partialDumpSaved(reason, rawPath, csvPath):
            if let csvPath {
                AppText.localized(
                    en: "\(reason)\n\nPartial history data was saved before the failure.\nCSV: \(csvPath)\nRaw: \(rawPath)",
                    ja: "\(reason)\n\n失敗前に取得できた履歴データを保存しました。\nCSV: \(csvPath)\nRaw: \(rawPath)"
                )
            } else {
                AppText.localized(
                    en: "\(reason)\n\nPartial raw data was saved before the failure.\nRaw: \(rawPath)",
                    ja: "\(reason)\n\n失敗前に取得できた生データを保存しました。\nRaw: \(rawPath)"
                )
            }
        case let .failureDumpFailed(reason, rawPath):
            AppText.localized(
                en: "\(reason)\n\nThe latest partial history could not be saved."
                    + (rawPath.map { "\nEarlier raw snapshot: \($0)" } ?? ""),
                ja: "\(reason)\n\n最新の部分履歴を保存できませんでした。"
                    + (rawPath.map { "\n以前の生データ: \($0)" } ?? "")
            )
        }
    }
}

private final class HistoryFetchOperation: @unchecked Sendable {
    private struct Command {
        let name: String
        let value: Data
        let quietTimeout: TimeInterval
        let maxTimeout: TimeInterval
        let readAfterWrite: Bool
        var finishesOnWrite = false
    }

    private struct CommandAttempt {
        let command: Command
        let characteristic: CBCharacteristic
    }

    private enum TransferMode {
        case legacyFFF8(CBCharacteristic)
        case ith11BTrace(command: CBCharacteristic, clock: CBCharacteristic, missingBlocks: CBCharacteristic)
        case readOnlySnapshot
    }

    private static let inkbirdServiceUUID = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    private static let configCharacteristicUUID = CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB")
    private static let ith11BConfigCharacteristicUUID = CBUUID(string: "0000FFF5-0000-1000-8000-00805F9B34FB")
    private static let ith11BMissingBlocksCharacteristicUUID = CBUUID(string: "0000FFF3-0000-1000-8000-00805F9B34FB")
    private static let ith11BCommandCharacteristicUUID = CBUUID(string: "0000FFF4-0000-1000-8000-00805F9B34FB")
    private static let notifyCharacteristicUUID = CBUUID(string: "0000FFF6-0000-1000-8000-00805F9B34FB")
    private static let ith11BClockCharacteristicUUID = CBUUID(string: "0000FFF7-0000-1000-8000-00805F9B34FB")
    private static let historyCharacteristicUUID = CBUUID(string: "0000FFF8-0000-1000-8000-00805F9B34FB")
    private static let operationTimeout: TimeInterval = 2_400

    private let centralManager: CBCentralManager
    private let peripheral: CBPeripheral
    private weak var peripheralDelegate: CBPeripheralDelegate?
    private let latestReading: InkbirdReading
    private let completion: (Result<InkbirdHistoryResult, Error>) -> Void
    private let progress: (HistoryFetchProgress) -> Void
    private let exportQueue = DispatchQueue(label: "st.rio.birdmenu.history-export")
    private let historyCommands: [Command] = [
        Command(name: "temp_header", value: Data([0x02]), quietTimeout: 0.8, maxTimeout: 5, readAfterWrite: true),
        Command(name: "temp_content", value: Data([0x01]), quietTimeout: 10, maxTimeout: 600, readAfterWrite: true),
        Command(name: "temp_content_crc", value: Data([0x07]), quietTimeout: 0.8, maxTimeout: 5, readAfterWrite: true),
        Command(name: "hum_header", value: Data([0x04]), quietTimeout: 0.8, maxTimeout: 5, readAfterWrite: true),
        Command(name: "hum_content", value: Data([0x03]), quietTimeout: 10, maxTimeout: 600, readAfterWrite: true),
        Command(name: "hum_content_crc", value: Data([0x08]), quietTimeout: 0.8, maxTimeout: 5, readAfterWrite: true)
    ]

    private var service: CBService?
    private var configCharacteristic: CBCharacteristic?
    private var allDiscoveredCharacteristics: [CBCharacteristic] = []
    private var transferMode: TransferMode = .readOnlySnapshot
    private var commandAttempts: [CommandAttempt] = []
    private var notifyCharacteristics: [CBCharacteristic] = []
    private var configData: Data?
    private var clockSetAt: Date?
    private var commandAttemptIndex = 0
    private var currentAttempt: CommandAttempt?
    private var currentAttemptReceivedPacket = false
    private var packets: [InkbirdHistoryPacket] = []
    private var characteristics: [InkbirdGATTCharacteristicInfo] = []
    private var warnings: [String] = []
    private var quietTimer: Timer?
    private var maxTimer: Timer?
    private var operationTimer: Timer?
    private var completed = false
    private var pendingCharacteristicServiceUUIDs: Set<String> = []
    private var pendingInitialReadKeys: Set<String> = []
    private var pendingNotificationKeys: Set<String> = []
    private var hasStartedCommands = false
    private var modeName = "read-only-gatt-snapshot"
    private var shouldDecodeHistory = false
    private var ith11BState: ITH11BTransferState?
    private var pendingUnacknowledgedWrite: CBCharacteristic?
    private var queuedWithoutResponse: (Data, CBCharacteristic)?
    private var outputFolder: URL?
    private var savedResult: InkbirdHistoryResult?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var setupDeadline: TimeInterval = 0
    private var lastCheckpointAt: TimeInterval = 0
    private var reconnectCount = 0
    private var reconnecting = false
    private var reconnectReadyAt: TimeInterval?
    private var reconnectDumpSaved = false
    private var reconnectDeadline: TimeInterval = 0
    private var disconnectedWhileSaving = false

    init(
        centralManager: CBCentralManager,
        peripheral: CBPeripheral,
        peripheralDelegate: CBPeripheralDelegate,
        latestReading: InkbirdReading,
        progress: @escaping (HistoryFetchProgress) -> Void,
        completion: @escaping (Result<InkbirdHistoryResult, Error>) -> Void
    ) {
        self.centralManager = centralManager
        self.peripheral = peripheral
        self.peripheralDelegate = peripheralDelegate
        self.latestReading = latestReading
        self.completion = completion
        self.progress = progress
    }

    func start() {
        startedAt = ProcessInfo.processInfo.systemUptime
        setupDeadline = startedAt + 30
        do {
            outputFolder = try InkbirdHistoryExportWriter.outputFolder(
                deviceName: latestReading.deviceName, peripheralID: latestReading.peripheralID
            )
        } catch {
            fail(error)
            return
        }
        BirdMenuLog.debugData("history.operation connect id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "-")")
        peripheral.delegate = nil
        centralManager.connect(peripheral)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        operationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        reportProgress(.connecting)
    }

    func didConnect(_ peripheral: CBPeripheral) {
        guard accepts(peripheral) else {
            return
        }
        peripheral.delegate = peripheralDelegate
        setupDeadline = ProcessInfo.processInfo.systemUptime + 30
        reportProgress(.discovering)
        BirdMenuLog.debugData("history.operation discoverServices id=\(peripheral.identifier.uuidString) scope=all")
        peripheral.discoverServices(nil)
    }

    func didDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral, !completed else {
            return
        }
        if reconnecting {
            scheduleReconnectIfReady()
            return
        }
        if ith11BState?.phase == .saving {
            disconnectedWhileSaving = true
            return
        }
        if savedResult != nil {
            finishSaved(warning: ith11BState?.command == .close && error == nil ? nil
                : "History is saved locally, but the device's session completion could not be confirmed.")
            return
        }
        handleCommunicationError(error ?? HistoryFetchError.disconnected)
    }

    func didFailToConnect(_ peripheral: CBPeripheral, error: Error?) {
        guard accepts(peripheral) else { return }
        handleCommunicationError(error ?? HistoryFetchError.connectionFailed)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard accepts(peripheral) else { return }
        setupDeadline = ProcessInfo.processInfo.systemUptime + 30
        if let error {
            handleCommunicationError(error)
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            fail(HistoryFetchError.serviceNotFound)
            return
        }
        self.service = services.first(where: { $0.uuid == Self.inkbirdServiceUUID })
        pendingCharacteristicServiceUUIDs = Set(services.map { $0.uuid.uuidString })
        BirdMenuLog.debugData("history.operation services=\(services.map { $0.uuid.uuidString }.joined(separator: ","))")
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard accepts(peripheral) else { return }
        setupDeadline = ProcessInfo.processInfo.systemUptime + 30
        if let error {
            pendingCharacteristicServiceUUIDs.remove(service.uuid.uuidString)
            handleCommunicationError(error)
            return
        }

        let discovered = service.characteristics ?? []
        allDiscoveredCharacteristics.append(contentsOf: discovered)
        characteristics.append(contentsOf: discovered.map { characteristic in
            InkbirdGATTCharacteristicInfo(
                serviceUUID: service.uuid.uuidString,
                characteristicUUID: characteristic.uuid.uuidString,
                properties: characteristic.properties.names,
                valueHex: nil
            )
        })
        BirdMenuLog.debugData("history.operation serviceCharacteristics service=\(service.uuid.uuidString) chars=\(discovered.map { "\($0.uuid.uuidString)[\($0.properties.names.joined(separator: ","))]" }.joined(separator: " "))")

        pendingCharacteristicServiceUUIDs.remove(service.uuid.uuidString)
        if pendingCharacteristicServiceUUIDs.isEmpty {
            configureHistoryTransferIfReady(peripheral: peripheral)
        }
    }

    private func configureHistoryTransferIfReady(peripheral: CBPeripheral) {
        BirdMenuLog.debugData("history.operation characteristics=\(characteristics.map { "\($0.characteristicUUID)[\($0.properties.joined(separator: ","))]" }.joined(separator: " "))")
        let sensorCharacteristics = allDiscoveredCharacteristics.filter { $0.service?.uuid == Self.inkbirdServiceUUID }
        configCharacteristic = sensorCharacteristics.first {
            $0.uuid == Self.configCharacteristicUUID || $0.uuid == Self.ith11BConfigCharacteristicUUID
        }
        if let historyCharacteristic = sensorCharacteristics.first(where: { $0.uuid == Self.historyCharacteristicUUID }) {
            transferMode = .legacyFFF8(historyCharacteristic)
            modeName = "fff8-history"
            shouldDecodeHistory = true
        } else if let ith11BCommandCharacteristic = sensorCharacteristics.first(where: { $0.uuid == Self.ith11BCommandCharacteristicUUID }),
                  let ith11BClockCharacteristic = sensorCharacteristics.first(where: { $0.uuid == Self.ith11BClockCharacteristicUUID }),
                  let ith11BMissingBlocksCharacteristic = sensorCharacteristics.first(where: { $0.uuid == Self.ith11BMissingBlocksCharacteristicUUID }) {
            transferMode = .ith11BTrace(
                command: ith11BCommandCharacteristic,
                clock: ith11BClockCharacteristic,
                missingBlocks: ith11BMissingBlocksCharacteristic
            )
            modeName = "ith11b-official-trace"
            shouldDecodeHistory = true
            warnings.append(
                "Using the offline-history command sequence observed from a compatible sensor app trace."
            )
        } else {
            transferMode = .readOnlySnapshot
            modeName = "read-only-gatt-snapshot"
            shouldDecodeHistory = false
            BirdMenuLog.debugData("history.operation noHistoryCommandMode mode=readOnlyGattSnapshot")
        }
        notifyCharacteristics = allDiscoveredCharacteristics.filter {
            $0.properties.contains(.notify) || $0.properties.contains(.indicate)
        }

        let readableCharacteristics: [CBCharacteristic]
        if case .ith11BTrace = transferMode {
            notifyCharacteristics = sensorCharacteristics.filter {
                $0.uuid == Self.notifyCharacteristicUUID && ($0.properties.contains(.notify) || $0.properties.contains(.indicate))
            }
            readableCharacteristics = [configCharacteristic].compactMap { $0 }.filter { $0.properties.contains(.read) }
        } else {
            readableCharacteristics = allDiscoveredCharacteristics.filter { $0.properties.contains(.read) }
        }
        pendingInitialReadKeys = Set(readableCharacteristics.map(characteristicKey))
        pendingNotificationKeys = Set(notifyCharacteristics.map(characteristicKey))
        for characteristic in readableCharacteristics {
            BirdMenuLog.debugData("history.operation readInitial char=\(characteristic.uuid.uuidString)")
            peripheral.readValue(for: characteristic)
        }

        for characteristic in notifyCharacteristics {
            BirdMenuLog.debugData("history.operation enableNotify char=\(characteristic.uuid.uuidString)")
            peripheral.setNotifyValue(true, for: characteristic)
        }
        if notifyCharacteristics.isEmpty {
            fail(HistoryFetchError.historyFlowIncomplete("no notifying characteristic was found"))
            return
        }
        startCommandsIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard accepts(peripheral) else { return }
        setupDeadline = ProcessInfo.processInfo.systemUptime + 30
        if let error {
            handleCommunicationError(error)
            return
        }
        guard characteristic.isNotifying else {
            fail(HistoryFetchError.historyFlowIncomplete("required notifications were disabled"))
            return
        }
        pendingNotificationKeys.remove(characteristicKey(characteristic))
        startCommandsIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard accepts(peripheral) else { return }
        let readKey = characteristicKey(characteristic)
        let wasPendingInitialRead = pendingInitialReadKeys.remove(readKey) != nil
        if wasPendingInitialRead {
            setupDeadline = ProcessInfo.processInfo.systemUptime + 30
        }
        if let error {
            handleCommunicationError(error)
            return
        }
        guard let value = characteristic.value else {
            if wasPendingInitialRead {
                startCommandsIfReady()
            }
            return
        }

        if characteristic.uuid == Self.configCharacteristicUUID || characteristic.uuid == Self.ith11BConfigCharacteristicUUID {
            configData = value
            BirdMenuLog.debugData("history.config hex=\(value.hexString) interval=\(InkbirdHistoryExportWriter.intervalSeconds(from: value).map(String.init) ?? "-")")
            updateCharacteristicValue(characteristic, value: value)
            if wasPendingInitialRead {
                startCommandsIfReady()
                return
            }
        }
        updateCharacteristicValue(characteristic, value: value)

        let commandName: String
        if let state = ith11BState {
            commandName = state.acceptsHistoryBlocks ? "ith11b_history_data"
                : state.command?.name ?? "initial_or_unsolicited"
        } else {
            commandName = currentAttempt?.command.name ?? "initial_or_unsolicited"
        }
        packets.append(
            InkbirdHistoryPacket(
                command: commandName,
                characteristicUUID: characteristic.uuid.uuidString,
                timestamp: Date(),
                hex: value.hexString
            )
        )
        BirdMenuLog.debugData("history.packet command=\(commandName) char=\(characteristic.uuid.uuidString) bytes=\(value.count) hex=\(value.hexString)")
        if ith11BState != nil {
            let now = ProcessInfo.processInfo.systemUptime
            let actions = ith11BState?.receive(value, characteristicUUID: characteristic.uuid.uuidString, at: now) ?? []
            run(actions)
            if !completed, ith11BState?.phase == .transferring, now - lastCheckpointAt >= 15 {
                lastCheckpointAt = now
                saveSnapshot(decodeHistory: false, state: "receiving") { [weak self] result in
                    if case let .failure(error) = result { self?.fail(error) }
                }
            }
        } else if wasPendingInitialRead {
            startCommandsIfReady()
        } else {
            currentAttemptReceivedPacket = true
            scheduleQuietTimer()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard accepts(peripheral),
              let pending = pendingUnacknowledgedWrite,
              pending === characteristic
        else { return }
        pendingUnacknowledgedWrite = nil
        if let error {
            handleCommunicationError(error)
            return
        }

        if ith11BState != nil {
            acknowledgeITH11BWrite(characteristic)
        } else if currentAttempt?.command.readAfterWrite == true, characteristic.properties.contains(.read), !completed {
            peripheral.readValue(for: characteristic)
        } else {
            scheduleQuietTimer()
        }
    }

    func fail(_ error: Error) {
        guard !completed else { return }
        if savedResult != nil {
            finishSaved(warning: "History is saved locally; device session completion is unconfirmed: \(error.localizedDescription)")
            return
        }
        completed = true
        invalidateTimers()
        operationTimer?.invalidate()
        operationTimer = nil
        ith11BState?.stop()
        warnings.append("Fetch stopped: \(error.localizedDescription)")
        BirdMenuLog.error("history.operation failed elapsed=\(Int(ProcessInfo.processInfo.systemUptime - startedAt)) error=\(error)")
        guard outputFolder != nil, !packets.isEmpty || !characteristics.isEmpty else {
            completion(.failure(error))
            return
        }
        saveSnapshot(decodeHistory: shouldDecodeHistory, state: "interrupted") { [self] result in
            switch result {
            case let .success(dump):
                completion(.failure(HistoryFetchError.partialDumpSaved(
                    reason: error.localizedDescription, rawPath: dump.rawURL.path, csvPath: dump.csvURL?.path
                )))
            case let .failure(saveError):
                BirdMenuLog.error("history.operation failureDumpFailed error=\(saveError)")
                let reason = "\(error.localizedDescription)\nCould not save the latest snapshot: \(saveError.localizedDescription)"
                if let raw = outputFolder?.appendingPathComponent("raw-history.json"),
                   FileManager.default.fileExists(atPath: raw.path) {
                    completion(.failure(HistoryFetchError.failureDumpFailed(reason: reason, rawPath: raw.path)))
                } else {
                    completion(.failure(HistoryFetchError.failureDumpFailed(reason: reason, rawPath: nil)))
                }
            }
        }
    }

    private func startCommandsIfReady() {
        guard !completed, !reconnecting, !hasStartedCommands, pendingNotificationKeys.isEmpty, pendingInitialReadKeys.isEmpty else {
            return
        }
        hasStartedCommands = true
        switch transferMode {
        case .readOnlySnapshot:
            fail(HistoryFetchError.historyCharacteristicNotFound)
            return
        case let .legacyFFF8(characteristic):
            commandAttempts = historyCommands.map { CommandAttempt(command: $0, characteristic: characteristic) }
        case .ith11BTrace:
            guard InkbirdHistoryExportWriter.intervalSeconds(from: configData) != nil else {
                fail(HistoryFetchError.historyFlowIncomplete("valid recording interval was not received"))
                return
            }
            let date = Date()
            clockSetAt = date
            ith11BState = ITH11BTransferState()
            let actions = ith11BState?.start(
                clock: InkbirdITH11BHistoryProtocol.timestampCommand(for: date),
                at: ProcessInfo.processInfo.systemUptime
            ) ?? []
            run(actions)
            return
        }
        BirdMenuLog.debugData(
            "history.operation commandMode=\(modeName) attempts=\(commandAttempts.map { "\($0.command.name)@\($0.characteristic.uuid.uuidString)" }.joined(separator: ","))"
        )
        writeNextCommand()
    }

    private func writeNextCommand() {
        invalidateTimers()
        guard commandAttemptIndex < commandAttempts.count else {
            finish()
            return
        }

        let attempt = commandAttempts[commandAttemptIndex]
        commandAttemptIndex += 1
        currentAttempt = attempt
        currentAttemptReceivedPacket = false
        let command = attempt.command
        let characteristic = attempt.characteristic
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        BirdMenuLog.debugData("history.command write name=\(command.name) value=\(command.value.hexString) char=\(characteristic.uuid.uuidString) type=\(writeType == .withResponse ? "withResponse" : "withoutResponse")")
        guard write(command.value, to: characteristic) else { return }
        let deadlineTimer = Timer(timeInterval: command.maxTimeout, repeats: false) { [weak self] _ in
            BirdMenuLog.debugData("history.command maxTimeout name=\(command.name)")
            self?.fail(HistoryFetchError.timedOut(command.name))
        }
        maxTimer = deadlineTimer
        RunLoop.main.add(deadlineTimer, forMode: .common)
        if writeType == .withoutResponse, queuedWithoutResponse == nil {
            if command.finishesOnWrite {
                finishCurrentCommand()
            } else if command.readAfterWrite, characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            } else {
                scheduleQuietTimer()
            }
        }
    }

    private func scheduleQuietTimer() {
        quietTimer?.invalidate()
        guard let currentAttempt, pendingUnacknowledgedWrite == nil, queuedWithoutResponse == nil else {
            return
        }
        guard currentAttemptReceivedPacket || !currentAttempt.command.readAfterWrite else {
            return
        }
        let timer = Timer(timeInterval: currentAttempt.command.quietTimeout, repeats: false) { [weak self] _ in
            if let commandName = self?.currentAttempt?.command.name {
                BirdMenuLog.debugData("history.command quietTimeout name=\(commandName)")
            }
            self?.handleQuietTimeout()
        }
        quietTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleQuietTimeout() {
        finishCurrentCommand()
    }

    private func finishCurrentCommand() {
        invalidateTimers()
        currentAttempt = nil
        writeNextCommand()
    }

    private func accepts(_ peripheral: CBPeripheral) -> Bool {
        peripheral === self.peripheral && !completed && !reconnecting
    }

    private func tick() {
        guard !completed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - startedAt >= Self.operationTimeout {
            fail(HistoryFetchError.timedOut("history operation (40-minute safety limit)"))
            return
        }
        if reconnecting {
            if reconnectReadyAt == nil, now >= reconnectDeadline {
                fail(HistoryFetchError.timedOut("disconnect and snapshot save before reconnect"))
                return
            }
            if let readyAt = reconnectReadyAt, now >= readyAt {
                restartConnection()
            }
            reportProgress(.reconnecting)
        } else if !hasStartedCommands {
            if now >= setupDeadline {
                handleCommunicationError(HistoryFetchError.timedOut("connection or service discovery"))
            }
        } else if ith11BState != nil {
            run(ith11BState?.tick(at: now) ?? [])
            if !completed {
                switch ith11BState?.phase {
                case .saving: reportProgress(.saving)
                case .finalizing: reportProgress(.finalizing)
                default:
                    let recovering: Bool
                    switch ith11BState?.command {
                    case .missing, .retry: recovering = true
                    default: recovering = false
                    }
                    reportProgress(recovering ? .recovering : .receiving)
                }
            }
        }
    }

    private func reportProgress(_ phase: HistoryFetchProgress.Phase) {
        let status = ith11BState?.status
        progress(HistoryFetchProgress(
            phase: phase,
            receivedRecords: status?.decodedRecordCount ?? 0,
            expectedRecords: status?.expectedRecordCount,
            receivedBlocks: status?.receivedSequences.count ?? 0,
            expectedBlocks: status?.expectedBlockCount,
            elapsed: ProcessInfo.processInfo.systemUptime - startedAt
        ))
    }

    private func run(_ actions: [ITH11BTransferState.Action]) {
        guard !completed, !reconnecting else { return }
        for action in actions {
            guard !completed else { return }
            switch action {
            case let .write(command):
                guard let characteristic = allDiscoveredCharacteristics.first(where: {
                    $0.service?.uuid == Self.inkbirdServiceUUID && $0.uuid == CBUUID(string: command.characteristicUUID)
                }) else {
                    fail(HistoryFetchError.historyCharacteristicNotFound)
                    return
                }
                BirdMenuLog.info("history.command \(command.name) received=\(ith11BState?.status?.receivedSequences.count ?? 0) retries=\(ith11BState?.recovery.retryRound ?? 0)")
                _ = write(command.value, to: characteristic)
            case .save:
                let records = InkbirdHistoryExportWriter.decodeITH11BRecords(
                    packets: packets, intervalSeconds: InkbirdHistoryExportWriter.intervalSeconds(from: configData),
                    latestReading: latestReading, clockSetAt: clockSetAt
                )
                guard let status = ith11BState?.status, status.isComplete,
                      records.count == status.expectedRecordCount else {
                    fail(HistoryFetchError.historyDecodeFailed)
                    return
                }
                reportProgress(.saving)
                saveSnapshot(decodeHistory: true, state: "saved_before_device_confirmation") { [self] result in
                    guard !completed else { return }
                    switch result {
                    case let .success(saved):
                        guard saved.isComplete else {
                            fail(HistoryFetchError.historyDecodeFailed)
                            return
                        }
                        savedResult = saved
                        if disconnectedWhileSaving {
                            finishSaved(warning: "History is saved locally; the device disconnected before session confirmation.")
                        } else {
                            run(ith11BState?.didSave(at: ProcessInfo.processInfo.systemUptime) ?? [])
                        }
                    case let .failure(error):
                        fail(error)
                    }
                }
            case .finish:
                finishSaved(warning: nil)
            case let .fail(reason):
                fail(HistoryFetchError.historyFlowIncomplete(reason))
            }
        }
    }

    @discardableResult
    private func write(_ value: Data, to characteristic: CBCharacteristic) -> Bool {
        guard pendingUnacknowledgedWrite == nil, queuedWithoutResponse == nil else {
            fail(HistoryFetchError.historyFlowIncomplete("another write is still awaiting completion"))
            return false
        }
        let withResponse = characteristic.properties.contains(.write)
        guard withResponse || characteristic.properties.contains(.writeWithoutResponse) else {
            fail(HistoryFetchError.historyCharacteristicNotFound)
            return false
        }
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        guard value.count <= peripheral.maximumWriteValueLength(for: type) else {
            fail(HistoryFetchError.historyFlowIncomplete("command exceeds the connection's maximum write length"))
            return false
        }
        if withResponse {
            pendingUnacknowledgedWrite = characteristic
        } else if !peripheral.canSendWriteWithoutResponse {
            queuedWithoutResponse = (value, characteristic)
            return true
        }
        peripheral.writeValue(value, for: characteristic, type: type)
        if !withResponse, ith11BState != nil {
            acknowledgeITH11BWrite(characteristic)
        }
        return true
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard accepts(peripheral), let (value, characteristic) = queuedWithoutResponse else { return }
        queuedWithoutResponse = nil
        guard write(value, to: characteristic), !completed, queuedWithoutResponse == nil else { return }
        if ith11BState == nil, characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
        }
    }

    private func acknowledgeITH11BWrite(_ characteristic: CBCharacteristic) {
        guard let uuid = ith11BState?.command?.characteristicUUID,
              characteristic.uuid == CBUUID(string: uuid) else { return }
        run(ith11BState?.didWrite(characteristicUUID: uuid, at: ProcessInfo.processInfo.systemUptime) ?? [])
    }

    private func saveSnapshot(
        decodeHistory: Bool,
        state: String,
        completion: @escaping @Sendable (Result<InkbirdHistoryResult, Error>) -> Void
    ) {
        let reading = latestReading
        let config = configData
        let characteristics = characteristics
        let packets = packets
        let warnings = warnings
        let mode = modeName
        let clock = clockSetAt
        let folder = outputFolder
        exportQueue.async {
            let result = Result {
                try InkbirdHistoryExportWriter.write(
                    deviceName: reading.deviceName, peripheralID: reading.peripheralID,
                    latestReading: reading, config: config, characteristics: characteristics,
                    packets: packets, warnings: warnings, mode: mode, decodeHistory: decodeHistory,
                    clockSetAt: clock, folderURL: folder, transferState: state
                )
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func handleCommunicationError(_ error: Error) {
        guard !completed, !reconnecting else { return }
        guard savedResult == nil, ith11BState?.phase != .saving,
              HistoryReconnectPolicy.shouldRestart(error: error, previousRestarts: reconnectCount) else {
            fail(error)
            return
        }
        reconnecting = true
        reconnectCount += 1
        reconnectDumpSaved = false
        reconnectDeadline = ProcessInfo.processInfo.systemUptime + 30
        pendingUnacknowledgedWrite = nil
        queuedWithoutResponse = nil
        invalidateTimers()
        warnings.append("Connection interrupted; restarting as a separate history snapshot: \(error.localizedDescription)")
        BirdMenuLog.info("history.reconnect attempt=\(reconnectCount) error=\(error)")
        reportProgress(.reconnecting)
        if peripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        saveSnapshot(decodeHistory: shouldDecodeHistory, state: "interrupted_before_restart") { [self] result in
            guard !completed else { return }
            switch result {
            case let .success(saved):
                warnings.append("Previous partial snapshot: \(saved.rawURL.path)")
                reconnectDumpSaved = true
                scheduleReconnectIfReady()
            case let .failure(saveError):
                fail(saveError)
            }
        }
    }

    private func scheduleReconnectIfReady() {
        guard reconnecting, reconnectDumpSaved, peripheral.state == .disconnected,
              reconnectReadyAt == nil else { return }
        reconnectReadyAt = ProcessInfo.processInfo.systemUptime + Double(reconnectCount * 2)
    }

    private func restartConnection() {
        guard peripheral.state == .disconnected, centralManager.state == .poweredOn else {
            fail(HistoryFetchError.bluetoothUnavailable)
            return
        }
        do {
            outputFolder = try InkbirdHistoryExportWriter.outputFolder(
                deviceName: latestReading.deviceName, peripheralID: latestReading.peripheralID
            )
        } catch {
            fail(error)
            return
        }
        // A new connection is a new snapshot; never merge block numbers across sessions.
        packets = []
        characteristics = []
        allDiscoveredCharacteristics = []
        configCharacteristic = nil
        configData = nil
        clockSetAt = nil
        service = nil
        notifyCharacteristics = []
        pendingInitialReadKeys = []
        pendingNotificationKeys = []
        pendingCharacteristicServiceUUIDs = []
        commandAttempts = []
        commandAttemptIndex = 0
        currentAttempt = nil
        ith11BState = nil
        transferMode = .readOnlySnapshot
        modeName = "read-only-gatt-snapshot"
        shouldDecodeHistory = false
        hasStartedCommands = false
        reconnecting = false
        reconnectReadyAt = nil
        disconnectedWhileSaving = false
        setupDeadline = ProcessInfo.processInfo.systemUptime + 30
        peripheral.delegate = nil
        centralManager.connect(peripheral)
        reportProgress(.connecting)
    }

    private func finishSaved(warning: String?) {
        guard !completed, var saved = savedResult else { return }
        completed = true
        ith11BState?.stop()
        invalidateTimers()
        operationTimer?.invalidate()
        operationTimer = nil
        if let warning {
            warnings.append(warning)
            saved.warnings.append(warning)
            BirdMenuLog.error("history.session unconfirmed \(warning)")
        }
        let retained = saved
        saveSnapshot(decodeHistory: true, state: warning == nil ? "complete" : "saved_session_unconfirmed") { [self] result in
            switch result {
            case let .success(final):
                completion(.success(final))
            case let .failure(error):
                var final = retained
                final.warnings.append("History was saved, but final status could not be updated: \(error.localizedDescription)")
                BirdMenuLog.error("history.finalStatusSaveFailed error=\(error)")
                completion(.success(final))
            }
        }
    }

    private func finish() {
        guard !completed else {
            return
        }
        invalidateTimers()
        do {
            try validateSuccessfulHistoryFlow()
            currentAttempt = nil
            saveSnapshot(decodeHistory: shouldDecodeHistory, state: "complete") { [self] result in
                guard !completed else { return }
                switch result {
                case let .success(saved):
                    completed = true
                    operationTimer?.invalidate()
                    operationTimer = nil
                    completion(.success(saved))
                case let .failure(error): fail(error)
                }
            }
        } catch {
            fail(error)
        }
    }

    private func validateSuccessfulHistoryFlow() throws {
        switch transferMode {
        case .readOnlySnapshot:
            throw HistoryFetchError.historyCharacteristicNotFound
        case .legacyFFF8:
            let requiredCommands = ["temp_content", "hum_content"]
            let missing = requiredCommands.filter { command in
                !packets.contains { $0.command == command }
            }
            if !missing.isEmpty {
                throw HistoryFetchError.historyFlowIncomplete("missing \(missing.joined(separator: ", "))")
            }
        case .ith11BTrace:
            guard ith11BState?.locallySaved == true else {
                throw HistoryFetchError.historyDecodeFailed
            }
        }
    }

    private func invalidateTimers() {
        quietTimer?.invalidate()
        quietTimer = nil
        maxTimer?.invalidate()
        maxTimer = nil
    }

    private func updateCharacteristicValue(_ characteristic: CBCharacteristic, value: Data) {
        characteristics = characteristics.map {
            guard $0.characteristicUUID == characteristic.uuid.uuidString,
                  $0.serviceUUID == characteristic.service?.uuid.uuidString else {
                return $0
            }
            return InkbirdGATTCharacteristicInfo(
                serviceUUID: $0.serviceUUID,
                characteristicUUID: $0.characteristicUUID,
                properties: $0.properties,
                valueHex: value.hexString
            )
        }
    }

    private func characteristicKey(_ characteristic: CBCharacteristic) -> String {
        "\(characteristic.service?.uuid.uuidString ?? "-")/\(characteristic.uuid.uuidString)"
    }

}

enum HistoryReconnectPolicy {
    static func shouldRestart(error: Error, previousRestarts: Int) -> Bool {
        guard previousRestarts < 2 else { return false }
        if let error = error as? HistoryFetchError {
            switch error {
            case .disconnected, .connectionFailed, .timedOut: return true
            default: return false
            }
        }
        let error = error as NSError
        guard error.domain == CBErrorDomain else { return false }
        return [CBError.Code.connectionTimeout, .peripheralDisconnected, .connectionFailed, .notConnected]
            .contains { $0.rawValue == error.code }
    }
}

private extension CBCharacteristicProperties {
    var names: [String] {
        var values: [String] = []
        if contains(.broadcast) { values.append("broadcast") }
        if contains(.read) { values.append("read") }
        if contains(.writeWithoutResponse) { values.append("writeWithoutResponse") }
        if contains(.write) { values.append("write") }
        if contains(.notify) { values.append("notify") }
        if contains(.indicate) { values.append("indicate") }
        if contains(.authenticatedSignedWrites) { values.append("authenticatedSignedWrites") }
        if contains(.extendedProperties) { values.append("extendedProperties") }
        if contains(.notifyEncryptionRequired) { values.append("notifyEncryptionRequired") }
        if contains(.indicateEncryptionRequired) { values.append("indicateEncryptionRequired") }
        return values
    }
}
