import AppKit
import Foundation
import Testing
@testable import BirdMenu

@Suite struct InkbirdUIAndChartTests {
    @Test @MainActor func menuDoesNotAutomaticallyReenableBusyActions() {
        let menu = StatusMenuController.makeMenu()
        let item = NSMenuItem(title: "Fetch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "")
        item.target = NSApplication.shared
        item.isEnabled = false
        menu.addItem(item)

        menu.update()

        #expect(!menu.autoenablesItems)
        #expect(!item.isEnabled)
    }

    @Test @MainActor func emptyHistoryExplainsNextStepAndDisablesGeneration() async throws {
        _ = NSApplication.shared
        let root = try makeHistoryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = HistoryChartWindowController(historyRoot: root)
        let content = try #require(controller.window?.contentView)
        controller.refreshHistorySensors()
        let status = try #require(descendants(content).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "historyChartStatus" })
        for _ in 0..<100 where status.stringValue != AppText.noSavedHistory {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(status.stringValue == AppText.noSavedHistory)
        let generate = try #require(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == AppText.generateHistoryChart })
        #expect(!generate.isEnabled)
        #expect(descendants(content).compactMap { $0 as? NSPopUpButton }.allSatisfy { !$0.isEnabled })
    }

    @Test @MainActor func historyGraphFlowProducesFileAndOffersReveal() async throws {
        _ = NSApplication.shared
        let root = try makeHistoryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        _ = try writeCSV(root, name: "sample-AAAAAA", sensorID: "11111111-1111-1111-1111-111111AAAAAA", rows: ["\(timestamp),0,23,45"])
        let controller = HistoryChartWindowController(historyRoot: root)
        let content = try #require(controller.window?.contentView)
        let views = descendants(content)
        let generate = try #require(views.compactMap { $0 as? NSButton }.first { $0.keyEquivalent == "\r" })
        let reveal = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == AppText.showInFinder })
        controller.refreshHistorySensors()
        for _ in 0..<100 where !generate.isEnabled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(generate.isEnabled)
        generate.performClick(nil)
        #expect(!generate.isEnabled)
        for _ in 0..<200 where reveal.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!reveal.isHidden)
        #expect(generate.isEnabled)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(files.contains { $0.pathExtension == "png" })
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @Test func duplicateRequestsAndUnrelatedCompletionsDoNotClearBusyState() throws {
        var state = HistoryUIRequestState()
        let firstRequest = state.begin()
        let first = try #require(firstRequest)
        let duplicateRequest = state.begin()
        #expect(duplicateRequest == nil)
        let unrelatedFinished = state.finish(UUID())
        #expect(!unrelatedFinished)
        #expect(state.isFetching)
        #expect(state.accepts(first))
        let firstFinished = state.finish(first)
        #expect(firstFinished)
        #expect(!state.accepts(first))

        let secondRequest = state.begin()
        let second = try #require(secondRequest)
        let staleFinished = state.finish(first)
        #expect(!staleFinished)
        #expect(!state.accepts(first))
        #expect(state.accepts(second))
        #expect(state.isFetching)
        let secondFinished = state.finish(second)
        #expect(secondFinished)
    }

    @Test func quitWhileCancellingWaitsForOriginalCompletion() throws {
        var state = HistoryUIRequestState()
        let startedRequest = state.begin()
        let request = try #require(startedRequest)
        let cancellationRequested = state.requestCancellation()
        #expect(cancellationRequested)
        let cancellationRequestedAgain = state.requestCancellation(forQuit: true)
        #expect(!cancellationRequestedAgain)
        #expect(state.pendingQuit)
        #expect(state.isFetching)
        #expect(state.cancellationRequested)
        let finished = state.finish(request)
        #expect(finished)
        #expect(state.pendingQuit)
        #expect(!state.isFetching)
        let requestAfterQuit = state.begin()
        #expect(requestAfterQuit == nil)
    }

    @Test func cancellationWithoutQuitAllowsAnotherRequestAfterCompletion() throws {
        var state = HistoryUIRequestState()
        let idleCancellation = state.requestCancellation(forQuit: true)
        #expect(!idleCancellation)
        #expect(!state.pendingQuit)
        let startedRequest = state.begin()
        let request = try #require(startedRequest)
        let cancellationRequested = state.requestCancellation()
        #expect(cancellationRequested)
        let finished = state.finish(request)
        #expect(finished)
        #expect(!state.cancellationRequested)
        let requestAfterCancellation = state.begin()
        #expect(requestAfterCancellation != nil)
    }

