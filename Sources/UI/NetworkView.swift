import AppKit

@MainActor
final class NetworkView: ThemedView {
    var onConnect: ((String) -> Void)?
    var onOpen: ((String) -> Void)?
    var onRefresh: (() -> Void)?

    private let scroll = makeScroller()
    private let content = FlippedView()
    private let titleLabel = makeLabel("Network", size: 15, weight: .semibold)
    private let noteLabel = makeLabel("Mounted shares and SMB servers visible on your local network.", size: 12, color: Theme.textSecondary)
    private let refreshButton = IconButton(image: "arrow.clockwise", accessibility: "Refresh network")
    private let addressField = SurfaceTextField(placeholder: "smb://server/share")
    private let connectButton = HoverButton(title: "Connect")
    private let hintLabel = makeLabel(
        "Connections and credentials are handled by Finder. After mounting, refresh to browse the share here.",
        size: 11.5,
        color: Theme.textSecondary,
        lines: 2
    )
    private let noticeLabel = makeLabel("", size: 12, color: Theme.accent)
    private let mountedTitle = makeLabel("Mounted shares", size: 13, weight: .semibold)
    private let serversTitle = makeLabel("Discovered servers", size: 13, weight: .semibold)
    private let mountedCard = ThemedView()
    private let serversCard = ThemedView()
    private let spinner = NSProgressIndicator()
    private var mountedRows: [NetworkRowView] = []
    private var serverRows: [NetworkRowView] = []
    private var noticeText: String?
    private var loading = false
    private var state: NetworkState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.content
        scroll.documentView = content
        addSubview(scroll)
        content.addSubview(titleLabel)
        content.addSubview(noteLabel)
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)
        content.addSubview(refreshButton)

        let form = ThemedView()
        form.fillColor = Theme.field
        form.strokeColor = Theme.controlBorder
        form.borderWidth = 1
        form.cornerRadius = 4
        content.addSubview(form)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        form.addSubview(addressField)
        NSLayoutConstraint.activate([
            addressField.leadingAnchor.constraint(equalTo: form.leadingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: form.trailingAnchor, constant: -8),
            addressField.centerYAnchor.constraint(equalTo: form.centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: 18),
        ])
        self.form = form

        connectButton.font = NSFont.systemFont(ofSize: 12)
        connectButton.isBordered = true
        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .small
        connectButton.hoverColor = nil
        connectButton.target = self
        connectButton.action = #selector(connectPressed)
        content.addSubview(connectButton)

        content.addSubview(hintLabel)
        content.addSubview(noticeLabel)
        content.addSubview(mountedTitle)
        mountedCard.fillColor = Theme.surface
        mountedCard.strokeColor = Theme.hairline
        mountedCard.borderWidth = 1
        mountedCard.cornerRadius = 8
        content.addSubview(mountedCard)
        content.addSubview(serversTitle)
        serversCard.fillColor = Theme.surface
        serversCard.strokeColor = Theme.hairline
        serversCard.borderWidth = 1
        serversCard.cornerRadius = 8
        content.addSubview(serversCard)

        spinner.style = .spinning
        spinner.controlSize = .small
        content.addSubview(spinner)
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(connectPressed)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var form: ThemedView?

    func update(state: NetworkState, loading: Bool, notice: String?) {
        self.state = state
        self.loading = loading
        self.noticeText = notice
        rebuild()
        needsLayout = true
    }

    private func rebuild() {
        mountedRows.forEach { $0.removeFromSuperview() }
        serverRows.forEach { $0.removeFromSuperview() }
        mountedRows = []
        serverRows = []
        for card in [mountedCard, serversCard] {
            for tag in [8101, 8102, 8103] {
                card.viewWithTag(tag)?.removeFromSuperview()
            }
        }

        noticeLabel.stringValue = noticeText ?? ""
        noticeLabel.isHidden = noticeText == nil
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        connectButton.isEnabled = !loading

        for share in state?.mounted ?? [] {
            let row = NetworkRowView(
                icon: "internaldrive",
                title: share.name,
                subtitle: "\(share.path) · \(share.fsType)",
                actionTitle: "Open"
            ) { [weak self] in
                self?.onOpen?(share.path)
            }
            mountedCard.addSubview(row)
            mountedRows.append(row)
        }
        for server in state?.servers ?? [] {
            let port = server.port.map { $0 != 445 ? ":\($0)" : "" } ?? ""
            let row = NetworkRowView(
                icon: "network",
                title: server.name,
                subtitle: "\(server.host)\(port)",
                actionTitle: "Connect"
            ) { [weak self] in
                self?.onConnect?("smb://\(server.host)\(port)")
            }
            serversCard.addSubview(row)
            serverRows.append(row)
        }
        if (state?.mounted ?? []).isEmpty {
            let label = makeLabel("No network shares are mounted.", size: 12.5, color: Theme.textSecondary)
            label.tag = 8101
            mountedCard.addSubview(label)
        }
        if let error = state?.error {
            let label = makeLabel("Discovery failed: \(error)", size: 12.5, color: Theme.textSecondary)
            label.tag = 8102
            serversCard.addSubview(label)
        } else if (state?.servers ?? []).isEmpty {
            let label = makeLabel("No SMB servers were discovered. You can still connect by address.", size: 12.5, color: Theme.textSecondary)
            label.tag = 8103
            serversCard.addSubview(label)
        }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutContent()
    }

    private func layoutContent() {
        let width = max(600, scroll.contentSize.width)
        let padding: CGFloat = 28
        let usable = width - padding * 2
        var y: CGFloat = 22
        titleLabel.frame = NSRect(x: padding, y: y, width: 220, height: 20)
        refreshButton.frame = NSRect(x: width - padding - 32, y: y - 6, width: 32, height: 32)
        y += 24
        noteLabel.frame = NSRect(x: padding, y: y, width: usable - 40, height: 16)
        y += 28

        form?.frame = NSRect(x: padding, y: y, width: max(220, usable - 100), height: 32)
        connectButton.frame = NSRect(x: padding + max(220, usable - 100) + 8, y: y + 2, width: 84, height: 28)
        y += 38
        hintLabel.frame = NSRect(x: padding, y: y, width: usable, height: 18)
        y += 24
        if !noticeLabel.isHidden {
            noticeLabel.frame = NSRect(x: padding, y: y, width: usable, height: 18)
            y += 24
        }
        if !spinner.isHidden {
            spinner.frame = NSRect(x: padding, y: y + 4, width: 16, height: 16)
            y += 28
        }

        mountedTitle.frame = NSRect(x: padding, y: y, width: usable, height: 18)
        y += 26
        let mountedHeight = max(52, CGFloat(mountedRows.count) * 52 + (mountedRows.isEmpty ? 44 : 10))
        mountedCard.frame = NSRect(x: padding, y: y, width: usable, height: mountedHeight)
        for (index, row) in mountedRows.enumerated() {
            row.frame = NSRect(x: 6, y: 5 + CGFloat(index) * 52, width: usable - 12, height: 48)
        }
        if let empty = mountedCard.viewWithTag(8101) {
            empty.frame = NSRect(x: 14, y: (mountedHeight - 16) / 2, width: usable - 28, height: 16)
        }
        y += mountedHeight + 20

        serversTitle.frame = NSRect(x: padding, y: y, width: usable, height: 18)
        y += 26
        let serverHeight = max(52, CGFloat(serverRows.count) * 52 + (serverRows.isEmpty ? 44 : 10))
        serversCard.frame = NSRect(x: padding, y: y, width: usable, height: serverHeight)
        for (index, row) in serverRows.enumerated() {
            row.frame = NSRect(x: 6, y: 5 + CGFloat(index) * 52, width: usable - 12, height: 48)
        }
        for tag in [8102, 8103] {
            if let label = serversCard.viewWithTag(tag) {
                label.frame = NSRect(x: 14, y: (serverHeight - 16) / 2, width: usable - 28, height: 16)
            }
        }
        y += serverHeight + 30
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, y))
    }

    @objc private func refreshPressed() { onRefresh?() }

    @objc private func connectPressed() {
        let value = addressField.stringValue
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onConnect?(value)
    }
}

