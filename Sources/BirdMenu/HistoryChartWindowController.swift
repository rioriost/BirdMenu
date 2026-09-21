import AppKit

@MainActor
final class HistoryChartWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let historyChartDateLabel = NSTextField(labelWithString: "")
    private let historyChartDatePicker = NSDatePicker()
    private let historyChartSensorLabel = NSTextField(labelWithString: "")
    private let historyChartSensorPicker = NSPopUpButton()
    private let historyChartStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let generateHistoryChartButton = NSButton(title: "", target: nil, action: nil)
    private var formGrid: NSGridView?
    private var chartSensors: [InkbirdHistoryChartSensor] = []
    private var chartTask: Task<Void, Never>?
    private var isGeneratingChart = false
    private var isLoadingSensors = false

    private let historyRoot: URL

    init(historyRoot: URL = InkbirdHistoryExportWriter.historyRootFolderURL()) {
        self.historyRoot = historyRoot
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 350),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 350)
        if !window.setFrameUsingName("BirdMenuHistoryChart") { window.center() }
        window.setFrameAutosaveName("BirdMenuHistoryChart")
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
        let wasVisible = window?.isVisible == true
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if !wasVisible { refreshHistorySensors() }
    }

    func reload() {
        window?.title = AppText.historyChartTitle
        descriptionLabel.stringValue = AppText.historyChartDescription
        historyChartDateLabel.stringValue = AppText.historyChartDate
        historyChartSensorLabel.stringValue = AppText.historyChartSensor
        formGrid?.column(at: 0).width = max(historyChartDateLabel.fittingSize.width, historyChartSensorLabel.fittingSize.width)
        historyChartSensorPicker.item(at: 0)?.title = AppText.selectHistorySensor
        historyChartSensorPicker.setAccessibilityLabel(AppText.historyChartSensor)
        historyChartDatePicker.setAccessibilityLabel(AppText.historyChartDate)
        revealChartButton.title = AppText.showInFinder
        updateChartControls()
    }

    func windowWillClose(_ notification: Notification) {
        chartTask?.cancel()
        chartTask = nil
        onClose?()
    }

    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let revealChartButton = NSButton(title: "", target: nil, action: nil)
    private var generatedChartURL: URL?

    private func configureContent() {
        guard let contentView = window?.contentView else { return }
        descriptionLabel.textColor = .secondaryLabelColor
        historyChartDatePicker.datePickerElements = [.yearMonthDay]
        historyChartDatePicker.datePickerMode = .single
        historyChartDatePicker.datePickerStyle = .textFieldAndStepper
        historyChartDatePicker.dateValue = Date()
        historyChartDatePicker.target = self
        historyChartDatePicker.action = #selector(changeHistorySensor)
        historyChartSensorPicker.target = self
        historyChartSensorPicker.action = #selector(changeHistorySensor)
        historyChartSensorPicker.addItem(withTitle: AppText.selectHistorySensor)
        historyChartSensorPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        historyChartSensorPicker.cell?.lineBreakMode = .byTruncatingMiddle
        historyChartStatusLabel.textColor = .secondaryLabelColor
        historyChartStatusLabel.setAccessibilityIdentifier("historyChartStatus")
        generateHistoryChartButton.target = self
        generateHistoryChartButton.action = #selector(generateHistoryChart)
        generateHistoryChartButton.bezelStyle = .rounded
        generateHistoryChartButton.keyEquivalent = "\r"
        revealChartButton.target = self
        revealChartButton.action = #selector(revealChart)
        revealChartButton.bezelStyle = .rounded
        revealChartButton.isHidden = true
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.setAccessibilityLabel(AppText.generatingHistoryChart)

        let form = NSGridView(views: [
            [historyChartSensorLabel, historyChartSensorPicker],
            [historyChartDateLabel, historyChartDatePicker]
        ])
        formGrid = form
        form.columnSpacing = 16
        form.rowSpacing = 16
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill
        form.cell(atColumnIndex: 1, rowIndex: 1).xPlacement = .leading
        form.yPlacement = .center

        let actions = NSStackView(views: [progressIndicator, revealChartButton, generateHistoryChartButton])
        actions.orientation = .horizontal
        actions.spacing = 12
        actions.alignment = .centerY
        let actionContainer = NSView()
        actions.translatesAutoresizingMaskIntoConstraints = false
        actionContainer.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.trailingAnchor.constraint(equalTo: actionContainer.trailingAnchor),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: actionContainer.leadingAnchor),
            actions.topAnchor.constraint(equalTo: actionContainer.topAnchor),
            actions.bottomAnchor.constraint(equalTo: actionContainer.bottomAnchor)
        ])
        let stack = NSStackView(views: [descriptionLabel, form, historyChartStatusLabel, actionContainer])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
            historyChartStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            historyChartStatusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        ])
        window?.initialFirstResponder = historyChartSensorPicker
        historyChartSensorPicker.nextKeyView = historyChartDatePicker
        historyChartDatePicker.nextKeyView = revealChartButton
        revealChartButton.nextKeyView = generateHistoryChartButton
        generateHistoryChartButton.nextKeyView = historyChartSensorPicker
    }

    @objc private func revealChart() {
        guard let generatedChartURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([generatedChartURL])
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
        let root = historyRoot
        let timeZone = TimeZone.current
        generatedChartURL = nil
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
                self.generatedChartURL = result.pngURL
                self.updateChartControls()
                self.historyChartStatusLabel.stringValue = AppText.historyChartSaved(result.recordCount)
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
        generatedChartURL = nil
        historyChartSensorPicker.toolTip = historyChartSensorPicker.titleOfSelectedItem
        historyChartStatusLabel.stringValue = selectedChartSensorID == nil ? AppText.selectHistorySensor : AppText.historyChartReady
        updateChartControls()
    }

    private func updateChartControls() {
        historyChartSensorPicker.isEnabled = !isGeneratingChart && !isLoadingSensors && !chartSensors.isEmpty
        historyChartDatePicker.isEnabled = !isGeneratingChart && !isLoadingSensors && !chartSensors.isEmpty
        revealChartButton.isHidden = generatedChartURL == nil
        progressIndicator.isHidden = !isGeneratingChart && !isLoadingSensors
        if isGeneratingChart || isLoadingSensors {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        generateHistoryChartButton.isEnabled = !isGeneratingChart && !isLoadingSensors && selectedChartSensorID != nil
        generateHistoryChartButton.title = isGeneratingChart ? AppText.generatingHistoryChart : AppText.generateHistoryChart
    }

    func refreshHistorySensors() {
        guard !isGeneratingChart else { return }
        chartTask?.cancel()
        isLoadingSensors = true
        let previousID = selectedChartSensorID
        let root = historyRoot
        generatedChartURL = nil
        updateChartControls()
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
                self.historyChartStatusLabel.stringValue = sensors.isEmpty ? AppText.noSavedHistory : (selection == nil ? AppText.selectHistorySensor : AppText.historyChartReady)
                self.historyChartSensorPicker.toolTip = self.historyChartSensorPicker.titleOfSelectedItem
                self.updateChartControls()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoadingSensors = false
                self.chartSensors = []
                self.historyChartSensorPicker.removeAllItems()
                self.historyChartSensorPicker.addItem(withTitle: AppText.selectHistorySensor)
                switch error {
                case InkbirdHistoryChartGenerationError.noHistoryCSVs, InkbirdHistoryChartGenerationError.noHistoryFolder:
                    self.historyChartStatusLabel.stringValue = AppText.noSavedHistory
                default:
                    self.historyChartStatusLabel.stringValue = error.localizedDescription
                }
                self.updateChartControls()
            }
        }
    }

    nonisolated static func chartSensorSelection(previousID: String?, sensors: [InkbirdHistoryChartSensor]) -> String? {
        if let previousID, sensors.contains(where: { $0.id == previousID }) { return previousID }
        return sensors.count == 1 ? sensors.first?.id : nil
    }

}
