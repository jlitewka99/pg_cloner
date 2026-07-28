import XCTest

final class PGClonerUITests: XCTestCase {
    @MainActor
    func testCreateConnectionProfile() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["settingsButton"].click()
        let add = app.buttons["addSourceConnectionButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()

        replaceText(in: app.textFields["profileName"], with: "UI Test")
        replaceText(in: app.textFields["profileHost"], with: "127.0.0.1")
        replaceText(in: app.textFields["profilePort"], with: "5432")
        replaceText(in: app.textFields["profileDatabase"], with: "postgres")
        replaceText(in: app.textFields["profileUsername"], with: "postgres")
        replaceText(in: app.secureTextFields["profilePassword"], with: "not-persisted-in-json")

        let save = app.buttons["saveSourceProfileButton"]
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(app.staticTexts["UI Test"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "UI Test").count, 1)
    }

  @MainActor
  func testExecutionSettingsPersistAfterRelaunch() throws {
    let app = XCUIApplication()
    app.launch()

    app.buttons["settingsButton"].click()
    let executionTab = app.tabGroups.buttons["Execution"]
    XCTAssertTrue(executionTab.waitForExistence(timeout: 5))
    executionTab.click()

    replaceText(in: app.textFields["queryTimeoutSeconds"], with: "45")
    replaceText(in: app.textFields["retryAttempts"], with: "4")
    app.buttons["saveExecutionSettingsButton"].click()
    XCTAssertTrue(app.staticTexts["executionSettingsSaved"].waitForExistence(timeout: 5))

    app.terminate()
    app.launch()
    app.buttons["settingsButton"].click()
    XCTAssertTrue(app.tabGroups.buttons["Execution"].waitForExistence(timeout: 5))
    app.tabGroups.buttons["Execution"].click()

    XCTAssertEqual(app.textFields["queryTimeoutSeconds"].value as? String, "45")
    XCTAssertEqual(app.textFields["retryAttempts"].value as? String, "4")
  }

    @MainActor
    func testClonePreviewConfirmationProgressAndCancellation() throws {
        guard ProcessInfo.processInfo.environment["PGCLONER_UI_DATABASE_READY"] == "1" else {
            throw XCTSkip(
                "Set PGCLONER_UI_DATABASE_READY=1 and prepare source/target profiles for the end-to-end UI test."
            )
        }

        let app = XCUIApplication()
        app.launch()
        let table = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'table.'")
        ).firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        table.click()

        let clone = app.buttons["cloneButton"]
        XCTAssertTrue(clone.isEnabled)
        clone.click()
        let confirm = app.buttons["Drop and clone"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        let cancel = app.buttons["cancelCloneButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        cancel.click()
        XCTAssertTrue(app.staticTexts["Partial result"].waitForExistence(timeout: 30))
    }

    @MainActor
    private func replaceText(in element: XCUIElement, with value: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(value)
    }
}
