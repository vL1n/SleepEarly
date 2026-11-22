import XCTest

final class ReviewFlowTests: XCTestCase {
    @MainActor
    func testRateAdvanceCompareAndUndoWithoutLeavingEditor() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Metadata-only records exercise culling and editing even with unreadable media.
        // Pixel rendering is verified separately with camera files.
        app.launchEnvironment["FRAMEFLOW_UI_TEST_CATALOG"] = #"["First.ARW","Second.ARW"]"#
        app.launch()
        let photo = app.buttons["photo-Second.ARW"]
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        photo.tap()
        let modes = app.segmentedControls["work-mode"]
        modes.buttons["选片"].tap()
        let advance = app.switches["标记后自动下一张"]
        if advance.value as? String != "1" { advance.tap() }
        app.buttons["评分 4 星"].tap()
        XCTAssertTrue(app.navigationBars["First.ARW"].waitForExistence(timeout: 5))
        let canvas = app.descendants(matching: .any).matching(identifier: "photo-canvas").firstMatch
        XCTAssertTrue(canvas.exists)
        canvas.swipeRight()
        XCTAssertTrue(app.navigationBars["Second.ARW"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["评分 4 星"].value as? String, "已选")
        modes.buttons["调色"].tap()
        app.buttons["presets"].tap()
        app.buttons["鲜明"].tap()
        XCTAssertTrue(app.buttons["undo-recipe"].isEnabled)
        app.buttons["查看原图"].tap()
        XCTAssertTrue(app.buttons["查看调整后"].exists)
        app.buttons["查看调整后"].tap()
        app.buttons["undo-recipe"].tap()
        XCTAssertFalse(app.buttons["undo-recipe"].isEnabled)
        XCTAssertTrue(app.buttons["redo-recipe"].isEnabled)
        app.buttons["redo-recipe"].tap()
        XCTAssertTrue(app.buttons["undo-recipe"].isEnabled)
    }
}