    @Test func failedPartialSaveVetoesQuitAndPreservesEarlierSnapshotDetails() throws {
        let earlierPath = "/earlier-snapshot/raw-history.json"
        let error = HistoryFetchError.failureDumpFailed(reason: "Disk full", rawPath: earlierPath)
        var state = HistoryUIRequestState()
        let startedRequest = state.begin()
        let request = try #require(startedRequest)
        let cancellationRequested = state.requestCancellation(forQuit: true)
        #expect(cancellationRequested)
        let prematureDecision = state.resolvePendingQuit(for: .failure(error))
        #expect(prematureDecision == nil)
        #expect(state.pendingQuit)

        let finished = state.finish(request)
        #expect(finished)
        let shouldTerminate = state.resolvePendingQuit(for: .failure(error))
        #expect(shouldTerminate == false)
        #expect(!state.pendingQuit)
        #expect(!state.isFetching)
        #expect(!state.cancellationRequested)
        #expect(error.localizedDescription.contains("Disk full"))
        #expect(error.localizedDescription.contains(earlierPath))
        let nextRequest = state.begin()
        #expect(nextRequest != nil)
    }

    @Test func cancelledOrSavedPartialHistoryAllowsSeamlessQuit() throws {
        let errors: [HistoryFetchError] = [
            .cancelled,
            .partialDumpSaved(reason: "Cancelled", rawPath: "/saved/raw-history.json", csvPath: nil)
        ]
        for error in errors {
            var state = try completedPendingQuit()
            let shouldTerminate = state.resolvePendingQuit(for: .failure(error))
            #expect(shouldTerminate == true)
            #expect(state.pendingQuit)
            #expect(!state.isFetching)
        }
    }

