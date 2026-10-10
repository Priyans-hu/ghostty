import AppKit
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

    // MARK: - Tabs

    @MainActor
    func testNewTabButtonAddsSelectedRow() throws {
        let app = try launchGhostty()

        app.windows.firstMatch.buttons["New Tab"].firstMatch.click()

        let rows = tabRows(in: app)
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 5), "The new tab should have a row")
        XCTAssertEqual(rows.count, 2, "There should be 2 tabs")
        assertSelectedRow(1, in: app, "The new tab should be selected")
    }

    @MainActor
    func testCloseButtonRemovesRow() throws {
        // Close the tab without asking, even if its shell hasn't reached a prompt yet.
        try updateConfig(
            """
            \(Self.config)
            confirm-close-surface = false
            """
        )
        let app = try launchGhostty()
        newTab(in: app)

        // The close button only shows while the row is hovered. It is at the leading end
        // of the row, in place of the tab's color.
        let closeButton = tabRows(in: app).element(boundBy: 1)
            .coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 15, dy: 0))
        closeButton.hover()
        closeButton.click()

        XCTAssertTrue(tabRows(in: app).element(boundBy: 1).waitForNonExistence(timeout: 5), "Closing the tab should remove its row")
        XCTAssertEqual(tabRows(in: app).count, 1, "There should be 1 tab")
    }

    @MainActor
    func testSelectedRowFollowsTabSelection() throws {
        let app = try launchGhostty()
        newTab(in: app)
        newTab(in: app)

        app.typeKey("1", modifierFlags: .command)
        assertSelectedRow(0, in: app, "Cmd+1 should select the first tab")

        tabRows(in: app).element(boundBy: 2).click()
        assertSelectedRow(2, in: app, "Clicking the third row should select its tab")

        app.typeKey("[", modifierFlags: [.command, .shift])
        assertSelectedRow(1, in: app, "Cmd+Shift+[ should select the previous tab")
    }

    // MARK: - Window

    @MainActor
    func testZoomIndicatorWithTabs() throws {
        let app = try launchGhostty()
        newTab(in: app)

        // Split, then zoom the new split.
        app.windows.firstMatch.groups["Terminal pane"].firstMatch.typeKey("d", modifierFlags: .command)
        app.typeKey("\n", modifierFlags: [.command, .shift])

        // Each native tab has a reset zoom button, but the native tab bar is hidden, so the
        // titlebar keeps its own.
        let resetZoomButton = app.windows.firstMatch.buttons["ResetZoom"].firstMatch
        XCTAssertTrue(resetZoomButton.waitForExistence(timeout: 5), "The titlebar should show the reset zoom button")
        XCTAssertTrue(resetZoomButton.isHittable, "The reset zoom button should be visible")
    }

    @MainActor
    func testShowTabBarMenuIsDisabled() throws {
        let app = try launchGhostty()

        // AppKit adds this item to the View menu. Its title says Show or Hide Tab Bar.
        app.menuBarItems["View"].firstMatch.click()
        let item = app.menuItems.matching(NSPredicate(
            format: "identifier == %@ OR title IN %@",
            "toggleTabBar:",
            ["Show Tab Bar", "Hide Tab Bar"]
        )).firstMatch
        guard item.waitForExistence(timeout: 2) else {
            app.typeKey(.escape, modifierFlags: [])
            throw XCTSkip("AppKit didn't add Show Tab Bar to the View menu")
        }

        XCTAssertFalse(item.isEnabled, "The tab sidebar replaces the tab bar, so it can't be shown")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testSidebarMatchesTitlebarBackground() async throws {
        try updateConfig(
            """
            \(Self.config)
            background = 336699
            """
        )
        let app = try launchGhostty()
        let window = app.windows.firstMatch

        // Let the window finish appearing and the shell start.
        try await Task.sleep(for: .seconds(1))

        let before = try sidebarAndTitlebarColors(in: window)
        XCTAssertTrue(before.sidebar.isClose(to: before.titlebar), "The tab sidebar should match the titlebar: \(before.sidebar) != \(before.titlebar)")

        // The titlebar follows a background color set by the terminal, and so should the
        // sidebar. Wait for the shell to run printf and the titlebar to change.
        app.typeText("printf '\\e]11;#993366\\a'\n")
        let deadline = Date().addingTimeInterval(10)
        var after = before
        while after.titlebar.isClose(to: before.titlebar), Date() < deadline {
            try await Task.sleep(for: .seconds(0.5))
            after = try sidebarAndTitlebarColors(in: window)
        }
        XCTAssertFalse(after.titlebar.isClose(to: before.titlebar), "OSC 11 should change the titlebar")

        // Give the sidebar a moment to draw too.
        try await Task.sleep(for: .seconds(0.5))
        after = try sidebarAndTitlebarColors(in: window)
        XCTAssertTrue(after.sidebar.isClose(to: after.titlebar), "The tab sidebar should match the titlebar: \(after.sidebar) != \(after.titlebar)")
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

    /// Waits for the sidebar on screen to show the tab at `index` as its only selected tab.
    @MainActor
    private func assertSelectedRow(
        _ index: Int,
        in app: XCUIApplication,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rows = tabRows(in: app)
        XCTAssertTrue(rows.element(boundBy: index).wait(for: \.isSelected, toEqual: true, timeout: 5), message, file: file, line: line)

        let selected = rows.allElementsBoundByIndex.indices.filter { rows.element(boundBy: $0).isSelected }
        XCTAssertEqual(selected, [index], message, file: file, line: line)
    }

    /// The colors in a screenshot of the window behind the tab sidebar, below its tabs, and
    /// in the titlebar, between the window buttons and the title.
    @MainActor
    private func sidebarAndTitlebarColors(in window: XCUIElement) throws -> (sidebar: NSColor, titlebar: NSColor) {
        let frame = window.frame
        let image = window.screenshot().image
        guard let pixelWidth = image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width else {
            throw XCTSkip("failed to get the window's pixels")
        }

        // The screenshot has the screen's scale. Pixels are counted from the top left.
        let scale = CGFloat(pixelWidth) / frame.width
        func color(x: CGFloat, y: CGFloat) throws -> NSColor {
            guard let color = image.colorAt(x: Int(x * scale), y: Int(y * scale)) else {
                throw XCTSkip("failed to get pixel color")
            }
            return color
        }

        let sidebar = try color(x: 100, y: frame.height - 40)
        let titlebar = try color(x: 120, y: 10)
        return (sidebar, titlebar)
    }
}

private extension NSColor {
    /// Whether this color looks the same as `other`, within `tolerance` in each sRGB component.
    func isClose(to other: NSColor, tolerance: CGFloat = 0.03) -> Bool {
        guard let color = usingColorSpace(.sRGB), let other = other.usingColorSpace(.sRGB) else { return false }
        return abs(color.redComponent - other.redComponent) <= tolerance
            && abs(color.greenComponent - other.greenComponent) <= tolerance
            && abs(color.blueComponent - other.blueComponent) <= tolerance
    }
}
