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
    private let generateHistoryChartButton = NSButton(title: "", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 238),
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
        generateHistoryChartButton.title = AppText.generateHistoryChart
    }

    func windowWillClose(_ notification: Notification) {
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

        let stack = NSStackView(views: [launchAtLoginCheckbox, unitRow, debugLoggingCheckbox, historyChartRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 26)
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
        alert.beginSheetModal(for: window!)
    }

    @objc private func generateHistoryChart() {
        do {
            let result = try InkbirdHistoryChartRenderer.writePNGForLocalDay(
                containing: historyChartDatePicker.dateValue,
                historyRoot: InkbirdHistoryExportWriter.historyRootFolderURL()
            )
            showAlert(
                title: AppText.historyChartGeneratedTitle,
                message: Self.historyChartGeneratedMessage(result),
                style: .informational
            )
        } catch {
            showAlert(
                title: AppText.historyChartGenerationFailedTitle,
                message: error.localizedDescription
            )
        }
    }

    private static func historyChartGeneratedMessage(_ result: InkbirdHistoryChartGenerationResult) -> String {
        if AppText.isJapanese {
            return "\(result.recordCount)件のCSVレコードからPNGを生成しました。\n\nPNG: \(result.pngURL.path)\nCSV: \(result.csvURLs.count)ファイル"
        }
        return "Generated a PNG from \(result.recordCount) CSV records.\n\nPNG: \(result.pngURL.path)\nCSV: \(result.csvURLs.count) files"
    }
}