    @Test func successfulHistorySaveAllowsPendingQuit() throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let result = InkbirdHistoryResult(
            folderURL: folder,
            rawURL: folder.appendingPathComponent("raw-history.json"),
            csvURL: nil,
            recordCount: 0,
            packetCount: 1,
            warnings: []
        )
        var state = try completedPendingQuit()
        let shouldTerminate = state.resolvePendingQuit(for: .success(result))
        #expect(shouldTerminate == true)
        #expect(state.pendingQuit)
    }

    @Test func unexpectedFailureAlsoVetoesPendingQuit() throws {
        var state = try completedPendingQuit()
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        let shouldTerminate = state.resolvePendingQuit(for: .failure(error))
        #expect(shouldTerminate == false)
        #expect(!state.pendingQuit)
        let repeatedDecision = state.resolvePendingQuit(for: .failure(error))
        #expect(repeatedDecision == nil)
    }

    @Test func unrelatedAdvertisementPreservesMissingSelectionAndHistoryTarget() throws {
        let selected = UUID()
        var state = SensorDisplayState(selectedPeripheralID: selected)
        state.receive(reading(id: UUID(), date: Date(), temperature: 30))
        #expect(state.selectedPeripheralID == selected)
        #expect(state.snapshot == nil)
        #expect(state.historyTargetReading == nil)

        let expected = reading(id: selected, date: Date(), temperature: 20)
        state.receive(expected)
        #expect(state.selectedPeripheralID == selected)
        #expect(state.historyTargetReading == expected)
        #expect(try #require(state.snapshot).temperatureCelsius == 20)
    }

    @Test func averageFreshnessUsesOldestIncludedSensor() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        var state = SensorDisplayState()
        let staleSensor = UUID()
        state.receive(reading(id: staleSensor, date: now.addingTimeInterval(-601), temperature: 10, humidity: 40))
        state.receive(reading(id: UUID(), date: now, temperature: 30, humidity: 60))
        let snapshot = try #require(state.snapshot)
        #expect(snapshot.isAggregate)
        #expect(snapshot.temperatureCelsius == 20)
        #expect(snapshot.humidityPercent == 50)
        #expect(snapshot.date == now.addingTimeInterval(-601))
        #expect(snapshot.freshness(at: now) == .missing)
        #expect(state.historyTargetReading == nil)

        state.receive(reading(id: staleSensor, date: now.addingTimeInterval(-121), temperature: 10))
        #expect(try #require(state.snapshot).freshness(at: now) == .stale)
        state.receive(reading(id: staleSensor, date: now.addingTimeInterval(-120), temperature: 10))
        #expect(try #require(state.snapshot).freshness(at: now) == .fresh)
    }

    @Test func selectionDoesNotInheritAnotherSensorsStaleness() throws {
        let now = Date()
        let selected = UUID()
        var state = SensorDisplayState(selectedPeripheralID: selected)
        state.receive(reading(id: selected, date: now, temperature: 21))
        state.receive(reading(id: UUID(), date: now.addingTimeInterval(-1_000), temperature: 99))
        let snapshot = try #require(state.snapshot)
        #expect(!snapshot.isAggregate)
        #expect(snapshot.temperatureCelsius == 21)
        #expect(snapshot.freshness(at: now) == .fresh)
    }

    @Test func successfulZeroRecordsDifferFromUndecodableRaw() {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var result = InkbirdHistoryResult(
            folderURL: folder,
            rawURL: folder.appendingPathComponent("raw-history.json"),
            csvURL: nil,
            recordCount: 0,
            packetCount: 1,
            warnings: []
        )
        #expect(HistoryUIRequestState.isEmptySuccess(result))
        result.isComplete = false
        #expect(!HistoryUIRequestState.isEmptySuccess(result))
    }

    @Test func progressShowsCountsAndElapsedTime() {
        let text = AppText.historyProgress(HistoryFetchProgress(
            phase: .recovering,
            receivedRecords: 90,
            expectedRecords: 180,
            receivedBlocks: 2,
            expectedBlocks: 4,
            elapsed: 125
        ))
        #expect(text.contains("90/180"))
        #expect(text.contains("2/4"))
        #expect(text.contains("2:05"))
    }

    @Test func chartPickerRequiresChoiceForMultipleSensorsAndRetainsIt() {
        let first = InkbirdHistoryChartSensor(id: UUID().uuidString)
        let second = InkbirdHistoryChartSensor(id: UUID().uuidString)
        #expect(HistoryChartWindowController.chartSensorSelection(previousID: nil, sensors: [first, second]) == nil)
        #expect(HistoryChartWindowController.chartSensorSelection(previousID: second.id, sensors: [first, second]) == second.id)
        #expect(HistoryChartWindowController.chartSensorSelection(previousID: nil, sensors: [first]) == first.id)
        #expect(HistoryChartWindowController.chartSensorSelection(previousID: first.id, sensors: []) == nil)
    }

    @Test func fullSensorIDsSeparateOverlappingAndDisjointHistories() throws {
        try withHistoryFolder { folder in
            let firstID = "11111111-1111-1111-1111-111111AAAAAA"
            let secondID = "22222222-2222-2222-2222-222222AAAAAA"
            let first = try writeCSV(folder, name: "2026-09-16T01-00-00Z-Sensor-AAAAAA", sensorID: firstID, rows: [
                "2026-09-16T01:00:00Z,0,10,40",
                "2026-09-16T02:00:00Z,1,11,41"
            ])
            let repeated = try writeCSV(folder, name: "2026-09-16T02-00-00Z-Sensor-AAAAAA", sensorID: firstID, rows: [
                "2026-09-16T01:00:00Z,0,12,42"
            ])
            let second = try writeCSV(folder, name: "2026-09-16T03-00-00Z-Sensor-AAAAAA", sensorID: secondID, rows: [
                "2026-09-16T01:00:00Z,0,30,60",
                "2026-09-16T03:00:00Z,1,31,61",
                "2026-09-16T04:00:00Z,2,32,62"
            ])
            let sensors = try InkbirdHistoryChartRenderer.availableSensors(in: folder)
            #expect(Set(sensors.map(\.id)) == Set([firstID, secondID]))
            #expect(throws: InkbirdHistoryChartGenerationError.sensorSelectionRequired) {
                try InkbirdHistoryChartRenderer.writePNGForLocalDay(containing: chartDay, historyRoot: folder, timeZone: utc)
            }
            let firstResult = try InkbirdHistoryChartRenderer.writePNGForLocalDay(
                containing: chartDay, historyRoot: folder, timeZone: utc, sensorID: firstID
            )
            let secondResult = try InkbirdHistoryChartRenderer.writePNGForLocalDay(
                containing: chartDay, historyRoot: folder, timeZone: utc, sensorID: secondID
            )
            #expect(firstResult.recordCount == 2)
            #expect(secondResult.recordCount == 3)
            #expect(Set(firstResult.csvURLs) == Set([first, repeated]))
            #expect(secondResult.csvURLs == [second])
            #expect(firstResult.pngURL != secondResult.pngURL)
            #expect(firstResult.pngURL.lastPathComponent.contains(firstID))
            #expect(secondResult.pngURL.lastPathComponent.contains(secondID))
            #expect(firstResult.sensor.id == firstID)
            #expect(secondResult.sensor.id == secondID)
            let firstPNG = try Data(contentsOf: firstResult.pngURL)
            let secondPNG = try Data(contentsOf: secondResult.pngURL)
            #expect(firstPNG.starts(with: [0x89, 0x50, 0x4e, 0x47]))
            #expect(secondPNG.starts(with: [0x89, 0x50, 0x4e, 0x47]))
            #expect(firstPNG != secondPNG)
        }
    }

    @Test func legacySingleSensorKeepsExistingFilenameAndDeduplicatesWithinSensor() throws {
        try withHistoryFolder { folder in
            _ = try writeCSV(folder, name: "2026-09-16T01-00-00Z-Sensor-aaaaaa", rows: ["2026-09-16T01:00:00Z,0,10,40"])
            _ = try writeCSV(folder, name: "2026-09-16T02-00-00Z-Sensor-AAAAAA", rows: ["2026-09-16T01:00:00Z,0,11,41"])
            let result = try InkbirdHistoryChartRenderer.writePNGForLocalDay(
                containing: chartDay, historyRoot: folder, timeZone: utc
            )
            #expect(result.pngURL.lastPathComponent == "history_20260916.png")
            #expect(result.sensor.id == "legacy:AAAAAA")
            #expect(result.recordCount == 1)
            #expect(result.csvURLs.count == 2)
        }
    }

    @Test func chartLoadingAndRenderingAcceptSendableBackgroundBoundary() async throws {
        let folder = try makeHistoryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try writeCSV(folder, name: "first-Sensor-AAAAAA", rows: ["2026-09-16T01:00:00Z,0,10,40"])
        let date = chartDay
        let timeZone = utc
        let result = try await Task.detached {
            let sensors = try InkbirdHistoryChartRenderer.availableSensors(in: folder)
            return try InkbirdHistoryChartRenderer.writePNGForLocalDay(
                containing: date, historyRoot: folder, timeZone: timeZone, sensorID: sensors.first?.id
            )
        }.value
        #expect(result.recordCount == 1)
        #expect(FileManager.default.fileExists(atPath: result.pngURL.path))
    }

    @Test func legacySuffixMapsOnlyToAnUnambiguousFullSensorID() throws {
        try withHistoryFolder { folder in
            let firstID = "11111111-1111-1111-1111-111111AAAAAA"
            _ = try writeCSV(folder, name: "first-Sensor-AAAAAA", sensorID: firstID, rows: ["2026-09-16T01:00:00Z,0,10,40"])
            _ = try writeCSV(folder, name: "legacy-Sensor-AAAAAA", rows: ["2026-09-16T02:00:00Z,0,11,41"])
            #expect(try InkbirdHistoryChartRenderer.availableSensors(in: folder).map(\.id) == [firstID])

            _ = try writeCSV(folder, name: "second-Sensor-AAAAAA", sensorID: "22222222-2222-2222-2222-222222AAAAAA", rows: ["2026-09-16T03:00:00Z,0,30,60"])
            #expect(throws: InkbirdHistoryChartGenerationError.ambiguousSensorIdentity("AAAAAA")) {
                try InkbirdHistoryChartRenderer.availableSensors(in: folder)
            }
        }
    }

    @Test func distinctLegacySensorsCannotBeMergedByDefault() throws {
        try withHistoryFolder { folder in
            _ = try writeCSV(folder, name: "first-Sensor-AAAAAA", rows: ["2026-09-16T01:00:00Z,0,10,40"])
            _ = try writeCSV(folder, name: "second-Sensor-BBBBBB", rows: ["2026-09-16T02:00:00Z,0,30,60"])
            #expect(try InkbirdHistoryChartRenderer.availableSensors(in: folder).count == 2)
            #expect(throws: InkbirdHistoryChartGenerationError.sensorSelectionRequired) {
                try InkbirdHistoryChartRenderer.writePNGForLocalDay(containing: chartDay, historyRoot: folder, timeZone: utc)
            }
        }
    }

    @Test func rawFullIdentityTakesPrecedenceOverFolderSuffix() throws {
        try withHistoryFolder { folder in
            let id = "11111111-1111-1111-1111-111111BBBBBB"
            _ = try writeCSV(folder, name: "first-Sensor-AAAAAA", sensorID: id, rows: ["2026-09-16T01:00:00Z,0,10,40"])
            #expect(try InkbirdHistoryChartRenderer.availableSensors(in: folder).map(\.id) == [id])
        }
    }

    @Test func unknownAndMalformedIdentitiesAreNotSilentlyGrouped() throws {
        try withHistoryFolder { folder in
            let csvURL = try writeCSV(folder, name: "unidentified", rows: ["2026-09-16T01:00:00Z,0,10,40"])
            #expect(throws: InkbirdHistoryChartGenerationError.unknownSensorIdentity(csvURL)) {
                try InkbirdHistoryChartRenderer.availableSensors(in: folder)
            }
            try "not JSON".write(to: csvURL.deletingLastPathComponent().appendingPathComponent("raw-history.json"), atomically: true, encoding: .utf8)
            #expect(throws: DecodingError.self) {
                try InkbirdHistoryChartRenderer.availableSensors(in: folder)
            }
        }
    }

    @Test func legacySuffixValidationRejectsUnrelatedNames() {
        #expect(InkbirdHistoryChartRenderer.legacySensorSuffix(in: "2026-09-16T01-00-00Z-Sensor-ab12cd") == "AB12CD")
        #expect(InkbirdHistoryChartRenderer.legacySensorSuffix(in: "2026-09-16T01-00-00Z-\(UUID().uuidString)-Sensor-AB12CD") == "AB12CD")
        #expect(InkbirdHistoryChartRenderer.legacySensorSuffix(in: "2026-Sensor-GGGGGG") == nil)
        #expect(InkbirdHistoryChartRenderer.legacySensorSuffix(in: "2026-Sensor-AAAAAA-extra") == nil)
        #expect(InkbirdHistoryChartRenderer.legacySensorSuffix(in: "2026-Sensor-AAAA") == nil)
    }

    private var utc: TimeZone { TimeZone(secondsFromGMT: 0)! }
    private var chartDay: Date { Date(timeIntervalSince1970: 1_789_516_800) }

    private func completedPendingQuit() throws -> HistoryUIRequestState {
        var state = HistoryUIRequestState()
        let startedRequest = state.begin()
        let request = try #require(startedRequest)
        let cancellationRequested = state.requestCancellation(forQuit: true)
        #expect(cancellationRequested)
        let finished = state.finish(request)
        #expect(finished)
        return state
    }

    private func reading(id: UUID, date: Date, temperature: Double, humidity: Double? = 50) -> InkbirdReading {
        InkbirdReading(
            model: "ITH-11-B", deviceName: "Sensor", peripheralID: id,
            temperatureCelsius: temperature, humidityPercent: humidity,
            batteryPercent: 90, rssi: -60, date: date, advertisementHex: ""
        )
    }

    private func withHistoryFolder(_ body: (URL) throws -> Void) throws {
        let folder = try makeHistoryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    private func makeHistoryFolder() throws -> URL {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = projectRoot
            .appendingPathComponent(".build/ui-chart-fixtures/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeCSV(_ root: URL, name: String, sensorID: String? = nil, rows: [String]) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let csvURL = folder.appendingPathComponent("history.csv")
        try (["timestamp,index,temperature_c,humidity_percent"] + rows).joined(separator: "\n")
            .write(to: csvURL, atomically: true, encoding: .utf8)
        if let sensorID {
            try JSONEncoder().encode(["peripheralID": sensorID])
                .write(to: folder.appendingPathComponent("raw-history.json"), options: .atomic)
        }
        return csvURL
    }
}
