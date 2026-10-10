import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the tabs of a window with the vertical tab sidebar may have changed: their
    /// order, titles, colors, key equivalents, or which one is selected. The object is the
    /// window whose tab changed.
    static let terminalTabsDidChange = Notification.Name("com.mitchellh.ghostty.terminalTabsDidChange")
}

/// The tabs of one terminal window's tab group, as listed by the vertical tab sidebar.
///
/// Every tab is its own window, so each window owns a model and shows its own copy of the
/// sidebar. Only the selected tab's window is on screen, so that is the copy the user sees.
@MainActor
final class TerminalTabSidebarModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier

        /// The 1-based position of the tab in its window.
        let index: Int
        let title: String
        let keyEquivalent: String?
        let color: TerminalTabColor
        let isSelected: Bool
    }

    @Published private(set) var tabs: [Tab] = []

    /// The color behind the sidebar, which is the one the window's titlebar uses. Nil draws
    /// nothing, so a glass window background shows through.
    @Published private(set) var backgroundColor: NSColor?

    /// The font of the window's title, or nil for the system font.
    @Published private(set) var titleFont: NSFont?

    /// The tab whose title is being edited in its row, if any.
    @Published private(set) var renamingTabID: ObjectIdentifier?

    /// Incremented when the list of tabs should scroll the selected tab into view: when
    /// the window becomes key, and when tabs are added while it is on screen.
    @Published private(set) var revealCount = 0

    /// The title that the edit in progress started from.
    private(set) var renameSeed = ""

    /// The title typed so far in the edit in progress.
    var renameText = ""

    /// The controller of the tab whose title is being edited.
    private weak var renamingController: BaseTerminalController?

    /// The window this sidebar is shown in.
    weak var window: NSWindow? {
        didSet {
            observeWindow()
            refresh()
        }
    }

    private var observer: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []

    /// Whether a refresh is already waiting to run on the main queue.
    private var isRefreshScheduled = false

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .terminalTabsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // The observer is delivered on the main queue.
            MainActor.assumeIsolated {
                self?.tabsDidChange(notification.object as? NSWindow)
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        for windowObserver in windowObservers {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }

    /// Forgets the window once it closes. Asking AppKit for a closed window's tabs (as a
    /// late refresh would) registers it with a tab group again, which keeps it alive.
    ///
    /// A hidden copy of the sidebar skips refreshes, so it also refreshes when its window
    /// becomes key, which happens before the window is drawn, and when its window comes
    /// back on screen without becoming key, such as when the app is unhidden. Becoming
    /// key also scrolls the selected tab into view.
    ///
    /// Like the native tab bar's editor, a title edit in progress commits when the window
    /// stops being key, such as when another tab is selected, and when it closes.
    private func observeWindow() {
        let center = NotificationCenter.default
        for windowObserver in windowObservers {
            center.removeObserver(windowObserver)
        }
        windowObservers = []
        guard let window else { return }

        windowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Forgetting the window empties the list of tabs, which would cancel
                // the edit, so commit it first.
                self?.finishRename(commit: true)
                self?.window = nil
            }
        })

        windowObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishRename(commit: true)
            }
        })

        windowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                self.revealCount += 1
            }
        })

        windowObservers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
                self.refresh()
            }
        })
    }

    /// Refreshes once the tab group settles if the window whose tab changed is ours or one
    /// of our tabs. Only identities are compared, because asking a closing window for its
    /// tab group would register it with one again.
    private func tabsDidChange(_ changed: NSWindow?) {
        if let changed,
           changed !== window,
           !tabs.contains(where: { $0.id == ObjectIdentifier(changed) }) {
            return
        }

        scheduleRefresh()
    }

    /// Refreshes on the next turn of the main queue, once for however many changes arrive
    /// before then. The tab group takes that long to settle after a tab is added, closed,
    /// or moved.
    private func scheduleRefresh() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRefreshScheduled = false

            // Only the selected tab's copy of the sidebar is on screen. The others catch
            // up when their window is shown. `isVisible` is true for every window in
            // a tab group, so this asks the occlusion state instead.
            guard self.window?.occlusionState.contains(.visible) == true else { return }
            self.refresh()
        }
    }

    /// The windows in our tab group in tab order. A window that isn't tabbed is its own only tab.
    ///
    /// This asks the tab group because `tabbedWindows` is nil whenever the window isn't
    /// showing a tab bar. AppKit remembers View > Hide Tab Bar across windows, so that
    /// would leave the sidebar with only our own tab.
    private var tabWindows: [NSWindow] {
        guard let window else { return [] }
        return window.tabGroup?.windows ?? [window]
    }

    /// The state shared with the other copies of the sidebar in our tab group. It is
    /// looked up each time because the window can move to another tab group.
    var groupState: TerminalTabSidebarGroupState? {
        window?.tabGroup.map(TerminalTabSidebarGroupState.shared(for:))
    }

    /// Whether this is the selected tab's copy of the sidebar, which is the one on screen.
    /// It already is when its window becomes key, before the window is drawn.
    private var isSelectedTab: Bool {
        guard let window else { return false }
        return (window.tabGroup?.selectedWindow ?? window) === window
    }

    func refresh() {
        // A tab that moves leaves the tab group and joins it again, so until the move is
        // done the group lists it in passing positions or not at all.
        if groupState?.isMovingTab == true { return }

        let newTabs = makeTabs(for: tabWindows)

        // The tab whose title is being edited is gone, such as when it was closed or
        // moved to another window, so there is nothing to commit the edit to.
        if let renamingTabID, !newTabs.contains(where: { $0.id == renamingTabID }) {
            finishRename(commit: false)
        }

        guard newTabs != tabs else { return }
        setTabs(newTabs)
    }

    /// Lists the given tabs. On screen, the list keeps the selected tab in view when tabs
    /// are added, such as a new tab that the tab group only lists once it settles, and when
    /// the selected tab moves. Closing other tabs doesn't scroll the list back to the
    /// selected tab, which would be in the way of closing more.
    private func setTabs(_ newTabs: [Tab]) {
        let isTabAdded = newTabs.count > tabs.count
        let isSelectedTabMoved = newTabs.count == tabs.count
            && newTabs.firstIndex(where: \.isSelected) != tabs.firstIndex(where: \.isSelected)
        tabs = newTabs
        if (isTabAdded || isSelectedTabMoved) && isSelectedTab {
            revealCount += 1
        }
    }

    /// The tabs listed for the given windows of our tab group, in the order given.
    private func makeTabs(for windows: [NSWindow]) -> [Tab] {
        // The window only carries a key equivalent label while it is in a tab group, so a
        // lone tab would have none. Look the shortcuts up from the keybinds instead.
        let config = (window?.windowController as? BaseTerminalController)?.ghostty.config
        return windows.enumerated().map { offset, tabWindow in
            let index = offset + 1
            return Tab(
                id: ObjectIdentifier(tabWindow),
                index: index,
                title: tabWindow.title,
                keyEquivalent: config.flatMap { TerminalController.tabKeyEquivalent(at: index, config: $0) },
                color: (tabWindow as? TerminalWindow)?.tabColor ?? .none,
                // Our window is only on screen while it is the selected tab.
                isSelected: tabWindow === window
            )
        }
    }

    /// Remembers how far the list of tabs is scrolled, so the copy of the sidebar shown
    /// when another tab is selected scrolls the same. Only the copy on screen counts. The
    /// others can lay out again while hidden, such as when the sidebar is resized.
    func scrollOffsetDidChange(_ offset: CGFloat) {
        guard isSelectedTab else { return }
        groupState?.scrollOffset = offset
    }

    /// Matches the sidebar to its window's titlebar. Only changed values are published.
    func syncAppearance(backgroundColor: NSColor?, titleFont: NSFont?) {
        if self.backgroundColor != backgroundColor {
            self.backgroundColor = backgroundColor
        }

        if self.titleFont != titleFont {
            self.titleFont = titleFont
        }
    }

    func newTab() {
        (window?.windowController as? TerminalController)?.newTab(nil)
    }

    func select(_ tab: Tab) {
        // Like clicking anywhere else, selecting a tab commits a title edit in progress.
        finishRename(commit: true)
        tabWindow(for: tab)?.makeKeyAndOrderFront(nil)
    }

    func close(_ tab: Tab) {
        controller(for: tab)?.closeTab(nil)
    }

    func closeOthers(_ tab: Tab) {
        select(tab)
        controller(for: tab)?.closeOtherTabs(nil)
    }

    func closeBelow(_ tab: Tab) {
        select(tab)
        controller(for: tab)?.closeTabsOnTheRight(nil)
    }

    func moveToNewWindow(_ tab: Tab) {
        tabWindow(for: tab)?.moveTabToNewWindow(nil)
    }

    func showAllTabs() {
        window?.toggleTabOverview(nil)
    }

    /// Whether tabs can be moved by dragging their rows. Not while a title is being edited,
    /// and not in fullscreen: a tab moves by leaving the tab group and joining it again,
    /// which could take its window out of the fullscreen space.
    var canReorderTabs: Bool {
        guard tabs.count > 1, renamingTabID == nil, let window else { return false }
        let fullscreenStyle = (window.windowController as? BaseTerminalController)?.fullscreenStyle
        return !window.styleMask.contains(.fullScreen) && !(fullscreenStyle?.isFullscreen ?? false)
    }

    /// Moves a tab to the given 0-based position, the way the move_tab action does. The new
    /// order is listed right away and kept while the tab group catches up.
    func move(_ tab: Tab, to destination: Int) {
        guard canReorderTabs,
              let window,
              let tabGroup = window.tabGroup,
              let groupState,
              let moving = tabWindow(for: tab)
        else { return }

        let windows = tabGroup.windows
        guard let source = windows.firstIndex(of: moving),
              windows.indices.contains(destination),
              destination != source
        else { return }

        var reordered = windows
        reordered.insert(reordered.remove(at: source), at: destination)
        setTabs(makeTabs(for: reordered))

        // Every copy of the sidebar in the tab group keeps its list until the move is done.
        groupState.isMovingTab = true

        // Take the tab out of the group and add it back beside the tab at its new position,
        // without animating. The selected tab stays selected, but selecting a window that
        // isn't in the group throws.
        let target = windows[destination]
        let selected = tabGroup.selectedWindow
        let selectedFrame = selected?.frame
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tabGroup.removeWindow(moving)
        target.addTabbedWindowSafely(moving, ordered: destination < source ? .below : .above)
        if let selected, tabGroup.windows.contains(selected) {
            tabGroup.selectedWindow = selected
        }
        NSAnimationContext.endGrouping()

        // Leaving and joining the group can move the window that stays on screen.
        if let selected, let selectedFrame, selected.frame != selectedFrame {
            selected.setFrame(selectedFrame, display: false)
        }

        DispatchQueue.main.async { [weak self, weak selected] in
            selected?.makeKey()
            groupState.isMovingTab = false

            // Relabeling sets the key equivalents of the tabs and tells the other copies
            // of the sidebar about the new order.
            (self?.window?.windowController as? TerminalController)?.relabelTabs()
            self?.refresh()
        }
    }

    /// Renames a tab by editing its title in its row. The collapsed rail has no room for
    /// an editor, so it prompts for the title instead.
    func rename(_ tab: Tab) {
        guard let tabWindow = tabWindow(for: tab) else { return }
        if beginRename(for: tabWindow) { return }

        // This runs from menus and mouse events, so the prompt's sheet is shown once
        // they are done.
        select(tab)
        let tabController = controller(for: tab)
        DispatchQueue.main.async { [weak tabController] in
            tabController?.promptTabTitle()
        }
    }

    /// Starts editing a tab's title in its row. Returns false if the sidebar can't, such as
    /// when it is collapsed to the rail, which has no room for an editor.
    @discardableResult
    func beginRename(for tabWindow: NSWindow) -> Bool {
        guard !UserDefaults.ghostty.bool(forKey: TerminalTabSidebar.collapsedKey),
              tabWindows.contains(where: { $0 === tabWindow }),
              let controller = tabWindow.windowController as? BaseTerminalController
        else { return false }

        // Starting over would throw away what has been typed.
        let id = ObjectIdentifier(tabWindow)
        guard renamingTabID != id else { return true }
        finishRename(commit: true)

        // Like the title prompt, start from the title the user set, if any.
        renameSeed = controller.titleOverride ?? tabWindow.title
        renameText = renameSeed
        renamingController = controller
        renamingTabID = id
        return true
    }

    /// Ends the title edit in progress, if any, and gives the terminal its focus back.
    func finishRename(commit: Bool) {
        // Cleared first so the editor ending its own editing can't finish the edit again.
        guard renamingTabID != nil else { return }
        renamingTabID = nil

        if commit, let renamingController {
            renamingController.titleOverride = Self.titleOverride(
                committing: renameText,
                seed: renameSeed,
                current: renamingController.titleOverride)
        }
        renamingController = nil

        guard let window,
              !(window.firstResponder is Ghostty.SurfaceView),
              let focusedSurface = (window.windowController as? BaseTerminalController)?.focusedSurface
        else { return }
        window.makeFirstResponder(focusedSurface)
    }

    /// The title override to set when an edit that started from `seed` commits `text`.
    ///
    /// Committing the title unchanged keeps the current override, so a title that comes
    /// from the terminal keeps following it rather than being frozen. An empty title
    /// restores the default, like the native tab bar's editor.
    nonisolated static func titleOverride(committing text: String, seed: String, current: String?) -> String? {
        guard text != seed else { return current }
        return text.isEmpty ? nil : text
    }

    func setColor(_ color: TerminalTabColor, for tab: Tab) {
        (tabWindow(for: tab) as? TerminalWindow)?.tabColor = color
    }

    /// The right-click menu for a tab. It has the same items as a native tab's menu, including
    /// the tab color palette, which is why it is an AppKit menu: the palette is a custom menu
    /// item view and SwiftUI menus can't hold one.
    func contextMenu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let hasOtherTabs = tabs.count > 1
        menu.addItem(menuItem("Close Tab", symbol: "xmark") { [weak self] in
            self?.close(tab)
        })
        menu.addItem(menuItem("Close Other Tabs", symbol: "xmark", isEnabled: hasOtherTabs) { [weak self] in
            self?.closeOthers(tab)
        })
        menu.addItem(menuItem("Close Tabs to the Right", symbol: "xmark", isEnabled: tab.index < tabs.count) { [weak self] in
            self?.closeBelow(tab)
        })
        menu.addItem(menuItem("Move Tab to New Window", symbol: "macwindow.badge.plus", isEnabled: hasOtherTabs) { [weak self] in
            self?.moveToNewWindow(tab)
        })
        menu.addItem(menuItem("Show All Tabs") { [weak self] in
            self?.showAllTabs()
        })

        menu.addItem(.separator())
        menu.addItem(menuItem("Rename Tab...", symbol: "pencil.line") { [weak self] in
            self?.rename(tab)
        })

        let paletteItem = NSMenuItem()
        paletteItem.view = makeTabColorPaletteView(selectedColor: tab.color) { [weak self] color in
            self?.setColor(color, for: tab)
        }
        menu.addItem(paletteItem)

        return menu
    }

    private func menuItem(
        _ title: String,
        symbol: String? = nil,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke(_:)), keyEquivalent: "")
        item.target = action
        // The item's target is weak, so the item itself keeps the action alive.
        item.representedObject = action
        item.isEnabled = isEnabled
        if let symbol {
            item.setImageIfDesired(systemSymbolName: symbol)
        }
        return item
    }

    /// Runs a closure as a menu item's action.
    private final class MenuAction: NSObject {
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }

        // This can't be named `perform(_:)`. A selector for that resolves to
        // NSObject's `performSelector:`, so choosing the item would do nothing.
        @objc func invoke(_ sender: Any?) {
            handler()
        }
    }

    private func tabWindow(for tab: Tab) -> NSWindow? {
        tabWindows.first { ObjectIdentifier($0) == tab.id }
    }

    private func controller(for tab: Tab) -> TerminalController? {
        tabWindow(for: tab)?.windowController as? TerminalController
    }
}

