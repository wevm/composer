import XCTest

final class PlaygroundUITests: XCTestCase {
  @MainActor
  func testLaunches() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.staticTexts["Composer Playground"].waitForExistence(timeout: 10))
  }
}
