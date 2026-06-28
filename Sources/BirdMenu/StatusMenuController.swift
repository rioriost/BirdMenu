import AppKit
import Foundation

@MainActor
final class StatusMenuController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let scanner = InkbirdScanner()
    private let menu = NSMenu()
    private let statusItemText = NSMenuItem(title: "Status: Starting", action: nil, keyEquivalent: "")
    private let displayItem = NSMenuItem(title: "Display: All Sensors", action: nil, keyEquivalent: "")
    private let deviceItem = NSMenuItem(title: "Sensor: --", action: nil, keyEquivalent: "")
    private let temperatureItem = NSMenuItem(title: "Temperature: --", action: nil, keyEquivalent: "")
    private let humidityItem = NSMenuItem(title: "Humidity: --", action: nil, keyEquivalent: "")
    private let batteryItem = NSMenuItem(title: "Battery: --", action: nil, keyEquivalent: "")
    private let signalItem = NSMenuItem(title: "Signal: --", action: nil, keyEquivalent: "")
    private let lastUpdateItem = NSMenuItem(title: "Last update: --", action: nil, keyEquivalent: "")
    private let historyItem = NSMenuItem(title: "History: --", action: nil, keyEquivalent: "")

    private var readingsByPeripheralID: [UUID: InkbirdReading] = [:]
    private var selectedPeripheralID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedPeripheralID?.uuidString, forKey: Self.selectedPeripheralDefaultsKey)
        }
    }
    private var scannerStatus: BLEScannerStatus = .starting
    private var timer: Timer?
    private var isFetchingHistory = false
    private var historyStatus = "History: Not fetched"
    private var isDebugLoggingEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: BirdMenuLog.debugLoggingDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: BirdMenuLog.debugLoggingDefaultsKey)
            BirdMenuLog.info("debugLogging \(newValue ? "enabled" : "disabled")")
        }
    }

    private static let selectedPeripheralDefaultsKey = "selectedPeripheralID"

    init() {
        selectedPeripheralID = UserDefaults.standard.string(forKey: Self.selectedPeripheralDefaultsKey).flatMap(UUID.init(uuidString:))
        configureStatusItem()
        configureScanner()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
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
                self.readingsByPeripheralID[reading.peripheralID] = reading
                if let selectedPeripheralID = self.selectedPeripheralID,
                   self.readingsByPeripheralID[selectedPeripheralID] == nil {
                    self.selectedPeripheralID = nil
                }
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
        scanner.restart()
    }

    @objc private func fetchHistory() {
        guard let reading = historyTargetReading() else {
            showAlert(title: "No Sensor Selected", message: "Select a specific sensor, or wait until exactly one compatible sensor is detected.")
            return
        }
        isFetchingHistory = true
        historyStatus = "History: Fetching..."
        refresh()
        scanner.fetchHistory(for: reading) { [weak self] result in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.isFetchingHistory = false
                switch result {
                case let .success(history):
                    if let csvURL = history.csvURL {
                        self.historyStatus = "History: \(history.recordCount) records"
                        let pngLine = history.pngURL.map { "\nPNG: \($0.path)" } ?? ""
                        self.showAlert(
                            title: "History Fetch Complete",
                            message: "Saved \(history.recordCount) decoded records and \(history.packetCount) raw packets.\n\nCSV: \(csvURL.path)\(pngLine)\nRaw: \(history.rawURL.path)"
                        )
                    } else {
                        self.historyStatus = "History: raw only"
                        self.showAlert(
                            title: "History Raw Dump Saved",
                            message: "Saved \(history.packetCount) raw packets, but could not confidently decode them into CSV yet.\n\nRaw: \(history.rawURL.path)"
                        )
                    }
                case let .failure(error):
                    self.historyStatus = "History: failed"
                    self.showAlert(title: "History Fetch Failed", message: error.localizedDescription)
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
            showAlert(title: "Could Not Open History Folder", message: error.localizedDescription)
            return
        }
        NSWorkspace.shared.open(historyFolderURL)
    }

    @objc private func toggleDebugLogging() {
        isDebugLoggingEnabled.toggle()
        scanner.restart()
        refresh()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func refresh() {
        let displayState = currentDisplayState()
        statusItem.button?.image = Self.statusImage(color: displayState.color)
        statusItem.button?.title = displayState.title
        statusItem.button?.toolTip = displayState.tooltip

        statusItemText.title = "Status: \(displayState.statusText)"
        updateDetailItems()
        rebuildMenu()
    }

    private func updateDetailItems() {
        guard let snapshot = selectedSnapshot() else {
            displayItem.title = selectedPeripheralID == nil ? "Display: All Sensors" : "Display: Missing Sensor"
            deviceItem.title = "Sensor: --"
            temperatureItem.title = "Temperature: --"
            humidityItem.title = "Humidity: --"
            batteryItem.title = "Battery: --"
            signalItem.title = "Signal: --"
            lastUpdateItem.title = "Last update: --"
            historyItem.title = historyStatus
            return
        }

        displayItem.title = snapshot.isAggregate ? "Display: All Sensors" : "Display: \(snapshot.label)"
        deviceItem.title = "Sensor: \(snapshot.label)"
        temperatureItem.title = "Temperature: \(Self.formatTemperature(snapshot.temperatureCelsius))"
        humidityItem.title = "Humidity: \(Self.formatHumidity(snapshot.humidityPercent))"
        batteryItem.title = snapshot.batteryPercent.map { "Battery: \($0)%" } ?? "Battery: --"
        signalItem.title = snapshot.rssi.map { "Signal: \($0) dBm" } ?? "Signal: --"
        lastUpdateItem.title = "Last update: \(Self.relativeTime(since: snapshot.date))"
        historyItem.title = historyStatus
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(statusItemText)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(displayItem)
        menu.addItem(deviceItem)
        menu.addItem(temperatureItem)
        menu.addItem(humidityItem)
        menu.addItem(batteryItem)
        menu.addItem(signalItem)
        menu.addItem(lastUpdateItem)
        menu.addItem(historyItem)
        menu.addItem(NSMenuItem.separator())

        let allDevicesItem = NSMenuItem(title: "All Sensors", action: #selector(selectAllDevices), keyEquivalent: "")
        allDevicesItem.target = self
        allDevicesItem.state = selectedPeripheralID == nil ? .on : .off
        menu.addItem(allDevicesItem)

        for reading in sortedReadings() {
            let item = NSMenuItem(title: deviceMenuTitle(for: reading), action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = reading.peripheralID.uuidString
            item.state = selectedPeripheralID == reading.peripheralID ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let fetchHistoryItem = NSMenuItem(title: "Fetch Sensor History (Experimental)", action: #selector(fetchHistory), keyEquivalent: "h")
        fetchHistoryItem.target = self
        fetchHistoryItem.isEnabled = !isFetchingHistory && historyTargetReading() != nil
        menu.addItem(fetchHistoryItem)

        let openHistoryFolderItem = NSMenuItem(title: "Open History Folder", action: #selector(openLatestHistoryFolder), keyEquivalent: "")
        openHistoryFolderItem.target = self
        menu.addItem(openHistoryFolderItem)

        menu.addItem(NSMenuItem.separator())
        let debugItem = NSMenuItem(title: "Debug Logging", action: #selector(toggleDebugLogging), keyEquivalent: "d")
        debugItem.target = self
        debugItem.state = isDebugLoggingEnabled ? .on : .off
        menu.addItem(debugItem)

        menu.addItem(NSMenuItem.separator())
        let rescanItem = NSMenuItem(title: "Rescan", action: #selector(rescan), keyEquivalent: "r")
        rescanItem.target = self
        menu.addItem(rescanItem)
        let quitItem = NSMenuItem(title: "Quit BirdMenu", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func currentDisplayState() -> (title: String, color: NSColor, statusText: String, tooltip: String) {
        if case let .bluetoothUnavailable(reason) = scannerStatus {
            return ("--.-°C --%", .systemRed, reason, "BirdMenu: \(reason)")
        }

        guard let snapshot = selectedSnapshot() else {
            let status = selectedPeripheralID == nil ? "Scanning for compatible sensors" : "Selected sensor has not been seen"
            return ("--.-°C --%", .systemOrange, status, "BirdMenu: \(status)")
        }

        let age = Date().timeIntervalSince(snapshot.date)
        let text = "\(Self.formatTemperature(snapshot.temperatureCelsius)) \(Self.formatHumidity(snapshot.humidityPercent))"
        if age <= 120 {
            return (text, .systemGreen, "Receiving BLE advertisements", "BirdMenu: \(snapshot.label)")
        }
        if age <= 600 {
            return (text, .systemOrange, "Last BLE advertisement is stale", "BirdMenu: last update \(Self.relativeTime(since: snapshot.date))")
        }
        return (text, .systemRed, "No recent BLE advertisements", "BirdMenu: last update \(Self.relativeTime(since: snapshot.date))")
    }

    private func selectedSnapshot() -> DisplaySnapshot? {
        if let selectedPeripheralID {
            guard let reading = readingsByPeripheralID[selectedPeripheralID] else {
                return nil
            }
            return DisplaySnapshot(reading: reading, label: deviceLabel(for: reading))
        }

        let readings = sortedReadings()
        guard !readings.isEmpty else {
            return nil
        }
        if readings.count == 1, let reading = readings.first {
            return DisplaySnapshot(reading: reading, label: deviceLabel(for: reading))
        }

        let temperatures = readings.map(\.temperatureCelsius)
        let humidities = readings.compactMap(\.humidityPercent)
        let freshest = readings.max { $0.date < $1.date }!
        let averageTemperature = temperatures.reduce(0, +) / Double(temperatures.count)
        let averageHumidity = humidities.isEmpty ? nil : humidities.reduce(0, +) / Double(humidities.count)

        return DisplaySnapshot(
            label: "All Sensors (\(readings.count))",
            temperatureCelsius: averageTemperature,
            humidityPercent: averageHumidity,
            batteryPercent: nil,
            rssi: nil,
            date: freshest.date,
            isAggregate: true
        )
    }

    private func historyTargetReading() -> InkbirdReading? {
        if let selectedPeripheralID {
            return readingsByPeripheralID[selectedPeripheralID]
        }
        let readings = sortedReadings()
        return readings.count == 1 ? readings.first : nil
    }

    private func sortedReadings() -> [InkbirdReading] {
        readingsByPeripheralID.values.sorted {
            let left = deviceLabel(for: $0)
            let right = deviceLabel(for: $1)
            if left == right {
                return $0.peripheralID.uuidString < $1.peripheralID.uuidString
            }
            return left < right
        }
    }

    private func deviceMenuTitle(for reading: InkbirdReading) -> String {
        let agePrefix = Date().timeIntervalSince(reading.date) > 600 ? "[stale] " : ""
        return "\(agePrefix)\(deviceLabel(for: reading))  \(Self.formatTemperature(reading.temperatureCelsius))  \(Self.formatHumidity(reading.humidityPercent))"
    }

    private func deviceLabel(for reading: InkbirdReading) -> String {
        "Sensor \(Self.shortID(reading.peripheralID))"
    }

    private static func shortID(_ uuid: UUID) -> String {
        String(uuid.uuidString.replacingOccurrences(of: "-", with: "").suffix(4)).uppercased()
    }

    private static func historyRootFolderURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BirdMenu Logs", isDirectory: true)
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
        String(format: "%.1f°C", value)
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
            return "\(seconds)s ago"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        return "\(minutes / 60)h ago"
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct DisplaySnapshot {
    let label: String
    let temperatureCelsius: Double
    let humidityPercent: Double?
    let batteryPercent: Int?
    let rssi: Int?
    let date: Date
    let isAggregate: Bool

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