/// The state shared by the copies of the vertical tab sidebar in one tab group.
@MainActor
final class TerminalTabSidebarGroupState {
    /// How far the list of tabs is scrolled in the copy of the sidebar on screen, or nil
    /// if it hasn't scrolled yet.
    var scrollOffset: CGFloat?

    /// Whether a tab is being moved to another position by dragging its row.
    var isMovingTab = false

    private static let states = NSMapTable<NSWindowTabGroup, TerminalTabSidebarGroupState>.weakToStrongObjects()

    static func shared(for tabGroup: NSWindowTabGroup) -> TerminalTabSidebarGroupState {
        if let state = states.object(forKey: tabGroup) {
            return state
        }

        let state = TerminalTabSidebarGroupState()
        states.setObject(state, forKey: tabGroup)
        return state
    }
}

/// Places the vertical tab sidebar beside a terminal window's content.
struct TerminalTabSidebarLayout<Content: View>: View {
    @ObservedObject var model: TerminalTabSidebarModel
    let content: Content

    @AppStorage(TerminalTabSidebar.collapsedKey, store: .ghostty) private var isCollapsed = false
    @AppStorage(TerminalTabSidebar.widthKey, store: .ghostty) private var width = TerminalTabSidebar.defaultWidth

    /// The sidebar width while its divider is being dragged. The width is only saved once
    /// the drag ends, so other windows and the other tabs of this one lay out once rather
    /// than on every step of the drag.
    @State private var dragWidth: Double?

