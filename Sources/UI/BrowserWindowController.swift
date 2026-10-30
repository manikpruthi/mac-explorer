import AppKit
import QuickLookUI
import UniformTypeIdentifiers

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
    TitleBarDelegate, FileListViewDelegate, SidebarViewDelegate {

    // MARK: - State

    private(set) var systemInfo: SystemInfo
    private let store = AppStore.shared
    private var tabs: [TabModel]
    private var activeIndex = 0
    private var clipboard = ClipboardInfo.empty
    private var renamingPath: String?
    private var overlay: OverlayView?
    private var toastView: ToastView?
    private var toastWork: DispatchWorkItem?
    private var searchWork: DispatchWorkItem?
    private var searchToken = UUID()
    private var listingToken = UUID()
    private var launchStateApplied = false
    private var isSyncingSelection = false
    private var browserWindow: BrowserWindow?
    private var typeAheadValue = ""
    private var typeAheadTime = Date.distantPast
    private let quickLook = QuickLookPreview()

    private var galleryView: GalleryView?
    private var galleryEntries: [FileEntry] = []
    private var galleryTruncated = false
    private var galleryLoading = false
    private var galleryError: String?
    private var galleryLoaded = false
    private var galleryToken = UUID()

    private var networkView: NetworkView?
    private var networkState: NetworkState?
    private var networkLoading = false
    private var networkNotice: String?
    private var networkLoaded = false

    private let directoryWatcher = DirectoryWatcher()
    private var workspaceObservers: [NSObjectProtocol] = []

    // MARK: - Views

    private let root = ThemedView()
    private let titleBar = TitleBarView()
    private let shell = FlippedView()
    private let sidebar = SidebarView()
    private let workspace = FlippedView()
    private let navBar = NavigationBarView()
    private let commandBar = CommandBarView()
    private let progress = ProgressLineView()
    private let contentRow = FlippedView()
    private let mainPane = FlippedView()
    private let detailsContainer = NSView()
    private var detailsPane: DetailsPaneView?
    private let statusBar = StatusBarView()
    private var fileListView: FileListView?
    private let homeView = HomeView()

    private var bannerView: ThemedView?
    private var searchHeaderView: ThemedView?
    private var contentHost: NSView?

    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var workspaceWithSidebar: NSLayoutConstraint!
    private var workspaceWithoutSidebar: NSLayoutConstraint!
    private var mainTrailingToDetails: NSLayoutConstraint!
    private var mainTrailingToRow: NSLayoutConstraint!

    private struct ListingOutcome: Sendable {
        var listing: DirListing?
        var message: String?
        var denied: Bool
        var missing: Bool
    }

    // MARK: - Init

    init(location: Location? = nil, cascadeFrom: NSRect? = nil) {
        systemInfo = FileService.systemInfo()
        let preferences = AppStore.shared.preferences
        if let location {
            tabs = [TabModel(location: location, view: preferences.view)]
        } else if let session = AppStore.shared.session {
            var restored: [TabModel] = []
            var restoredActiveIndex: Int?
            for (savedIndex, saved) in session.tabs.enumerated() {
                guard !saved.location.isArchive else { continue }
                if case .fs(let path) = saved.location, !FileManager.default.fileExists(atPath: path) {
                    continue
                }
                if savedIndex == session.activeIndex { restoredActiveIndex = restored.count }
                let tab = TabModel(location: saved.location, view: saved.view)
                tab.sortKey = saved.sortKey
                tab.sortDir = saved.sortDir
                restored.append(tab)
            }
            if restored.isEmpty {
                tabs = [TabModel(location: .home, view: preferences.view)]
            } else {
                tabs = restored
                activeIndex = min(max(0, restoredActiveIndex ?? 0), restored.count - 1)
            }
        } else {
            tabs = [TabModel(location: .home, view: preferences.view)]
        }
        Theme.apply(preferences.theme)

        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Explorer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 900, height: 560)
        window.backgroundColor = Theme.chrome
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier("MacExplorerMain")
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }

        super.init(window: window)
        window.delegate = self
        browserWindow = window

        if let cascadeFrom {
            let width = max(900, cascadeFrom.width - 40)
            let height = max(560, cascadeFrom.height - 40)
            let origin = NSPoint(x: cascadeFrom.origin.x + 36, y: cascadeFrom.origin.y - 36)
            window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        } else {
            window.setFrameAutosaveName("MacExplorerWindow")
            if !window.setFrameUsingName("MacExplorerWindow") {
                window.center()
            }
        }

        buildUI()
        browserWindow?.keyHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        quickLook.onEvent = { [weak self] event in
            self?.handlePreviewEvent(event) ?? false
        }
        quickLook.sourceFrameForPath = { [weak self] path in
            self?.previewSourceFrame(path: path) ?? .zero
        }
        quickLook.onShownPathChange = { [weak self] path in
            self?.syncSelection(toPreviewPath: path)
        }
        quickLook.onDidClose = { [weak self] path in
            self?.finishPreview(path: path)
        }
        directoryWatcher.onChange = { [weak self] in self?.directoryDidChange() }
        observeVolumeChanges()
        store.ensureDefaults(system: systemInfo)
        reloadActiveTab()
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI construction

    private var activeTab: TabModel {
        tabs[min(max(0, activeIndex), tabs.count - 1)]
    }

    private var preferences: Preferences {
        get { store.preferences }
        set { store.preferences = newValue; store.save() }
    }

    @discardableResult
    private func ensureFileListView() -> FileListView {
        if let fileListView { return fileListView }
        let view = FileListView()
        view.delegate = self
        fileListView = view
        return view
    }

    private func buildUI() {
        guard let window else { return }
        root.fillColor = Theme.chrome
        window.contentView = root

        titleBar.delegate = self
        root.addSubview(titleBar)
        root.addSubview(shell)
        shell.addSubview(sidebar)
        shell.addSubview(workspace)
        workspace.addSubview(navBar)
        workspace.addSubview(commandBar)
        workspace.addSubview(progress)
        workspace.addSubview(contentRow)
        workspace.addSubview(statusBar)
        contentRow.addSubview(mainPane)
        contentRow.addSubview(detailsContainer)

        for view in [titleBar, shell, sidebar, workspace, navBar, commandBar, progress, contentRow, mainPane, detailsContainer, statusBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        sidebarWidthConstraint = sidebar.widthAnchor.constraint(equalToConstant: 232)
        workspaceWithSidebar = workspace.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)
        workspaceWithoutSidebar = workspace.leadingAnchor.constraint(equalTo: shell.leadingAnchor)
        mainTrailingToDetails = mainPane.trailingAnchor.constraint(equalTo: detailsContainer.leadingAnchor)
        mainTrailingToRow = mainPane.trailingAnchor.constraint(equalTo: contentRow.trailingAnchor)

        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: root.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 40),

            shell.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            shell.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            shell.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            sidebar.topAnchor.constraint(equalTo: shell.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
            sidebarWidthConstraint,

            workspace.topAnchor.constraint(equalTo: shell.topAnchor),
            workspace.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            workspace.bottomAnchor.constraint(equalTo: shell.bottomAnchor),

            navBar.topAnchor.constraint(equalTo: workspace.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 50),

            commandBar.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            commandBar.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            commandBar.heightAnchor.constraint(equalToConstant: 44),

            progress.topAnchor.constraint(equalTo: commandBar.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),

            contentRow.topAnchor.constraint(equalTo: progress.bottomAnchor),
            contentRow.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            contentRow.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            contentRow.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: workspace.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),

            mainPane.leadingAnchor.constraint(equalTo: contentRow.leadingAnchor),
            mainPane.topAnchor.constraint(equalTo: contentRow.topAnchor),
            mainPane.bottomAnchor.constraint(equalTo: contentRow.bottomAnchor),

            detailsContainer.trailingAnchor.constraint(equalTo: contentRow.trailingAnchor),
            detailsContainer.topAnchor.constraint(equalTo: contentRow.topAnchor),
            detailsContainer.bottomAnchor.constraint(equalTo: contentRow.bottomAnchor),
            detailsContainer.widthAnchor.constraint(equalToConstant: 300),
        ])

        applyPaneVisibility()

        navBar.onBack = { [weak self] in self?.goHistory(-1) }
        navBar.onForward = { [weak self] in self?.goHistory(1) }
        navBar.onUp = { [weak self] in self?.goUp() }
        navBar.onRefresh = { [weak self] in self?.refresh() }
        navBar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        navBar.onNavigatePath = { [weak self] path in self?.navigateToPath(path) }
        navBar.onNavigateArchiveInner = { [weak self] path in self?.navigateArchiveInner(path) }
        navBar.onEditAddress = { [weak self] path in self?.navigateToPath(path) }
        navBar.onSearchChange = { [weak self] value in self?.handleSearchChange(value) }
        navBar.onDropPaths = { [weak self] paths, destination, copy in
            self?.transfer(paths: paths, destination: destination, copy: copy)
        }

        commandBar.onNewFolder = { [weak self] in self?.createFolder() }
        commandBar.onNewTextFile = { [weak self] in self?.createTextFile() }
        commandBar.onCut = { [weak self] in self?.copySelection(cut: true) }
        commandBar.onCopy = { [weak self] in self?.copySelection(cut: false) }
        commandBar.onPaste = { [weak self] in self?.pasteIntoCurrent() }
        commandBar.onRename = { [weak self] in self?.beginRename() }
        commandBar.onDelete = { [weak self] in self?.trashSelection() }
        commandBar.onSort = { [weak self] key, dir in self?.setSort(key, dir) }
        commandBar.onSetView = { [weak self] mode in self?.setView(mode) }
        commandBar.onToggleHidden = { [weak self] in self?.toggleHidden() }
        commandBar.onToggleExtensions = { [weak self] in self?.toggleExtensions() }
        commandBar.onToggleDetails = { [weak self] in self?.toggleDetails() }
        commandBar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        commandBar.onTogglePin = { [weak self] in self?.togglePinForSelection() }
        commandBar.onSetTheme = { [weak self] theme in self?.setTheme(theme) }
        commandBar.onOpenTerminal = { [weak self] in
            guard let self, let path = self.activeTab.location.writePath else { return }
            _ = FileService.openTerminal(path)
        }
        commandBar.onShowAbout = { [weak self] in self?.showAbout() }

        statusBar.onViewChange = { [weak self] mode in self?.setView(mode) }
        statusBar.onToggleDetails = { [weak self] in self?.toggleDetails() }

        sidebar.delegate = self

        homeView.onOpenFolder = { [weak self] path in self?.navigateToPath(path) }
        homeView.onOpenRecent = { [weak self] item in self?.openRecent(item) }
        homeView.onClearRecent = { [weak self] in
            AppStore.shared.clearRecent()
            self?.render()
        }
        homeView.onOpenGallery = { [weak self] in self?.navigate(to: .gallery) }
        homeView.onQuickMenu = { [weak self] item, event in self?.showQuickMenu(item, event: event) }
        homeView.onRecentMenu = { [weak self] item, event in self?.showRecentMenu(item, event: event) }
        homeView.onOpenVolume = { [weak self] volume in self?.navigateToPath(volume.path) }
        homeView.onVolumeMenu = { [weak self] volume, event in self?.showVolumeMenu(volume, event: event) }
    }

    // MARK: - Pane visibility

    private func applyPaneVisibility() {
        let prefs = preferences
        sidebar.isHidden = !prefs.sidebarVisible
        detailsContainer.isHidden = !prefs.detailsOpen
        mainTrailingToDetails.isActive = prefs.detailsOpen
        mainTrailingToRow.isActive = !prefs.detailsOpen
        workspaceWithSidebar.isActive = prefs.sidebarVisible
        workspaceWithoutSidebar.isActive = !prefs.sidebarVisible
        updateProgress()
    }

    private func updateProgress() {
        let loading = activeTab.isSearching ? activeTab.searchLoading : activeTab.loading
        progress.isAnimating = loading
    }

    // MARK: - Render

    private func render() {
        titleBar.update(
            tabs: tabs.map { TabDisplay(title: LocationTools.title($0.location, system: systemInfo), icon: icon(for: $0.location)) },
            activeIndex: activeIndex,
            maximized: window?.isZoomed ?? false
        )
        sidebar.update(
            system: systemInfo,
            pinned: store.pinnedPaths,
            activeLocation: activeTab.location,
            quickAccessOpen: preferences.quickAccessOpen,
            thisPcOpen: preferences.thisPcOpen
        )
        navBar.update(
            location: activeTab.location,
            system: systemInfo,
            canBack: activeTab.historyIndex > 0,
            canForward: activeTab.historyIndex < activeTab.history.count - 1,
            canUp: canGoUp(),
            searchEnabled: !activeTab.location.isNetwork,
            searchValue: activeTab.searchQuery,
            sidebarVisible: preferences.sidebarVisible
        )
        updateCommandBar()
        applyPaneVisibility()
        renderContent()
        updateDetailsPane()
        statusBar.update(label: statusLabel(), view: activeTab.view, detailsOpen: preferences.detailsOpen)
        updateProgress()
        updateDirectoryWatch()
        window?.contentView?.needsDisplay = true
        persistSession()
    }

    private func updateDirectoryWatch() {
        if case .fs(let path) = activeTab.location {
            directoryWatcher.watch(path: path)
        } else {
            directoryWatcher.stop()
        }
    }

    private func directoryDidChange() {
        guard case .fs = activeTab.location else { return }
        reloadActiveTab()
    }

    private func persistSession() {
        let snapshot = PersistedSession(
            tabs: tabs.map {
                PersistedTab(location: $0.location, view: $0.view, sortKey: $0.sortKey, sortDir: $0.sortDir)
            },
            activeIndex: activeIndex
        )
        store.saveSession(snapshot)
    }

    private func updateCommandBar() {
        let tab = activeTab
        commandBar.update(
            canCreate: tab.location.writePath != nil && !tab.isSearching,
            canModify: tab.location.writePath != nil,
            canPaste: tab.location.writePath != nil && !clipboard.paths.isEmpty && !tab.isSearching,
            canPin: selectedFolderPaths().isEmpty == false && !tab.location.isArchive,
            pinnedSelection: !selectedFolderPaths().isEmpty && selectedFolderPaths().allSatisfy { store.isPinned($0) },
            selectionCount: tab.selected.count,
            view: tab.view,
            sortKey: tab.sortKey,
            sortDir: tab.sortDir,
            showHidden: preferences.showHidden,
            showExtensions: preferences.showExtensions,
            detailsOpen: preferences.detailsOpen,
            sidebarVisible: preferences.sidebarVisible,
            theme: preferences.theme
        )
    }

    private func icon(for location: Location) -> String {
        switch location {
        case .home: return "house"
        case .gallery: return "photo.on.rectangle"
        case .network: return "network"
        case .archive: return "archivebox"
        case .fs(let path):
            return path == systemInfo.trashPath ? "trash" : "folder"
        }
    }

    // MARK: - Content

    private func renderContent() {
        bannerView?.removeFromSuperview()
        bannerView = nil
        searchHeaderView?.removeFromSuperview()
        searchHeaderView = nil
        contentHost?.removeFromSuperview()
        contentHost = nil
        let tab = activeTab

        if tab.location != .gallery {
            galleryView = nil
            galleryEntries = []
            galleryTruncated = false
            galleryLoading = false
            galleryError = nil
            galleryLoaded = false
        }
        if tab.location != .network {
            networkView = nil
            networkState = nil
            networkLoading = false
            networkNotice = nil
            networkLoaded = false
        }
        let wantsFileList = tab.isSearching || tab.location.readPath != nil
        if !wantsFileList {
            fileListView = nil
        }

        var top = mainPane.topAnchor

        if tab.location.isArchive, !tab.isSearching, let archivePath = tab.location.archivePath {
            let banner = makeArchiveBanner(archivePath: archivePath)
            banner.translatesAutoresizingMaskIntoConstraints = false
            mainPane.addSubview(banner)
            NSLayoutConstraint.activate([
                banner.topAnchor.constraint(equalTo: mainPane.topAnchor),
                banner.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
                banner.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
                banner.heightAnchor.constraint(equalToConstant: 36),
            ])
            bannerView = banner
            top = banner.bottomAnchor
        }

        if tab.isSearching {
            let header = makeSearchHeader()
            header.translatesAutoresizingMaskIntoConstraints = false
            mainPane.addSubview(header)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: top),
                header.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
                header.heightAnchor.constraint(equalToConstant: 36),
            ])
            searchHeaderView = header
            top = header.bottomAnchor
        }

        let content: NSView
        if wantsFileList {
            let list = ensureFileListView()
            updateFileList(list)
            content = list
        } else if tab.location == .gallery {
            if galleryView == nil {
                let view = GalleryView()
                view.onOpen = { [weak self] entry in self?.open(entry) }
                view.onContextMenu = { [weak self] entry, event in self?.showGalleryMenu(entry, event: event) }
                galleryView = view
            }
            galleryView?.update(
                root: galleryRoot,
                entries: galleryEntries,
                truncated: galleryTruncated,
                loading: galleryLoading,
                errorMessage: galleryError
            )
            content = galleryView ?? NSView()
        } else if tab.location == .network {
            if networkView == nil {
                let view = NetworkView()
                view.onConnect = { [weak self] target in self?.connectServer(target) }
                view.onOpen = { [weak self] path in self?.navigateToPath(path) }
                view.onRefresh = { [weak self] in self?.refreshNetwork() }
                networkView = view
            }
            networkView?.update(
                state: networkState ?? NetworkState(servers: [], mounted: [], error: nil),
                loading: networkLoading,
                notice: networkNotice
            )
            content = networkView ?? NSView()
        } else {
            homeView.update(quickItems: quickItems(), recent: store.recent, volumes: systemInfo.volumes)
            content = homeView
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        mainPane.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: top),
            content.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: mainPane.bottomAnchor),
        ])
        contentHost = content
    }

    private func makeArchiveBanner(archivePath: String) -> ThemedView {
        let banner = ThemedView()
        banner.fillColor = Theme.surface
        let label = makeLabel("Browsing \(PathTools.basename(archivePath)) — read-only extraction", size: 12.5, color: Theme.textPrimary)
        let button = HoverButton(title: "Extract all")
        button.font = NSFont.systemFont(ofSize: 12)
        button.contentTintColor = Theme.accent
        button.target = self
        button.action = #selector(extractAllPressed)
        label.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(label)
        banner.addSubview(button)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -14),
            button.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 84),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
        let line = ThemedView()
        line.fillColor = Theme.hairline
        line.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: banner.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return banner
    }

    private func makeSearchHeader() -> ThemedView {
        let header = ThemedView()
        header.fillColor = Theme.surface
        let tab = activeTab
        let text: String
        if tab.searchLoading {
            text = "Searching for \(tab.searchQuery) in \(tab.searchRoot)"
        } else {
            let truncated = tab.searchTruncated ? " · showing the first 250 matches" : ""
            text = "\(FormatTools.plural(tab.searchEntries.count, "result")) for \(tab.searchQuery) in \(tab.searchRoot)\(truncated)"
        }
        let label = makeLabel(text, size: 12.5, color: Theme.textSecondary)
        let clear = HoverButton(title: "Clear", image: "xmark")
        clear.font = NSFont.systemFont(ofSize: 12)
        clear.contentTintColor = Theme.textSecondary
        clear.target = self
        clear.action = #selector(clearSearchPressed)
        label.translatesAutoresizingMaskIntoConstraints = false
        clear.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)
        header.addSubview(clear)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: clear.leadingAnchor, constant: -8),
            clear.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            clear.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: 64),
            clear.heightAnchor.constraint(equalToConstant: 24),
        ])
        let line = ThemedView()
        line.fillColor = Theme.hairline
        line.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return header
    }

    private func updateFileList(_ explicitList: FileListView? = nil) {
        guard let list = explicitList ?? fileListView else { return }
        let tab = activeTab
        if let renamingPath, !visibleEntries().contains(where: { $0.path == renamingPath }) {
            self.renamingPath = nil
        }
        list.update(
            entries: visibleEntries(),
            mode: tab.view,
            selected: tab.selected,
            focused: tab.focusedPath,
            renamingPath: renamingPath,
            cutPaths: clipboard.cut ? Set(clipboard.paths) : [],
            showExtensions: preferences.showExtensions,
            sortKey: tab.sortKey,
            sortDir: tab.sortDir,
            loading: tab.isSearching ? tab.searchLoading : tab.loading,
            errorMessage: tab.pathError,
            permissionError: tab.permissionError,
            isSearch: tab.isSearching
        )
    }

    private func visibleEntries() -> [FileEntry] {
        let tab = activeTab
        let source = tab.isSearching ? tab.searchEntries : tab.entries
        let filtered = source.filter { preferences.showHidden || !$0.hidden }
        return sortEntries(filtered, key: tab.sortKey, dir: tab.sortDir, showExtensions: preferences.showExtensions)
    }

    private func selectedEntries() -> [FileEntry] {
        let tab = activeTab
        let source = tab.isSearching ? tab.searchEntries : tab.entries
        return source.filter { tab.selected.contains($0.path) }
    }

    private func selectedFolderPaths() -> [String] {
        selectedEntries()
            .filter { $0.isDirectory && $0.kind != .app }
            .map { $0.path }
    }

    private func quickItems() -> [QuickItem] {
        let map = Dictionary(uniqueKeysWithValues: systemInfo.specialFolders.map { ($0.path, $0) })
        return store.pinnedPaths.map { path in
            QuickItem(path: path, label: map[path]?.label ?? (path == systemInfo.home ? "Home" : PathTools.basename(path)))
        }
    }

    private func statusLabel() -> String {
        let tab = activeTab
        if !tab.selected.isEmpty {
            let size = selectedEntries().reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }
            let suffix = size > 0 ? " · \(FormatTools.bytes(size))" : ""
            return "\(FormatTools.plural(tab.selected.count, "item")) selected\(suffix)"
        }
        if tab.isSearching {
            return tab.searchLoading ? "Searching…" : FormatTools.plural(tab.searchEntries.count, "search result")
        }
        switch tab.location {
        case .home: return "Home"
        case .gallery: return "Gallery"
        case .network: return "Network"
        default: break
        }
        if tab.loading { return "Loading…" }
        if tab.pathError != nil { return "Can’t access this folder" }
        return FormatTools.plural(visibleEntries().count, "item")
    }

    @discardableResult
    private func ensureDetailsPane() -> DetailsPaneView {
        if let detailsPane { return detailsPane }
        let pane = DetailsPaneView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        detailsContainer.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: detailsContainer.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: detailsContainer.trailingAnchor),
            pane.topAnchor.constraint(equalTo: detailsContainer.topAnchor),
            pane.bottomAnchor.constraint(equalTo: detailsContainer.bottomAnchor),
        ])
        pane.onClose = { [weak self] in self?.toggleDetails() }
        pane.onOpen = { [weak self] entry in self?.open(entry) }
        pane.onReveal = { entry in _ = FileService.reveal(entry.path) }
        detailsPane = pane
        return pane
    }

    private func updateDetailsPane() {
        guard preferences.detailsOpen else {
            detailsPane?.removeFromSuperview()
            detailsPane = nil
            return
        }
        let pane = ensureDetailsPane()
        pane.update(entries: selectedEntries(), isArchive: activeTab.location.isArchive)
    }

    private func updateSelectionDependentUI() {
        updateCommandBar()
        statusBar.update(label: statusLabel(), view: activeTab.view, detailsOpen: preferences.detailsOpen)
        updateDetailsPane()
        if let fileListView, contentHost === fileListView {
            updateFileList(fileListView)
        }
        if quickLook.isOpen {
            quickLook.sync(paths: previewablePaths())
        }
    }

    // MARK: - Loading

    private nonisolated static func loadListing(_ path: String) -> ListingOutcome {
        do {
            let listing = try FileService.readDirectory(path)
            return ListingOutcome(listing: listing, message: nil, denied: false, missing: false)
        } catch {
            let ns = error as NSError
            var code = ns.code
            var domain = ns.domain
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                code = underlying.code
                domain = underlying.domain
            }
            let denied = (domain == NSPOSIXErrorDomain && (code == Int(EACCES) || code == Int(EPERM)))
                || (domain == NSCocoaErrorDomain && code == NSFileReadNoPermissionError)
            let missing = (domain == NSPOSIXErrorDomain && code == Int(ENOENT))
                || (domain == NSCocoaErrorDomain && code == NSFileReadNoSuchFileError)
            return ListingOutcome(listing: nil, message: error.localizedDescription, denied: denied, missing: missing)
        }
    }

    private func reloadActiveTab() {
        let tab = activeTab
        guard let path = tab.location.readPath else {
            tab.entries = []
            tab.loading = false
            tab.pathError = nil
            tab.permissionError = false
            if tab.location == .gallery { enterGallery() }
            if tab.location == .network { enterNetwork() }
            render()
            return
        }
        let token = UUID()
        listingToken = token
        tab.loading = true
        tab.pathError = nil
        tab.permissionError = false
        render()
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Self.loadListing(path)
            await self?.applyListing(outcome, token: token, path: path)
        }
    }

    private func applyListing(_ outcome: ListingOutcome, token: UUID, path: String) {
        guard token == listingToken, activeTab.location.readPath == path else { return }
        let tab = activeTab
        tab.loading = false
        if let listing = outcome.listing {
            tab.entries = listing.entries
            tab.pathError = nil
            tab.permissionError = false
            let available = Set(listing.entries.map { $0.path })
            tab.selected = tab.selected.filter { available.contains($0) }
            if let focused = tab.focusedPath, !available.contains(focused) {
                tab.focusedPath = nil
            }
        } else {
            tab.entries = []
            tab.selected = []
            tab.focusedPath = nil
            var message = outcome.message ?? "This folder can’t be opened."
            if outcome.denied {
                message = path == systemInfo.trashPath
                    ? "macOS protects the Trash from third-party apps. Mac Explorer needs Full Disk Access permission in System Settings → Privacy & Security to browse Trash here."
                    : "You don’t have permission to access this folder. Grant Full Disk Access if this is a protected location."
            } else if outcome.missing {
                message = "This folder can’t be found. It may have been moved or deleted."
            }
            tab.pathError = message
            tab.permissionError = outcome.denied
        }
        applyLaunchStateIfNeeded()
        if tab.isSearching {
            handleSearchChange(tab.searchQuery)
        }
        render()
    }

    private func applyLaunchStateIfNeeded() {
        guard !launchStateApplied else { return }
        launchStateApplied = true
        let arguments = CommandLine.arguments
        if arguments.contains("--select-first"), let first = visibleEntries().first {
            activeTab.selected = [first.path]
            activeTab.focusedPath = first.path
        }
        if let index = arguments.firstIndex(of: "--search"), index + 1 < arguments.count {
            handleSearchChange(arguments[index + 1])
        }
        if arguments.contains("--edit-address") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                self.navBar.beginAddressEdit()
            }
        }
        if arguments.contains("--properties"), let path = activeTab.focusedPath ?? visibleEntries().first?.path {
            let kind = selectedEntries().first?.kind ?? visibleEntries().first?.kind
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.showProperties(paths: [path], kind: kind)
            }
        }
    }

    // MARK: - Navigation

    private func canGoUp() -> Bool {
        let tab = activeTab
        if tab.location.isArchive { return true }
        guard case .fs(let path) = tab.location else { return false }
        if systemInfo.volumes.contains(where: { $0.path == path }) { return false }
        return true
    }

    private func navigate(to location: Location, newTab: Bool = false) {
        renamingPath = nil
        cancelSearchWork()
        if newTab {
            let tab = TabModel(location: location, view: preferences.view)
            tabs.append(tab)
            activeIndex = tabs.count - 1
        } else if LocationTools.same(activeTab.location, location) {
            reloadActiveTab()
            return
        } else {
            activeTab.push(location)
        }
        reloadActiveTab()
    }

    private func navigateToPath(_ rawPath: String) {
        let path = PathTools.expand(rawPath, home: systemInfo.home)
        guard !path.isEmpty else { return }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        guard FileService.exists(resolved) else {
            showToast("Can’t find “\(path)”. Check the spelling and try again.", isError: true)
            return
        }
        if let info = FileService.statInfo(resolved), !info.isDirectory {
            showToast("“\(PathTools.basename(resolved))” is a file, not a folder.", isError: true)
            return
        }
        navigate(to: .fs(path: resolved))
    }

    private func navigateArchiveInner(_ path: String) {
        guard case .archive(let archivePath, let extractRoot, _) = activeTab.location else { return }
        guard path == extractRoot || path.hasPrefix(extractRoot + "/") else { return }
        navigate(to: .archive(archivePath: archivePath, extractRoot: extractRoot, path: path))
    }

    private func goHistory(_ delta: Int) {
        renamingPath = nil
        cancelSearchWork()
        activeTab.goHistory(delta)
        reloadActiveTab()
    }

    private func goUp() {
        let tab = activeTab
        switch tab.location {
        case .archive(let archivePath, let extractRoot, let inner):
            if inner != extractRoot {
                let parent = PathTools.dirname(inner)
                if parent == extractRoot || parent.hasPrefix(extractRoot + "/") {
                    navigate(to: .archive(archivePath: archivePath, extractRoot: extractRoot, path: parent))
                }
            } else {
                navigateToPath(PathTools.dirname(archivePath))
            }
        case .fs(let path):
            if systemInfo.volumes.contains(where: { $0.path == path }) { return }
            if path == "/" { return }
            navigateToPath(PathTools.dirname(path))
        default:
            break
        }
    }

    private func refresh() {
        systemInfo = FileService.systemInfo()
        renamingPath = nil
        switch activeTab.location {
        case .gallery:
            galleryLoaded = false
            enterGallery()
        case .network:
            refreshNetwork()
        default:
            reloadActiveTab()
        }
    }

    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.volumesDidChange() }
            }
            workspaceObservers.append(token)
        }
    }

    private func volumesDidChange() {
        systemInfo = FileService.systemInfo()
        if case .fs(let path) = activeTab.location, !FileManager.default.fileExists(atPath: path) {
            reloadActiveTab()
        } else {
            render()
        }
    }

    private func createTab() {
        renamingPath = nil
        cancelSearchWork()
        let tab = TabModel(location: .home, view: preferences.view)
        tabs.append(tab)
        activeIndex = tabs.count - 1
        persistSession()
        reloadActiveTab()
    }

    private func closeTab(index: Int) {
        guard index >= 0, index < tabs.count else { return }
        if tabs.count == 1 {
            window?.close()
            return
        }
        renamingPath = nil
        cancelSearchWork()
        tabs.remove(at: index)
        if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
        else if index < activeIndex { activeIndex -= 1 }
        else if index == activeIndex { activeIndex = min(index, tabs.count - 1) }
        persistSession()
        if activeTab.entries.isEmpty, activeTab.location.readPath != nil {
            reloadActiveTab()
        } else {
            render()
        }
    }

    private func activateTab(index: Int) {
        guard index >= 0, index < tabs.count, index != activeIndex else { return }
        renamingPath = nil
        cancelSearchWork()
        let previousTab = activeTab
        activeTab.searchQuery = ""
        activeTab.searchEntries = []
        activeTab.searchLoading = false
        activeTab.searchTruncated = false
        activeIndex = index
        previousTab.entries = []
        previousTab.searchEntries = []
        activeTab.searchQuery = ""
        activeTab.searchEntries = []
        activeTab.searchLoading = false
        activeTab.searchTruncated = false
        persistSession()
        if activeTab.entries.isEmpty, activeTab.location.readPath != nil {
            reloadActiveTab()
        } else if activeTab.location == .gallery, !galleryLoaded {
            enterGallery()
        } else if activeTab.location == .network, !networkLoaded {
            enterNetwork()
        } else {
            render()
        }
    }

    private func detachTab(index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let tab = tabs[index]
        (NSApp.delegate as? AppDelegate)?.detachTab(location: tab.location, from: window)
        if tabs.count == 1 {
            window?.close()
        } else {
            closeTab(index: index)
        }
    }

    private func moveTab(from: Int, to: Int) {
        guard from >= 0, from < tabs.count, to >= 0, to < tabs.count, from != to else { return }
        let active = activeTab
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        activeIndex = tabs.firstIndex(where: { $0 === active }) ?? min(to, tabs.count - 1)
        persistSession()
        render()
    }

    // MARK: - Search

    private func handleSearchChange(_ value: String) {
        let tab = activeTab
        if value != tab.searchQuery {
            tab.selected = []
            tab.focusedPath = nil
        }
        tab.searchQuery = value
        cancelSearchWork()
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let root = searchRoot() else {
            tab.searchEntries = []
            tab.searchLoading = false
            tab.searchTruncated = false
            tab.searchRoot = ""
            render()
            return
        }
        let token = UUID()
        searchToken = token
        tab.searchLoading = true
        tab.searchRoot = root
        updateFileList()
        statusBar.update(label: statusLabel(), view: tab.view, detailsOpen: preferences.detailsOpen)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let query = value
            let hidden = self.preferences.showHidden
            let currentRoot = root
            Task.detached(priority: .userInitiated) { [weak self] in
                let response = FileService.search(root: currentRoot, query: query, showHidden: hidden)
                await self?.applySearch(response, token: token, query: query)
            }
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    private func cancelSearchWork() {
        searchWork?.cancel()
        searchWork = nil
        searchToken = UUID()
    }

    private func searchRoot() -> String? {
        let tab = activeTab
        switch tab.location {
        case .fs(let path), .archive(_, _, let path): return path
        case .gallery: return systemInfo.picturesPath
        case .home: return systemInfo.home
        case .network: return nil
        }
    }

    private func applySearch(_ response: SearchResponse, token: UUID, query: String) {
        guard token == searchToken, activeTab.searchQuery == query else { return }
        let tab = activeTab
        tab.searchEntries = response.entries
        tab.searchLoading = false
        tab.searchTruncated = response.truncated
        tab.searchRoot = response.root
        render()
    }

    @objc private func clearSearchPressed() {
        activeTab.searchQuery = ""
        activeTab.searchEntries = []
        activeTab.searchLoading = false
        activeTab.searchTruncated = false
        activeTab.selected = []
        activeTab.focusedPath = nil
        cancelSearchWork()
        render()
    }

    // MARK: - Gallery / Network

    private var galleryRoot: String {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--gallery-root"), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        return systemInfo.picturesPath
    }

    private func enterGallery() {
        if galleryLoaded && galleryView != nil {
            render()
            return
        }
        galleryLoaded = true
        galleryLoading = true
        galleryError = nil
        let token = UUID()
        galleryToken = token
        render()
        let root = galleryRoot
        Task.detached(priority: .userInitiated) { [weak self] in
            let response = FileService.gallery(root: root)
            await self?.applyGallery(response, token: token)
        }
    }

    private func applyGallery(_ response: GalleryResponse, token: UUID) {
        guard token == galleryToken else { return }
        galleryEntries = response.entries
        galleryTruncated = response.truncated
        galleryLoading = false
        galleryError = nil
        render()
    }

    private func enterNetwork() {
        if networkLoaded && networkView != nil {
            render()
            return
        }
        networkLoaded = true
        networkLoading = true
        render()
        Task { @MainActor in
            let state = await NetworkService.state()
            self.networkState = state
            self.networkLoading = false
            self.render()
        }
    }

    private func refreshNetwork() {
        networkLoading = true
        networkNotice = nil
        render()
        Task { @MainActor in
            let state = await NetworkService.state()
            self.networkState = state
            self.networkLoading = false
            self.render()
        }
    }

    private func connectServer(_ target: String) {
        let result = NetworkService.connect(target)
        if result.ok {
            networkNotice = "Finder is opening the SMB connection. Mount the share, then refresh this view."
            showToast("Opening SMB connection in Finder…")
        } else {
            networkNotice = result.error ?? "Could not open this server."
            showToast(networkNotice ?? "", isError: true)
        }
        render()
    }

    // MARK: - Preferences

    private func setSort(_ key: SortKey, _ dir: SortDir) {
        activeTab.sortKey = key
        activeTab.sortDir = dir
        if let fileListView, contentHost === fileListView { updateFileList(fileListView) }
        updateCommandBar()
        persistSession()
    }

    private func setView(_ mode: ViewMode) {
        activeTab.view = mode
        preferences.view = mode
        store.save()
        updateFileList()
        updateCommandBar()
        statusBar.update(label: statusLabel(), view: mode, detailsOpen: preferences.detailsOpen)
        persistSession()
    }

    private func toggleHidden() {
        preferences.showHidden.toggle()
        if activeTab.isSearching {
            handleSearchChange(activeTab.searchQuery)
        }
        render()
    }

    private func toggleExtensions() {
        preferences.showExtensions.toggle()
        render()
    }

    private func toggleDetails() {
        preferences.detailsOpen.toggle()
        store.save()
        render()
    }

    private func toggleSidebar() {
        preferences.sidebarVisible.toggle()
        store.save()
        render()
    }

    private func setTheme(_ theme: ThemePreference) {
        preferences.theme = theme
        store.save()
        Theme.apply(theme)
        render()
        root.needsDisplay = true
        titleBar.needsDisplay = true
        fileListView?.needsDisplay = true
    }

    private func togglePinForSelection() {
        let paths = selectedFolderPaths()
        guard !paths.isEmpty else { return }
        let pinned = store.togglePin(paths)
        showToast(pinned ? "Pinned \(FormatTools.plural(paths.count, "folder")) to Quick access" : "Unpinned \(FormatTools.plural(paths.count, "folder")) from Quick access")
        render()
    }

    // MARK: - File operations

    private func copySelection(cut: Bool) {
        let paths = Array(activeTab.selected)
        guard !paths.isEmpty else { return }
        if cut && activeTab.location.writePath == nil {
            showToast("Cut isn’t available inside archives.", isError: true)
            return
        }
        let result = PasteboardService.copy(paths, cut: cut)
        clipboard = PasteboardService.current()
        if result.ok {
            showToast("\(FormatTools.plural(paths.count, "item")) \(cut ? "cut" : "copied")")
        } else if let error = result.error {
            showToast(error, isError: true)
        }
        updateSelectionDependentUI()
    }

    private func pasteIntoCurrent() {
        guard let destination = activeTab.location.writePath, !activeTab.isSearching else { return }
        paste(into: destination)
    }

    private func paste(into destination: String) {
        guard let plan = PasteboardService.pastePlan() else {
            showToast("The clipboard is empty.", isError: true)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = FileService.paste(plan: plan, into: destination)
            await self?.finishPaste(outcome, plan: plan, destination: destination)
        }
    }

    private func finishPaste(_ outcome: PasteOutcome, plan: FileService.PastePlan, destination: String) {
        if plan.cut && plan.internalSource {
            PasteboardService.finishCut(remaining: outcome.remainingSources)
        }
        clipboard = PasteboardService.current()
        if let count = outcome.result.count, count > 0 {
            showToast("Pasted \(FormatTools.plural(count, "item"))")
            if destination == activeTab.location.writePath {
                let paths = outcome.result.paths ?? []
                activeTab.selected = Set(paths)
                activeTab.focusedPath = paths.first
            }
        }
        if !outcome.result.ok, let error = outcome.result.error, error != "The clipboard is empty." {
            showToast(error, isError: true)
        }
        reloadActiveTab()
    }

    private func transfer(paths: [String], destination: String, copy: Bool) {
        guard !paths.isEmpty, !activeTab.location.isArchive else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = FileService.transfer(paths, to: destination, copy: copy)
            await self?.finishTransfer(result, destination: destination, copy: copy)
        }
    }

    private func finishTransfer(_ result: OpResult, destination: String, copy: Bool) {
        if let count = result.count, count > 0 {
            showToast("\(copy ? "Copied" : "Moved") \(FormatTools.plural(count, "item"))")
            if destination == activeTab.location.writePath {
                let paths = result.paths ?? []
                activeTab.selected = Set(paths)
                activeTab.focusedPath = paths.first
            }
        }
        if !result.ok, let error = result.error {
            showToast(error, isError: true)
        }
        reloadActiveTab()
    }

    private func createFolder() {
        guard let path = activeTab.location.writePath, !activeTab.isSearching else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = FileService.createFolder(dir: path)
            await self?.finishCreate(result, rename: true)
        }
    }

    private func createTextFile() {
        guard let path = activeTab.location.writePath, !activeTab.isSearching else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = FileService.createTextFile(dir: path)
            await self?.finishCreate(result, rename: true)
        }
    }

    private func finishCreate(_ result: OpResult, rename: Bool) {
        guard result.ok, let path = result.path else {
            showToast(result.error ?? "Could not create the item.", isError: true)
            return
        }
        activeTab.selected = [path]
        activeTab.focusedPath = path
        if rename { renamingPath = path }
        reloadActiveTab()
    }

    private func beginRename() {
        guard activeTab.location.writePath != nil, activeTab.selected.count == 1 else { return }
        renamingPath = activeTab.selected.first
        if let fileListView, contentHost === fileListView { updateFileList(fileListView) }
    }

    private func commitRename(_ entry: FileEntry, to name: String) {
        renamingPath = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = FileService.rename(entry.path, to: name)
            await self?.finishRename(result)
        }
    }

    private func finishRename(_ result: OpResult) {
        if result.ok, let path = result.path {
            activeTab.selected = [path]
            activeTab.focusedPath = path
            reloadActiveTab()
        } else {
            showToast(result.error ?? "Could not rename this item.", isError: true)
            updateFileList()
        }
    }

    private func trashSelection() {
        let paths = Array(activeTab.selected)
        guard !paths.isEmpty, activeTab.location.writePath != nil else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = FileService.trash(paths)
            await self?.finishTrash(result)
        }
    }

    private func finishTrash(_ result: OpResult) {
        if let count = result.count, count > 0 {
            showToast("Moved \(FormatTools.plural(count, "item")) to Trash")
        }
        if !result.ok, let error = result.error {
            let lowered = error.lowercased()
            if lowered.contains("permission") || lowered.contains("operation not permitted") || lowered.contains("denied") {
                showConfirm(
                    title: "Full Disk Access required",
                    message: "macOS blocked this file operation. Grant Mac Explorer Full Disk Access in System Settings → Privacy & Security, then try again.",
                    confirmLabel: "Privacy settings",
                    dangerous: false
                ) { [weak self] in
                    self?.openPrivacySettings()
                }
            } else {
                showToast(error, isError: true)
            }
        }
        activeTab.selected = []
        activeTab.focusedPath = nil
        reloadActiveTab()
    }

    private func confirmPermanentDelete() {
        let paths = Array(activeTab.selected)
        guard !paths.isEmpty, activeTab.location.writePath != nil else { return }
        showConfirm(
            title: "Delete permanently?",
            message: "\(FormatTools.plural(paths.count, "item")) will be deleted permanently. This can’t be undone.",
            confirmLabel: "Delete permanently",
            dangerous: true
        ) { [weak self] in
            guard let self else { return }
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = FileService.remove(paths)
                await self?.finishRemove(result)
            }
        }
    }

    private func finishRemove(_ result: OpResult) {
        if let count = result.count, count > 0 {
            showToast("Deleted \(FormatTools.plural(count, "item")) permanently")
        }
        if !result.ok, let error = result.error {
            showToast(error, isError: true)
        }
        activeTab.selected = []
        activeTab.focusedPath = nil
        reloadActiveTab()
    }

    private func open(_ entry: FileEntry) {
        let archiveLocation = activeTab.location.isArchive
        if !archiveLocation {
            AppStore.shared.addRecent(entry)
        }
        if archiveLocation {
            if entry.isDirectory && entry.kind != .app {
                if case .archive(let archivePath, let extractRoot, _) = activeTab.location {
                    navigate(to: .archive(archivePath: archivePath, extractRoot: extractRoot, path: entry.path))
                }
                return
            }
            if entry.kind == .app {
                showToast("Applications can’t be opened from inside an archive.", isError: true)
                return
            }
        } else if entry.isDirectory && entry.kind != .app {
            navigateToPath(entry.path)
            return
        }
        if !entry.isDirectory && FileKinds.isBrowsableArchive(entry.name) {
            openArchive(entry)
            return
        }
        let result = FileService.openPath(entry.path)
        if !result.ok {
            showToast(result.error ?? "Could not open “\(entry.name)”.", isError: true)
        }
    }

    private func openFocused() {
        let path = activeTab.focusedPath ?? Array(activeTab.selected).first
        guard let path else { return }
        let source = activeTab.isSearching ? activeTab.searchEntries : activeTab.entries
        guard let entry = source.first(where: { $0.path == path }) else { return }
        open(entry)
    }

    private func openRecent(_ item: RecentItem) {
        let result = FileService.openPath(item.path)
        if result.ok {
            AppStore.shared.addRecent(FileEntry(
                name: item.name,
                path: item.path,
                isDirectory: false,
                isSymlink: false,
                size: 0,
                modified: item.modified,
                created: item.modified,
                kind: item.kind,
                hidden: false
            ))
        } else {
            AppStore.shared.removeRecent(item.path)
            showToast(result.error ?? "This file can’t be opened.", isError: true)
        }
        render()
    }

    private func openArchive(_ entry: FileEntry) {
        showToast("Opening “\(entry.name)”…")
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = ArchiveService.openArchive(entry.path)
            await self?.finishArchiveOpen(result, name: entry.name)
        }
    }

    private func finishArchiveOpen(_ result: ArchiveResult, name: String) {
        guard result.ok, let archivePath = result.archivePath, let extractRoot = result.extractRoot else {
            showToast(result.error ?? "Could not open “\(name)”.", isError: true)
            return
        }
        navigate(to: .archive(archivePath: archivePath, extractRoot: extractRoot, path: extractRoot))
    }

    @objc private func extractAllPressed() {
        guard let archivePath = activeTab.location.archivePath else { return }
        extractArchive(archivePath, destination: PathTools.dirname(archivePath))
    }

    private func extractArchive(_ archivePath: String, destination: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = ArchiveService.extractAll(archivePath, destinationParent: destination)
            await self?.finishExtract(result, destination: destination)
        }
    }

    private func finishExtract(_ result: OpResult, destination: String) {
        if result.ok, let path = result.path {
            showToast("Extracted to “\(PathTools.basename(path))”")
            if destination == activeTab.location.writePath {
                activeTab.selected = [path]
                activeTab.focusedPath = path
            }
            reloadActiveTab()
        } else {
            showToast(result.error ?? "Could not extract this archive.", isError: true)
        }
    }

    // MARK: - Clipboard options

    private func refreshClipboard() {
        clipboard = PasteboardService.current()
        updateSelectionDependentUI()
    }

    // MARK: - Dialogs

    private func showAbout() {
        let about = AboutOverlay()
        presentOverlay(about)
    }

    private func showProperties(paths: [String], kind: FileKind?) {
        guard !paths.isEmpty else { return }
        let properties = PropertiesOverlay(paths: paths, kind: kind)
        presentOverlay(properties)
    }

    private func showConfirm(
        title: String,
        message: String,
        confirmLabel: String,
        dangerous: Bool,
        action: @escaping () -> Void
    ) {
        let confirm = ConfirmOverlay(title: title, message: message, confirmLabel: confirmLabel, dangerous: dangerous) { [weak self] in
            self?.dismissOverlay()
            action()
        }
        confirm.onDismiss = { [weak self] in self?.dismissOverlay() }
        presentOverlay(confirm)
    }

    private func presentOverlay(_ view: OverlayView) {
        dismissOverlay()
        overlay = view
        if view is AboutOverlay || view is PropertiesOverlay {
            view.onDismiss = { [weak self] in self?.dismissOverlay() }
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            view.topAnchor.constraint(equalTo: root.topAnchor),
            view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.needsLayout = true
    }

    private func dismissOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
    }

    private func showToast(_ message: String, isError: Bool = false) {
        toastWork?.cancel()
        toastView?.removeFromSuperview()
        let toast = ToastView(message: message, isError: isError)
        toast.alphaValue = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toast)
        let textWidth = (message as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5)]).width
        let width = min(560, max(200, textWidth + 70))
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -14),
            toast.widthAnchor.constraint(equalToConstant: width),
            toast.heightAnchor.constraint(equalToConstant: 40),
        ])
        toastView = toast
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            toast.animator().alphaValue = 1
        }
        Task { @MainActor [weak self, weak toast] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard let toast else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                toast.animator().alphaValue = 0
            }
            try? await Task.sleep(nanoseconds: 220_000_000)
            toast.removeFromSuperview()
            if self?.toastView === toast { self?.toastView = nil }
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Keyboard

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if let overlay {
            if event.keyCode == 53 {
                dismissOverlay()
                return true
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                if let confirm = overlay as? ConfirmOverlay {
                    confirm.triggerConfirm()
                    return true
                }
                if overlay is AboutOverlay || overlay is PropertiesOverlay {
                    dismissOverlay()
                    return true
                }
            }
            return false
        }

        if window?.firstResponder is NSTextView {
            return false
        }

        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let tab = activeTab

        if command {
            if event.keyCode == 51 {
                trashSelection()
                return true
            }
            if event.keyCode == 126 {
                goUp()
                return true
            }
            if event.keyCode == 125 {
                openFocused()
                return true
            }
            switch chars {
            case "c":
                copySelection(cut: false)
                return true
            case "x":
                copySelection(cut: true)
                return true
            case "v":
                pasteIntoCurrent()
                return true
            case "a":
                if let fileListView, contentHost === fileListView {
                    fileListView.selectAllEntries()
                }
                return true
            case "t":
                createTab()
                return true
            case "w":
                closeTab(index: activeIndex)
                return true
            case "n":
                if shift {
                    createFolder()
                } else {
                    (NSApp.delegate as? AppDelegate)?.newWindow(from: window)
                }
                return true
            case "f":
                navBar.focusSearch()
                return true
            case "l":
                navBar.beginAddressEdit()
                return true
            case "r":
                refresh()
                return true
            case "i":
                if !tab.selected.isEmpty {
                    showProperties(paths: Array(tab.selected), kind: selectedEntries().first?.kind)
                }
                return true
            case "[":
                goHistory(-1)
                return true
            case "]":
                goHistory(1)
                return true
            default:
                break
            }
        }

        if event.keyCode == 120 {
            beginRename()
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            if shift {
                confirmPermanentDelete()
            } else {
                trashSelection()
            }
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            openFocused()
            return true
        }
        if event.keyCode == 53 {
            if tab.isSearching {
                clearSearchPressed()
            } else if !tab.selected.isEmpty {
                tab.selected = []
                tab.focusedPath = nil
                updateSelectionDependentUI()
                if let fileListView, contentHost === fileListView { fileListView.deselectAllEntries() }
            }
            return true
        }
        if event.keyCode == 49, renamingPath == nil, !command,
           !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control), !shift {
            toggleQuickLook()
            return true
        }
        if [123, 124, 125, 126].contains(event.keyCode), !command, !event.modifierFlags.contains(.option) {
            if (tab.view.isGrid || tab.view == .tiles), let fileListView, contentHost === fileListView {
                let horizontal = event.keyCode == 123 ? -1 : (event.keyCode == 124 ? 1 : 0)
                let vertical = event.keyCode == 126 ? -1 : (event.keyCode == 125 ? 1 : 0)
                fileListView.moveGridFocus(horizontal: horizontal, vertical: vertical, extend: shift)
                return true
            }
            return false
        }
        if !command, !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control),
           chars.count == 1, let first = chars.first, first.isLetter || first.isNumber {
            typeAhead(String(first))
            return true
        }
        return false
    }

    private func typeAhead(_ character: String) {
        let now = Date()
        if now.timeIntervalSince(typeAheadTime) > 0.8 { typeAheadValue = "" }
        typeAheadValue += character.lowercased()
        typeAheadTime = now
        let needle = typeAheadValue
        let entries = visibleEntries()
        guard let match = entries.first(where: { displayName($0.name, preferences.showExtensions).lowercased().hasPrefix(needle) }) else { return }
        activeTab.selected = [match.path]
        activeTab.focusedPath = match.path
        if activeTab.view.isGrid || activeTab.view == .tiles {
            ensureFileListView().update(
                entries: entries,
                mode: activeTab.view,
                selected: [match.path],
                focused: match.path,
                renamingPath: renamingPath,
                cutPaths: clipboard.cut ? Set(clipboard.paths) : [],
                showExtensions: preferences.showExtensions,
                sortKey: activeTab.sortKey,
                sortDir: activeTab.sortDir,
                loading: activeTab.loading,
                errorMessage: activeTab.pathError,
                permissionError: activeTab.permissionError,
                isSearch: activeTab.isSearching
            )
        } else {
            updateFileList()
        }
        updateSelectionDependentUI()
    }

    // MARK: - Quick Look

    private func isPreviewable(_ entry: FileEntry) -> Bool {
        if entry.isDirectory && entry.kind != .app { return false }
        return entry.kind != .archive
    }

    private func previewablePaths() -> [String] {
        visibleEntries().filter(isPreviewable).map { $0.path }
    }

    private func previewEntry() -> FileEntry? {
        let tab = activeTab
        let source = tab.isSearching ? tab.searchEntries : tab.entries
        if let focused = tab.focusedPath, let entry = source.first(where: { $0.path == focused }), isPreviewable(entry) {
            return entry
        }
        for entry in visibleEntries() where tab.selected.contains(entry.path) {
            if isPreviewable(entry) { return entry }
        }
        return nil
    }

    private func toggleQuickLook() {
        if quickLook.isVisible {
            quickLook.hide()
            return
        }
        guard contentHost === fileListView, let entry = previewEntry() else { return }
        let paths = previewablePaths()
        guard let current = paths.firstIndex(of: entry.path) else { return }
        quickLook.show(paths: paths, current: current)
    }

    private func handlePreviewEvent(_ event: NSEvent) -> Bool {
        guard quickLook.isVisible else { return false }
        if event.keyCode == 49 || event.keyCode == 53 {
            quickLook.hide()
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            let path = quickLook.currentPreviewPath() ?? activeTab.focusedPath
            quickLook.hide()
            if let path, let entry = (activeTab.isSearching ? activeTab.searchEntries : activeTab.entries)
                .first(where: { $0.path == path }) {
                open(entry)
            }
            return true
        }
        return false
    }

    private func previewSourceFrame(path: String) -> NSRect {
        fileListView?.screenFrame(forPath: path) ?? .zero
    }

    private func syncSelection(toPreviewPath path: String?) {
        guard let path, visibleEntries().contains(where: { $0.path == path }) else { return }
        let tab = activeTab
        guard tab.focusedPath != path else { return }
        tab.selected = [path]
        tab.focusedPath = path
        updateSelectionDependentUI()
    }

    private func finishPreview(path: String?) {
        syncSelection(toPreviewPath: path)
        window?.makeFirstResponder(fileListView)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLook.isOpen }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = quickLook
            panel.delegate = quickLook
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    // MARK: - Window delegate

    func windowDidBecomeKey(_ notification: Notification) {
        refreshClipboard()
    }

    func windowDidResize(_ notification: Notification) {
        titleBar.updateMaximized(window?.isZoomed ?? false)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        titleBar.updateMaximized(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        titleBar.updateMaximized(window?.isZoomed ?? false)
    }

    func windowWillClose(_ notification: Notification) {
        cancelSearchWork()
        directoryWatcher.stop()
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()
        persistSession()
        store.flush()
        (NSApp.delegate as? AppDelegate)?.removeController(self)
    }

    // MARK: - TitleBarDelegate

    func titleBarActivateTab(_ index: Int) { activateTab(index: index) }
    func titleBarCloseTab(_ index: Int) { closeTab(index: index) }
    func titleBarNewTab() { createTab() }
    func titleBarDetachTab(_ index: Int) { detachTab(index: index) }
    func titleBarMoveTab(_ from: Int, _ to: Int) { moveTab(from: from, to: to) }
    func titleBarMinimize() { window?.miniaturize(nil) }
    func titleBarToggleMaximize() { window?.zoom(nil) }
    func titleBarCloseWindow() { window?.close() }

    func titleBarShowMenu(_ index: Int, event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(makeMenuItem("Move tab to new window", icon: "macwindow") { [weak self] in
            self?.detachTab(index: index)
        })
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Close tab", icon: "xmark", key: "w") { [weak self] in
            self?.closeTab(index: index)
        })
        popUp(menu, event: event)
    }

    func titleBarReorderTab(_ from: Int, screenPoint: NSPoint) {
        let target = titleBar.tabIndex(atScreenPoint: screenPoint)
        moveTab(from: from, to: target)
    }

    // MARK: - Sidebar delegate

    func sidebarSelect(node: SidebarNode) {
        switch node.kind {
        case .home: navigate(to: .home)
        case .gallery: navigate(to: .gallery)
        case .network: navigate(to: .network)
        default:
            if let path = node.path { navigateToPath(path) }
        }
    }

    func sidebarContextMenu(node: SidebarNode?, event: NSEvent) {
        guard let node, let path = node.path else { return }
        let menu = NSMenu()
        menu.addItem(makeMenuItem("Open", icon: "folder") { [weak self] in self?.navigateToPath(path) })
        menu.addItem(makeMenuItem("Open in new tab", icon: "plus.square.on.square") { [weak self] in
            self?.navigate(to: .fs(path: path), newTab: true)
        })
        if node.kind == .volume, FileService.isEjectableVolume(path: path) {
            menu.addItem(makeMenuItem("Eject", icon: "eject") { [weak self] in
                self?.ejectVolume(path: path, name: node.title)
            })
        }
        menu.addItem(.separator())
        if node.kind == .folder {
            let pinned = store.isPinned(path)
            menu.addItem(makeMenuItem(pinned ? "Unpin from Quick access" : "Pin to Quick access", icon: pinned ? "pin.slash" : "pin") { [weak self] in
                _ = self?.store.togglePin([path])
                self?.render()
            })
        }
        menu.addItem(makeMenuItem("Show in Finder", icon: "folder") { _ = FileService.reveal(path) })
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Properties", icon: "info.circle", key: "i") { [weak self] in
            self?.showProperties(paths: [path], kind: nil)
        })
        popUp(menu, event: event)
    }

    func sidebarToggleSection(_ title: String, expanded: Bool) {
        if title == "Quick access" {
            preferences.quickAccessOpen = expanded
        } else if title == "This PC" {
            preferences.thisPcOpen = expanded
        }
        store.save()
    }

    func sidebarDrop(paths: [String], destination: String, copy: Bool) {
        transfer(paths: paths, destination: destination, copy: copy)
    }

    func sidebarNewTab(path: String) {
        navigate(to: .fs(path: path), newTab: true)
    }

    func sidebarTogglePin(path: String) {
        _ = store.togglePin([path])
        render()
    }

    func sidebarReveal(path: String) {
        _ = FileService.reveal(path)
    }

    func sidebarProperties(path: String) {
        showProperties(paths: [path], kind: nil)
    }

    // MARK: - FileListView delegate

    func fileListSelectionDidChange(_ paths: [String], focused: String?) {
        guard !isSyncingSelection else { return }
        isSyncingSelection = true
        activeTab.selected = Set(paths)
        activeTab.focusedPath = focused
        isSyncingSelection = false
        updateSelectionDependentUI()
    }

    func fileListMarqueeSelection(_ paths: [String]) {
        guard !isSyncingSelection else { return }
        isSyncingSelection = true
        activeTab.selected = Set(paths)
        isSyncingSelection = false
        updateCommandBar()
        statusBar.update(label: statusLabel(), view: activeTab.view, detailsOpen: preferences.detailsOpen)
        updateDetailsPane()
        if quickLook.isOpen {
            quickLook.sync(paths: previewablePaths())
        }
    }

    func fileListOpen(_ entry: FileEntry) {
        open(entry)
    }

    func fileListBackgroundClick() {
        activeTab.selected = []
        activeTab.focusedPath = nil
        updateSelectionDependentUI()
    }

    func fileListToggleSelection(_ path: String) {
        var selected = activeTab.selected
        if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
        activeTab.selected = selected
        activeTab.focusedPath = path
        updateSelectionDependentUI()
    }

    func fileListRename(_ entry: FileEntry, to name: String) {
        commitRename(entry, to: name)
    }

    func fileListCancelRename() {
        renamingPath = nil
        updateFileList()
    }

    func fileListDrop(paths: [String], destination: String?, copy: Bool) {
        guard let target = destination ?? activeTab.location.writePath else { return }
        transfer(paths: paths, destination: target, copy: copy)
    }

    func fileListSort(_ key: SortKey) {
        if key == activeTab.sortKey {
            setSort(key, activeTab.sortDir == .asc ? .desc : .asc)
        } else {
            setSort(key, key == .modified ? .desc : .asc)
        }
    }

    func fileListNewFolder() {
        createFolder()
    }

    func fileListRetry() {
        reloadActiveTab()
    }

    func fileListOpenPrivacy() {
        openPrivacySettings()
    }

    func fileListAddRecent(_ entry: FileEntry) {
        AppStore.shared.addRecent(entry)
    }

    // MARK: - Context menus

    private func popUp(_ menu: NSMenu, event: NSEvent) {
        guard let view = event.window?.contentView else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    func fileListContextMenu(entry: FileEntry?, event: NSEvent) {
        if let entry {
            showEntryMenu(entry, event: event)
        } else {
            showBackgroundMenu(event: event)
        }
    }

    private func showEntryMenu(_ entry: FileEntry, event: NSEvent) {
        let tab = activeTab
        if !tab.selected.contains(entry.path) {
            tab.selected = [entry.path]
            tab.focusedPath = entry.path
            updateSelectionDependentUI()
        }
        let paths = Array(tab.selected)
        let isFolder = entry.isDirectory && entry.kind != .app
        let writable = tab.location.writePath != nil
        let archive = tab.location.isArchive
        let pinPaths = isFolder ? paths.filter { path in
            selectedEntries().first(where: { $0.path == path })?.isDirectory == true
        } : []
        let allPinned = !pinPaths.isEmpty && pinPaths.allSatisfy { store.isPinned($0) }

        let menu = NSMenu()
        menu.addItem(makeMenuItem("Open", icon: "arrow.up.forward.app", key: "\r") { [weak self] in
            self?.open(entry)
        })
        if isPreviewable(entry) {
            menu.addItem(makeMenuItem("Quick Look", icon: "eye") { [weak self] in
                DispatchQueue.main.async { self?.toggleQuickLook() }
            })
        }
        if !entry.isDirectory {
            menu.addItem(makeOpenWithItem(for: entry))
        }
        if isFolder {
            menu.addItem(makeMenuItem("Open in new tab", icon: "plus.square.on.square") { [weak self] in
                guard let self else { return }
                if case .archive(let archivePath, let extractRoot, _) = self.activeTab.location {
                    self.navigate(
                        to: .archive(archivePath: archivePath, extractRoot: extractRoot, path: entry.path),
                        newTab: true
                    )
                } else {
                    self.navigate(to: .fs(path: entry.path), newTab: true)
                }
            })
        }
        if writable && !entry.isDirectory && FileKinds.isBrowsableArchive(entry.name) {
            menu.addItem(makeMenuItem("Extract all here", icon: "archivebox") { [weak self] in
                self?.extractArchive(entry.path, destination: tab.location.writePath ?? PathTools.dirname(entry.path))
            })
        }
        if !pinPaths.isEmpty && !archive {
            menu.addItem(makeMenuItem(
                allPinned ? "Unpin from Quick access" : "Pin to Quick access",
                icon: allPinned ? "pin.slash" : "pin"
            ) { [weak self] in
                _ = self?.store.togglePin(pinPaths)
                self?.render()
            })
        }
        if !archive {
            menu.addItem(makeMenuItem("Show in Finder", icon: "folder") { _ = FileService.reveal(entry.path) })
        }
        if isFolder && !archive {
            menu.addItem(makeMenuItem("Open in Terminal", icon: "terminal") { _ = FileService.openTerminal(entry.path) })
        }
        menu.addItem(.separator())
        if writable {
            menu.addItem(makeMenuItem("Cut", icon: "scissors", key: "x") { [weak self] in
                self?.activeTab.selected = Set(paths)
                self?.copySelection(cut: true)
            })
        }
        menu.addItem(makeMenuItem("Copy", icon: "doc.on.doc", key: "c") { [weak self] in
            self?.activeTab.selected = Set(paths)
            self?.copySelection(cut: false)
        })
        if writable && isFolder && !clipboard.paths.isEmpty {
            menu.addItem(makeMenuItem("Paste into folder", icon: "doc.on.clipboard", key: "v") { [weak self] in
                self?.paste(into: entry.path)
            })
        }
        if writable {
            menu.addItem(.separator())
            menu.addItem(makeMenuItem("Rename", icon: "pencil", enabled: paths.count == 1) { [weak self] in
                self?.renamingPath = entry.path
                self?.updateFileList()
            })
            menu.addItem(makeMenuItem("Delete", icon: "trash", key: "\u{8}") { [weak self] in
                self?.activeTab.selected = Set(paths)
                self?.trashSelection()
            })
            menu.addItem(makeMenuItem("Delete permanently", icon: "trash.slash") { [weak self] in
                self?.activeTab.selected = Set(paths)
                self?.confirmPermanentDelete()
            })
        }
        if !archive {
            menu.addItem(.separator())
            menu.addItem(makeMenuItem("Properties", icon: "info.circle", key: "i") { [weak self] in
                self?.activeTab.selected = Set(paths)
                self?.showProperties(paths: paths, kind: entry.kind)
            })
        }
        popUp(menu, event: event)
    }

    private func makeOpenWithItem(for entry: FileEntry) -> NSMenuItem {
        let item = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
        item.image = Icons.symbol("arrow.up.forward.app", size: 13)
        let submenu = NSMenu()
        let defaultURL = FileService.defaultApplication(toOpen: entry.path)
        var apps = FileService.applications(toOpen: entry.path)
        if let defaultURL, let index = apps.firstIndex(where: { $0.url.standardizedFileURL == defaultURL.standardizedFileURL }) {
            let preferred = apps.remove(at: index)
            apps.insert(preferred, at: 0)
        }
        for app in apps.prefix(10) {
            let appItem = makeMenuItem(app.name) { [weak self] in
                self?.open(entry, withApplicationAt: app.url)
            }
            appItem.image = IconService.shared.workspaceIcon(forPath: app.url.path, size: 16)
            if let defaultURL, app.url.standardizedFileURL == defaultURL.standardizedFileURL {
                appItem.state = .on
            }
            submenu.addItem(appItem)
        }
        if !apps.isEmpty {
            submenu.addItem(.separator())
        }
        submenu.addItem(makeMenuItem("Other…", icon: "app.badge") { [weak self] in
            self?.chooseApplication(for: entry)
        })
        item.submenu = submenu
        return item
    }

    private func open(_ entry: FileEntry, withApplicationAt applicationURL: URL) {
        AppStore.shared.addRecent(entry)
        let result = FileService.open(entry.path, withApplicationAt: applicationURL)
        if !result.ok {
            showToast(result.error ?? "Could not open “\(entry.name)”.", isError: true)
        }
    }

    private func chooseApplication(for entry: FileEntry) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose an application to open “\(entry.name)”."
        panel.prompt = "Open"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(entry, withApplicationAt: url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func sortMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for key in SortKey.allCases {
            items.append(makeMenuItem(key.label, checked: activeTab.sortKey == key) { [weak self] in
                guard let self else { return }
                if key == self.activeTab.sortKey {
                    self.setSort(key, self.activeTab.sortDir == .asc ? .desc : .asc)
                } else {
                    self.setSort(key, key == .modified ? .desc : .asc)
                }
            })
        }
        items.append(.separator())
        items.append(makeMenuItem("Ascending", checked: activeTab.sortDir == .asc) { [weak self] in
            guard let self else { return }
            self.setSort(self.activeTab.sortKey, .asc)
        })
        items.append(makeMenuItem("Descending", checked: activeTab.sortDir == .desc) { [weak self] in
            guard let self else { return }
            self.setSort(self.activeTab.sortKey, .desc)
        })
        return items
    }

    private func viewMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for mode in ViewMode.allCases {
            items.append(makeMenuItem(mode.label, checked: activeTab.view == mode) { [weak self] in
                self?.setView(mode)
            })
        }
        items.append(.separator())
        items.append(makeMenuItem("Show hidden items", checked: preferences.showHidden) { [weak self] in
            self?.toggleHidden()
        })
        items.append(makeMenuItem("Show file extensions", checked: preferences.showExtensions) { [weak self] in
            self?.toggleExtensions()
        })
        return items
    }

    private func showBackgroundMenu(event: NSEvent) {
        let tab = activeTab
        let canCreate = tab.location.writePath != nil && !tab.isSearching
        let menu = NSMenu()
        if canCreate {
            let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
            newItem.image = Icons.symbol("folder.badge.plus", size: 13)
            let submenu = NSMenu()
            submenu.addItem(makeMenuItem("Folder", icon: "folder.badge.plus") { [weak self] in self?.createFolder() })
            submenu.addItem(makeMenuItem("Text document", icon: "doc.badge.plus") { [weak self] in self?.createTextFile() })
            newItem.submenu = submenu
            menu.addItem(newItem)
        }
        menu.addItem(makeMenuItem("Paste", icon: "doc.on.clipboard", key: "v", enabled: canCreate && !clipboard.paths.isEmpty) { [weak self] in
            self?.pasteIntoCurrent()
        })
        menu.addItem(.separator())
        let sortItem = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: "")
        sortItem.image = Icons.symbol("arrow.up.arrow.down", size: 13)
        let sortMenu = NSMenu()
        for item in sortMenuItems() { sortMenu.addItem(item) }
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.image = Icons.symbol("square.grid.2x2", size: 13)
        let viewMenu = NSMenu()
        for item in viewMenuItems() { viewMenu.addItem(item) }
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        menu.addItem(makeMenuItem("Refresh", icon: "arrow.clockwise", key: "r") { [weak self] in self?.refresh() })
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Open in Terminal", icon: "terminal", enabled: tab.location.writePath != nil) { [weak self] in
            guard let self, let path = self.activeTab.location.writePath else { return }
            _ = FileService.openTerminal(path)
        })
        menu.addItem(makeMenuItem("Properties", icon: "info.circle", enabled: tab.location.writePath != nil) { [weak self] in
            guard let self, let path = self.activeTab.location.writePath else { return }
            self.showProperties(paths: [path], kind: .folder)
        })
        popUp(menu, event: event)
    }

    private func showVolumeMenu(_ volume: Volume, event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(makeMenuItem("Open", icon: "internaldrive") { [weak self] in
            self?.navigateToPath(volume.path)
        })
        menu.addItem(makeMenuItem("Open in new tab", icon: "plus.square.on.square") { [weak self] in
            self?.navigate(to: .fs(path: volume.path), newTab: true)
        })
        if FileService.isEjectableVolume(path: volume.path) {
            menu.addItem(makeMenuItem("Eject", icon: "eject") { [weak self] in
                self?.ejectVolume(path: volume.path, name: volume.name)
            })
        }
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Properties", icon: "info.circle") { [weak self] in
            self?.showProperties(paths: [volume.path], kind: .folder)
        })
        popUp(menu, event: event)
    }

    private func ejectVolume(path: String, name: String) {
        let result = FileService.ejectVolume(at: path)
        guard result.ok else {
            showToast(result.error ?? "Could not eject “\(name)”.", isError: true)
            return
        }
        systemInfo = FileService.systemInfo()
        showToast("Ejected “\(name)”.")
        if case .fs(let current) = activeTab.location,
           current == path || current.hasPrefix(path + "/") {
            navigate(to: .home)
        } else {
            render()
        }
    }

    private func showQuickMenu(_ item: QuickItem, event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(makeMenuItem("Open", icon: "folder") { [weak self] in self?.navigateToPath(item.path) })
        menu.addItem(makeMenuItem("Open in new tab", icon: "plus.square.on.square") { [weak self] in
            self?.navigate(to: .fs(path: item.path), newTab: true)
        })
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Unpin from Quick access", icon: "pin.slash") { [weak self] in
            _ = self?.store.togglePin([item.path])
            self?.render()
        })
        menu.addItem(makeMenuItem("Show in Finder", icon: "folder") { _ = FileService.reveal(item.path) })
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Properties", icon: "info.circle") { [weak self] in
            self?.showProperties(paths: [item.path], kind: .folder)
        })
        popUp(menu, event: event)
    }

    private func showRecentMenu(_ item: RecentItem, event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(makeMenuItem("Open", icon: "arrow.up.forward.app") { [weak self] in self?.openRecent(item) })
        menu.addItem(makeMenuItem("Show in Finder", icon: "folder") { _ = FileService.reveal(item.path) })
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Remove from Recent", icon: "xmark") { [weak self] in
            AppStore.shared.removeRecent(item.path)
            self?.render()
        })
        menu.addItem(makeMenuItem("Properties", icon: "info.circle") { [weak self] in
            self?.showProperties(paths: [item.path], kind: item.kind)
        })
        popUp(menu, event: event)
    }

    private func showGalleryMenu(_ entry: FileEntry, event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(makeMenuItem("Open", icon: "arrow.up.forward.app") { [weak self] in self?.open(entry) })
        menu.addItem(makeMenuItem("Show in Finder", icon: "folder") { _ = FileService.reveal(entry.path) })
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Properties", icon: "info.circle") { [weak self] in
            self?.showProperties(paths: [entry.path], kind: entry.kind)
        })
        popUp(menu, event: event)
    }

    // MARK: - UI smoke harness

    private func marqueeUnionFrame(_ list: FileListView) -> NSRect? {
        let entriesNow = visibleEntries()
        var frames: [NSRect] = []
        frames.reserveCapacity(entriesNow.count)
        for entry in entriesNow {
            guard let frame = list.itemFrame(forPath: entry.path) else { return nil }
            frames.append(frame)
        }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    func runSmokeTest() async -> Int {
        var failures = 0
        var passes = 0
        func report(_ ok: Bool, _ name: String, _ detail: String = "") {
            if ok { passes += 1 } else { failures += 1 }
            let line = ok ? "PASS  \(name)" : "FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")"
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
        func waitUntil(_ condition: @escaping () -> Bool, timeout: Double = 6) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            return condition()
        }

        let fm = FileManager.default
        let testRoot = fm.temporaryDirectory.appendingPathComponent("explorer-neo-ui-\(UUID().uuidString)")
        try? fm.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: testRoot) }
        try? Data("hello".utf8).write(to: testRoot.appendingPathComponent("alpha.txt"))
        try? Data("world".utf8).write(to: testRoot.appendingPathComponent("beta.txt"))

        navigate(to: .fs(path: testRoot.path))
        _ = await waitUntil { !self.activeTab.loading && self.activeTab.location.readPath == testRoot.path }
        report(activeTab.entries.count == 2, "navigate + listing", "count=\(activeTab.entries.count)")

        setView(.large)
        report(activeTab.view == .large, "switch to large icons")
        setView(.medium)
        report(activeTab.view == .medium, "switch to medium icons")
        setView(.list)
        report(activeTab.view == .list, "switch to list")
        setView(.tiles)
        report(activeTab.view == .tiles, "switch to tiles")
        setView(.details)
        report(activeTab.view == .details, "switch to details")

        setSort(.name, .desc)
        report(activeTab.sortDir == .desc, "sort descending")
        setSort(.name, .asc)

        toggleHidden()
        report(preferences.showHidden, "toggle hidden items")
        toggleHidden()
        report(!preferences.showHidden, "toggle hidden items off")

        toggleExtensions()
        report(preferences.showExtensions, "toggle extensions")
        toggleExtensions()

        toggleSidebar()
        report(!preferences.sidebarVisible, "hide navigation pane")
        toggleSidebar()
        report(preferences.sidebarVisible, "show navigation pane")

        if preferences.detailsOpen { toggleDetails() }
        toggleDetails()
        report(preferences.detailsOpen, "open details pane")
        if let first = visibleEntries().first {
            activeTab.selected = [first.path]
            activeTab.focusedPath = first.path
            updateSelectionDependentUI()
            report(detailsPane != nil, "details pane updates")
        }
        toggleDetails()

        createFolder()
        let created = await waitUntil { self.visibleEntries().contains { $0.name == "New folder" } }
        report(created, "create folder")
        if let folder = visibleEntries().first(where: { $0.name == "New folder" }) {
            commitRename(folder, to: "Smoke Folder")
            let renamed = await waitUntil { self.visibleEntries().contains { $0.name == "Smoke Folder" } }
            report(renamed, "inline rename")
        } else {
            report(false, "inline rename", "folder missing")
        }

        if let folder = visibleEntries().first(where: { $0.name == "Smoke Folder" }) {
            activeTab.selected = [folder.path]
            copySelection(cut: false)
            paste(into: testRoot.path)
            let copied = await waitUntil { self.visibleEntries().contains { $0.name == "Smoke Folder - Copy" } }
            report(copied, "copy + paste with unique name")
        } else {
            report(false, "copy + paste with unique name", "folder missing")
        }

        if let copy = visibleEntries().first(where: { $0.name == "Smoke Folder - Copy" }) {
            activeTab.selected = [copy.path]
            copySelection(cut: true)
            paste(into: testRoot.path)
            let moved = await waitUntil {
                self.visibleEntries().contains { $0.name == "Smoke Folder - Copy - Copy" }
            }
            report(moved, "cut + paste move")
        } else {
            report(false, "cut + paste move", "copy missing")
        }

        handleSearchChange("smoke")
        let searched = await waitUntil { !self.activeTab.searchLoading && self.activeTab.searchQuery == "smoke" }
        report(searched && !self.activeTab.searchEntries.isEmpty, "search", "results=\(activeTab.searchEntries.count)")
        clearSearchPressed()
        report(activeTab.searchQuery.isEmpty, "clear search")

        showAbout()
        report(overlay is AboutOverlay, "about dialog")
        dismissOverlay()

        showProperties(paths: [testRoot.path], kind: .folder)
        report(overlay is PropertiesOverlay, "properties dialog")
        try? await Task.sleep(nanoseconds: 400_000_000)
        dismissOverlay()

        showConfirm(title: "Test", message: "Test", confirmLabel: "OK", dangerous: false) {}
        report(overlay is ConfirmOverlay, "confirmation dialog")
        dismissOverlay()

        let tabsBefore = tabs.count
        createTab()
        report(tabs.count == tabsBefore + 1, "new tab")
        closeTab(index: activeIndex)
        report(tabs.count == tabsBefore, "close tab")

        window?.makeFirstResponder(nil)
        if let window {
            func keyEvent(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: flags,
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: code
                )
            }
            activeTab.selected = []
            activeTab.focusedPath = nil
            if let event = keyEvent("a", 0, []) { _ = handleKeyDown(event) }
            report(activeTab.selected.contains(where: { $0.hasSuffix("alpha.txt") }), "type-ahead selection")
            if let event = keyEvent("a", 0, [.command]) { _ = handleKeyDown(event) }
            report(activeTab.selected.count == visibleEntries().count, "⌘A select all")
            if let event = keyEvent("\u{1b}", 53, []) { _ = handleKeyDown(event) }
            report(activeTab.selected.isEmpty, "escape clears selection")
            let countBeforeKeys = tabs.count
            if let event = keyEvent("t", 17, [.command]) { _ = handleKeyDown(event) }
            report(tabs.count == countBeforeKeys + 1, "⌘T new tab (keyboard)")
            if let event = keyEvent("w", 13, [.command]) { _ = handleKeyDown(event) }
            report(tabs.count == countBeforeKeys, "⌘W close tab (keyboard)")
            if let file = visibleEntries().first(where: { !$0.isDirectory }) {
                activeTab.selected = [file.path]
                activeTab.focusedPath = file.path
                updateSelectionDependentUI()
                if let event = keyEvent(" ", 49, []) { _ = handleKeyDown(event) }
                report(quickLook.isOpen, "space opens Quick Look")
                if let event = keyEvent(" ", 49, []) { _ = handleKeyDown(event) }
                report(!quickLook.isOpen, "space closes Quick Look")
                DispatchQueue.main.async { [weak self] in self?.toggleQuickLook() }
                try? await Task.sleep(nanoseconds: 300_000_000)
                report(quickLook.isVisible, "menu-style Quick Look opens")
                DispatchQueue.main.async { [weak self] in self?.toggleQuickLook() }
                try? await Task.sleep(nanoseconds: 300_000_000)
                report(!quickLook.isVisible, "menu-style Quick Look closes")
                if let list = fileListView {
                    let expected = visibleEntries().count
                    if let union = marqueeUnionFrame(list) {
                        list.beginMarquee(at: NSPoint(x: union.minX + 4, y: union.minY - 12), extend: false)
                        list.updateMarquee(to: NSPoint(x: union.maxX - 4, y: union.maxY + 12))
                        list.endMarquee()
                    }
                    report(activeTab.selected.count == expected, "marquee selects rows in details view", "count=\(activeTab.selected.count)/\(expected)")
                    if let union = marqueeUnionFrame(list) {
                        list.beginMarquee(at: NSPoint(x: union.minX + 4, y: union.minY - 28), extend: false)
                        list.endMarquee()
                    }
                    report(activeTab.selected.isEmpty, "background click clears selection")
                    setView(.large)
                    if let union = marqueeUnionFrame(list) {
                        list.beginMarquee(at: NSPoint(x: union.minX + 4, y: union.minY - 12), extend: false)
                        list.updateMarquee(to: NSPoint(x: union.maxX - 4, y: union.maxY + 12))
                        list.endMarquee()
                    }
                    report(activeTab.selected.count == expected, "marquee selects items in icon view", "count=\(activeTab.selected.count)/\(expected)")
                    setView(.details)
                } else {
                    report(false, "marquee selects rows in details view", "no file list")
                    report(false, "background click clears selection", "no file list")
                    report(false, "marquee selects items in icon view", "no file list")
                }
            } else {
                report(false, "space opens Quick Look", "no file entry")
                report(false, "space closes Quick Look", "no file entry")
            }
        }

        if let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu,
           let item = fileMenu.item(withTitle: "New Tab"),
           let action = item.action {
            let before = tabs.count
            let handled = NSApp.sendAction(action, to: nil, from: item)
            report(handled && tabs.count == before + 1, "menu bar New Tab routes to window")
            closeTab(index: activeIndex)
        } else {
            report(false, "menu bar New Tab routes to window", "menu item missing")
        }
        if let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu,
           let item = viewMenu.item(withTitle: "Large icons"),
           let action = item.action {
            _ = NSApp.sendAction(action, to: nil, from: item)
            report(activeTab.view == .large, "menu bar view mode routes to window")
            setView(.details)
        } else {
            report(false, "menu bar view mode routes to window", "menu item missing")
        }

        navBar.triggerAddressBarClick()
        report(navBar.isEditingAddress, "address bar click enters edit mode")
        navBar.cancelAddressEditing()

        if let file = visibleEntries().first(where: { !$0.isDirectory }) {
            let openWith = makeOpenWithItem(for: file)
            report(openWith.submenu?.items.isEmpty == false, "Open with menu")
        } else {
            report(false, "Open with menu", "no file entry")
        }

        if let editMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu,
           let item = editMenu.item(withTitle: "Select All"),
           let action = item.action {
            activeTab.selected = []
            activeTab.focusedPath = nil
            _ = NSApp.sendAction(action, to: nil, from: item)
            report(activeTab.selected.count == visibleEntries().count, "menu bar Select All routes to window")
        } else {
            report(false, "menu bar Select All routes to window", "menu item missing")
        }

        let originalTheme = preferences.theme
        setTheme(.light)
        report(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua, "light theme")
        setTheme(.dark)
        report(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, "dark theme")
        setTheme(originalTheme)

        refresh()
        let refreshed = await waitUntil { !self.activeTab.loading }
        report(refreshed, "refresh")

        FileHandle.standardOutput.write(Data("\n\(passes) passed, \(failures) failed\n".utf8))
        return failures
    }

    // MARK: - Menu actions

    @objc func showAboutAction(_ sender: Any?) { showAbout() }
    @objc func newTabAction(_ sender: Any?) { createTab() }
    @objc func closeTabAction(_ sender: Any?) { closeTab(index: activeIndex) }
    @objc func newFolderAction(_ sender: Any?) { createFolder() }
    @objc func deleteAction(_ sender: Any?) { trashSelection() }
    @objc func deletePermanentlyAction(_ sender: Any?) { confirmPermanentDelete() }
    @objc func propertiesAction(_ sender: Any?) {
        guard !activeTab.selected.isEmpty else { return }
        showProperties(paths: Array(activeTab.selected), kind: selectedEntries().first?.kind)
    }
    @objc func toggleHiddenAction(_ sender: Any?) { toggleHidden() }
    @objc func toggleExtensionsAction(_ sender: Any?) { toggleExtensions() }
    @objc func toggleSidebarAction(_ sender: Any?) { toggleSidebar() }
    @objc func toggleDetailsAction(_ sender: Any?) { toggleDetails() }
    @objc func goBackAction(_ sender: Any?) { goHistory(-1) }
    @objc func goForwardAction(_ sender: Any?) { goHistory(1) }
    @objc func goUpAction(_ sender: Any?) { goUp() }
    @objc func refreshAction(_ sender: Any?) { refresh() }
    @objc func openTerminalAction(_ sender: Any?) {
        guard let path = activeTab.location.writePath else { return }
        _ = FileService.openTerminal(path)
    }

    @objc func setViewModeAction(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < ViewMode.allCases.count else { return }
        setView(ViewMode.allCases[sender.tag])
    }

    @objc func copy(_ sender: Any?) { copySelection(cut: false) }
    @objc func cut(_ sender: Any?) { copySelection(cut: true) }
    @objc func paste(_ sender: Any?) { pasteIntoCurrent() }
    @objc override func selectAll(_ sender: Any?) {
        if let fileListView, contentHost === fileListView {
            fileListView.selectAllEntries()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return !activeTab.selected.isEmpty
        case #selector(cut(_:)), #selector(deleteAction(_:)), #selector(deletePermanentlyAction(_:)):
            return activeTab.location.writePath != nil && !activeTab.selected.isEmpty
        case #selector(paste(_:)):
            return activeTab.location.writePath != nil && !clipboard.paths.isEmpty && !activeTab.isSearching
        case #selector(selectAll(_:)):
            return !visibleEntries().isEmpty
        case #selector(propertiesAction(_:)):
            return !activeTab.selected.isEmpty && !activeTab.location.isArchive
        case #selector(goBackAction(_:)):
            return activeTab.historyIndex > 0
        case #selector(goForwardAction(_:)):
            return activeTab.historyIndex < activeTab.history.count - 1
        case #selector(goUpAction(_:)):
            return canGoUp()
        case #selector(setViewModeAction(_:)):
            if menuItem.tag >= 0, menuItem.tag < ViewMode.allCases.count {
                menuItem.state = activeTab.view == ViewMode.allCases[menuItem.tag] ? .on : .off
            }
            return true
        case #selector(toggleHiddenAction(_:)):
            menuItem.state = preferences.showHidden ? .on : .off
            return true
        case #selector(toggleExtensionsAction(_:)):
            menuItem.state = preferences.showExtensions ? .on : .off
            return true
        case #selector(toggleSidebarAction(_:)):
            menuItem.state = preferences.sidebarVisible ? .on : .off
            return true
        case #selector(toggleDetailsAction(_:)):
            menuItem.state = preferences.detailsOpen ? .on : .off
            return true
        case #selector(newTabAction(_:)):
            return true
        default:
            return true
        }
    }
}

final class BrowserWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) {
            return
        }
        super.sendEvent(event)
    }
}

final class ProgressLineView: NSView {
    private let bar = NSView()
    private var animating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Theme.accent.cgColor
        bar.layer?.cornerRadius = 1
        addSubview(bar)
        bar.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isAnimating: Bool {
        get { animating }
        set {
            guard animating != newValue else { return }
            animating = newValue
            bar.isHidden = !newValue
            if newValue {
                start()
            } else {
                bar.layer?.removeAllAnimations()
            }
        }
    }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width * 0.3, height: bounds.height)
        if animating { start() }
    }

    private func start() {
        guard bounds.width > 0 else { return }
        bar.layer?.removeAllAnimations()
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -bounds.width * 0.35
        animation.toValue = bounds.width * 1.15
        animation.duration = 1.1
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.layer?.add(animation, forKey: "slide")
    }
}
