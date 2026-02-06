import AppKit
import Combine

/// Custom header cell that skips drawing vertical separator lines
class DarkHeaderCell: NSTableHeaderCell {
    var centerAligned = false

    /// Determine sort state by inspecting the owning table view's sort descriptors
    private func sortAscending(in controlView: NSView) -> Bool? {
        guard let headerView = controlView as? NSTableHeaderView,
              let tableView = headerView.tableView else { return nil }
        // Find which column this cell belongs to
        guard let col = tableView.tableColumns.first(where: { $0.headerCell === self }),
              let proto = col.sortDescriptorPrototype,
              let activeDesc = tableView.sortDescriptors.first,
              activeDesc.key == proto.key else { return nil }
        return activeDesc.ascending
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Fill black background
        NSColor.black.setFill()
        cellFrame.fill()

        let ascending = sortAscending(in: controlView)

        // Reserve space for sort indicator if active
        let sortIndicatorWidth: CGFloat = (ascending != nil) ? 14 : 0
        let textWidth = cellFrame.width - 8 - sortIndicatorWidth

        // Draw text vertically centered
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = centerAligned ? .center : .left
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: font,
            .paragraphStyle: paragraphStyle,
        ]
        let textHeight = (attributedStringValue.string as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin,
            attributes: attrs
        ).height
        let yOffset = max(0, (cellFrame.height - textHeight) / 2)
        let textRect = NSRect(x: cellFrame.origin.x + 4, y: cellFrame.origin.y + yOffset,
                              width: textWidth, height: textHeight)
        attributedStringValue.string.draw(in: textRect, withAttributes: attrs)

        // Draw sort indicator
        if let asc = ascending {
            let arrowText = asc ? "▲" : "▼"
            let arrowAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white.withAlphaComponent(0.8),
                .font: NSFont.systemFont(ofSize: 7, weight: .medium),
            ]
            let size = (arrowText as NSString).size(withAttributes: arrowAttrs)
            let x = cellFrame.maxX - size.width - 4
            let y = cellFrame.origin.y + (cellFrame.height - size.height) / 2
            (arrowText as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: arrowAttrs)
        }
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {
        // No-op: we draw the indicator ourselves in draw() to avoid it being painted over
    }
}