    init(model: TerminalTabSidebarModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            // The window's appearance already follows its background, so the sidebar's
            // light or dark content matches the titlebar without setting a color scheme.
            TerminalTabSidebar(model: model, isCollapsed: $isCollapsed)
                .frame(width: isCollapsed ? TerminalTabSidebar.collapsedWidth : expandedWidth)
                .background(Color(nsColor: model.backgroundColor ?? .clear))

            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: TerminalTabSidebar.dividerWidth)

            content
        }
        // The handle lies over the whole layout rather than the divider so that it is
        // above the terminal's view, which it reaches over.
        .overlay(alignment: .leading) {
            if !isCollapsed {
                resizeHandle
            }
        }
    }

    /// The width of the sidebar when it isn't collapsed.
    private var expandedWidth: Double {
        dragWidth ?? width
    }

    private var resizeHandle: some View {
        TerminalTabSidebarResizeHandle(
            width: expandedWidth,
            onResize: { dragWidth = $0 },
            onResizeEnd: {
                if let dragWidth { width = dragWidth }
                dragWidth = nil
            },
            onReset: {
                dragWidth = nil
                width = TerminalTabSidebar.defaultWidth
            })
        .frame(width: TerminalTabSidebarResizeHandle.sidebarOverlap
            + TerminalTabSidebar.dividerWidth
            + TerminalTabSidebarResizeHandle.contentOverlap)
        .offset(x: expandedWidth - TerminalTabSidebarResizeHandle.sidebarOverlap)
    }
}

