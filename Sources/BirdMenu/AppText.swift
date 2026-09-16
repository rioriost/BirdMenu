import Foundation

enum AppText {
    static var isJapanese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("ja") == true
    }

    static func localized(en: String, ja: String) -> String {
        isJapanese ? ja : en
    }

    static var status: String { localized(en: "Status", ja: "状態") }
    static var starting: String { localized(en: "Starting", ja: "起動中") }
    static var display: String { localized(en: "Display", ja: "表示") }
    static var allSensors: String { localized(en: "All Sensors", ja: "すべてのセンサー") }
    static var missingSensor: String { localized(en: "Missing Sensor", ja: "見つからないセンサー") }
    static var sensor: String { localized(en: "Sensor", ja: "センサー") }
    static var temperature: String { localized(en: "Temperature", ja: "温度") }
    static var humidity: String { localized(en: "Humidity", ja: "湿度") }
    static var battery: String { localized(en: "Battery", ja: "バッテリー") }
    static var signal: String { localized(en: "Signal", ja: "信号") }
    static var lastUpdate: String { localized(en: "Last update", ja: "最終更新") }
    static var oldestUpdate: String { localized(en: "Oldest update in average", ja: "平均に含む最も古い更新") }
    static var history: String { localized(en: "History", ja: "履歴") }
    static var notFetched: String { localized(en: "Not fetched", ja: "未取得") }
    static var fetching: String { localized(en: "Fetching...", ja: "取得中...") }
    static var rawOnly: String { localized(en: "raw only", ja: "生データのみ") }
    static var failed: String { localized(en: "failed", ja: "失敗") }
    static var rescan: String { localized(en: "Rescan", ja: "再スキャン") }
    static var fetchSensorHistory: String { localized(en: "Fetch Sensor History", ja: "センサー履歴を取得") }
    static var cancelHistory: String { localized(en: "Cancel History Fetch", ja: "履歴取得をキャンセル") }
    static var cancellingHistory: String { localized(en: "Cancelling; saving received data...", ja: "キャンセル中・受信済みデータを保存中...") }
    static var noNewHistory: String { localized(en: "No new history records", ja: "新しい履歴はありません") }
    static var quitDuringHistoryTitle: String { localized(en: "Cancel history fetch and quit?", ja: "履歴取得をキャンセルして終了しますか？") }
    static var quitDuringHistoryMessage: String {
        localized(
            en: "BirdMenu will save received data before quitting. Keep the app running until saving finishes.",
            ja: "受信済みデータを保存してから終了します。保存が終わるまでアプリを強制終了しないでください。"
        )
    }
    static var cancelHistoryAndQuit: String { localized(en: "Save and Quit", ja: "保存して終了") }
    static var keepRunning: String { localized(en: "Keep Running", ja: "終了しない") }
    static var openHistoryFolder: String { localized(en: "Open History Folder", ja: "履歴フォルダを開く") }
    static var about: String { localized(en: "About BirdMenu...", ja: "BirdMenuについて...") }
    static var settings: String { localized(en: "Settings...", ja: "設定...") }
    static var quit: String { localized(en: "Quit BirdMenu", ja: "BirdMenuを終了") }
    static var ok: String { localized(en: "OK", ja: "OK") }

    static var scanning: String { localized(en: "Scanning for compatible sensors", ja: "対応センサーをスキャン中") }
    static var selectedSensorMissing: String { localized(en: "Selected sensor has not been seen", ja: "選択したセンサーはまだ検出されていません") }
    static var receivingBLE: String { localized(en: "Receiving BLE advertisements", ja: "BLE広告を受信中") }
    static var staleBLE: String { localized(en: "Last BLE advertisement is stale", ja: "最後のBLE広告が古くなっています") }
    static var noRecentBLE: String { localized(en: "No recent BLE advertisements", ja: "最近のBLE広告がありません") }
    static var someSensorsStaleBLE: String { localized(en: "Some sensors in the average have stale readings", ja: "平均に含む一部のセンサーの測定値が古くなっています") }
    static var someSensorsNoRecentBLE: String { localized(en: "Some sensors in the average have no recent BLE advertisements", ja: "平均に含む一部のセンサーの最近のBLE広告がありません") }

    static var noSensorSelectedTitle: String { localized(en: "No Sensor Selected", ja: "センサーが選択されていません") }
    static var noSensorSelectedMessage: String {
        localized(
            en: "Select a specific sensor, or wait until exactly one compatible sensor is detected.",
            ja: "特定のセンサーを選択するか、対応センサーが1台だけ検出されるまで待ってください。"
        )
    }
    static var historyFetchCompleteTitle: String { localized(en: "History Fetch Complete", ja: "履歴の取得が完了しました") }
    static var historyRawDumpSavedTitle: String { localized(en: "History Raw Dump Saved", ja: "履歴の生データを保存しました") }
    static var historyFetchFailedTitle: String { localized(en: "History Fetch Failed", ja: "履歴の取得に失敗しました") }
    static var couldNotOpenHistoryFolderTitle: String { localized(en: "Could Not Open History Folder", ja: "履歴フォルダを開けませんでした") }

    static var settingsTitle: String { localized(en: "BirdMenu Settings", ja: "BirdMenu設定") }
    static var launchAtLogin: String { localized(en: "Launch at login", ja: "ログイン時に起動") }
    static var temperatureUnit: String { localized(en: "Temperature unit", ja: "温度単位") }
    static var celsius: String { localized(en: "Celsius", ja: "摂氏") }
    static var fahrenheit: String { localized(en: "Fahrenheit", ja: "華氏") }
    static var debugLogging: String { localized(en: "Debug logging", ja: "デバッグログ") }
    static var historyChartDate: String { localized(en: "History chart date", ja: "履歴グラフの日付") }
    static var historyChartSensor: String { localized(en: "History sensor", ja: "履歴センサー") }
    static var selectHistorySensor: String { localized(en: "Select a sensor", ja: "センサーを選択") }
    static var loadingHistorySensors: String { localized(en: "Loading saved sensors...", ja: "保存済みセンサーを読込中...") }
    static var generatingHistoryChart: String { localized(en: "Generating...", ja: "生成中...") }
    static var generateHistoryChart: String { localized(en: "Generate Graph", ja: "グラフを生成") }
    static var historyChartGeneratedTitle: String { localized(en: "History Graph Generated", ja: "履歴グラフを生成しました") }
    static var historyChartGenerationFailedTitle: String { localized(en: "Could Not Generate History Graph", ja: "履歴グラフを生成できませんでした") }

    static var bluetoothOff: String { localized(en: "Bluetooth is off", ja: "Bluetoothがオフです") }
    static var bluetoothUnauthorized: String { localized(en: "Bluetooth access is not allowed", ja: "Bluetoothの使用が許可されていません") }
    static var bluetoothUnsupported: String { localized(en: "This Mac does not support Bluetooth LE", ja: "このMacはBluetooth LEをサポートしていません") }
    static var bluetoothUnknown: String { localized(en: "Could not read Bluetooth state", ja: "Bluetooth状態を取得できません") }

    static func historyProgress(_ progress: HistoryFetchProgress) -> String {
        let phase: String
        switch progress.phase {
        case .connecting: phase = localized(en: "Connecting", ja: "接続中")
        case .discovering: phase = localized(en: "Discovering", ja: "探索中")
        case .receiving: phase = localized(en: "Receiving", ja: "受信中")
        case .recovering: phase = localized(en: "Recovering missing blocks", ja: "欠損ブロックを再受信中")
        case .reconnecting: phase = localized(en: "Reconnecting", ja: "再接続中")
        case .saving: phase = localized(en: "Saving", ja: "保存中")
        case .finalizing: phase = localized(en: "Closing device session", ja: "デバイスのセッションを終了中")
        }
        let records = "\(progress.receivedRecords)/\(progress.expectedRecords.map(String.init) ?? "?")"
        let blocks = "\(progress.receivedBlocks)/\(progress.expectedBlocks.map(String.init) ?? "?")"
        let seconds = Int(max(0, progress.elapsed))
        let elapsed = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return localized(
            en: "\(phase) · \(records) records · \(blocks) blocks · \(elapsed)",
            ja: "\(phase) · \(records)件 · \(blocks)ブロック · \(elapsed)"
        )
    }
}
