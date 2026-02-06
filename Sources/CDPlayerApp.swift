import SwiftUI
import AppKit
import Combine

@main
struct CDPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var colimaManager: ColimaManager!
    private var dockerManager: DockerManager!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        colimaManager = ColimaManager()
        dockerManager = DockerManager()

        setupStatusItem()
        setupMenu()

        colimaManager.$instances
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
                self?.setupMenu()
            }
            .store(in: &cancellables)

        colimaManager.$configuredUser
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.setupMenu()
            }
            .store(in: &cancellables)

        dockerManager.$containers
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.setupMenu()
            }
            .store(in: &cancellables)

        dockerManager.$pinnedContainerIds
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.setupMenu()
            }
            .store(in: &cancellables)

        dockerManager.$unavailableReason
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.setupMenu()
            }
            .store(in: &cancellables)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        // let hasTransitioning = colimaManager.instances.contains { $0.status.isTransitioning }
        let hasStopping = colimaManager.instances.contains { $0.status.isStopping }
        let hasRunning = colimaManager.hasRunningInstance

        let symbolName: String
        let accessibilityLabel: String

        /* if hasTransitioning { // Half-filled icon
            // symbolName = "hare"  // Indicates activity
            symbolName = "circle.grid.2x2.fill"  // Indicates activity
            accessibilityLabel = "Colima Busy"
        } else */ 
        if hasRunning || hasStopping  {
            // symbolName = "hare.fill"
            // symbolName = "circle.grid.2x2.fill"
            symbolName = "smallcircle.fill.circle.fill"
            accessibilityLabel = "Colima Running"
        } else {
            // symbolName = "hare"
            // symbolName = "circle.grid.2x2"
            symbolName = "smallcircle.circle"
            accessibilityLabel = "Colima Stopped"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel) {
            image.isTemplate = true
            button.image = image
        }
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // // ── Colima Section ──
        // let colimaHeader = NSMenuItem(title: "── Colima ──", action: nil, keyEquivalent: "")
        // colimaHeader.isEnabled = false
        // menu.addItem(colimaHeader)

        if colimaManager.instances.isEmpty {
            let noInstancesItem = NSMenuItem(title: "No Colima instances found", action: nil, keyEquivalent: "")
            noInstancesItem.isEnabled = false
            menu.addItem(noInstancesItem)
        } else if colimaManager.hasOnlyDefaultProfile {
            let instance = colimaManager.instances[0]

            // Header with instance name and status icon
            let statusIcon = instance.status.isTransitioning ? "◐" : (instance.status.isRunning ? "●" : "○")
            let headerItem = NSMenuItem(title: "\(statusIcon) Colima (\(instance.name))", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            menu.addItem(headerItem)

            for line in instance.statusLines {
                let item = NSMenuItem(title: "    \(line)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }

            menu.addItem(NSMenuItem.separator())

            if instance.status.isTransitioning {
                let actionItem = NSMenuItem(title: instance.status == .starting ? "Starting..." : "Stopping...", action: nil, keyEquivalent: "")
                actionItem.isEnabled = false
                menu.addItem(actionItem)
            } else if instance.status.isStopped {
                let startItem = NSMenuItem(title: "Start Colima", action: #selector(startInstance(_:)), keyEquivalent: "s")
                startItem.target = self
                startItem.representedObject = instance.name
                menu.addItem(startItem)
            } else if instance.status.isRunning {
                let stopItem = NSMenuItem(title: "Stop Colima", action: #selector(stopInstance(_:)), keyEquivalent: "s")
                stopItem.target = self
                stopItem.representedObject = instance.name
                menu.addItem(stopItem)
            }
        } else {
            for instance in colimaManager.instances {
                let instanceMenu = NSMenu()
                instanceMenu.autoenablesItems = false

                for line in instance.statusLines {
                    let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    instanceMenu.addItem(item)
                }

                instanceMenu.addItem(NSMenuItem.separator())

                if instance.status.isTransitioning {
                    let actionItem = NSMenuItem(title: instance.status == .starting ? "Starting..." : "Stopping...", action: nil, keyEquivalent: "")
                    actionItem.isEnabled = false
                    instanceMenu.addItem(actionItem)
                } else if instance.status.isStopped {
                    let startItem = NSMenuItem(title: "Start", action: #selector(startInstance(_:)), keyEquivalent: "")
                    startItem.target = self
                    startItem.representedObject = instance.name
                    instanceMenu.addItem(startItem)
                } else if instance.status.isRunning {
                    let stopItem = NSMenuItem(title: "Stop", action: #selector(stopInstance(_:)), keyEquivalent: "")
                    stopItem.target = self
                    stopItem.representedObject = instance.name
                    instanceMenu.addItem(stopItem)
                }

                let statusIcon: String
                if instance.status.isTransitioning {
                    statusIcon = "◐"
                } else if instance.status.isRunning {
                    statusIcon = "●"
                } else {
                    statusIcon = "○"
                }
                let instanceItem = NSMenuItem(title: "\(statusIcon) Colima (\(instance.name))", action: nil, keyEquivalent: "")
                instanceItem.submenu = instanceMenu
                menu.addItem(instanceItem)
            }
        }

        // // ── Docker Section ──
        menu.addItem(NSMenuItem.separator())
        // let dockerHeader = NSMenuItem(title: "── Docker ──", action: nil, keyEquivalent: "")
        // dockerHeader.isEnabled = false
        // menu.addItem(dockerHeader)

        if !dockerManager.isAvailable && dockerManager.containers.isEmpty {
            let reason = dockerManager.unavailableReason
            switch reason {
            case .permissionDenied:
                let item = NSMenuItem(title: "Docker: Permission Denied...", action: #selector(runDockerDiagnostics), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            case .daemonNotRunning, .socketNotFound:
                let item = NSMenuItem(title: "Docker Unavailable (Colima Not Running)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .unknown, .none:
                let unavailable = NSMenuItem(title: "Docker Unavailable", action: nil, keyEquivalent: "")
                unavailable.isEnabled = false
                menu.addItem(unavailable)
            }
        } else {
            let pinned = dockerManager.pinnedContainers
            if pinned.isEmpty {
                let noPinned = NSMenuItem(title: "No Pinned Containers", action: nil, keyEquivalent: "")
                noPinned.isEnabled = false
                menu.addItem(noPinned)
            } else {
                for container in pinned {
                    let submenu = NSMenu()
                    submenu.autoenablesItems = false

                    // Info items
                    let imageItem = NSMenuItem(title: "Image: \(container.image)", action: nil, keyEquivalent: "")
                    imageItem.isEnabled = false
                    submenu.addItem(imageItem)

                    let statusItem = NSMenuItem(title: container.statusText, action: nil, keyEquivalent: "")
                    statusItem.isEnabled = false
                    submenu.addItem(statusItem)

                    let parsedPorts = DockerContainer.parsePorts(container.ports)
                    if !parsedPorts.isEmpty {
                        if parsedPorts.count <= 3 {
                            let portsStr = parsedPorts.joined(separator: ", ")
                            let portsItem = NSMenuItem(title: "Ports: \(portsStr)", action: nil, keyEquivalent: "")
                            portsItem.isEnabled = false
                            submenu.addItem(portsItem)
                        } else {
                            let portsHeader = NSMenuItem(title: "Ports:", action: nil, keyEquivalent: "")
                            portsHeader.isEnabled = false
                            submenu.addItem(portsHeader)
                            for port in parsedPorts {
                                let portItem = NSMenuItem(title: "    \(port)", action: nil, keyEquivalent: "")
                                portItem.isEnabled = false
                                submenu.addItem(portItem)
                            }
                        }
                    }

                    submenu.addItem(NSMenuItem.separator())

                    // Actions based on state
                    switch container.status {
                    case .running:
                        let stop = NSMenuItem(title: "Stop", action: #selector(dockerStopContainer(_:)), keyEquivalent: "")
                        stop.target = self
                        stop.representedObject = container.id
                        if let img = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop") { stop.image = img }
                        submenu.addItem(stop)

                        let pause = NSMenuItem(title: "Pause", action: #selector(dockerPauseContainer(_:)), keyEquivalent: "")
                        pause.target = self
                        pause.representedObject = container.id
                        if let img = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause") { pause.image = img }
                        submenu.addItem(pause)
                    case .paused:
                        let unpause = NSMenuItem(title: "Unpause", action: #selector(dockerUnpauseContainer(_:)), keyEquivalent: "")
                        unpause.target = self
                        unpause.representedObject = container.id
                        if let img = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Unpause") { unpause.image = img }
                        submenu.addItem(unpause)

                        let stop = NSMenuItem(title: "Stop", action: #selector(dockerStopContainer(_:)), keyEquivalent: "")
                        stop.target = self
                        stop.representedObject = container.id
                        if let img = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop") { stop.image = img }
                        submenu.addItem(stop)
                    case .exited, .created, .other:
                        let start = NSMenuItem(title: "Start", action: #selector(dockerStartContainer(_:)), keyEquivalent: "")
                        start.target = self
                        start.representedObject = container.id
                        if let img = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Start") { start.image = img }
                        submenu.addItem(start)
                    }

                    submenu.addItem(NSMenuItem.separator())

                    let idItem = NSMenuItem(title: "Copy \(container.shortId)", action: #selector(dockerCopyContainerId(_:)), keyEquivalent: "")
                    if let img = NSImage(systemSymbolName: "grid.circle", accessibilityDescription: "Copy ID") {
                        idItem.image = img
                    }
                    idItem.target = self
                    idItem.representedObject = container.id
                    submenu.addItem(idItem)

                    let unpin = NSMenuItem(title: "Unpin", action: #selector(dockerUnpinContainer(_:)), keyEquivalent: "")
                    unpin.target = self
                    unpin.representedObject = container.id
                    if let img = NSImage(systemSymbolName: "pin", accessibilityDescription: "Unpin") { unpin.image = img }
                    submenu.addItem(unpin)

                    let label = "\(container.status.icon) \(container.displayLabel)"
                    let containerItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                    containerItem.submenu = submenu
                    menu.addItem(containerItem)
                }
            }

            let totalCount = dockerManager.containers.count
            let totalRunning = dockerManager.containers.filter { $0.status == .running }.count
            let allTitle: String
            if totalRunning > 0 {
                allTitle = "All Containers... (\(totalRunning) of \(totalCount) running)"
            } else {
                allTitle = "All Containers... (\(totalCount))"
            }
            let allContainers = NSMenuItem(title: allTitle, action: #selector(showAllContainers), keyEquivalent: "")
            allContainers.target = self
            menu.addItem(allContainers)
        }

        menu.addItem(NSMenuItem.separator())

        // Refresh
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshStatus), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        // Set User
        let userLabel = colimaManager.configuredUser.map { "Change User (\($0))" } ?? "Change User"
        let setUserItem = NSMenuItem(title: userLabel, action: #selector(setColimaUser), keyEquivalent: "")
        setUserItem.target = self
        menu.addItem(setUserItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    // MARK: - Colima Actions

    @objc private func setColimaUser() {
        let alert = NSAlert()
        alert.messageText = "Change Colima User"
        alert.informativeText = "Enter the username whose colima.yaml configuration should be used (leave blank for current user):"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = colimaManager.configuredUser ?? ""
        textField.placeholderString = ProcessInfo.processInfo.userName
        alert.accessoryView = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let user = textField.stringValue.trimmingCharacters(in: .whitespaces)
            if let error = colimaManager.setColimaUser(user.isEmpty ? nil : user) {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Invalid User"
                errorAlert.informativeText = error
                errorAlert.alertStyle = .warning
                errorAlert.addButton(withTitle: "OK")
                errorAlert.runModal()
            } else {
                dockerManager.updateConfiguredUser(user.isEmpty ? nil : user)
            }
        }
    }

    @objc private func startInstance(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        colimaManager.start(profile: profile)
    }

    @objc private func stopInstance(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        colimaManager.stop(profile: profile)
    }

    @objc private func refreshStatus() {
        colimaManager.refreshStatus()
        dockerManager.refresh()
    }

    @objc private func runDockerDiagnostics() {
        let (title, message) = dockerManager.runDiagnostics()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Docker Actions

    @objc private func dockerStartContainer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        dockerManager.startContainer(id)
    }

    @objc private func dockerCopyContainerId(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

    @objc private func dockerStopContainer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        dockerManager.stopContainer(id)
    }

    @objc private func dockerPauseContainer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        dockerManager.pauseContainer(id)
    }

    @objc private func dockerUnpauseContainer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        dockerManager.unpauseContainer(id)
    }

    @objc private func dockerUnpinContainer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        dockerManager.unpin(id)
    }

    @objc private func showAllContainers() {
        ContainerWindowController.shared.show(dockerManager: dockerManager)
    }

    @objc private func quitApp() {
        ContainerWindowController.shared.cleanup()
        // Close all remaining windows so terminate isn't blocked
        for w in NSApp.windows {
            w.close()
        }
        NSApplication.shared.terminate(nil)
    }
}
