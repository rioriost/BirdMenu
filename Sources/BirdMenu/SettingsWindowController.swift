import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onChange: (() -> Void)?

    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let temperatureUnitLabel = NSTextField(labelWithString: "")
    private let temperatureUnitControl = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let debugLoggingCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let historyChartDateLabel = NSTextField(labelWithString: "")
    private let historyChartDatePicker = NSDatePicker()
    private let historyChartSensorLabel = NSTextField(labelWithString: "")
    private let historyChartSensorPicker = NSPopUpButton()
    private let historyChartStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let generateHistoryChartButton = NSButton(title: "", target: nil, action: nil)
    private var chartSensors: [InkbirdHistoryChartSensor] = []
    private var chartTask: Task<Void, Never>?
    private var isGeneratingChart = false
    private var isLoadingSensors = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureContent()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        reload()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        refreshHistorySensors()
    }

    func reload() {
        window?.title = AppText.settingsTitle
        launchAtLoginCheckbox.title = AppText.launchAtLogin
        launchAtLoginCheckbox.state = LoginItemManager.isEnabled ? .on : .off
        temperatureUnitLabel.stringValue = AppText.temperatureUnit
        temperatureUnitControl.setLabel(AppText.celsius, forSegment: 0)
        temperatureUnitControl.setLabel(AppText.fahrenheit, forSegment: 1)
        temperatureUnitControl.selectedSegment = TemperatureUnit.current == .celsius ? 0 : 1
        debugLoggingCheckbox.title = AppText.debugLogging
        debugLoggingCheckbox.state = BirdMenuLog.isDebugLoggingEnabled ? .on : .off
        historyChartDateLabel.stringValue = AppText.historyChartDate
        historyChartSensorLabel.stringValue = AppText.historyChartSensor
        historyChartSensorPicker.item(at: 0)?.title = AppText.selectHistorySensor
        generateHistoryChartButton.title = isGeneratingChart ? AppText.generatingHistoryChart : AppText.generateHistoryChart
    }

    func windowWillClose(_ notification: Notification) {
        chartTask?.cancel()
        chartTask = nil
        onClose?()
    }

    private func configureContent() {
        guard let contentView = window?.contentView else {
            return
        }

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)

        temperatureUnitControl.target = self
        temperatureUnitControl.action = #selector(changeTemperatureUnit)
        temperatureUnitControl.setWidth(120, forSegment: 0)
        temperatureUnitControl.setWidth(120, forSegment: 1)

        debugLoggingCheckbox.target = self
        debugLoggingCheckbox.action = #selector(toggleDebugLogging)

        historyChartDatePicker.datePickerElements = [.yearMonthDay]
        historyChartDatePicker.datePickerMode = .single
        historyChartDatePicker.datePickerStyle = .textFieldAndStepper
        historyChartDatePicker.dateValue = Date()

        generateHistoryChartButton.target = self
        generateHistoryChartButton.action = #selector(generateHistoryChart)
        generateHistoryChartButton.isEnabled = false
        historyChartSensorPicker.target = self
        historyChartSensorPicker.action = #selector(changeHistorySensor)
        historyChartSensorPicker.addItem(withTitle: AppText.selectHistorySensor)
        historyChartStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        historyChartStatusLabel.textColor = .secondaryLabelColor

        let unitRow = NSStackView(views: [temperatureUnitLabel, temperatureUnitControl])
        unitRow.orientation = .horizontal
        unitRow.alignment = .centerY
        unitRow.distribution = .gravityAreas
        unitRow.spacing = 14

        let historyChartRow = NSStackView(views: [historyChartDateLabel, historyChartDatePicker, generateHistoryChartButton])
        historyChartRow.orientation = .horizontal
        historyChartRow.alignment = .centerY
        historyChartRow.distribution = .gravityAreas
        historyChartRow.spacing = 12

        let sensorRow = NSStackView(views: [historyChartSensorLabel, historyChartSensorPicker])
        sensorRow.orientation = .horizontal
        sensorRow.alignment = .centerY
        sensorRow.spacing = 12

        let stack = NSStackView(views: [launchAtLoginCheckbox, unitRow, debugLoggingCheckbox, sensorRow, historyChartRow, historyChartStatusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 26),
            historyChartSensorPicker.widthAnchor.constraint(equalToConstant: 390),
            historyChartStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 552)
        ])
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItemManager.setEnabled(launchAtLoginCheckbox.state == .on)
        } catch {
            launchAtLoginCheckbox.state = LoginItemManager.isEnabled ? .on : .off
            showAlert(title: AppText.settingsTitle, message: error.localizedDescription)
        }
        onChange?()
    }

    @objc private func changeTemperatureUnit() {
        TemperatureUnit.current = temperatureUnitControl.selectedSegment == 1 ? .fahrenheit : .celsius
        onChange?()
    }

    @objc private func toggleDebugLogging() {
        BirdMenuLog.isDebugLoggingEnabled = debugLoggingCheckbox.state == .on
        onChange?()
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: AppText.ok)
        guard let window else { return }
        alert.beginSheetModal(for: window)
    }

    @objc private func generateHistoryChart() {
        guard !isGeneratingChart, !isLoadingSensors, let sensorID = selectedChartSensorID else { return }
        let date = historyChartDatePicker.dateValue
        let root = InkbirdHistoryExportWriter.historyRootFolderURL()
        let timeZone = TimeZone.current
        isGeneratingChart = true
        updateChartControls()
        historyChartStatusLabel.stringValue = AppText.generatingHistoryChart
        chartTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try InkbirdHistoryChartRenderer.writePNGForLocalDay(
                        containing: date,
                        historyRoot: root,
                        timeZone: timeZone,
                        sensorID: sensorID
                    )
                }.value
                guard let self, !Task.isCancelled else { return }
                self.isGeneratingChart = false
                self.updateChartControls()
                self.historyChartStatusLabel.stringValue = result.pngURL.lastPathComponent
                self.showAlert(
                    title: AppText.historyChartGeneratedTitle,
                    message: Self.historyChartGeneratedMessage(result),
                    style: .informational
                )
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isGeneratingChart = false
                self.updateChartControls()
                self.historyChartStatusLabel.stringValue = error.localizedDescription
                self.showAlert(title: AppText.historyChartGenerationFailedTitle, message: error.localizedDescription)
            }
        }
    }

    private var selectedChartSensorID: String? {
        historyChartSensorPicker.selectedItem?.representedObject as? String
    }

    @objc private func changeHistorySensor() {
        updateChartControls()
    }

    private func updateChartControls() {
        historyChartSensorPicker.isEnabled = !isGeneratingChart && !isLoadingSensors && !chartSensors.isEmpty
        historyChartDatePicker.isEnabled = !isGeneratingChart
        generateHistoryChartButton.isEnabled = !isGeneratingChart && !isLoadingSensors && selectedChartSensorID != nil
        generateHistoryChartButton.title = isGeneratingChart ? AppText.generatingHistoryChart : AppText.generateHistoryChart
    }

    func refreshHistorySensors() {
        guard !isGeneratingChart else { return }
        chartTask?.cancel()
        isLoadingSensors = true
        let previousID = selectedChartSensorID
        let root = InkbirdHistoryExportWriter.historyRootFolderURL()
        historyChartSensorPicker.isEnabled = false
        generateHistoryChartButton.isEnabled = false
        historyChartStatusLabel.stringValue = AppText.loadingHistorySensors
        chartTask = Task { [weak self] in
            do {
                let sensors = try await Task.detached(priority: .userInitiated) {
                    try InkbirdHistoryChartRenderer.availableSensors(in: root)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.isLoadingSensors = false
                self.chartSensors = sensors
                self.historyChartSensorPicker.removeAllItems()
                self.historyChartSensorPicker.addItem(withTitle: AppText.selectHistorySensor)
                for sensor in sensors {
                    self.historyChartSensorPicker.addItem(withTitle: sensor.label)
                    self.historyChartSensorPicker.lastItem?.representedObject = sensor.id
                }
                let selection = Self.chartSensorSelection(previousID: previousID, sensors: sensors)
                if let index = sensors.firstIndex(where: { $0.id == selection }) {
                    self.historyChartSensorPicker.selectItem(at: index + 1)
                }
                self.historyChartStatusLabel.stringValue = sensors.count > 1 ? AppText.selectHistorySensor : ""
                self.updateChartControls()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoadingSensors = false
                self.chartSensors = []
                self.historyChartSensorPicker.removeAllItems()
                self.historyChartSensorPicker.addItem(withTitle: AppText.selectHistorySensor)
                self.historyChartStatusLabel.stringValue = error.localizedDescription
                self.updateChartControls()
            }
        }
    }

    nonisolated static func chartSensorSelection(previousID: String?, sensors: [InkbirdHistoryChartSensor]) -> String? {
        if let previousID, sensors.contains(where: { $0.id == previousID }) { return previousID }
        return sensors.count == 1 ? sensors.first?.id : nil
    }

    private static func historyChartGeneratedMessage(_ result: InkbirdHistoryChartGenerationResult) -> String {
        if AppText.isJapanese {
            return "\(result.sensor.label)\n\(result.recordCount)件のCSVレコードからPNGを生成しました。\n\nPNG: \(result.pngURL.path)\nCSV: \(result.csvURLs.count)ファイル"
        }
        return "\(result.sensor.label)\nGenerated a PNG from \(result.recordCount) CSV records.\n\nPNG: \(result.pngURL.path)\nCSV: \(result.csvURLs.count) files"
    }
}