/// The area around the tab sidebar's divider that resizes the sidebar when dragged and
/// resets its width when double-clicked. It is an AppKit view so that the resize cursor
/// comes from a cursor rect, which goes away with the view when the sidebar collapses.
private struct TerminalTabSidebarResizeHandle: NSViewRepresentable {
    /// How far the handle reaches into the sidebar, beside the divider.
    static let sidebarOverlap: Double = 6

    /// How far the handle reaches over the terminal, beside the divider.
    static let contentOverlap: Double = 4

    /// The current width of the sidebar.
    let width: Double
    let onResize: (Double) -> Void
    let onResizeEnd: () -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.width = width
        nsView.onResize = onResize
        nsView.onResizeEnd = onResizeEnd
        nsView.onReset = onReset
    }

    final class HandleView: NSView {
        var width: Double = 0
        var onResize: ((Double) -> Void)?
        var onResizeEnd: (() -> Void)?
        var onReset: (() -> Void)?

        /// Where the drag in progress began, in window coordinates, and the sidebar width
        /// then. The handle moves with the divider, so the drag is measured in the window.
        private var dragStart: (x: CGFloat, width: Double)?

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func cursorUpdate(with event: NSEvent) {
            // Where the handle reaches over the terminal, the terminal's cursor rect
            // overlaps this one, so don't leave the cursor to the overlapping rects.
            NSCursor.resizeLeftRight.set()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Scrolling belongs to the sidebar's list or the terminal beneath.
            guard NSApp.currentEvent?.type != .scrollWheel else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                dragStart = nil
                onReset?()
                return
            }

            dragStart = (event.locationInWindow.x, width)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }

            // The sidebar and the terminal share the window's content.
            let width = dragStart.width + event.locationInWindow.x - dragStart.x
            let availableWidth = window?.contentView?.bounds.width ?? .infinity
            onResize?(TerminalTabSidebar.clampedWidth(width, availableWidth: availableWidth))
        }

        override func mouseUp(with event: NSEvent) {
            dragStart = nil
            onResizeEnd?()
        }
    }
}

