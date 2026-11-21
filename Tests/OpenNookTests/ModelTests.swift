import XCTest
@testable import OpenNook

final class ModelTests: XCTestCase {
    // MARK: NotchGeometry & NotchShape

    func testNoNotchReturnsNil() {
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertNil(NotchGeometry.notchRect(for: frame, leftInset: 0, topInset: 0))
        XCTAssertNil(NotchGeometry.notchRect(for: frame, leftInset: 240, topInset: 0))
    }

    func testNotchRectIsCenteredAndSizedByInsets() {
        let frame = NSRect(x: 0, y: 0, width: 1470, height: 920)
        let notch = NotchGeometry.notchRect(for: frame, leftInset: 240, topInset: 32)
        XCTAssertNotNil(notch)
        XCTAssertEqual(notch!.midX, frame.midX, accuracy: 0.001)
        XCTAssertEqual(notch!.width, 990)
        XCTAssertEqual(notch!.height, 32)
        XCTAssertEqual(notch!.maxY, frame.maxY)
    }

    func testNotchedScreenWithZeroSideInsets() {
        let frame = NSRect(x: 0, y: 0, width: 1470, height: 956)
        let notch = NotchGeometry.notchRect(for: frame, leftInset: 0, topInset: 32)
        XCTAssertNotNil(notch)
        XCTAssertEqual(notch!.height, 32)
        let handle = NotchGeometry.handleRect(notch: notch!, screenFrame: frame)
        XCTAssertEqual(handle.maxY, 956)
        XCTAssertEqual(handle.minY, 956 - 32 - 26)
    }

