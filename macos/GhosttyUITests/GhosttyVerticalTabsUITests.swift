import XCTest

final class GhosttyVerticalTabsUITests: GhosttyCustomConfigCase {
    /// The title of every tab that hasn't been renamed.
    private static let defaultTitle = "GhosttyVerticalTabsUITests"

    private static let config = """
        macos-titlebar-style = vertical-tabs
        title = "\(defaultTitle)"
        """

    override func setUp() async throws {
        try await super.setUp()

        try updateConfig(Self.config)
    }

    // MARK: - Renaming

    @MainActor
    func testRenameSelectedTabFromSidebarMenu() throws {
        let app = try launchGhostty()

        let row = tabRows(in: app).element(boundBy: 0)
        renameFromMenu(row, in: app)
        commitTitle("Renamed", in: app)

        XCTAssertTrue(row.wait(for: \.label, toEqual: "Renamed", timeout: 5), "The row should show the new title")
        XCTAssertEqual(app.windows.firstMatch.title, "Renamed", "The window should have the new title")
    }

    @MainActor
    func testRenameBackgroundTabFromSidebarMenu() throws {
        let app = try launchGhostty()
        newTab(in: app)

        renameFromMenu(tabRows(in: app).element(boundBy: 0), in: app)
        commitTitle("Renamed", in: app)

        let rows = tabRows(in: app)
        XCTAssertTrue(rows.element(boundBy: 0).wait(for: \.label, toEqual: "Renamed", timeout: 5), "The first row should show the new title")
        XCTAssertEqual(rows.element(boundBy: 1).label, Self.defaultTitle, "The second tab should keep its title")

        // The window on screen is the selected tab's, so the second tab is still selected.
        XCTAssertEqual(app.windows.firstMatch.title, Self.defaultTitle, "The second tab should stay selected")
    }

    @MainActor
    func testRenameByDoubleClick() throws {
        let app = try launchGhostty()
        newTab(in: app)

        // The first click selects the tab, which shows its window, so the second click
        // lands in that window's copy of the sidebar.
        tabRows(in: app).element(boundBy: 0).doubleClick()
        commitTitle("Renamed", in: app)

        XCTAssertTrue(tabRows(in: app).element(boundBy: 0).wait(for: \.label, toEqual: "Renamed", timeout: 5), "The first row should show the new title")
        XCTAssertEqual(app.windows.firstMatch.title, "Renamed", "The double-clicked tab should be selected")
    }

    @MainActor
    func testChangeTabTitleMenuEditsInSidebar() throws {
        let app = try launchGhostty()

        chooseChangeTabTitle(in: app)
        commitTitle("First", in: app)

        XCTAssertTrue(tabRows(in: app).element(boundBy: 0).wait(for: \.label, toEqual: "First", timeout: 5), "The row should show the new title")
        XCTAssertEqual(app.windows.firstMatch.title, "First", "The window should have the new title")

        // With more than one tab, the native tab bar exists but is hidden.
        newTab(in: app)
        chooseChangeTabTitle(in: app)
        commitTitle("Second", in: app)

        let rows = tabRows(in: app)
        XCTAssertTrue(rows.element(boundBy: 1).wait(for: \.label, toEqual: "Second", timeout: 5), "The second row should show the new title")
        XCTAssertEqual(rows.element(boundBy: 0).label, "First", "The first tab should keep its title")
        XCTAssertEqual(app.windows.firstMatch.title, "Second", "The window should have the new title")
    }