/// The vertical list of a terminal window's tabs, replacing the native tab bar.
struct TerminalTabSidebar: View {
    static let collapsedKey = "TerminalTabSidebarCollapsed"
    static let widthKey = "TerminalTabSidebarWidth"
    static let defaultWidth: Double = 200
    static let widthRange: ClosedRange<Double> = 120...400
    static let collapsedWidth: Double = 40
    static let dividerWidth: Double = 1

    /// The height of a row in the list of tabs, the size of a tile in the collapsed rail,
    /// and the space between them.
    static let rowHeight: CGFloat = 28
    static let tileSize: CGFloat = 30
    static let rowSpacing: CGFloat = 2

    /// The distance from the top of one row in the list of tabs to the top of the next.
    static let rowPitch: CGFloat = rowHeight + rowSpacing

    /// The 0-based position that a row dragged `translation` points from position `from`
    /// moves to in a list of `count` rows: that of the row nearest to where it is dropped.
    static func reorderDestination(from: Int, translation: CGFloat, count: Int) -> Int {
        max(0, min(from + Int((translation / rowPitch).rounded()), count - 1))
    }

    /// The narrowest that resizing the sidebar can make the terminal beside it.
    static let minimumTerminalWidth: Double = 200

    /// The width of a sidebar resized to `width` in a window whose content is
    /// `availableWidth` wide. It stays within `widthRange` and leaves the terminal at least
    /// `minimumTerminalWidth`, except in a window too narrow for both, where the sidebar
    /// keeps its minimum width.
    static func clampedWidth(_ width: Double, availableWidth: Double) -> Double {
        let maximum = min(widthRange.upperBound, availableWidth - dividerWidth - minimumTerminalWidth)
        return max(widthRange.lowerBound, min(width, maximum))
    }

    /// The width the sidebar and its divider currently take out of a window's content.
    static var occupiedWidth: CGFloat {
        let defaults = UserDefaults.ghostty
        if defaults.bool(forKey: collapsedKey) {
            return collapsedWidth + dividerWidth
        }

        let width = defaults.object(forKey: widthKey) as? Double ?? defaultWidth
        return width + dividerWidth
    }

    /// A row being dragged to another position in the list of tabs.
    private struct ReorderDrag {
        let id: ObjectIdentifier

        /// The 0-based position of the row when the drag began.
        let from: Int

        /// How far the row has been dragged up or down.
        var translation: CGFloat
    }

    /// The coordinate space that rows are dragged in. It is the list's, because the row
    /// itself moves with the drag.
    private static let listCoordinateSpace = "TerminalTabSidebarList"

    /// When a drag ends, the rows go straight to their new places rather than the rows
    /// that made room for the dragged one sliding back first.
    private static let reorderEndTransaction: Transaction = {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }()

    @ObservedObject var model: TerminalTabSidebarModel
    @Binding var isCollapsed: Bool

    /// The row being dragged, if any. This resets on its own if the drag is cancelled.
    @GestureState(resetTransaction: TerminalTabSidebar.reorderEndTransaction)
    private var reorderDrag: ReorderDrag?

    var body: some View {
        VStack(spacing: 0) {
            if isCollapsed {
                VStack(spacing: 4) {
                    collapseButton
                    newTabButton
                }
                .padding(.top, 5)
                .padding(.bottom, 6)

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: Self.rowSpacing) {
                        ForEach(model.tabs) { tab in
                            TerminalTabSidebarRow(model: model, tab: tab, isCompact: true)
                        }
                    }
                    .padding(.bottom, 6)
                    .background(TerminalTabSidebarScrollOffsetReader(model: model))
                }
                .modifier(TerminalTabSidebarScrollKeeper(model: model, rowHeight: Self.tileSize))
            } else {
                HStack {
                    collapseButton
                    Spacer()
                    newTabButton
                }
                .padding(.horizontal, 6)
                .frame(height: 40)

                ScrollView {
                    LazyVStack(spacing: Self.rowSpacing) {
                        let canReorder = model.canReorderTabs
                        ForEach(model.tabs) { tab in
                            let shift = reorderShift(for: tab)
                            TerminalTabSidebarRow(
                                model: model,
                                tab: tab,
                                isCompact: false,
                                isRenaming: model.renamingTabID == tab.id
                            )
                            .offset(y: shift)
                            .animation(.easeOut(duration: 0.15), value: shift)
                            // The dragged row follows the mouse without animating.
                            .offset(y: dragOffset(for: tab))
                            .zIndex(reorderDrag?.id == tab.id ? 1 : 0)
                            // Before the row's own gestures, so a drag doesn't also select
                            // or close the tab, while a click that doesn't move still does.
                            .highPriorityGesture(reorderGesture(for: tab), including: canReorder ? .all : .subviews)
                        }
                    }
                    .coordinateSpace(name: Self.listCoordinateSpace)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    .background(TerminalTabSidebarScrollOffsetReader(model: model))
                }
                .modifier(TerminalTabSidebarScrollKeeper(model: model, rowHeight: Self.rowHeight))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Drags a row to another position in the list. The row moves to the position nearest
    /// to where it is dropped, within the list.
    private func reorderGesture(for tab: TerminalTabSidebarModel.Tab) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listCoordinateSpace))
            .updating($reorderDrag) { value, drag, _ in
                if drag == nil {
                    // Fullscreen doesn't update the view, so check again as the drag begins.
                    guard model.canReorderTabs else { return }
                    drag = ReorderDrag(id: tab.id, from: tab.index - 1, translation: 0)
                }
                drag?.translation = value.translation.height
            }
            .onEnded { value in
                let source = tab.index - 1
                let destination = Self.reorderDestination(
                    from: source,
                    translation: value.translation.height,
                    count: model.tabs.count)
                guard destination != source else { return }
                withTransaction(Self.reorderEndTransaction) {
                    model.move(tab, to: destination)
                }
            }
    }

    /// How far the row being dragged is from its place, kept within the list.
    private func dragOffset(for tab: TerminalTabSidebarModel.Tab) -> CGFloat {
        guard let reorderDrag, reorderDrag.id == tab.id else { return 0 }
        let above = CGFloat(reorderDrag.from) * Self.rowPitch
        let below = CGFloat(model.tabs.count - 1 - reorderDrag.from) * Self.rowPitch
        return min(max(reorderDrag.translation, -above), below)
    }

    /// How far a row moves aside to make room for the row being dragged past it.
    private func reorderShift(for tab: TerminalTabSidebarModel.Tab) -> CGFloat {
        guard let reorderDrag, reorderDrag.id != tab.id else { return 0 }
        let index = tab.index - 1
        let destination = Self.reorderDestination(
            from: reorderDrag.from,
            translation: reorderDrag.translation,
            count: model.tabs.count)
        if reorderDrag.from < index && index <= destination { return -Self.rowPitch }
        if destination <= index && index < reorderDrag.from { return Self.rowPitch }
        return 0
    }

    private var collapseButton: some View {
        TerminalTabSidebarButton(
            systemName: "sidebar.left",
            label: isCollapsed ? "Show Tab Sidebar" : "Hide Tab Sidebar"
        ) {
            // The rail has no room for a title editor.
            model.finishRename(commit: true)
            isCollapsed.toggle()
        }
    }

    private var newTabButton: some View {
        TerminalTabSidebarButton(systemName: "plus", label: "New Tab") {
            model.newTab()
        }
    }
}

