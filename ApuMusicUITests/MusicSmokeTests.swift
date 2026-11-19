import XCTest

final class MusicSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["UITEST_MODE"] = "1"
        app.launchEnvironment["APU_API_BASE_URL"] = "http://127.0.0.1:18765/api/v1"
        app.launch()
    }

    func testHomeRecommendationsAndSearchResultsAndPlayback() {
        XCTAssertTrue(app.staticTexts["为你精选"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.matching(identifier: "歌曲-Hello").firstMatch.waitForExistence(timeout: 15))
        screenshot("首页")

        app.buttons["搜索音乐"].tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("hello")
        let firstHello = app.buttons.matching(identifier: "歌曲-Hello").element(boundBy: 0)
        XCTAssertTrue(firstHello.waitForExistence(timeout: 8))
        screenshot("搜索")

        firstHello.tap()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 8))
        let playPause = app.buttons["全屏播放控制"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 8))
        let playing = expectation(for: NSPredicate(format: "label == %@", "暂停"), evaluatedWith: playPause)
        let elapsed = app.staticTexts["已播放时间"]
        let advancing = expectation(for: NSPredicate(format: "exists == true AND label != %@", "0:00"), evaluatedWith: elapsed)
        wait(for: [playing, advancing], timeout: 15)
        screenshot("全屏播放")

        let swipeStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        let swipeEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86))
        swipeStart.press(forDuration: 0.05, thenDragTo: swipeEnd)
        let playerSheet = app.buttons["收起播放器"]
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: playerSheet)
        wait(for: [dismissed], timeout: 8)
        let miniPlayer = app.buttons["打开迷你播放器"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        screenshot("迷你播放条")
        miniPlayer.tap()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
        XCTAssertEqual(playPause.label, "暂停")
    }

    func testLibraryImportedPlaylistDetails() {
        app.launchArguments += ["--uitesting-playlist"]
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["我的收藏"].waitForExistence(timeout: 5))
        app.buttons["我的收藏"].tap()
        XCTAssertTrue(app.staticTexts["Spotify 喜欢的歌曲"].waitForExistence(timeout: 12))
        screenshot("我的收藏")
        app.staticTexts["Spotify 喜欢的歌曲"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "播放全部")).firstMatch.waitForExistence(timeout: 8))
        screenshot("歌单详情")
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "ApuMusic-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
