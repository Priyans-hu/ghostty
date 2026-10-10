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
    /// back on screen without becoming key, such as when the app is unhidden.
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
                self?.refresh()
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

    func refresh() {
        // The window only carries a key equivalent label while it is in a tab group, so a
        // lone tab would have none. Look the shortcuts up from the keybinds instead.
        let config = (window?.windowController as? BaseTerminalController)?.ghostty.config
        let newTabs = tabWindows.enumerated().map { offset, tabWindow in
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

        // The tab whose title is being edited is gone, such as when it was closed or
        // moved to another window, so there is nothing to commit the edit to.
        if let renamingTabID, !newTabs.contains(where: { $0.id == renamingTabID }) {
            finishRename(commit: false)
        }

        guard newTabs != tabs else { return }
        tabs = newTabs
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

/// Places the vertical tab sidebar beside a terminal window's content.
struct TerminalTabSidebarLayout<Content: View>: View {
    @ObservedObject var model: TerminalTabSidebarModel
    let content: Content

    @AppStorage(TerminalTabSidebar.collapsedKey, store: .ghostty) private var isCollapsed = false
    @AppStorage(TerminalTabSidebar.widthKey, store: .ghostty) private var width = TerminalTabSidebar.defaultWidth

    /// The sidebar width when the current resize drag began.
    @State private var widthAtDragStart: Double?

    init(model: TerminalTabSidebarModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            // The window's appearance already follows its background, so the sidebar's
            // light or dark content matches the titlebar without setting a color scheme.
            TerminalTabSidebar(model: model, isCollapsed: $isCollapsed)
                .frame(width: isCollapsed ? TerminalTabSidebar.collapsedWidth : width)
                .background(Color(nsColor: model.backgroundColor ?? .clear))

            divider

            content
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: TerminalTabSidebar.dividerWidth)
            .overlay {
                if !isCollapsed {
                    // A wider invisible strip so the divider is easy to grab.
                    Color.clear
                        .frame(width: 7)
                        .contentShape(Rectangle())
                        .gesture(resizeGesture)
                        .onHover { isHovering in
                            if isHovering {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = widthAtDragStart ?? width
                widthAtDragStart = start
                let range = TerminalTabSidebar.widthRange
                width = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                widthAtDragStart = nil
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

    /// The width the sidebar and its divider currently take out of a window's content.
    static var occupiedWidth: CGFloat {
        let defaults = UserDefaults.ghostty
        if defaults.bool(forKey: collapsedKey) {
            return collapsedWidth + dividerWidth
        }

        let width = defaults.object(forKey: widthKey) as? Double ?? defaultWidth
        return width + dividerWidth
    }

    @ObservedObject var model: TerminalTabSidebarModel
    @Binding var isCollapsed: Bool

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
                    LazyVStack(spacing: 2) {
                        ForEach(model.tabs) { tab in
                            TerminalTabSidebarRow(model: model, tab: tab, isCompact: true)
                        }
                    }
                    .padding(.bottom, 6)
                }
            } else {
                HStack {
                    collapseButton
                    Spacer()
                    newTabButton
                }
                .padding(.horizontal, 6)
                .frame(height: 40)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.tabs) { tab in
                                TerminalTabSidebarRow(
                                    model: model,
                                    tab: tab,
                                    isCompact: false,
                                    isRenaming: model.renamingTabID == tab.id)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    // Keep the row whose title is being edited in view.
                    .onChange(of: model.renamingTabID) { id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                model.select(tab)
            }
            .onHover { isHovering = $0 }
            .help(tab.title)
            .overlay(TerminalTabSidebarClickArea(
                tabID: tab.id,
                isRenaming: isRenaming,
                menu: { model.contextMenu(for: tab) },
                onDoubleClick: { model.rename(tab) }))
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
            .frame(width: 30, height: 30)
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
        .frame(height: 28)
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
/// control-click shows an AppKit menu, and a double-click renames the tab. Every other
/// mouse event goes through to the SwiftUI views beneath it.
private struct TerminalTabSidebarClickArea: NSViewRepresentable {
    let tabID: ObjectIdentifier
    let isRenaming: Bool
    let menu: () -> NSMenu
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClickAreaView {
        let view = ClickAreaView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: ClickAreaView, context: Context) {
        nsView.tabID = tabID
        nsView.isRenaming = isRenaming
        nsView.menuProvider = menu
        nsView.onDoubleClick = onDoubleClick
    }

    final class ClickAreaView: NSView {
        /// The tab whose row last took a single click, in any copy of the sidebar. The first
        /// click of a double-click can select another tab, which shows that tab's window, so
        /// the second click lands in that window's copy of the sidebar.
        private static var lastClickedTabID: ObjectIdentifier?

        var tabID: ObjectIdentifier?
        var isRenaming = false
        var menuProvider: (() -> NSMenu)?
        var onDoubleClick: (() -> Void)?

        /// Whether this view kept the last mouse down from the row beneath, so it keeps the
        /// mouse up too.
        private var keptMouseDown = false

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
            case .leftMouseDown where event.clickCount > 1:
                // The rest of a double-click is handled here.
                return super.hitTest(point)
            case .leftMouseDown:
                // The row selects the tab, but remember the tab in case this is the first
                // click of a double-click.
                if super.hitTest(point) != nil {
                    Self.lastClickedTabID = tabID
                }
                return nil
            default:
                return nil
            }
        }

        override func mouseDown(with event: NSEvent) {
            keptMouseDown = !event.modifierFlags.contains(.control)
            guard keptMouseDown else {
                super.mouseDown(with: event)
                return
            }

            // Only rename the tab if the first click was on it too. If the tab under the
            // mouse changed in between, such as when the first click closed a tab and the
            // next one moved up, the click does nothing rather than select or close it.
            if event.clickCount == 2, let tabID, Self.lastClickedTabID == tabID {
                onDoubleClick?()
            }
        }

        override func mouseUp(with event: NSEvent) {
            guard keptMouseDown else {
                super.mouseUp(with: event)
                return
            }
            keptMouseDown = false
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            menuProvider?()
        }
    }
}