/// Scrolls a list of tabs in the sidebar the same as the copy of the sidebar that was on
/// screen before, and only as much more as it takes to show all of the selected tab's
/// row. Every tab's window has its own copy, so the list would otherwise jump whenever
/// another tab is selected.
private struct TerminalTabSidebarScrollKeeper: ViewModifier {
    static let coordinateSpace = "TerminalTabSidebarScrollView"

    @ObservedObject var model: TerminalTabSidebarModel

    /// The height of every row in the list.
    let rowHeight: CGFloat

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                let listHeight = geometry.size.height
                content
                    .coordinateSpace(name: Self.coordinateSpace)
                    .onAppear {
                        // The list hasn't laid out its rows yet.
                        DispatchQueue.main.async {
                            reveal(proxy, listHeight: listHeight)
                        }
                    }
                    .onChange(of: model.revealCount) { _ in
                        reveal(proxy, listHeight: listHeight)
                    }
                    // Keep the row whose title is being edited in view.
                    .onChange(of: model.renamingTabID) { id in
                        if let id { proxy.scrollTo(id) }
                    }
            }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy, listHeight: CGFloat) {
        guard let index = model.tabs.firstIndex(where: \.isSelected) else { return }
        let id = model.tabs[index].id
        let anchor = revealAnchor(forRowAt: index, listHeight: listHeight)

        // Scrolling right away keeps the window from being drawn at the old offset first.
        // Rows that changed along with this may not be laid out until this turn of the main
        // queue is over, so scroll to the same place once more then.
        proxy.scrollTo(id, anchor: anchor)
        DispatchQueue.main.async {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    /// The anchor for scrolling to the selected row, which is at `index`, that leaves the
    /// list where the copy of the sidebar on screen before had it, if all of the row is in
    /// view there. Otherwise the row is aligned at its nearer edge. Nil scrolls as little
    /// as it takes to show the row from wherever this copy of the list is.
    private func revealAnchor(forRowAt index: Int, listHeight: CGFloat) -> UnitPoint? {
        guard let offset = model.groupState?.scrollOffset, listHeight > rowHeight else { return nil }

        // Every row has the same height, so this is where the top of the row would be
        // with the list at that offset. Aligning the same fraction of the row and of the
        // list puts the row exactly there.
        let top = CGFloat(index) * (rowHeight + TerminalTabSidebar.rowSpacing) - offset
        if top < 0 { return .top }
        if top > listHeight - rowHeight { return .bottom }
        return UnitPoint(x: 0.5, y: top / (listHeight - rowHeight))
    }
}

/// Tells the model how far the list of tabs it is behind is scrolled.
private struct TerminalTabSidebarScrollOffsetReader: View {
    let model: TerminalTabSidebarModel

    var body: some View {
        GeometryReader { geometry in
            let top = geometry.frame(in: .named(TerminalTabSidebarScrollKeeper.coordinateSpace)).minY
            Color.clear.onChange(of: top) { top in
                model.scrollOffsetDidChange(-top)
            }
        }
    }
}

/// A round icon button in the tab sidebar, drawn like the native tab bar's buttons.
private struct TerminalTabSidebarButton: View {
    enum Kind {
        /// Like the tab bar's new tab button: a large glass circle.
        case bar

        /// Like a tab's close button: a small circle lighter than the tab it sits on.
        case close
    }

    let systemName: String
    let label: String
    var kind: Kind = .bar
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: glyphWeight))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(kind == .close ? closeFill : .clear))
                .terminalTabSidebarGlass(
                    in: Circle(),
                    isEnabled: kind == .bar,
                    isInteractive: true,
                    tint: isHovering ? Color.primary.opacity(0.12) : nil,
                    fallback: barFallbackFill
                )
                // The click target can be larger than the circle that is drawn.
                .frame(width: targetSize, height: targetSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    private var diameter: CGFloat {
        switch kind {
        case .bar: 30
        case .close: 16
        }
    }

    private var targetSize: CGFloat {
        switch kind {
        case .bar: 30
        case .close: 22
        }
    }

    private var glyphSize: CGFloat {
        switch kind {
        case .bar: 14
        case .close: 8.5
        }
    }

    private var glyphWeight: Font.Weight {
        switch kind {
        case .bar: .medium
        case .close: .bold
        }
    }

    private var closeFill: Color {
        Color.primary.opacity(isHovering ? 0.30 : 0.16)
    }

    /// What the bar buttons are filled with where there is no glass.
    private var barFallbackFill: Color {
        if isHovering { return Color.primary.opacity(0.14) }
        return Color.black.opacity(colorScheme == .dark ? 0.28 : 0.07)
    }
}

