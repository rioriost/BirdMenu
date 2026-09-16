import AppKit
import Foundation

@MainActor
final class StatusMenuController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let scanner = InkbirdScanner()
    private let menu = StatusMenuController.makeMenu()
    private let statusItemText = NSMenuItem(title: "\(AppText.status): \(AppText.starting)", action: nil, keyEquivalent: "")
    private let displayItem = NSMenuItem(title: "\(AppText.display): \(AppText.allSensors)", action: nil, keyEquivalent: "")
    private let deviceItem = NSMenuItem(title: "\(AppText.sensor): --", action: nil, keyEquivalent: "")
    private let temperatureItem = NSMenuItem(title: "\(AppText.temperature): --", action: nil, keyEquivalent: "")
    private let humidityItem = NSMenuItem(title: "\(AppText.humidity): --", action: nil, keyEquivalent: "")
    private let batteryItem = NSMenuItem(title: "\(AppText.battery): --", action: nil, keyEquivalent: "")
    private let signalItem = NSMenuItem(title: "\(AppText.signal): --", action: nil, keyEquivalent: "")
    private let lastUpdateItem = NSMenuItem(title: "\(AppText.lastUpdate): --", action: nil, keyEquivalent: "")
    private let historyItem = NSMenuItem(title: "\(AppText.history): --", action: nil, keyEquivalent: "")

    private var sensorState = SensorDisplayState()
    private var selectedPeripheralID: UUID? {
        get { sensorState.selectedPeripheralID }
        set {
            sensorState.selectedPeripheralID = newValue
            UserDefaults.standard.set(newValue?.uuidString, forKey: Self.selectedPeripheralDefaultsKey)
        }
    }
    private var scannerStatus: BLEScannerStatus = .starting
    private var timer: Timer?
    private var historyRequest = HistoryUIRequestState()
    private var historyProgress: HistoryFetchProgress?
    private var isFetchingHistory: Bool { historyRequest.isFetching }
    private var historyStatus: HistoryDisplayStatus = .notFetched
    private var settingsWindowController: SettingsWindowController?

    private static let selectedPeripheralDefaultsKey = "selectedPeripheralID"

    static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    init() {
        selectedPeripheralID = UserDefaults.standard.string(forKey: Self.selectedPeripheralDefaultsKey).flatMap(UUID.init(uuidString:))
        configureStatusItem()
        configureScanner()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localeDidChange),
            name: NSLocale.currentLocaleDidChangeNotification,
            object: nil
        )
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureStatusItem() {
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.menu = menu
    }

    private func configureScanner() {
        scanner.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.scannerStatus = status
                self?.refresh()
            }
        }
        scanner.onReading = { [weak self] reading in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.sensorState.receive(reading)
                self.refresh()
            }
        }
    }

    @objc private func selectAllDevices() {
        selectedPeripheralID = nil
        refresh()
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let uuidString = sender.representedObject as? String,
              let uuid = UUID(uuidString: uuidString) else {
            return
        }
        selectedPeripheralID = uuid
        refresh()
    }

    @objc private func rescan() {
        guard !isFetchingHistory else { return }
        scanner.restart()
    }

    @objc private func fetchHistory() {
        guard !isFetchingHistory, !historyRequest.pendingQuit else { return }
        guard let reading = historyTargetReading() else {
            showAlert(title: AppText.noSensorSelectedTitle, message: AppText.noSensorSelectedMessage)
            return
        }
        guard let requestID = historyRequest.begin() else { return }
        historyProgress = nil
        historyStatus = .fetching
        refresh()
        scanner.onHistoryProgress = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.historyRequest.accepts(requestID) else { return }
                self.historyProgress = progress
                self.refresh()
            }
        }
        scanner.fetchHistory(for: reading) { [weak self] result in
            Task { @MainActor in
                guard let self, self.historyRequest.finish(requestID) else {
                    return
                }
                self.scanner.onHistoryProgress = nil
                self.historyProgress = nil
                if let shouldTerminate = self.historyRequest.resolvePendingQuit(for: result) {
                    NSApplication.shared.reply(toApplicationShouldTerminate: shouldTerminate)
                    if shouldTerminate { return }
                }
                self.settingsWindowController?.refreshHistorySensors()
                switch result {
                case let .success(history):
                    if HistoryUIRequestState.isEmptySuccess(history) {
                        self.historyStatus = .noNewRecords
                        self.showAlert(
                            title: AppText.historyFetchCompleteTitle,
                            message: Self.withWarnings(
                                "\(AppText.noNewHistory)\n\nRaw: \(history.rawURL.path)",
                                history: history
                            )
                        )
                    } else if let csvURL = history.csvURL {
                        self.historyStatus = .records(history.recordCount)
                        self.showAlert(
                            title: AppText.historyFetchCompleteTitle,
                            message: Self.historyCompleteMessage(history: history, csvURL: csvURL)
                        )
                    } else {
                        self.historyStatus = .rawOnly
                        self.showAlert(
                            title: AppText.historyRawDumpSavedTitle,
                            message: Self.historyRawDumpMessage(history: history)
                        )
                    }
                case let .failure(error):
                    self.historyStatus = .failed
                    self.showAlert(title: AppText.historyFetchFailedTitle, message: error.localizedDescription)
                }
                self.refresh()
            }
        }
    }

    @objc private func openLatestHistoryFolder() {
        let historyFolderURL = Self.historyRootFolderURL()
        do {
            try FileManager.default.createDirectory(at: historyFolderURL, withIntermediateDirectories: true)
        } catch {
            showAlert(title: AppText.couldNotOpenHistoryFolderTitle, message: error.localizedDescription)
            return
        }
        NSWorkspace.shared.open(historyFolderURL)
    }

    @objc private func showAbout() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    @objc private func showSettings() {
        guard settingsWindowController == nil else {
            settingsWindowController?.show()
            return
        }
        let controller = SettingsWindowController()
        controller.onClose = { [weak self] in
            Task { @MainActor in
                self?.settingsWindowController = nil
                self?.refresh()
            }
        }
        controller.onChange = { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
        settingsWindowController = controller
        refresh()
        controller.show()
    }

    @objc private func localeDidChange() {
        settingsWindowController?.reload()
        refresh()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        guard isFetchingHistory else { return .terminateNow }
        if historyRequest.pendingQuit { return .terminateLater }
        let alert = NSAlert()
        alert.messageText = AppText.quitDuringHistoryTitle
        alert.informativeText = AppText.quitDuringHistoryMessage
        alert.addButton(withTitle: AppText.cancelHistoryAndQuit)
        alert.addButton(withTitle: AppText.keepRunning)
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        guard isFetchingHistory else { return .terminateNow }
        let shouldCancel = historyRequest.requestCancellation(forQuit: true)
        refresh()
        if shouldCancel {
            // Defer completion until AppKit has registered the terminateLater reply.
            Task { @MainActor [weak self] in
                self?.scanner.cancelHistory()
            }
        }
        return .terminateLater
    }

    @objc private func cancelHistory() {
        guard historyRequest.requestCancellation() else { return }
        refresh()
        scanner.cancelHistory()
    }

    private func refresh() {
        let displayState = currentDisplayState()
        statusItem.button?.image = Self.statusImage(color: displayState.color)
        statusItem.button?.title = displayState.title
        statusItem.button?.toolTip = displayState.tooltip

        statusItemText.title = "\(AppText.status): \(displayState.statusText)"
        updateDetailItems()
        rebuildMenu()
    }

    private func updateDetailItems() {
        if historyRequest.cancellationRequested {
            historyItem.title = "\(AppText.history): \(AppText.cancellingHistory)"
        } else if let historyProgress, isFetchingHistory {
            historyItem.title = "\(AppText.history): \(AppText.historyProgress(historyProgress))"
        } else {
            historyItem.title = historyStatus.menuTitle
        }
        guard let snapshot = selectedSnapshot() else {
            displayItem.title = "\(AppText.display): \(selectedPeripheralID == nil ? AppText.allSensors : AppText.missingSensor)"
            deviceItem.title = "\(AppText.sensor): --"
            temperatureItem.title = "\(AppText.temperature): --"
            humidityItem.title = "\(AppText.humidity): --"
            batteryItem.title = "\(AppText.battery): --"
            signalItem.title = "\(AppText.signal): --"
            lastUpdateItem.title = "\(AppText.lastUpdate): --"
            return
        }

        displayItem.title = "\(AppText.display): \(snapshot.isAggregate ? AppText.allSensors : snapshot.label)"
        deviceItem.title = "\(AppText.sensor): \(snapshot.label)"
        temperatureItem.title = "\(AppText.temperature): \(Self.formatTemperature(snapshot.temperatureCelsius))"
        humidityItem.title = "\(AppText.humidity): \(Self.formatHumidity(snapshot.humidityPercent))"
        batteryItem.title = snapshot.batteryPercent.map { "\(AppText.battery): \($0)%" } ?? "\(AppText.battery): --"
        signalItem.title = snapshot.rssi.map { "\(AppText.signal): \($0) dBm" } ?? "\(AppText.signal): --"
        lastUpdateItem.title = "\(snapshot.isAggregate ? AppText.oldestUpdate : AppText.lastUpdate): \(Self.relativeTime(since: snapshot.date))"
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        for item in [statusItemText, displayItem, deviceItem, temperatureItem, humidityItem, batteryItem, signalItem, lastUpdateItem, historyItem] {
            item.isEnabled = false
        }
        menu.addItem(statusItemText)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(displayItem)
        menu.addItem(deviceItem)
        menu.addItem(temperatureItem)
        menu.addItem(humidityItem)
        menu.addItem(batteryItem)
        menu.addItem(signalItem)
        menu.addItem(lastUpdateItem)
        menu.addItem(NSMenuItem.separator())

        let allDevicesItem = NSMenuItem(title: AppText.allSensors, action: #selector(selectAllDevices), keyEquivalent: "")
        allDevicesItem.target = self
        allDevicesItem.state = selectedPeripheralID == nil ? .on : .off
        menu.addItem(allDevicesItem)

        if let selectedPeripheralID, sensorState.readingsByPeripheralID[selectedPeripheralID] == nil {
            let missingItem = NSMenuItem(
                title: "\(AppText.sensor) \(Self.shortID(selectedPeripheralID)) — \(AppText.selectedSensorMissing)",
                action: nil,
                keyEquivalent: ""
            )
            missingItem.state = .on
            missingItem.isEnabled = false
            menu.addItem(missingItem)
        }
        for reading in sortedReadings() {
            let item = NSMenuItem(title: deviceSelectionTitle(for: reading), action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = reading.peripheralID.uuidString
            item.state = selectedPeripheralID == reading.peripheralID ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let rescanItem = NSMenuItem(title: AppText.rescan, action: #selector(rescan), keyEquivalent: "")
        rescanItem.target = self
        rescanItem.isEnabled = !isFetchingHistory
        menu.addItem(rescanItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(historyItem)
        let fetchHistoryItem = NSMenuItem(title: AppText.fetchSensorHistory, action: #selector(fetchHistory), keyEquivalent: "")
        fetchHistoryItem.target = self
        fetchHistoryItem.isEnabled = !isFetchingHistory && historyTargetReading() != nil
        menu.addItem(fetchHistoryItem)

        if isFetchingHistory {
            let cancelItem = NSMenuItem(title: AppText.cancelHistory, action: #selector(cancelHistory), keyEquivalent: "")
            cancelItem.target = self
            cancelItem.isEnabled = !historyRequest.cancellationRequested
            menu.addItem(cancelItem)
        }
        let openHistoryFolderItem = NSMenuItem(title: AppText.openHistoryFolder, action: #selector(openLatestHistoryFolder), keyEquivalent: "")
        openHistoryFolderItem.target = self
        menu.addItem(openHistoryFolderItem)

        menu.addItem(NSMenuItem.separator())
        let aboutItem = NSMenuItem(title: AppText.about, action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: AppText.settings, action: #selector(showSettings), keyEquivalent: "")
        settingsItem.target = self
        settingsItem.isEnabled = settingsWindowController == nil
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: AppText.quit, action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func currentDisplayState() -> (title: String, color: NSColor, statusText: String, tooltip: String) {
        if case let .bluetoothUnavailable(reason) = scannerStatus {
            let text = Self.bluetoothUnavailableText(for: reason)
            return ("--.-\(TemperatureUnit.current == .celsius ? "°C" : "°F") --%", .systemRed, text, "BirdMenu: \(text)")
        }

        guard let snapshot = selectedSnapshot() else {
            let status = selectedPeripheralID == nil ? AppText.scanning : AppText.selectedSensorMissing
            return ("--.-\(TemperatureUnit.current == .celsius ? "°C" : "°F") --%", .systemOrange, status, "BirdMenu: \(status)")
        }

        let text = "\(Self.formatTemperature(snapshot.temperatureCelsius)) \(Self.formatHumidity(snapshot.humidityPercent))"
        let updateLabel = snapshot.isAggregate ? AppText.oldestUpdate : AppText.lastUpdate
        switch snapshot.freshness(at: Date()) {
        case .fresh:
            return (text, .systemGreen, AppText.receivingBLE, "BirdMenu: \(snapshot.label)")
        case .stale:
            return (text, .systemOrange, snapshot.isAggregate ? AppText.someSensorsStaleBLE : AppText.staleBLE, "BirdMenu: \(updateLabel) \(Self.relativeTime(since: snapshot.date))")
        case .missing:
            return (text, .systemRed, snapshot.isAggregate ? AppText.someSensorsNoRecentBLE : AppText.noRecentBLE, "BirdMenu: \(updateLabel) \(Self.relativeTime(since: snapshot.date))")
        }
    }

    private func selectedSnapshot() -> DisplaySnapshot? {
        sensorState.snapshot
    }

    private func historyTargetReading() -> InkbirdReading? {
        sensorState.historyTargetReading
    }

    private func sortedReadings() -> [InkbirdReading] {
        sensorState.readingsByPeripheralID.values.sorted {
            let left = deviceLabel(for: $0)
            let right = deviceLabel(for: $1)
            if left == right {
                return $0.peripheralID.uuidString < $1.peripheralID.uuidString
            }
            return left < right
        }
    }

    private func deviceSelectionTitle(for reading: InkbirdReading) -> String {
        deviceLabel(for: reading)
    }

    private func deviceLabel(for reading: InkbirdReading) -> String {
        "\(AppText.sensor) \(Self.shortID(reading.peripheralID))"
    }

    private static func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.replacingOccurrences(of: "-", with: "").suffix(4)).uppercased()
    }

    private static func historyRootFolderURL() -> URL {
        InkbirdHistoryExportWriter.historyRootFolderURL()
    }

    private static func statusImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 11, height: 11)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 9, height: 9)).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 9, height: 9)).stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func formatTemperature(_ value: Double) -> String {
        TemperatureUnit.current.formatted(value)
    }

    private static func formatHumidity(_ value: Double?) -> String {
        guard let value else {
            return "--%"
        }
        return String(format: "%.0f%%", value)
    }

    private static func relativeTime(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return AppText.localized(en: "\(seconds)s ago", ja: "\(seconds)秒前")
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return AppText.localized(en: "\(minutes)m ago", ja: "\(minutes)分前")
        }
        let hours = minutes / 60
        return AppText.localized(en: "\(hours)h ago", ja: "\(hours)時間前")
    }

    private static func bluetoothUnavailableText(for reason: BluetoothUnavailableReason) -> String {
        switch reason {
        case .poweredOff:
            AppText.bluetoothOff
        case .unauthorized:
            AppText.bluetoothUnauthorized
        case .unsupported:
            AppText.bluetoothUnsupported
        case .unknown:
            AppText.bluetoothUnknown
        }
    }

    private static func historyCompleteMessage(history: InkbirdHistoryResult, csvURL: URL) -> String {
        if AppText.isJapanese {
            return withWarnings("\(history.recordCount)件の履歴レコードと\(history.packetCount)件の生パケットを保存しました。\n\nCSV: \(csvURL.path)\nRaw: \(history.rawURL.path)", history: history)
        }
        return withWarnings("Saved \(history.recordCount) decoded records and \(history.packetCount) raw packets.\n\nCSV: \(csvURL.path)\nRaw: \(history.rawURL.path)", history: history)
    }

    private static func historyRawDumpMessage(history: InkbirdHistoryResult) -> String {
        if AppText.isJapanese {
            return withWarnings("\(history.packetCount)件の生パケットを保存しましたが、CSVとして確実にデコードできませんでした。\n\nRaw: \(history.rawURL.path)", history: history)
        }
        return withWarnings("Saved \(history.packetCount) raw packets, but could not confidently decode them into CSV yet.\n\nRaw: \(history.rawURL.path)", history: history)
    }

    private static func withWarnings(_ message: String, history: InkbirdHistoryResult) -> String {
        history.warnings.isEmpty ? message : message + "\n\n" + history.warnings.joined(separator: "\n")
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: AppText.ok)
        alert.runModal()
    }
}

private enum HistoryDisplayStatus {
    case notFetched
    case fetching
    case records(Int)
    case rawOnly
    case noNewRecords
    case failed

    var menuTitle: String {
        switch self {
        case .notFetched:
            "\(AppText.history): \(AppText.notFetched)"
        case .fetching:
            "\(AppText.history): \(AppText.fetching)"
        case let .records(count):
            AppText.isJapanese ? "\(AppText.history): \(count)件" : "\(AppText.history): \(count) records"
        case .rawOnly:
            "\(AppText.history): \(AppText.rawOnly)"
        case .noNewRecords:
            "\(AppText.history): \(AppText.noNewHistory)"
        case .failed:
            "\(AppText.history): \(AppText.failed)"
        }
    }
}

struct HistoryUIRequestState {
    private(set) var requestID: UUID?
    private(set) var cancellationRequested = false
    private(set) var pendingQuit = false

    var isFetching: Bool { requestID != nil }

    mutating func begin() -> UUID? {
        guard !isFetching, !pendingQuit else { return nil }
        let id = UUID()
        requestID = id
        return id
    }

    func accepts(_ id: UUID) -> Bool { requestID == id }

    mutating func finish(_ id: UUID) -> Bool {
        guard accepts(id) else { return false }
        requestID = nil
        cancellationRequested = false
        return true
    }

    mutating func requestCancellation(forQuit: Bool = false) -> Bool {
        guard isFetching else { return false }
        pendingQuit = pendingQuit || forQuit
        guard !cancellationRequested else { return false }
        cancellationRequested = true
        return true
    }

    mutating func resolvePendingQuit(for result: Result<InkbirdHistoryResult, Error>) -> Bool? {
        guard pendingQuit, !isFetching else { return nil }
        switch result {
        case .success:
            return true
        case let .failure(error):
            if let historyError = error as? HistoryFetchError {
                switch historyError {
                case .cancelled, .partialDumpSaved:
                    return true
                default:
                    break
                }
            }
            pendingQuit = false
            return false
        }
    }

    static func isEmptySuccess(_ result: InkbirdHistoryResult) -> Bool {
        result.isComplete && result.recordCount == 0
    }
}

struct SensorDisplayState {
    var selectedPeripheralID: UUID?
    private(set) var readingsByPeripheralID: [UUID: InkbirdReading] = [:]

    mutating func receive(_ reading: InkbirdReading) {
        readingsByPeripheralID[reading.peripheralID] = reading
    }

    var historyTargetReading: InkbirdReading? {
        if let selectedPeripheralID { return readingsByPeripheralID[selectedPeripheralID] }
        return readingsByPeripheralID.count == 1 ? readingsByPeripheralID.values.first : nil
    }

    var snapshot: DisplaySnapshot? {
        let readings: [InkbirdReading]
        if let selectedPeripheralID {
            guard let reading = readingsByPeripheralID[selectedPeripheralID] else { return nil }
            readings = [reading]
        } else {
            readings = Array(readingsByPeripheralID.values)
        }
        guard let oldest = readings.min(by: { $0.date < $1.date }) else { return nil }
        if readings.count == 1 {
            let shortID = oldest.peripheralID.uuidString.replacingOccurrences(of: "-", with: "").suffix(4)
            return DisplaySnapshot(reading: oldest, label: "\(AppText.sensor) \(shortID)")
        }
        let humidities = readings.compactMap(\.humidityPercent)
        return DisplaySnapshot(
            label: "\(AppText.allSensors) (\(readings.count))",
            temperatureCelsius: readings.map(\.temperatureCelsius).reduce(0, +) / Double(readings.count),
            humidityPercent: humidities.isEmpty ? nil : humidities.reduce(0, +) / Double(humidities.count),
            batteryPercent: nil,
            rssi: nil,
            date: oldest.date,
            isAggregate: true
        )
    }
}

struct DisplaySnapshot {
    enum Freshness { case fresh, stale, missing }

    let label: String
    let temperatureCelsius: Double
    let humidityPercent: Double?
    let batteryPercent: Int?
    let rssi: Int?
    let date: Date
    let isAggregate: Bool

    func freshness(at now: Date) -> Freshness {
        let age = now.timeIntervalSince(date)
        if age <= 120 { return .fresh }
        if age <= 600 { return .stale }
        return .missing
    }

    init(reading: InkbirdReading, label: String) {
        self.label = label
        temperatureCelsius = reading.temperatureCelsius
        humidityPercent = reading.humidityPercent
        batteryPercent = reading.batteryPercent
        rssi = reading.rssi
        date = reading.date
        isAggregate = false
    }

    init(
        label: String,
        temperatureCelsius: Double,
        humidityPercent: Double?,
        batteryPercent: Int?,
        rssi: Int?,
        date: Date,
        isAggregate: Bool
    ) {
        self.label = label
        self.temperatureCelsius = temperatureCelsius
        self.humidityPercent = humidityPercent
        self.batteryPercent = batteryPercent
        self.rssi = rssi
        self.date = date
        self.isAggregate = isAggregate
    }
}
