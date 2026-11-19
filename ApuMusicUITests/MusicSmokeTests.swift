import XCTest

final class MusicSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["UITEST_MODE"] = "1"
        app.launch()
    }

    func testHomeRecommendationsAndSearchResultsAndPlayback() {
        XCTAssertTrue(app.staticTexts["为你精选"].waitForExistence(timeout: 15))
        screenshot("首页")

        app.buttons["搜索音乐"].tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("hello")
        XCTAssertTrue(app.buttons["歌曲-Hello"].firstMatch.waitForExistence(timeout: 8))
        screenshot("搜索")

        app.buttons["歌曲-Hello"].tap()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 8))
        screenshot("全屏播放")

        let swipeStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        let swipeEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86))
        swipeStart.press(forDuration: 0.05, thenDragTo: swipeEnd)
        XCTAssertTrue(app.descendants(matching: .any)["迷你播放条"].waitForExistence(timeout: 5))
        screenshot("迷你播放条")
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