private extension View {
    /// Draws the view on the system's Liquid Glass, which is what the native tab bar's tabs
    /// and buttons are made of and what gives them their bright rim. Glass needs macOS 26;
    /// earlier systems get a flat fill instead.
    @ViewBuilder
    func terminalTabSidebarGlass<S: Shape>(
        in shape: S,
        isEnabled: Bool = true,
        isInteractive: Bool = false,
        tint: Color? = nil,
        fallback: Color
    ) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(
                isEnabled ? Glass.regular.tint(tint).interactive(isInteractive) : .identity,
                in: shape
            )
        } else {
            background(shape.fill(isEnabled ? fallback : .clear))
        }
#else
        background(shape.fill(isEnabled ? fallback : .clear))
#endif
    }
}

/// One tab in the sidebar: a pill-shaped row when the sidebar is expanded, or a round
/// tile showing its key equivalent in the collapsed rail. The selected tab is drawn on glass like a native tab.
private struct TerminalTabSidebarRow: View {
    @ObservedObject var model: TerminalTabSidebarModel
    let tab: TerminalTabSidebarModel.Tab
    let isCompact: Bool

    /// Whether the tab's title is being edited in this row. Tiles in the rail never are.
    var isRenaming = false

    @State private var isHovering = false

    var body: some View {
        content
            // Like the titlebar, titles use `window-title-font-family` when it is set.
            .font(model.titleFont.map { Font($0) } ?? .system(size: 13))
            .foregroundStyle(Color.primary.opacity(tab.isSelected ? 1 : 0.75))
            .background(Capsule().fill(hoverFill))
            .terminalTabSidebarGlass(
                in: Capsule(),
                isEnabled: tab.isSelected,
                fallback: Color.primary.opacity(0.14)
            )
            .contentShape(Capsule())
            .onTapGesture {
                // While the title is being edited, clicks on the row belong to the editor.
                guard !isRenaming else { return }

                // Both clicks of a double-click come here, and the second one renames the tab,
                // but only if the first was on this tab too. It wasn't if the tab under the
                // mouse changed in between, such as when the first click closed a tab and the
                // next one moved up.
                switch Self.clickCount {
                case 1:
                    model.select(tab)
                case 2 where TerminalTabSidebarClickArea.ClickAreaView.lastClickedTabID == tab.id:
                    model.rename(tab)
                default:
                    break
                }
            }
            .onHover { isHovering = $0 }
            // Selecting another tab hides this window with the mouse still on the row, so
            // the row would look hovered when its window is shown again.
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didResignKeyNotification,
                object: model.window
            )) { _ in
                isHovering = false
            }
            .help(tab.title)
            .overlay(TerminalTabSidebarClickArea(
                tabID: tab.id,
                isRenaming: isRenaming,
                menu: { model.contextMenu(for: tab) },
                onMiddleClick: { model.close(tab) }))
            // The editor has to stay reachable while the title is being edited.
            .accessibilityElement(children: isRenaming ? .contain : .combine)
            .accessibilityIdentifier("TerminalTabSidebarRow")
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(tab.isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.select(tab) }
    }

    private var hoverFill: Color {
        Color.primary.opacity(!tab.isSelected && isHovering ? 0.08 : 0)
    }

    /// The click count of the left click being handled, such as 2 for the second click of a
    /// double-click. It is 1 when no left click is being handled.
    private static var clickCount: Int {
        guard let event = NSApp.currentEvent, event.type == .leftMouseUp else { return 1 }
        return event.clickCount
    }

    @ViewBuilder
    private var content: some View {
        if isCompact {
            tile
        } else {
            row
        }
    }

    private var tile: some View {
        // The key equivalent that selects the tab (e.g. ⌘1), or its position when it has none.
        Text(tab.keyEquivalent ?? "\(tab.index)")
            .font(.system(size: 11))
            .frame(width: TerminalTabSidebar.tileSize, height: TerminalTabSidebar.tileSize)
            .overlay(alignment: .topTrailing) {
                if let color = tab.color.displayColor {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 6, height: 6)
                        .padding(3)
                }
            }
    }

    private var row: some View {
        HStack(spacing: 4) {
            // Like a native tab, the close button is on the leading side and only shows
            // on hover. Its slot is always reserved so the title doesn't shift.
            ZStack {
                if isHovering {
                    TerminalTabSidebarButton(systemName: "xmark", label: "Close Tab", kind: .close) {
                        // A double-click closes one tab, not also the one that moves up into
                        // its place.
                        guard Self.clickCount == 1 else { return }
                        model.close(tab)
                    }
                } else if let color = tab.color.displayColor {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 22, height: 22)

            if isRenaming {
                // The editor takes the room of the title and the space after it.
                TerminalTabSidebarTitleEditor(model: model, tabID: tab.id)
            } else {
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)
            }

            if let keyEquivalent = tab.keyEquivalent {
                Text(keyEquivalent)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(height: TerminalTabSidebar.rowHeight)
    }
}

/// Edits a tab's title in its row with the rules of the native tab bar's editor: Return
/// commits, Escape cancels, and losing focus commits.
private struct TerminalTabSidebarTitleEditor: NSViewRepresentable {
    let model: TerminalTabSidebarModel
    let tabID: ObjectIdentifier

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, tabID: tabID)
    }

    func makeNSView(context: Context) -> NSTextField {
        // Configured like the native tab bar's editor. The text is only set here, because
        // setting it on updates would throw away what is being typed.
        let field = NSTextField(string: model.renameText)
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        if let cell = field.cell as? NSTextFieldCell {
            cell.wraps = false
            cell.usesSingleLineMode = true
            cell.isScrollable = true
        }
        field.font = model.titleFont ?? .systemFont(ofSize: 13)
        field.setAccessibilityIdentifier("TerminalTabSidebarTitleEditor")

        // Focus after insertion so AppKit has created the field editor for this text field.
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak field] in
            guard let field, coordinator.isEditing, let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        // Take the width the row offers rather than growing with the title.
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        nsView.delegate = nil

        // The field can go away in the middle of an edit, such as when its row scrolls out
        // of the lazy stack. Like losing focus, that commits. SwiftUI is updating its views
        // here, so the model changes on the next turn of the main queue.
        DispatchQueue.main.async {
            coordinator.finish(commit: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let model: TerminalTabSidebarModel
        private let tabID: ObjectIdentifier

        init(model: TerminalTabSidebarModel, tabID: ObjectIdentifier) {
            self.model = model
            self.tabID = tabID
        }

        /// Whether this field's edit is still in progress. The field can end editing after
        /// the edit is over, such as when it is removed because the edit finished.
        var isEditing: Bool {
            model.renamingTabID == tabID
        }

        func finish(commit: Bool) {
            guard isEditing else { return }
            model.finishRename(commit: commit)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                finish(commit: true)
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                finish(commit: false)
                return true

            default:
                return false
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard isEditing, let field = obj.object as? NSTextField else { return }
            model.renameText = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            finish(commit: true)
        }
    }
}

