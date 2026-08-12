import AppKit

@MainActor
final class UsageViewController: NSViewController {
    static let width: CGFloat = 360

    var onContentSizeChange: ((NSSize) -> Void)?

    private let store: AppStore
    private let statusManager: StatusManager
    private let settings: Settings
    private let maximumHeight: CGFloat
    private let onRefresh: () -> Void

    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let contentStack = VerticalStackView(spacing: 16)
    private var showingSettings = false
    private var showingStatusDetails = false
    private var reloadScheduled = false

    init(
        store: AppStore,
        statusManager: StatusManager,
        settings: Settings,
        maximumHeight: CGFloat,
        onRefresh: @escaping () -> Void
    ) {
        self.store = store
        self.statusManager = statusManager
        self.settings = settings
        self.maximumHeight = min(600, maximumHeight)
        self.onRefresh = onRefresh
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 260))

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        documentView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(
                equalTo: documentView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(
                equalTo: documentView.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -16),
        ])
    }

    func reload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.rebuildContent()
        }
    }

    func prepare() {
        loadViewIfNeeded()
        rebuildContent()
    }

    private func rebuildContent() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        contentStack.addArrangedSubview(label("Agent Usage", style: .headline))

        if store.visibleProviders.isEmpty {
            contentStack.addArrangedSubview(signInPrompt())
        } else {
            for provider in store.visibleProviders {
                contentStack.addArrangedSubview(providerSection(provider))
            }
        }

        if statusManager.hasFetched {
            contentStack.addArrangedSubview(separator())
            contentStack.addArrangedSubview(statusSection())
        }

        contentStack.addArrangedSubview(separator())
        contentStack.addArrangedSubview(footer())
        contentStack.addArrangedSubview(settingsSection())

        view.layoutSubtreeIfNeeded()
        let contentHeight = contentStack.fittingSize.height + 32
        let height = min(max(contentHeight, 120), maximumHeight)
        view.frame.size = NSSize(width: Self.width, height: height)
        onContentSizeChange?(view.frame.size)
    }

    private func signInPrompt() -> NSView {
        let stack = verticalStack(spacing: 6)
        stack.addArrangedSubview(label("👋 No providers signed in", style: .subheadline))
        for provider in Provider.allCases {
            stack.addArrangedSubview(
                label(provider.signInHint, style: .caption, color: .secondaryLabelColor))
        }
        return stack
    }

    private func providerSection(_ provider: Provider) -> NSView {
        let stack = verticalStack(spacing: 10)
        let snapshot = store.snapshot(for: provider)
        let title =
            snapshot?.planLabel.map { "\(provider.displayName) · \($0)" }
            ?? provider.displayName
        stack.addArrangedSubview(label(title, style: .subheadline, weight: .semibold))

        if let failure = store.failures[provider] {
            stack.addArrangedSubview(label(failure, style: .caption, color: .systemOrange))
        }

        if let snapshot {
            for window in snapshot.windows where window.isHeadline || window.percent >= 1 {
                stack.addArrangedSubview(windowRow(window))
            }

            if let budget = store.budget(for: provider) {
                stack.addArrangedSubview(budgetRow(provider: provider, budget: budget))
            } else if let balance = snapshot.creditBalanceMinor,
                let unit = snapshot.creditUnit
            {
                stack.addArrangedSubview(
                    label(
                        "\(Fmt.amount(balance, unit: unit)) available",
                        style: .caption, color: .secondaryLabelColor))
            } else if snapshot.budgetReading != nil {
                stack.addArrangedSubview(
                    label(
                        "No monthly limit reported. Set one in Settings to see percent used.",
                        style: .caption2,
                        color: .secondaryLabelColor
                    ))
            }

            if !snapshot.unrecognized.isEmpty {
                stack.addArrangedSubview(
                    label(
                        "⚠ Unrecognized from API: \(snapshot.unrecognized.joined(separator: ", "))",
                        style: .caption2,
                        color: .systemOrange
                    ))
            }
        } else if store.failures[provider] == nil {
            stack.addArrangedSubview(
                label("Loading…", style: .caption, color: .secondaryLabelColor))
        }
        return stack
    }

    private func windowRow(_ window: RateWindow) -> NSView {
        let stack = verticalStack(spacing: 4)
        let title = label(window.label, style: .subheadline)
        let reset = window.resetsAt.map {
            label(
                "Resets \(Fmt.resetPhrase($0, includeDate: !window.isSessionLength))",
                style: .caption, color: .secondaryLabelColor)
        }
        stack.addArrangedSubview(row(title, trailing: reset))
        stack.addArrangedSubview(progressBar(percent: window.percent))
        stack.addArrangedSubview(
            label(
                "\(Int(window.percent.rounded()))% used",
                style: .caption, color: .secondaryLabelColor))
        return stack
    }

    private func budgetRow(provider: Provider, budget: Budget) -> NSView {
        let stack = verticalStack(spacing: 4)
        let title: String
        switch budget.unit {
        case .credits:
            title = "Monthly credit limit"
        case .currency:
            title = budget.isOrganizationWide ? "Monthly budget (whole org)" : "Monthly budget"
        }
        let manage = ActionButton(title: "Manage →") {
            NSWorkspace.shared.open(provider.manageURL)
        }
        manage.bezelStyle = .inline
        manage.controlSize = .small
        stack.addArrangedSubview(row(label(title, style: .subheadline), trailing: manage))
        stack.addArrangedSubview(progressBar(percent: Double(budget.percent)))

        let spent = Fmt.amount(budget.spentMinor, unit: budget.unit)
        let limit = Fmt.amount(budget.limitMinor, unit: budget.unit)
        let detail: String
        if budget.isOver {
            detail =
                "\(spent) of \(limit) · over by \(Fmt.amount(budget.overageMinor, unit: budget.unit))"
        } else {
            detail =
                "\(spent) of \(limit) · \(Fmt.amount(budget.remainingMinor, unit: budget.unit)) left · \(budget.percent)%"
        }
        let reset = budget.resetsAt.map {
            label(Fmt.shortReset($0), style: .caption, color: .secondaryLabelColor)
        }
        stack.addArrangedSubview(
            row(
                label(detail, style: .caption, color: .secondaryLabelColor),
                trailing: reset))

        let badge: String?
        switch budget.state {
        case .active: badge = nil
        case .limitReached: badge = "⚠ Monthly spend limit reached"
        case .outOfCredits: badge = "⚠ Prepaid credits exhausted"
        case .disabled(let reason): badge = "⚠ \(reason)"
        }
        if let badge {
            stack.addArrangedSubview(label(badge, style: .caption2, color: .systemOrange))
        }
        if budget.isUserOverride {
            stack.addArrangedSubview(
                label(
                    "Limit set by you in Settings, not reported by \(provider.displayName).",
                    style: .caption2,
                    color: .secondaryLabelColor
                ))
        }
        return stack
    }

    private func statusSection() -> NSView {
        let stack = verticalStack(spacing: 8)
        let dot = StatusDot(color: statusManager.indicator.nsColor)
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])

        let summary = verticalStack(spacing: 2)
        summary.addArrangedSubview(
            label(
                statusManager.indicator == .none
                    ? "All Claude services operational"
                    : statusManager.description,
                style: .caption,
                color: .secondaryLabelColor
            ))
        summary.addArrangedSubview(
            label(
                statusManager.contextLine,
                style: .caption2, color: .secondaryLabelColor))

        var detailButton: NSView?
        if statusManager.hasIssue {
            let button = ActionButton(title: showingStatusDetails ? "Hide ▴" : "Details ▾") {
                [weak self] in
                guard let self else { return }
                self.showingStatusDetails.toggle()
                self.reload()
            }
            button.bezelStyle = .inline
            button.controlSize = .mini
            detailButton = button
        }
        stack.addArrangedSubview(row(dot, summary, trailing: detailButton))

        if statusManager.hasIssue && showingStatusDetails {
            stack.addArrangedSubview(statusDetails())
        }
        return stack
    }

    private func statusDetails() -> NSView {
        let stack = verticalStack(spacing: 12)
        for incident in statusManager.filteredIncidents {
            let incidentStack = verticalStack(spacing: 5)
            incidentStack.addArrangedSubview(
                label(incident.name, style: .caption, weight: .semibold))
            let status = label(
                incident.status.rawValue.uppercased(),
                style: .caption2, color: incident.status.nsColor)
            let updated = incident.updatedAt.map {
                label("Updated \(Fmt.relative($0))", style: .caption2, color: .secondaryLabelColor)
            }
            incidentStack.addArrangedSubview(row(status, trailing: updated))
            if !incident.latestUpdate.isEmpty {
                incidentStack.addArrangedSubview(label(incident.latestUpdate, style: .caption))
            }
            stack.addArrangedSubview(incidentStack)
        }

        if statusManager.filteredIncidents.isEmpty && !statusManager.affectedComponents.isEmpty {
            stack.addArrangedSubview(
                label("Affected services", style: .caption2, weight: .semibold))
            for component in statusManager.affectedComponents {
                stack.addArrangedSubview(
                    row(
                        label("• \(component.name)", style: .caption2),
                        trailing: label(
                            component.status.label,
                            style: .caption2, color: .secondaryLabelColor)
                    ))
            }
        }

        stack.addArrangedSubview(separator())
        let checked = statusManager.lastUpdated.map {
            label("Checked \(Fmt.relative($0))", style: .caption2, color: .secondaryLabelColor)
        }
        let open = ActionButton(title: "Open status page →") {
            NSWorkspace.shared.open(URL(string: "https://status.claude.com")!)
        }
        open.bezelStyle = .inline
        open.controlSize = .mini
        stack.addArrangedSubview(row(checked, trailing: open))

        let panel = PanelView(color: NSColor.systemOrange.withAlphaComponent(0.10))
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
        ])
        return panel
    }

    private func footer() -> NSView {
        let updated = store.lastUpdated.map {
            label(
                "Last updated: \(Fmt.timeOfDay.string(from: $0))",
                style: .caption, color: .secondaryLabelColor)
        }
        let refresh = ActionButton(title: store.isRefreshing ? "Refreshing…" : "Refresh") {
            [weak self] in self?.onRefresh()
        }
        refresh.isEnabled = !store.isRefreshing
        refresh.bezelStyle = .inline
        refresh.controlSize = .small
        return row(updated, trailing: refresh)
    }

    private func settingsSection() -> NSView {
        let stack = verticalStack(spacing: 12)
        let toggle = ActionButton(title: showingSettings ? "Hide Settings" : "Settings") {
            [weak self] in
            guard let self else { return }
            self.showingSettings.toggle()
            self.reload()
            if self.showingSettings {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.scrollView.contentView.scroll(
                        to: NSPoint(x: 0, y: CGFloat.greatestFiniteMagnitude)
                    )
                    self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
                }
            }
        }
        toggle.bezelStyle = .inline
        toggle.controlSize = .small
        stack.addArrangedSubview(toggle)
        if showingSettings {
            stack.addArrangedSubview(settingsPanel())
        }
        return stack
    }

    private func settingsPanel() -> NSView {
        let stack = verticalStack(spacing: 12)
        stack.addArrangedSubview(
            checkbox(
                title: "Open at Login",
                detail: "Launch automatically when you log in",
                isOn: settings.openAtLogin
            ) { [weak settings] value in settings?.applyLoginItem(value) })
        stack.addArrangedSubview(
            checkbox(
                title: "Claude Outage Notifications",
                detail: "Alert when a tracked Claude service goes down",
                isOn: settings.statusNotificationsEnabled
            ) { [weak settings] value in settings?.statusNotificationsEnabled = value })

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(
            checkbox(
                title: "Keyboard Shortcut (⌘U)",
                detail: "Toggle this popup from anywhere",
                isOn: settings.shortcutEnabled
            ) { [weak settings] value in settings?.shortcutEnabled = value })
        if settings.shortcutEnabled && store.shortcutConflict {
            stack.addArrangedSubview(
                label(
                    "⌘U is already in use by another app, so the shortcut is inactive.",
                    style: .caption2,
                    color: .systemOrange
                ))
        }

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(budgetSettings())
        stack.addArrangedSubview(separator())

        let tracked = verticalStack(spacing: 6)
        tracked.addArrangedSubview(
            label(
                "Claude status alerts: services to track",
                style: .caption, weight: .semibold))
        tracked.addArrangedSubview(
            label(
                "Untracked services never color the dot or trigger an alert.",
                style: .caption2,
                color: .secondaryLabelColor
            ))
        for component in statusManager.components {
            tracked.addArrangedSubview(
                checkbox(
                    title: component.name,
                    isOn: settings.trackedComponentIDs.contains(component.id)
                ) { [weak settings] _ in settings?.toggleComponent(component.id) })
        }
        stack.addArrangedSubview(tracked)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(appearanceControl())

        let panel = PanelView(color: NSColor.secondaryLabelColor.withAlphaComponent(0.08))
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
        ])
        return panel
    }

    private func budgetSettings() -> NSView {
        let stack = verticalStack(spacing: 6)
        stack.addArrangedSubview(label("Monthly budget", style: .caption, weight: .semibold))
        let candidates = store.visibleProviders.filter {
            store.snapshot(for: $0)?.budgetReading?.limitMinor == nil
        }
        if candidates.isEmpty {
            stack.addArrangedSubview(
                label(
                    "Both providers report their own limits, so nothing to set here.",
                    style: .caption2,
                    color: .secondaryLabelColor
                ))
        } else {
            for provider in candidates {
                stack.addArrangedSubview(budgetField(provider))
            }
        }
        return stack
    }

    private func budgetField(_ provider: Provider) -> NSView {
        let name = label(provider.displayName, style: .caption2)
        name.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let field = CommitTextField()
        field.placeholderString = "e.g. 1000"
        field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        field.stringValue =
            settings.budgetOverrideMinor[provider].map {
                String(format: "%.2f", Double($0) / 100)
            } ?? ""
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let commit: () -> Void = { [weak self, weak field] in
            guard let self, let field else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                self.settings.budgetOverrideMinor[provider] = nil
            } else if let value = Double(text), value > 0, value.isFinite {
                self.settings.budgetOverrideMinor[provider] = Int((value * 100).rounded())
            } else {
                NSSound.beep()
                field.textColor = .systemOrange
            }
        }
        field.onCommit = commit
        let set = ActionButton(title: "Set", action: commit)
        set.controlSize = .small

        var trailing: [NSView] = [name, field, set]
        if settings.budgetOverrideMinor[provider] != nil {
            let clear = ActionButton(title: "Clear") { [weak settings] in
                settings?.budgetOverrideMinor[provider] = nil
            }
            clear.controlSize = .small
            trailing.append(clear)
        }
        return row(trailing)
    }

    private func appearanceControl() -> NSView {
        let stack = verticalStack(spacing: 4)
        stack.addArrangedSubview(label("Appearance", style: .caption))
        let modes = AppearanceMode.allCases
        let segmented = ActionSegmentedControl(labels: modes.map(\.label)) {
            [weak settings] index in
            guard modes.indices.contains(index) else { return }
            settings?.appearanceMode = modes[index]
        }
        segmented.selectedSegment = modes.firstIndex(of: settings.appearanceMode) ?? 0
        segmented.segmentStyle = .automatic
        stack.addArrangedSubview(segmented)
        return stack
    }

    private func checkbox(
        title: String,
        detail: String? = nil,
        isOn: Bool,
        action: @escaping (Bool) -> Void
    ) -> NSView {
        let button = ToggleButton(title: title, isOn: isOn, action: action)
        button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        guard let detail else { return button }
        let stack = verticalStack(spacing: 2)
        stack.addArrangedSubview(button)
        let detailLabel = label(detail, style: .caption2, color: .secondaryLabelColor)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(detailLabel)
        return stack
    }

    private func progressBar(percent: Double) -> NSView {
        let bar = UsageProgressBar(
            fraction: percent / 100,
            color: UsageTier(percent: percent).nsColor)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return bar
    }

    private enum LabelStyle {
        case headline
        case subheadline
        case caption
        case caption2

        var size: CGFloat {
            switch self {
            case .headline: return NSFont.systemFontSize
            case .subheadline: return NSFont.smallSystemFontSize + 1
            case .caption: return NSFont.smallSystemFontSize
            case .caption2: return NSFont.smallSystemFontSize - 1
            }
        }
    }

    private func label(
        _ text: String,
        style: LabelStyle,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: style.size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        VerticalStackView(spacing: spacing)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func row(_ leading: NSView?, _ middle: NSView? = nil, trailing: NSView?) -> NSView {
        var views: [NSView] = []
        if let leading { views.append(leading) }
        if let middle { views.append(middle) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        if let trailing { views.append(trailing) }
        let stack = row(views)
        stack.distribution = .fill
        return stack
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class VerticalStackView: NSStackView {
    init(spacing: CGFloat) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        self.spacing = spacing
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func addArrangedSubview(_ view: NSView) {
        super.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}

private final class ActionButton: NSButton {
    private let actionHandler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        actionHandler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(performAction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    @objc private func performAction() {
        actionHandler()
    }
}

private final class ToggleButton: NSButton {
    private let actionHandler: (Bool) -> Void

    init(title: String, isOn: Bool, action: @escaping (Bool) -> Void) {
        actionHandler = action
        super.init(frame: .zero)
        self.title = title
        setButtonType(.switch)
        state = isOn ? .on : .off
        target = self
        self.action = #selector(performAction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    @objc private func performAction() {
        actionHandler(state == .on)
    }
}

private final class CommitTextField: NSTextField, NSTextFieldDelegate {
    var onCommit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        onCommit?()
    }
}

private final class ActionSegmentedControl: NSSegmentedControl {
    private let actionHandler: (Int) -> Void

    init(labels: [String], action: @escaping (Int) -> Void) {
        actionHandler = action
        super.init(frame: .zero)
        segmentCount = labels.count
        trackingMode = .selectOne
        for (index, label) in labels.enumerated() {
            setLabel(label, forSegment: index)
        }
        target = self
        self.action = #selector(performAction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    @objc private func performAction() {
        actionHandler(selectedSegment)
    }
}

private final class UsageProgressBar: NSView {
    private let fraction: CGFloat
    private let color: NSColor

    init(fraction: Double, color: NSColor) {
        self.fraction = CGFloat(max(0, min(1, fraction)))
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        path.fill()
        guard fraction > 0 else { return }
        let filled = NSRect(
            x: bounds.minX, y: bounds.minY,
            width: bounds.width * fraction, height: bounds.height)
        color.setFill()
        NSBezierPath(roundedRect: filled, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            .fill()
    }
}

private final class StatusDot: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

private final class PanelView: NSView {
    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = color.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

extension RateWindow {
    var isSessionLength: Bool { id == WindowID.session }
}
