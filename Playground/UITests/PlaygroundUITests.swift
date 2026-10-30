import XCTest

final class PlaygroundUITests: XCTestCase {
  @MainActor
  func testLaunches() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.staticTexts["Composer Playground"].waitForExistence(timeout: 10))
  }

  #if os(iOS)
    /// A tap focuses an unfocused composer, before and after it moves.
    @MainActor
    func testTapFocusesTheComposer() {
      let app = XCUIApplication()
      app.launch()
      let composer = app.textViews["composer"]
      let keyboard = app.keyboards.firstMatch
      XCTAssertTrue(composer.waitForExistence(timeout: 10))
      app.buttons["Done"].tap()
      XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
      composer.tap()
      XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
      app.buttons["Done"].tap()
      XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
      app.switches["Docked"].tap()
      composer.tap()
      XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    }
  #endif
}
