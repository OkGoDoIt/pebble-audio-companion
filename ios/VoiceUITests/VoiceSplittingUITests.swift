import XCTest

final class VoiceSplittingUITests: XCTestCase {
    @MainActor func testMixedVoiceCanSplitFurtherReviewIndividualClipsAndSave() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.audiocompanion.app.dev")
        app.launchArguments = ["-demo-data", "-onboarding.skip", "-route", "settings/voices"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let voices = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Voices to name")).firstMatch
        for _ in 0..<6 {
            if voices.exists && voices.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(voices.waitForExistence(timeout: 10))
        voices.tap()
        let mixed = app.buttons["voice.demo-voice-1"]
        XCTAssertTrue(mixed.waitForExistence(timeout: 8))
        mixed.tap()
        let split = app.buttons["More than one person"]
        XCTAssertTrue(split.waitForExistence(timeout: 8))
        capture(app,"Before splitting")
        split.tap()
        XCTAssertTrue(app.buttons["Keep 3 groups"].waitForExistence(timeout: 8))
        capture(app,"Smaller groups")
        if app.frame.width > 600 {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.buttons["Keep 3 groups"].exists)
            capture(app,"Smaller groups wide")
            XCUIDevice.shared.orientation = .portrait
        }
        app.buttons["Split further"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Keep 4 groups"].waitForExistence(timeout: 8))
        capture(app,"Split further")
        app.buttons["Review clips"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["0 selected"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Separate selected clips"].isEnabled)
        capture(app,"Individual clips")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Keep 4 groups"].tap()
        XCTAssertTrue(app.navigationBars["Voices to name"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["voice.demo-voice-1"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voice.split-")).count >= 4)
        capture(app,"Saved groups in queue")
    }
    @MainActor func testManualSeparationAndUndo() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.audiocompanion.app.dev")
        app.launchArguments = ["-demo-data", "-onboarding.skip", "-route", "settings/voices"]
        app.launch()
        let voices = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Voices to name")).firstMatch
        XCTAssertTrue(voices.waitForExistence(timeout: 10))
        voices.tap()
        app.buttons["voice.demo-voice-1"].tap()
        app.buttons["More than one person"].tap()
        XCTAssertTrue(app.buttons["Keep 3 groups"].waitForExistence(timeout: 8))
        app.buttons["Review clips"].firstMatch.tap()
        app.buttons["Select all"].tap()
        XCTAssertTrue(app.staticTexts["2 selected"].exists)
        app.buttons["Clear selection"].tap()
        app.buttons.matching(NSPredicate(format: "value == %@", "Not checked")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 selected"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "value == %@", "Checked")).firstMatch.waitForExistence(timeout: 3))
        capture(app,"Manual clip selection")
        app.buttons["Separate selected clips"].tap()
        XCTAssertTrue(app.buttons["Keep 4 groups"].waitForExistence(timeout: 8))
        app.buttons["Keep 4 groups"].tap()
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 4))
        undo.tap()
        XCTAssertTrue(app.buttons["voice.demo-voice-1"].waitForExistence(timeout: 5))
    }
    @MainActor func testGroupsCanBeNamedWhileSplitting() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.audiocompanion.app.dev")
        app.launchArguments = ["-demo-data", "-onboarding.skip", "-route", "settings/voices"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let voices = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Voices to name")).firstMatch
        for _ in 0..<6 {
            if voices.exists && voices.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(voices.waitForExistence(timeout: 10))
        voices.tap()
        app.buttons["voice.demo-voice-1"].tap()
        app.buttons["More than one person"].tap()
        XCTAssertTrue(app.buttons["Keep 3 groups"].waitForExistence(timeout: 8))
        app.buttons["split.name.0"].tap()
        XCTAssertTrue(app.navigationBars["Who is this?"].waitForExistence(timeout: 5))
        capture(app,"Naming a group")
        app.buttons["Dana"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
        app.buttons["split.name.1"].tap()
        app.buttons["Someone new"].tap()
        app.textFields.firstMatch.typeText("Priya")
        capture(app,"Naming someone new")
        app.buttons["Name Priya"].tap()
        XCTAssertTrue(app.staticTexts["Priya"].waitForExistence(timeout: 5))
        capture(app,"Groups with names")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Voices to name"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Named Dana and Priya"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["voice.demo-voice-1"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voice.split-")).count, 1)
        capture(app,"Named from the split")
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