@MainActor
final class ContainerWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = ContainerWindowController()

    private var window: NSWindow?
    private var dockerManager: DockerManager?
    private var cancellables = Set<AnyCancellable>()

    private var tableView: NSTableView!
    private var bottomPanel: NSView!
    private var bottomScrollView: NSScrollView!
    private var bottomTextView: NSTextView!
    private var bottomTitleField: NSTextField!
    private var bottomSplitPosition: NSLayoutConstraint!
    private var logProcess: Process?
    private var logContainerId: String?
    private enum BottomMode { case none, ports(String), logs(String), inspect(String) }
    private var bottomMode: BottomMode = .none

    private var bottomViewerButton: NSButton!
    private var logScrollFraction: CGFloat = 1.0
    private var logScrollObserver: NSObjectProtocol?

    private var containers: [DockerContainer] = []
    private var sortedContainers: [DockerContainer] = []
    private var windowHeightBeforePanel: CGFloat?
    /// Container IDs that have a pending action (transitioning)
    private var pendingActions: Set<String> = []
    private var sortDescriptors: [NSSortDescriptor] = [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))]

    private let rowHeight: CGFloat = 28

    func show(dockerManager: DockerManager) {
        self.dockerManager = dockerManager

        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        setupWindow()
        subscribeToUpdates()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cleanup() {
        closeBottomPanel()
        window?.close()
        cancellables.removeAll()
        window = nil
    }

    // MARK: - Window Setup

    private func setupWindow() {
        let windowWidth: CGFloat = 1020
        let windowHeight: CGFloat = 436
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "All Containers"
        w.center()
        w.delegate = self
        w.minSize = NSSize(width: windowWidth, height: 400)
        w.maxSize = NSSize(width: windowWidth, height: CGFloat.greatestFiniteMagnitude)
        w.isReleasedWhenClosed = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = contentView

        // Table view (no toolbar/refresh button — polling handles updates)
        tableView = NSTableView()
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = rowHeight

        // Swapped: Ports before Running
        let columns: [(id: String, title: String, width: CGFloat, sortKey: String?)] = [
            ("name", "   Name", 245, "name"),
            ("image", "Image", 240, "image"),
            ("ports", "Ports", 124, "ports"),
            ("status", "Running", 140, "status"),
            ("startstop", "Start/Stop", 95, nil),
            ("more", "More", 116, nil),
            ("pin", "Pin", 60, nil),
        ]

        let centeredHeaders: Set<String> = ["startstop", "more", "pin"]
        for c in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.width = c.width
            col.resizingMask = []

            // Use custom header cell to avoid separator lines
            let headerCell = DarkHeaderCell()
            headerCell.stringValue = c.title
            headerCell.centerAligned = centeredHeaders.contains(c.id)
            col.headerCell = headerCell

            if let key = c.sortKey {
                col.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
            }
            tableView.addTableColumn(col)
        }

        // Hide column separators (grid lines) but keep columns
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: tableView.intercellSpacing.height)
        // Disable row selection highlighting
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true

        tableView.dataSource = self
        tableView.delegate = self

        // Dark header background
        if let headerView = tableView.headerView {
            headerView.wantsLayer = true
            headerView.layer?.backgroundColor = NSColor.black.cgColor
        }

        let tableScrollView = NSScrollView()
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        contentView.addSubview(tableScrollView)

        // Bottom panel (shared for ports and logs)
        bottomPanel = NSView()
        bottomPanel.translatesAutoresizingMaskIntoConstraints = false
        bottomPanel.isHidden = true
        contentView.addSubview(bottomPanel)

        let bottomTitleBar = NSView()
        bottomTitleBar.translatesAutoresizingMaskIntoConstraints = false
        bottomTitleBar.wantsLayer = true
        bottomTitleBar.layer?.backgroundColor = NSColor.black.cgColor
        bottomPanel.addSubview(bottomTitleBar)

        bottomTitleField = NSTextField(labelWithString: "")
        bottomTitleField.translatesAutoresizingMaskIntoConstraints = false
        bottomTitleField.font = .boldSystemFont(ofSize: 12)
        bottomTitleField.textColor = .white
        bottomTitleBar.addSubview(bottomTitleField)

        // Viewer button (for logs panel)
        bottomViewerButton = NSButton(frame: .zero)
        bottomViewerButton.translatesAutoresizingMaskIntoConstraints = false
        bottomViewerButton.bezelStyle = .regularSquare
        bottomViewerButton.isBordered = false
        bottomViewerButton.target = self
        bottomViewerButton.action = #selector(openInViewer)
        bottomViewerButton.toolTip = "Open in terminal viewer"
        bottomViewerButton.isHidden = true
        if let img = NSImage(systemSymbolName: "text.justifyleft", accessibilityDescription: "Open in viewer") {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            bottomViewerButton.image = img.withSymbolConfiguration(config)
        }
        bottomViewerButton.imagePosition = .imageOnly
        bottomViewerButton.contentTintColor = .white
        bottomTitleBar.addSubview(bottomViewerButton)

        let closeButton = NSButton(title: "✕", target: self, action: #selector(closeBottomPanel))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .rounded
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        bottomTitleBar.addSubview(closeButton)

        // Build NSTextView properly via NSScrollView's factory
        bottomScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: 250))
        bottomScrollView.translatesAutoresizingMaskIntoConstraints = false
        bottomScrollView.hasVerticalScroller = true
        bottomScrollView.hasHorizontalScroller = false

        let contentSize = bottomScrollView.contentSize
        bottomTextView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        bottomTextView.minSize = NSSize(width: 0, height: 0)
        bottomTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        bottomTextView.isVerticallyResizable = true
        bottomTextView.isHorizontallyResizable = false
        bottomTextView.autoresizingMask = [.width]
        bottomTextView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        bottomTextView.textContainer?.widthTracksTextView = true
        bottomTextView.textContainer?.lineBreakMode = .byCharWrapping
        bottomTextView.isEditable = false
        bottomTextView.isSelectable = true
        bottomTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        bottomTextView.backgroundColor = .textBackgroundColor

        bottomScrollView.documentView = bottomTextView
        bottomPanel.addSubview(bottomScrollView)

        bottomSplitPosition = bottomPanel.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            // Table directly at top
            tableScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tableScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor),

            bottomPanel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomPanel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomPanel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bottomSplitPosition,

            bottomTitleBar.topAnchor.constraint(equalTo: bottomPanel.topAnchor),
            bottomTitleBar.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor),
            bottomTitleBar.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor),
            bottomTitleBar.heightAnchor.constraint(equalToConstant: 28),
            bottomTitleField.centerYAnchor.constraint(equalTo: bottomTitleBar.centerYAnchor),
            bottomTitleField.leadingAnchor.constraint(equalTo: bottomTitleBar.leadingAnchor, constant: 12),
            bottomViewerButton.centerYAnchor.constraint(equalTo: bottomTitleBar.centerYAnchor),
            bottomViewerButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            bottomViewerButton.widthAnchor.constraint(equalToConstant: 20),
            bottomViewerButton.heightAnchor.constraint(equalToConstant: 20),
            closeButton.centerYAnchor.constraint(equalTo: bottomTitleBar.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: bottomTitleBar.trailingAnchor, constant: -8),

            bottomScrollView.topAnchor.constraint(equalTo: bottomTitleBar.bottomAnchor),
            bottomScrollView.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor),
            bottomScrollView.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor),
            bottomScrollView.bottomAnchor.constraint(equalTo: bottomPanel.bottomAnchor),
        ])

        self.window = w
    }

    private func subscribeToUpdates() {
        dockerManager?.$containers
            .receive(on: RunLoop.main)
            .sink { [weak self] containers in
                guard let self else { return }
                // Clear pending actions for containers whose status actually changed
                let previousById = Dictionary(uniqueKeysWithValues: self.containers.map { ($0.id, $0) })
                for c in containers {
                    if let prev = previousById[c.id], prev.status != c.status {
                        self.pendingActions.remove(c.id)
                    }
                }
                self.containers = containers
                self.resortAndReload()
            }
            .store(in: &cancellables)
    }

    // MARK: - NSTableView DataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        sortedContainers.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colId = tableColumn?.identifier, row < sortedContainers.count else { return nil }
        let container = sortedContainers[row]
        let isInactive = container.status != .running
        let isPending = pendingActions.contains(container.id)

        switch colId.rawValue {
        case "name":
            let icon = isPending ? "◐" : container.status.icon
            return makeCenteredLabel("\(icon) \(container.name)", dimmed: isInactive)
        case "image":
            return makeCenteredLabel(container.image, dimmed: isInactive)
        case "status":
            let text = isPending ? "..." : container.shortStatus
            return makeCenteredLabel(text, dimmed: isInactive)
        case "ports":
            return makePortsCell(for: container, dimmed: isInactive)
        case "startstop":
            return makeCenteredView(makeStartStopButtons(for: container))
        case "more":
            return makeCenteredView(makeMoreButtons(for: container))
        case "pin":
            return makeCenteredView(makePinButton(for: container))
        default:
            return nil
        }
    }

    /// Label vertically centered in the row
    private func makeCenteredLabel(_ text: String, dimmed: Bool = false) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 12)
        if dimmed { field.textColor = .secondaryLabelColor }
        field.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
        ])
        return wrapper
    }

    private func makeCenteredView(_ inner: NSView) -> NSView {
        let wrapper = NSView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            inner.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
        ])
        return wrapper
    }

    // MARK: - Ports Cell

    private func makePortsCell(for container: DockerContainer, dimmed: Bool) -> NSView {
        let parsed = DockerContainer.parsePorts(container.ports)
        if parsed.isEmpty {
            return makeCenteredLabel("—", dimmed: dimmed)
        }

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let portLabel = NSTextField(labelWithString: parsed[0])
        portLabel.font = .systemFont(ofSize: 12)
        portLabel.lineBreakMode = .byTruncatingTail
        if dimmed { portLabel.textColor = .secondaryLabelColor }
        stack.addArrangedSubview(portLabel)

        let ellipsis = NSButton(title: "...", target: self, action: #selector(showPortsClicked(_:)))
        ellipsis.bezelStyle = .inline
        ellipsis.font = .systemFont(ofSize: 10)
        ellipsis.tag = sortedContainers.firstIndex(where: { $0.id == container.id }) ?? 0
        ellipsis.toolTip = "Show port details"
        stack.addArrangedSubview(ellipsis)

        let wrapper = NSView()
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 2),
            stack.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
        ])
        return wrapper
    }

    // MARK: - SF Symbol Buttons

    private func makeSFSymbolButton(symbolName: String, tooltip: String, tag: Int, action: Selector) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.target = self
        btn.action = action
        btn.toolTip = tooltip
        btn.tag = tag
        btn.setContentHuggingPriority(.required, for: .horizontal)

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            btn.image = image.withSymbolConfiguration(config)
        }
        btn.imagePosition = .imageOnly
        btn.showsBorderOnlyWhileMouseInside = false
        (btn.cell as? NSButtonCell)?.highlightsBy = []

        btn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 24).isActive = true

        return btn
    }

    private func tagFor(_ container: DockerContainer) -> Int {
        sortedContainers.firstIndex(where: { $0.id == container.id }) ?? 0
    }

    private func makeStartStopButtons(for container: DockerContainer) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        let t = tagFor(container)

        if pendingActions.contains(container.id) {
            // Show a "..." indicator while action is pending
            let pending = NSTextField(labelWithString: "...")
            pending.font = .boldSystemFont(ofSize: 14)
            pending.textColor = .secondaryLabelColor
            stack.addArrangedSubview(pending)
            return stack
        }

        switch container.status {
        case .running:
            stack.addArrangedSubview(makeSFSymbolButton(symbolName: "pause.fill", tooltip: "Pause", tag: t, action: #selector(pauseClicked(_:))))
            stack.addArrangedSubview(makeSFSymbolButton(symbolName: "stop.fill", tooltip: "Stop", tag: t, action: #selector(stopClicked(_:))))
        case .paused:
            stack.addArrangedSubview(makeSFSymbolButton(symbolName: "play.fill", tooltip: "Unpause", tag: t, action: #selector(unpauseClicked(_:))))
            stack.addArrangedSubview(makeSFSymbolButton(symbolName: "stop.fill", tooltip: "Stop", tag: t, action: #selector(stopClicked(_:))))
        case .exited, .created, .other:
            stack.addArrangedSubview(makeSFSymbolButton(symbolName: "play.fill", tooltip: "Start", tag: t, action: #selector(startClicked(_:))))
        }

        return stack
    }

    private func makeMoreButtons(for container: DockerContainer) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        let t = tagFor(container)

        stack.addArrangedSubview(makeSFSymbolButton(symbolName: "grid.circle", tooltip: "Copy ID", tag: t, action: #selector(copyIdClicked(_:))))
        stack.addArrangedSubview(makeSFSymbolButton(symbolName: "doc.plaintext", tooltip: "Inspect", tag: t, action: #selector(inspectClicked(_:))))

        if container.status == .running {
            stack.addArrangedSubview(makeSFSymbolButton(symbolName: "text.justifyleft", tooltip: "Logs", tag: t, action: #selector(logsClicked(_:))))
            stack.addArrangedSubview(makeSFSymbolButton(symbolName: "macwindow", tooltip: "Shell", tag: t, action: #selector(shellClicked(_:))))
        } else if container.status == .paused {
            stack.addArrangedSubview(makeSFSymbolButton(symbolName: "text.justifyleft", tooltip: "Logs", tag: t, action: #selector(logsClicked(_:))))
        }

        return stack
    }

    private func makePinButton(for container: DockerContainer) -> NSView {
        let pinned = dockerManager?.isPinned(container.id) ?? false
        return makeSFSymbolButton(
            symbolName: pinned ? "pin.fill" : "pin",
            tooltip: pinned ? "Unpin" : "Pin",
            tag: tagFor(container),
            action: #selector(pinClicked(_:))
        )
    }

    // MARK: - Actions

    @objc private func startClicked(_ sender: NSButton) {
        guard sender.tag < sortedContainers.count else { return }
        let id = sortedContainers[sender.tag].id
        pendingActions.insert(id)
        tableView.reloadData()
        dockerManager?.startContainer(id)
    }

    @objc private func stopClicked(_ sender: NSButton) {
        guard sender.tag < sortedContainers.count else { return }
        let id = sortedContainers[sender.tag].id
        pendingActions.insert(id)
        tableView.reloadData()
        dockerManager?.stopContainer(id)
    }

    @objc private func pauseClicked(_ sender: NSButton) {
        guard sender.tag < sortedContainers.count else { return }
        let id = sortedContainers[sender.tag].id
        pendingActions.insert(id)
        tableView.reloadData()
        dockerManager?.pauseContainer(id)
    }

    @objc private func unpauseClicked(_ sender: NSButton) {
        guard sender.tag < sortedContainers.count else { return }
        let id = sortedContainers[sender.tag].id
        pendingActions.insert(id)
        tableView.reloadData()
        dockerManager?.unpauseContainer(id)
    }

    @objc private func logsClicked(_ sender: NSButton) {
        guard sender.tag < sortedContainers.count else { return }
        showLogs(for: sortedContainers[sender.tag])
    }

    @objc private func shellClicked(_ sender: NSButton) {
        guard sender.tag < sortedContainers.count else { return }
        dockerManager?.openShell(sortedContainers[sender.tag].id)
    }

    @objc private func copyIdClicked(_ sender: NSButton) {
        guard sender.tag < sortedContainers.count else { return }
        let container = sortedContainers[sender.tag]
        let row = sender.tag
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(container.id, forType: .string)

        // Flash: show ID in the name column for 1 second
        let nameColIndex = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard nameColIndex >= 0, let cellView = tableView.view(atColumn: nameColIndex, row: row, makeIfNecessary: false) else { return }
        // Find the NSTextField inside the wrapper
        if let label = cellView.subviews.compactMap({ $0 as? NSTextField }).first {
            let originalText = label.stringValue
            let icon = container.status.icon
            label.stringValue = "\(icon) \(container.id)"
            label.textColor = .systemYellow
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak label] in
                label?.stringValue = originalText
                label?.textColor = container.status == .running ? .labelColor : .secondaryLabelColor
            }
        }
    }

    @objc private func inspectClicked(_ sender: NSButton) {
        guard sender.tag < sortedContainers.count else { return }
        let container = sortedContainers[sender.tag]

        // Toggle off if already showing inspect for this container
        if case .inspect(let id) = bottomMode, id == container.id {
            closeBottomPanel()
            return
        }

        Task {
            guard let output = await dockerManager?.inspectContainer(container.id) else { return }
            logProcess?.terminate()
            logProcess = nil
            removeScrollObserver()

            bottomMode = .inspect(container.id)
            bottomTitleField.stringValue = "Inspect: \(container.name) - \(container.shortId)"
            bottomTextView.string = output
            bottomViewerButton.isHidden = true
            showBottomPanel(height: 300)
        }
    }

    @objc private func pinClicked(_ sender: NSButton) {
        guard sender.tag < sortedContainers.count else { return }
        let container = sortedContainers[sender.tag]
        if dockerManager?.isPinned(container.id) == true {
            dockerManager?.unpin(container.id)
        } else {
            dockerManager?.pin(container.id)
        }
        tableView.reloadData()
    }

    @objc private func openInViewer() {
        guard case .logs(let containerId) = bottomMode else { return }
        let cmd = dockerManager?.dockerTerminalCommand("logs -f --tail 1000 \(containerId)") ?? "docker logs -f --tail 1000 \(containerId)"
        openTerminalWithCommand(cmd)
    }

    @objc private func showPortsClicked(_ sender: NSButton) {
        guard sender.tag < sortedContainers.count else { return }
        let container = sortedContainers[sender.tag]

        if case .ports(let id) = bottomMode, id == container.id {
            closeBottomPanel()
            return
        }

        logProcess?.terminate()
        logProcess = nil
        removeScrollObserver()

        bottomMode = .ports(container.id)
        bottomViewerButton.isHidden = true
        bottomTitleField.stringValue = "Ports of \(container.name):"
        bottomTextView.string = "  \(container.ports)"
        showBottomPanel(height: 80)
    }

    @objc private func closeBottomPanel() {
        logProcess?.terminate()
        logProcess = nil
        removeScrollObserver()
        logContainerId = nil
        bottomMode = .none
        bottomViewerButton?.isHidden = true
        bottomPanel?.isHidden = true
        bottomSplitPosition?.constant = 0
        bottomTextView?.string = ""

        if let savedHeight = windowHeightBeforePanel, let w = window {
            var frame = w.frame
            frame.origin.y += (frame.height - savedHeight)
            frame.size.height = savedHeight
            w.setFrame(frame, display: true, animate: true)
        }
        windowHeightBeforePanel = nil
    }

    // MARK: - Bottom Panel Helpers

    private func showBottomPanel(height: CGFloat) {
        bottomPanel.isHidden = false
        bottomSplitPosition.constant = height

        if let w = window {
            if windowHeightBeforePanel == nil {
                windowHeightBeforePanel = w.frame.height
            }
            let screenHeight = w.screen?.visibleFrame.height ?? 800
            let maxHeight = screenHeight * 0.85
            let targetHeight = (windowHeightBeforePanel ?? w.frame.height) + height
            var frame = w.frame
            let newHeight = min(maxHeight, targetHeight)
            frame.origin.y -= (newHeight - frame.height)
            frame.size.height = newHeight
            w.setFrame(frame, display: true, animate: true)
        }
    }

    // MARK: - Log Panel

    private func showLogs(for container: DockerContainer) {
        if case .logs(let id) = bottomMode, id == container.id {
            closeBottomPanel()
            return
        }

        logProcess?.terminate()
        logProcess = nil
        removeScrollObserver()

        logContainerId = container.id
        bottomMode = .logs(container.id)
        bottomTitleField.stringValue = "Logs: \(container.name) - \(container.shortId)"
        bottomTextView.string = ""
        logScrollFraction = 1.0
        bottomViewerButton.isHidden = false
        showBottomPanel(height: 250)

        if let clipView = bottomScrollView?.contentView {
            logScrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    self?.updateScrollFraction()
                }
            }
            clipView.postsBoundsChangedNotifications = true
        }

        logProcess = dockerManager?.streamLogs(for: container.id) { [weak self] text in
            guard let self else { return }
            let wasObserving = self.logScrollObserver != nil
            if wasObserving { self.removeScrollObserver() }

            let savedFraction = self.logScrollFraction

            self.bottomTextView.textStorage?.append(NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.textColor,
                ]
            ))

            self.scrollToFraction(savedFraction)

            if wasObserving, let clipView = self.bottomScrollView?.contentView {
                self.logScrollObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        self?.updateScrollFraction()
                    }
                }
            }
        }
    }

    private func updateScrollFraction() {
        guard let scrollView = bottomTextView.enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let docHeight = bottomTextView.frame.height
        let clipHeight = clipView.bounds.height
        let maxScroll = docHeight - clipHeight
        if maxScroll <= 0 {
            logScrollFraction = 1.0
        } else {
            logScrollFraction = clipView.bounds.origin.y / maxScroll
        }
    }

    private func scrollToFraction(_ fraction: CGFloat) {
        guard let scrollView = bottomTextView.enclosingScrollView else { return }
        // Force layout so document height is up to date
        bottomTextView.layoutManager?.ensureLayout(for: bottomTextView.textContainer!)
        let clipView = scrollView.contentView
        let docHeight = bottomTextView.frame.height
        let clipHeight = clipView.bounds.height
        let maxScroll = docHeight - clipHeight
        if maxScroll <= 0 { return }
        let targetY = max(0, min(maxScroll, fraction * maxScroll))
        clipView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func removeScrollObserver() {
        if let obs = logScrollObserver {
            NotificationCenter.default.removeObserver(obs)
            logScrollObserver = nil
        }
    }

    // MARK: - Sorting

    private func resortAndReload() {
        sortedContainers = applySortDescriptors(containers)
        tableView?.reloadData()
        window?.title = "All Containers (\(containers.count))"
    }

    private func applySortDescriptors(_ list: [DockerContainer]) -> [DockerContainer] {
        guard let desc = sortDescriptors.first else {
            return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return list.sorted { a, b in
            let cmp: ComparisonResult
            switch desc.key {
            case "name": cmp = a.name.localizedCaseInsensitiveCompare(b.name)
            case "image": cmp = a.image.localizedCaseInsensitiveCompare(b.image)
            case "ports":
                let aPort = DockerContainer.parsePorts(a.ports).first.flatMap { Int($0.components(separatedBy: "->").first ?? "") } ?? Int.max
                let bPort = DockerContainer.parsePorts(b.ports).first.flatMap { Int($0.components(separatedBy: "->").first ?? "") } ?? Int.max
                if aPort == bPort { cmp = .orderedSame }
                else { cmp = aPort < bPort ? .orderedAscending : .orderedDescending }
            case "status":
                let aS = a.sortableSeconds, bS = b.sortableSeconds
                if aS == bS { cmp = .orderedSame }
                else { cmp = aS < bS ? .orderedAscending : .orderedDescending }
            default: cmp = a.name.localizedCaseInsensitiveCompare(b.name)
            }
            return desc.ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortDescriptors = tableView.sortDescriptors
        resortAndReload()
        tableView.headerView?.needsDisplay = true
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        closeBottomPanel()
        cancellables.removeAll()
        window = nil
    }
}
