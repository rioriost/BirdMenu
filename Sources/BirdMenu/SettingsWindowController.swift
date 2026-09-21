import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onChange: (() -> Void)?

    private let generalHeading = NSTextField(labelWithString: "")
    private let diagnosticsHeading = NSTextField(labelWithString: "")
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let temperatureUnitLabel = NSTextField(labelWithString: "")
    private let temperatureUnitControl = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let debugLoggingCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let diagnosticsDescription = NSTextField(wrappingLabelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 290),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureContent()
        reload()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func reload() {
        window?.title = AppText.settingsTitle
        generalHeading.stringValue = AppText.generalSettings
        diagnosticsHeading.stringValue = AppText.diagnostics
        diagnosticsDescription.stringValue = AppText.debugLoggingDescription
        launchAtLoginCheckbox.title = AppText.launchAtLogin
        launchAtLoginCheckbox.state = LoginItemManager.isEnabled ? .on : .off
        temperatureUnitLabel.stringValue = AppText.temperatureUnit
        temperatureUnitControl.setLabel("\(AppText.celsius) (°C)", forSegment: 0)
        temperatureUnitControl.setLabel("\(AppText.fahrenheit) (°F)", forSegment: 1)
        temperatureUnitControl.selectedSegment = TemperatureUnit.current == .celsius ? 0 : 1
        temperatureUnitControl.setAccessibilityLabel(AppText.temperatureUnit)
        debugLoggingCheckbox.title = AppText.debugLogging
        debugLoggingCheckbox.state = BirdMenuLog.isDebugLoggingEnabled ? .on : .off
        debugLoggingCheckbox.setAccessibilityHelp(AppText.debugLoggingDescription)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)
        temperatureUnitControl.target = self
        temperatureUnitControl.action = #selector(changeTemperatureUnit)
        debugLoggingCheckbox.target = self
        debugLoggingCheckbox.action = #selector(toggleDebugLogging)
        generalHeading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        diagnosticsHeading.font = generalHeading.font
        diagnosticsDescription.textColor = .secondaryLabelColor
        diagnosticsDescription.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let unitRow = NSStackView(views: [temperatureUnitLabel, temperatureUnitControl])
        unitRow.orientation = .horizontal
        unitRow.alignment = .centerY
        unitRow.spacing = 16
        let divider = NSBox()
        divider.boxType = .separator
        let stack = NSStackView(views: [generalHeading, launchAtLoginCheckbox, unitRow, divider, diagnosticsHeading, debugLoggingCheckbox, diagnosticsDescription])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(20, after: unitRow)
        stack.setCustomSpacing(20, after: divider)
        stack.setCustomSpacing(6, after: debugLoggingCheckbox)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            diagnosticsDescription.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window?.initialFirstResponder = launchAtLoginCheckbox
        launchAtLoginCheckbox.nextKeyView = temperatureUnitControl
        temperatureUnitControl.nextKeyView = debugLoggingCheckbox
        debugLoggingCheckbox.nextKeyView = launchAtLoginCheckbox
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItemManager.setEnabled(launchAtLoginCheckbox.state == .on)
        } catch {
            launchAtLoginCheckbox.state = LoginItemManager.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = AppText.settingsTitle
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: AppText.ok)
            if let window { alert.beginSheetModal(for: window) }
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
}