    func testHandleRectOnNotchedScreen() {
        let frame = NSRect(x: 0, y: 0, width: 1470, height: 920)
        let notch = NotchGeometry.notchRect(for: frame, leftInset: 240, topInset: 32)!
        let handle = NotchGeometry.handleRect(notch: notch, screenFrame: frame)
        XCTAssertEqual(handle.midX, frame.midX, accuracy: 0.001)
        XCTAssertEqual(handle.minY, frame.maxY - max(32, 32) - 26, accuracy: 0.001)
        XCTAssertEqual(handle.maxY, frame.maxY, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(handle.width, 184)
    }

    func testHandleRectOnNonNotchedScreen() {
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let handle = NotchGeometry.handleRect(notch: nil, screenFrame: frame)
        XCTAssertEqual(handle.height, 26)
        XCTAssertEqual(handle.maxY, frame.maxY)
        XCTAssertEqual(handle.midX, frame.midX, accuracy: 0.001)
    }

    func testNotchShapePathGeneration() {
        let shape = NotchShape(topCornerRadius: 10, bottomCornerRadius: 22)
        let rect = CGRect(x: 0, y: 0, width: 980, height: 158)
        let path = shape.path(in: rect)
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(path.boundingRect.width, 980, accuracy: 0.5)
        XCTAssertEqual(path.boundingRect.height, 158, accuracy: 0.5)
    }

    // MARK: Settings

    func testSettingsRoundTripAndPresets() {
        var s = Settings()
        s.accentColorName = "purple"
        s.contentPadding = 18
        s.openOnHover = false
        s.notchWidthPreset = "wide"
        s.enableHUDReplacement = true
        s.useDynamicAlbumTint = false
        let data = try! JSONEncoder().encode(s)
        let s2 = try! JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(s, s2)
        XCTAssertEqual(s2.expandedMaxWidth, 1080)
    }

    // MARK: Countdown

    func testCountdownStartTickFinish() {
        var c = CountdownState(totalSeconds: 0, remaining: 0)
        c.start(totalSeconds: 2, label: "test")
        XCTAssertEqual(c.remaining, 2)
        c.tick()
        XCTAssertEqual(c.remaining, 1)
        XCTAssertEqual(c.progress, 0.5, accuracy: 0.0001)
        c.tick()
        XCTAssertEqual(c.remaining, 0)
        XCTAssertFalse(c.running)
        c.tick()
        XCTAssertEqual(c.remaining, 0)
    }

    func testCountdownAdjustDuration() {
        var c = CountdownState(totalSeconds: 60, remaining: 30)
        c.adjustDuration(by: 60)
        XCTAssertEqual(c.remaining, 90)
        XCTAssertEqual(c.totalSeconds, 90)
    }

    func testCountdownIgnoresTickWhenStopped() {
        var c = CountdownState(totalSeconds: 0, remaining: 0)
        c.start(totalSeconds: 10, label: "x")
        c.running = false
        c.tick()
        XCTAssertEqual(c.remaining, 10)
    }

    func testCountdownIgnoresInvalidStart() {
        var c = CountdownState(totalSeconds: 0, remaining: 0)
        c.start(totalSeconds: 0, label: "x")
        XCTAssertEqual(c.totalSeconds, 1)
        XCTAssertEqual(c.remaining, 1)
    }

    func testTimeFormat() {
        XCTAssertEqual(CountdownState.formatHRMN(65), "01:05")
        XCTAssertEqual(CountdownState.formatHRMN(3600), "1:00:00")
        XCTAssertEqual(CountdownState.formatHRMN(1500), "25:00")
        XCTAssertEqual(CountdownState.formatHRMN(0), "00:00")
    }

    // MARK: MediaInfo parsing

    func testMRDictionaryParsing() {
        let dict = [
            "kMRMediaRemoteNowPlayingInfoTitle": "Song",
            "kMRMediaRemoteNowPlayingInfoArtist": "Artist",
            "kMRMediaRemoteNowPlayingInfoApplicationIdentifier": "com.spotify.client",
            "kMRMediaRemoteNowPlayingInfoIsPlaying": true
        ] as [String: Any]
        let info = MediaInfo.fromMRDictionary(dict)
        XCTAssertNotNil(info)
        XCTAssertEqual(info!.title, "Song")
        XCTAssertEqual(info!.artist, "Artist")
        XCTAssertEqual(info!.app, "client")
        XCTAssertEqual(info!.sourceDisplayName, "Spotify")
        XCTAssertTrue(info!.playing)
    }

    func testMRDictionaryRejectsEmptyTitle() {
        XCTAssertNil(MediaInfo.fromMRDictionary(["kMRMediaRemoteNowPlayingInfoArtist": "A"]))
    }

    // MARK: Calendar URL Extraction

    func testCalendarMeetingURLExtraction() {
        let zoomText = "Join our call at https://us02web.zoom.us/j/123456789 right now"
        XCTAssertEqual(CalendarProvider.extractMeetingURL(from: zoomText)?.absoluteString, "https://us02web.zoom.us/j/123456789")

        let meetText = "Standup: https://meet.google.com/abc-defg-hij"
        XCTAssertEqual(CalendarProvider.extractMeetingURL(from: meetText)?.absoluteString, "https://meet.google.com/abc-defg-hij")
    }

    // MARK: Format

    func testFormatHelpers() {
        let cal = Calendar.current
        let date = cal.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 15, minute: 5))!
        XCTAssertEqual(Format.clock(from: date), "3:05")
        XCTAssertEqual(Format.dateShort(date, calendar: cal), "Mar 1")
    }

    // MARK: Store (tasks, star priority, clipboard, tray multi-select)

    private func makeTempStore() -> (Store, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opennook-tests-\(UUID().uuidString)", isDirectory: true)
        return (Store(directory: dir), dir)
    }

    func testStoreTasksAndStarLifecycle() {
        let (store, _) = makeTempStore()
        XCTAssertEqual(store.tasks.count, 0)
        store.addTask("  buy milk  ")
        store.addTask("ship release")
        XCTAssertEqual(store.tasks.count, 2)

        // Star first added task ("buy milk") and verify it sorts to top
        let milkID = store.tasks.first(where: { $0.title == "buy milk" })!.id
        store.toggleStarTask(milkID)
        XCTAssertEqual(store.tasks.first?.id, milkID)
        XCTAssertTrue(store.tasks.first!.starred)

        store.toggleTask(milkID)
        XCTAssertTrue(store.tasks.first(where: { $0.id == milkID })!.done)

        store.clearCompletedTasks()
        XCTAssertEqual(store.tasks.count, 1)
    }

    func testStoreClipboardHistory() {
        let (store, _) = makeTempStore()
        store.addClipboardSnippet("https://github.com/TheBoredTeam/boring.notch")
        store.addClipboardSnippet("https://github.com/morluto/rea")
        XCTAssertEqual(store.clipboardHistory.count, 2)
        XCTAssertEqual(store.clipboardHistory.first?.content, "https://github.com/morluto/rea")

        // Dedupes identical consecutive snippet
        store.addClipboardSnippet("https://github.com/morluto/rea")
        XCTAssertEqual(store.clipboardHistory.count, 2)

        store.clearClipboardHistory()
        XCTAssertTrue(store.clipboardHistory.isEmpty)
    }

    func testStoreRejectsBlankTask() {
        let (store, _) = makeTempStore()
        store.addTask("   ")
        XCTAssertEqual(store.tasks.count, 0)
    }

    func testStoreTrayDedupeSelectionAndCleanup() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fnote-\(UUID().uuidString).txt")
        try? "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let (store, _) = makeTempStore()
        XCTAssertTrue(store.addTrayItem(path: url.path))
        XCTAssertFalse(store.addTrayItem(path: url.path)) // deduped
        XCTAssertEqual(store.trayItems.count, 1)
        let id = store.trayItems[0].id

        store.toggleTraySelection(id)
        XCTAssertTrue(store.selectedTrayIDs.contains(id))

        store.removeTrayItem(id)
        XCTAssertEqual(store.trayItems.count, 0)
        XCTAssertFalse(store.selectedTrayIDs.contains(id))

        store.addTrayItem(path: url.path)
        try? FileManager.default.removeItem(at: url)
        store.cleanMissingTrayItems()
        XCTAssertEqual(store.trayItems.count, 0)
    }

    @MainActor
    func testTimerModelAddMinutesAndStep() {
        let model = TimerModel()
        model.start(seconds: 60, label: "x")
        model.addMinutes(5)
        XCTAssertEqual(model.state.remaining, 360)
        model.stepSeconds(15)
        XCTAssertEqual(model.state.remaining, 375)
    }

    @MainActor
    func testSystemMonitorBatteryAndAlertPresentation() {
        let mon = SystemMonitor.shared
        mon.refreshBattery()
        XCTAssertGreaterThanOrEqual(mon.battery.percentage, 0)
        XCTAssertLessThanOrEqual(mon.battery.percentage, 100)

        let alert = LiveActivityAlert(kind: .volume, title: "Volume", subtitle: "75%", icon: "speaker.wave.2.fill", value: 0.75)
        mon.presentAlert(alert, duration: 1.0)
        XCTAssertEqual(mon.activeAlert?.title, "Volume")
    }
}