/// Handles the clicks on a tab in the sidebar that SwiftUI can't: a right-click or
/// control-click shows an AppKit menu, and a middle click closes it. Every other mouse
/// event goes through to the SwiftUI views beneath it.
private struct TerminalTabSidebarClickArea: NSViewRepresentable {
    let tabID: ObjectIdentifier
    let isRenaming: Bool
    let menu: () -> NSMenu
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> ClickAreaView {
        let view = ClickAreaView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: ClickAreaView, context: Context) {
        nsView.tabID = tabID
        nsView.isRenaming = isRenaming
        nsView.menuProvider = menu
        nsView.onMiddleClick = onMiddleClick
    }

    final class ClickAreaView: NSView {
        /// The tab whose row last took a single click, in any copy of the sidebar, so the row
        /// can tell whether a double-click began on its tab. The first click of a double-click
        /// can select another tab, which shows that tab's window, so the second click lands
        /// in that window's copy of the sidebar.
        private(set) static var lastClickedTabID: ObjectIdentifier?

        var tabID: ObjectIdentifier?
        var isRenaming = false
        var menuProvider: (() -> NSMenu)?
        var onMiddleClick: (() -> Void)?

        /// Whether a middle click started on this tab.
        private var middleClickStarted = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            // While the title is being edited, every click belongs to the editor. Otherwise
            // only claim the clicks handled here. Everything else, such as selecting the tab
            // or pressing its close button, belongs to the row beneath.
            guard !isRenaming, let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            case .leftMouseDown where event.modifierFlags.contains(.control):
                return super.hitTest(point)
            case .leftMouseDown where event.clickCount == 1:
                // The row selects the tab, and renames it on the second click of a
                // double-click, which AppKit sends to the view that took the first click
                // anyway. Remember the tab in case this is that first click.
                if super.hitTest(point) != nil {
                    Self.lastClickedTabID = tabID
                }
                return nil
            case .otherMouseDown where event.buttonNumber == 2,
                 .otherMouseUp where event.buttonNumber == 2:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func otherMouseDown(with event: NSEvent) {
            guard event.buttonNumber == 2 else {
                super.otherMouseDown(with: event)
                return
            }
            middleClickStarted = true
        }

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2 else {
                super.otherMouseUp(with: event)
                return
            }

            // The tab only closes if the middle click is released on the tab it started on.
            let isClick = middleClickStarted && bounds.contains(convert(event.locationInWindow, from: nil))
            middleClickStarted = false
            guard isClick else { return }

            // Closing the tab can close this window or ask for confirmation, so it waits
            // until this event is done.
            DispatchQueue.main.async { [onMiddleClick] in
                onMiddleClick?()
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            menuProvider?()
        }
    }
}