extension NetworkView: NSTextFieldDelegate {}

@MainActor
private final class NetworkRowView: ThemedView {
    private let icon = NSImageView()
    private let titleLabel = makeLabel("", size: 13)
    private let subLabel = makeLabel("", size: 11.5, color: Theme.textSecondary)
    private let actionButton = HoverButton(title: "")
    private let closure: () -> Void

    init(icon: String, title: String, subtitle: String, actionTitle: String, action: @escaping () -> Void) {
        self.closure = action
        super.init(frame: .zero)
        self.icon.image = Icons.symbol(icon, size: 20)
        self.icon.contentTintColor = Theme.textSecondary
        self.icon.imageScaling = .scaleProportionallyDown
        titleLabel.stringValue = title
        subLabel.stringValue = subtitle
        actionButton.title = actionTitle
        actionButton.font = NSFont.systemFont(ofSize: 12)
        actionButton.isBordered = true
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.hoverColor = nil
        actionButton.target = self
        actionButton.action = #selector(actionPressed)
        [self.icon, titleLabel, subLabel, actionButton].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: (bounds.height - 20) / 2, width: 20, height: 20)
        actionButton.frame = NSRect(x: bounds.width - 80, y: (bounds.height - 24) / 2, width: 70, height: 24)
        titleLabel.frame = NSRect(x: 40, y: 10, width: max(0, bounds.width - 130), height: 16)
        subLabel.frame = NSRect(x: 40, y: 26, width: max(0, bounds.width - 130), height: 14)
    }

    @objc private func actionPressed() {
        closure()
    }
}
