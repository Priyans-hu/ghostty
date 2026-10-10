import Testing
@testable import Ghostty

struct TerminalTabSidebarTests {
    // MARK: - Title Edits

    /// A title that comes from the terminal must keep following it when the edit commits
    /// it unchanged, rather than being frozen as an override.
    @Test func unchangedTitleKeepsNoOverride() {
        #expect(TerminalTabSidebarModel.titleOverride(committing: "zsh", seed: "zsh", current: nil) == nil)
    }

    @Test func unchangedTitleKeepsOverride() {
        #expect(TerminalTabSidebarModel.titleOverride(committing: "Build", seed: "Build", current: "Build") == "Build")
    }

    @Test func emptyTitleClearsOverride() {
        #expect(TerminalTabSidebarModel.titleOverride(committing: "", seed: "Build", current: "Build") == nil)
    }

    @Test func newTitleSetsOverride() {
        #expect(TerminalTabSidebarModel.titleOverride(committing: "Logs", seed: "zsh", current: nil) == "Logs")
    }

    /// Like the native tab bar's editor, only an empty title restores the default.
    @Test func whitespaceTitleIsKept() {
        #expect(TerminalTabSidebarModel.titleOverride(committing: " ", seed: "zsh", current: nil) == " ")
    }

    // MARK: - Width

    @MainActor
    @Test func widthStaysInRange() {
        #expect(TerminalTabSidebar.clampedWidth(50, availableWidth: 2000) == 120)
        #expect(TerminalTabSidebar.clampedWidth(250, availableWidth: 2000) == 250)
        #expect(TerminalTabSidebar.clampedWidth(500, availableWidth: 2000) == 400)
    }

    /// The divider takes 1pt and the terminal keeps at least 200pt.
    @MainActor
    @Test func widthLeavesRoomForTerminal() {
        #expect(TerminalTabSidebar.clampedWidth(350, availableWidth: 500) == 299)
    }

    @MainActor
    @Test func widthKeepsMinimumInNarrowWindow() {
        #expect(TerminalTabSidebar.clampedWidth(200, availableWidth: 250) == 120)
    }

    // MARK: - Reordering

    /// Rows are 30pt apart, so a row dragged less than halfway to the next one stays.
    @MainActor
    @Test func shortDragKeepsPosition() {
        #expect(TerminalTabSidebar.reorderDestination(from: 2, translation: 10, count: 5) == 2)
    }

    /// A row dragged one and a half rows moves two positions.
    @MainActor
    @Test func dragMovesToNearestPosition() {
        #expect(TerminalTabSidebar.reorderDestination(from: 1, translation: 45, count: 5) == 3)
        #expect(TerminalTabSidebar.reorderDestination(from: 2, translation: -30, count: 5) == 1)
    }

    @MainActor
    @Test func dragStaysInList() {
        #expect(TerminalTabSidebar.reorderDestination(from: 1, translation: -300, count: 5) == 0)
        #expect(TerminalTabSidebar.reorderDestination(from: 3, translation: 300, count: 5) == 4)
    }
}
