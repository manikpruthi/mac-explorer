import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [BrowserWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = IconService.shared.appIcon(size: 256)
        buildMainMenu()
        ArchiveService.cleanup()
        applyLaunchOverrides()
        Theme.apply(AppStore.shared.preferences.theme)
        let controller = makeController(location: initialLocation())
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        scheduleScreenshotIfRequested()
        if CommandLine.arguments.contains("--ui-test") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                let failures = await controller.runSmokeTest()
                exit(failures == 0 ? 0 : 1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let controller = focusedController() {
                controller.showWindow(nil)
                controller.window?.makeKeyAndOrderFront(nil)
            } else {
                let controller = makeController(location: nil)
                controller.showWindow(nil)
                controller.window?.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppStore.shared.flush()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    // MARK: - Window registry

    private func makeController(location: Location?, cascadeFrom: NSRect? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(location: location, cascadeFrom: cascadeFrom)
        controllers.append(controller)
        return controller
    }

    func removeController(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
    }

    func focusedController() -> BrowserWindowController? {
        if let key = NSApp.keyWindow, let match = controllers.first(where: { $0.window === key }) {
            return match
        }
        if let main = NSApp.mainWindow, let match = controllers.first(where: { $0.window === main }) {
            return match
        }
        return controllers.last
    }

    func newWindow(from source: NSWindow?) {
        let frame = source?.frame
        let controller = makeController(location: .home, cascadeFrom: frame)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func detachTab(location: Location, from source: NSWindow?) {
        let controller = makeController(location: location, cascadeFrom: source?.frame)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func scheduleScreenshotIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--screenshot"), index + 1 < arguments.count else { return }
        let path = arguments[index + 1]
        let shouldExit = arguments.contains("--screenshot-exit")
        var delay: Double = 1.5
        if let delayIndex = arguments.firstIndex(of: "--screenshot-delay"), delayIndex + 1 < arguments.count,
           let value = Double(arguments[delayIndex + 1]) {
            delay = value
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.captureScreenshot(to: path)
            if shouldExit { NSApp.terminate(nil) }
        }
    }

    private func captureScreenshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func applyLaunchOverrides() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--view"), index + 1 < arguments.count,
           let mode = ViewMode(rawValue: arguments[index + 1]) {
            AppStore.shared.preferences.view = mode
        }
        if let index = arguments.firstIndex(of: "--theme"), index + 1 < arguments.count,
           let theme = ThemePreference(rawValue: arguments[index + 1]) {
            AppStore.shared.preferences.theme = theme
        }
        if arguments.contains("--details") { AppStore.shared.preferences.detailsOpen = true }
        if arguments.contains("--preview") {
            AppStore.shared.preferences.previewOpen = true
            AppStore.shared.preferences.detailsOpen = false
        }
        if arguments.contains("--show-hidden") { AppStore.shared.preferences.showHidden = true }
        if arguments.contains("--no-sidebar") { AppStore.shared.preferences.sidebarVisible = false }
    }

    private func initialLocation() -> Location? {
        let arguments = CommandLine.arguments
        if arguments.contains("--ui-test") || arguments.contains("--self-test") {
            return .home
        }
        if let index = arguments.firstIndex(of: "--archive"), index + 1 < arguments.count {
            let result = ArchiveService.openArchive(arguments[index + 1])
            if result.ok, let archivePath = result.archivePath, let extractRoot = result.extractRoot {
                return .archive(archivePath: archivePath, extractRoot: extractRoot, path: extractRoot)
            }
        }
        if arguments.contains("--gallery") { return .gallery }
        if arguments.contains("--network") { return .network }
        if let index = arguments.firstIndex(of: "--location"), index + 1 < arguments.count {
            return .fs(path: arguments[index + 1])
        }
        return nil
    }

    // MARK: - Menu

    @objc private func showAboutAction(_ sender: Any?) {
        if let controller = focusedController() {
            controller.showAboutAction(sender)
        } else {
            let controller = makeController(location: nil)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.showAboutAction(sender)
        }
    }

    @objc private func newWindowAction(_ sender: Any?) {
        newWindow(from: NSApp.keyWindow)
    }

    private func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil,
        tag: Int = 0
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = target
        menuItem.tag = tag
        return menuItem
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appMenuItem = NSMenuItem(title: "Mac Explorer", action: nil, keyEquivalent: "")
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(item("About Mac Explorer", #selector(showAboutAction(_:)), target: self))
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Mac Explorer", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Mac Explorer", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        appMenuItem.submenu = appMenu

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("New Window", #selector(newWindowAction(_:)), "n", target: self))
        fileMenu.addItem(item("New Tab", #selector(BrowserWindowController.newTabAction(_:)), "t"))
        fileMenu.addItem(item("New Folder", #selector(BrowserWindowController.newFolderAction(_:)), "n", [.command, .shift]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Permissions…", #selector(BrowserWindowController.permissionsAction(_:))))
        fileMenu.addItem(item("Find Duplicates…", #selector(BrowserWindowController.findDuplicatesAction(_:))))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Close Tab", #selector(BrowserWindowController.closeTabAction(_:)), "w"))
        fileMenu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(item("Undo", Selector(("undo:")), "z"))
        editMenu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        editItem.submenu = editMenu

        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(item("Show Hidden Items", #selector(BrowserWindowController.toggleHiddenAction(_:))))
        viewMenu.addItem(item("Show File Extensions", #selector(BrowserWindowController.toggleExtensionsAction(_:))))
        viewMenu.addItem(.separator())
        for (tag, mode) in ViewMode.allCases.enumerated() {
            viewMenu.addItem(item(mode.label, #selector(BrowserWindowController.setViewModeAction(_:)), tag: tag))
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Navigation Pane", #selector(BrowserWindowController.toggleSidebarAction(_:))))
        viewMenu.addItem(item("Details Pane", #selector(BrowserWindowController.toggleDetailsAction(_:))))
        viewMenu.addItem(item("Preview Pane", #selector(BrowserWindowController.togglePreviewAction(_:)), "p", [.command, .option]))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
