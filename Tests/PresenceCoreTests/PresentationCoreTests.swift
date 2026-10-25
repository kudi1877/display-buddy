@testable import PresenceCore
import XCTest

final class PresentationCoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("presence-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func fullSnapshot() -> PresentationSnapshot {
        var s = PresentationSnapshot(startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        s.focusTurnedOn = true
        s.dockMenuBar = DockMenuBarState(dockAutohide: true, menuBarAutohide: false)
        s.alertVolume = 51
        s.display = DisplayState(brightness: 42, adaptive: true, colorMode: "auto", manualKelvin: 5000)
        s.wallpapers = [ScreenWallpaper(screenKey: "UUID-1", url: URL(fileURLWithPath: "/Users/me/Pictures/a.heic"),
                                        scaling: 3, allowClipping: true, fillColor: [0.1, 0.2, 0.3, 1])]
        s.hiddenApps = [HiddenApp(pid: 101, bundleID: "com.example.notes")]
        s.frontmostApp = HiddenApp(pid: 202, bundleID: "com.example.slides")
        PresentationStep.allCases.forEach { s.markApplied($0) }
        return s
    }

    // MARK: Restore plan

    func testRestoreRunsInReverseOrder() {
        XCTAssertEqual(fullSnapshot().restoreOrder, PresentationStep.allCases.reversed())
    }

    func testOnlyAppliedStepsAreRestored() {
        // Crashed after the first two steps: only those are undone.
        var s = PresentationSnapshot(startedAt: Date())
        s.markApplied(.keepAwake)
        s.markApplied(.focus)
        XCTAssertEqual(s.restoreOrder, [.focus, .keepAwake])
    }

    func testMarkingIsIdempotentAndRestoredStepsDropOut() {
        var s = PresentationSnapshot(startedAt: Date())
        s.markApplied(.wallpaper)
        s.markApplied(.wallpaper)
        XCTAssertEqual(s.applied, [.wallpaper])
        s.markRestored(.wallpaper)
        XCTAssertTrue(s.isFullyRestored)
    }

    func testFailedRestoreStepStaysForNextLaunch() {
        var s = fullSnapshot()
        for step in s.restoreOrder where step != .dockAndMenuBar { s.markRestored(step) }
        XCTAssertFalse(s.isFullyRestored)
        XCTAssertEqual(s.restoreOrder, [.dockAndMenuBar])
    }

    // MARK: Store

    func testSaveAndLoadRoundTrip() throws {
        let store = SnapshotStore(url: folder.appendingPathComponent("state.json"))
        XCTAssertEqual(store.load(), .none)
        let snapshot = fullSnapshot()
        try store.save(snapshot)
        XCTAssertTrue(store.exists)
        XCTAssertEqual(store.load(), .snapshot(snapshot))
        try store.remove()
        XCTAssertFalse(store.exists)
        XCTAssertEqual(store.load(), .none)
    }

    func testSavingAgainReplacesTheFile() throws {
        let store = SnapshotStore(url: folder.appendingPathComponent("state.json"))
        var s = PresentationSnapshot(startedAt: Date(timeIntervalSince1970: 0))
        try store.save(s)
        s.markApplied(.focus)
        s.focusTurnedOn = true
        try store.save(s)
        XCTAssertEqual(store.load(), .snapshot(s))
    }

    func testUnreadableFileIsMovedAsideNotRetried() throws {
        let url = folder.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let store = SnapshotStore(url: url)
        guard case .unreadable(let moved) = store.load() else { return XCTFail("expected unreadable") }
        XCTAssertNotNil(moved)
        XCTAssertFalse(store.exists)
        XCTAssertEqual(store.load(), .none)
    }

    func testRemovingAMissingFileIsFine() {
        XCTAssertNoThrow(try SnapshotStore(url: folder.appendingPathComponent("nope.json")).remove())
    }

    // MARK: Hiding apps

    func testHideSkipsOwnAppPresentationAppHiddenAndBackgroundApps() {
        let running = [
            AppHiding.RunningApp(pid: 1, bundleID: "com.kudi1877.displaybuddy", isRegular: true, isHidden: false),
            AppHiding.RunningApp(pid: 2, bundleID: "com.example.slides", isRegular: true, isHidden: false),
            AppHiding.RunningApp(pid: 3, bundleID: "com.example.notes", isRegular: true, isHidden: false),
            AppHiding.RunningApp(pid: 4, bundleID: "com.example.already", isRegular: true, isHidden: true),
            AppHiding.RunningApp(pid: 5, bundleID: "com.example.agent", isRegular: false, isHidden: false),
        ]
        let hide = AppHiding.appsToHide(running: running, ownPID: 1, keepBundleIDs: ["com.example.slides"])
        XCTAssertEqual(hide.map(\.pid), [3])
    }

    func testUnhideOnlyWhatWeHid() {
        let hidden = [HiddenApp(pid: 3, bundleID: "com.example.notes"), HiddenApp(pid: 9, bundleID: "com.example.quit")]
        let running = [
            AppHiding.RunningApp(pid: 3, bundleID: "com.example.notes", isRegular: true, isHidden: true),
            AppHiding.RunningApp(pid: 4, bundleID: "com.example.already", isRegular: true, isHidden: true),
        ]
        // pid 4 was hidden by the user before; pid 9 has quit.
        XCTAssertEqual(AppHiding.appsToUnhide(hidden: hidden, running: running).map(\.pid), [3])
    }

    func testUnhideIgnoresAReusedProcessID() {
        let hidden = [HiddenApp(pid: 3, bundleID: "com.example.notes")]
        let running = [AppHiding.RunningApp(pid: 3, bundleID: "com.example.other", isRegular: true, isHidden: true)]
        XCTAssertTrue(AppHiding.appsToUnhide(hidden: hidden, running: running).isEmpty)
    }

    func testUnhideSkipsAppsTheUserAlreadyShowed() {
        let hidden = [HiddenApp(pid: 3, bundleID: nil)]
        let running = [AppHiding.RunningApp(pid: 3, bundleID: nil, isRegular: true, isHidden: false)]
        XCTAssertTrue(AppHiding.appsToUnhide(hidden: hidden, running: running).isEmpty)
    }

    // MARK: Wallpaper and Focus

    func testWallpaperPolicy() {
        XCTAssertTrue(WallpaperPolicy.canRestore(url: URL(fileURLWithPath: "/Users/me/Pictures/desert.heic"), fileExists: true))
        XCTAssertTrue(WallpaperPolicy.canRestore(url: URL(fileURLWithPath: "/System/Library/Desktop Pictures/Solid Colors/Black.png"), fileExists: true))
        XCTAssertFalse(WallpaperPolicy.canRestore(url: nil, fileExists: false))
        XCTAssertFalse(WallpaperPolicy.canRestore(url: URL(fileURLWithPath: "/gone.png"), fileExists: false))
        XCTAssertFalse(WallpaperPolicy.canRestore(url: URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/x.mov"), fileExists: true))
        XCTAssertFalse(WallpaperPolicy.canRestore(url: URL(string: "https://example.com/a.png"), fileExists: true))
    }

    func testFocusStatusParsing() {
        XCTAssertTrue(FocusStatus.isFocusOn(shortcutOutput: "Do Not Disturb\n"))
        XCTAssertTrue(FocusStatus.isFocusOn(shortcutOutput: "Work"))
        XCTAssertFalse(FocusStatus.isFocusOn(shortcutOutput: ""))
        XCTAssertFalse(FocusStatus.isFocusOn(shortcutOutput: "  \n"))
        XCTAssertFalse(FocusStatus.isFocusOn(shortcutOutput: "None"))
    }

    func testMissingShortcuts() {
        let available: Set<String> = ["Display Buddy Focus On", "Something"]
        XCTAssertEqual(FocusStatus.missing(required: ["Display Buddy Focus On", "Display Buddy Focus Off"], available: available),
                       ["Display Buddy Focus Off"])
        XCTAssertEqual(FocusStatus.missing(required: ["", "Display Buddy Focus On"], available: available), [])
    }
}