    @MainActor
    func testRenameEscapeCancelsAndEmptyRestoresDefault() throws {
        let app = try launchGhostty()
        let row = tabRows(in: app).element(boundBy: 0)

        renameFromMenu(row, in: app)
        commitTitle("Renamed", in: app)
        XCTAssertTrue(row.wait(for: \.label, toEqual: "Renamed", timeout: 5), "The row should show the new title")

        renameFromMenu(row, in: app)
        let editor = titleEditor(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "The title editor should appear")
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Discarded")
        editor.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Escape should end the edit")
        XCTAssertEqual(row.label, "Renamed", "Escape should keep the title")
        XCTAssertEqual(app.windows.firstMatch.title, "Renamed", "Escape should keep the title")

        renameFromMenu(row, in: app)
        commitTitle("", in: app)

        XCTAssertTrue(row.wait(for: \.label, toEqual: Self.defaultTitle, timeout: 5), "An empty title should restore the default")
        XCTAssertEqual(app.windows.firstMatch.title, Self.defaultTitle, "An empty title should restore the default")
    }

    @MainActor
    func testRenameInCollapsedSidebarPrompts() throws {
        let app = try launchGhostty()

        app.windows.firstMatch.buttons["Hide Tab Sidebar"].firstMatch.click()
        XCTAssertTrue(app.windows.firstMatch.buttons["Show Tab Sidebar"].firstMatch.waitForExistence(timeout: 5), "The sidebar should collapse")

        // The collapsed sidebar has no room for an editor, so the title is prompted for.
        chooseChangeTabTitle(in: app)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Change Tab Title should prompt for the title")
        XCTAssertFalse(titleEditor(in: app).exists, "The collapsed sidebar shouldn't edit the title")

        let field = sheet.textFields.firstMatch
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Prompted")
        sheet.buttons["OK"].click()

        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Prompted", timeout: 5), "The window should have the new title")
        XCTAssertEqual(tabRows(in: app).element(boundBy: 0).label, "Prompted", "The tab should have the new title")
    }

    // MARK: - Helpers

    /// Launches Ghostty with the tab sidebar's width and collapsed state reset, since they
    /// are saved in the user defaults that the UI tests share.
    @MainActor
    private func launchGhostty() throws -> XCUIApplication {
        let app = try ghosttyApplication()
        // Suppress Restoration
        app.launchArguments += ["-NSQuitAlwaysKeepsWindows", "NO"]
        // Clean run
        app.launchEnvironment["GHOSTTY_CLEAR_USER_DEFAULTS"] = "YES"
        app.launch()

        XCTAssertTrue(tabRows(in: app).firstMatch.waitForExistence(timeout: 5), "The tab sidebar should list the tab")
        return app
    }

    /// The rows of the tab sidebar on screen, which is the selected tab's copy.
    @MainActor
    private func tabRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.windows.firstMatch.buttons.matching(identifier: "TerminalTabSidebarRow")
    }

    /// Opens a tab with the new_tab keybind and waits for the sidebar to list it.
    @MainActor
    private func newTab(in app: XCUIApplication) {
        let count = tabRows(in: app).count
        app.windows.firstMatch.groups["Terminal pane"].firstMatch.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(tabRows(in: app).element(boundBy: count).waitForExistence(timeout: 5), "The tab sidebar should list the new tab")
    }

    @MainActor
    private func renameFromMenu(_ row: XCUIElement, in app: XCUIApplication) {
        row.rightClick()
        app.menuItems["Rename Tab..."].firstMatch.click()
    }

    @MainActor
    private func chooseChangeTabTitle(in app: XCUIApplication) {
        app.menuBarItems["View"].firstMatch.click()
        app.menuItems["Change Tab Title..."].firstMatch.click()
    }

    @MainActor
    private func titleEditor(in app: XCUIApplication) -> XCUIElement {
        app.textFields["TerminalTabSidebarTitleEditor"]
    }

    /// Replaces the text in the sidebar's title editor with `title` and presses Return.
    @MainActor
    private func commitTitle(_ title: String, in app: XCUIApplication) {
        let editor = titleEditor(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "The title editor should appear")
        editor.typeKey("a", modifierFlags: .command)
        editor.typeKey(.delete, modifierFlags: [])
        editor.typeText("\(title)\n")
    }
}
