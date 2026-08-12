import SwiftUI

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct UsageView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var statusManager: StatusManager
    @ObservedObject var settings: Settings

    @State private var showingSettings = false
    @State private var showingStatusDetails = false
    @State private var measuredHeight: CGFloat = 260
    @Environment(\.colorScheme) private var colorScheme

    private let width: CGFloat = 360
    private let maxHeight: CGFloat = 600

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .padding()
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        }
                    )
            }
            .frame(width: width, height: min(max(measuredHeight, 120), maxHeight))
            // Dark: a light scrim over the native material. Light: near-opaque, or a
            // dark desktop bleeds through as murky blue-gray.
            .background(
                colorScheme == .dark
                    ? Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.3)
                    : Color.white.opacity(0.85)
            )
            .onPreferenceChange(ContentHeightKey.self) { value in
                guard value > 0 else { return }
                measuredHeight = value
            }
            .onChange(of: showingSettings) { _, isOpen in
                guard isOpen else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo("settings-anchor", anchor: .bottom)
                    }
                }
            }
            .onChange(of: store.openToken) { _, _ in
                // Every opening starts at the top, and with Settings collapsed.
                showingSettings = false
                proxy.scrollTo("top-anchor", anchor: .top)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent Usage")
                .font(.headline)
                .padding(.bottom, 4)
                .id("top-anchor")

            if store.visibleProviders.isEmpty {
                signInPrompt
            } else {
                ForEach(store.visibleProviders) { provider in
                    providerSection(provider)
                }
            }

            if statusManager.hasFetched {
                Divider()
                statusSection
            }

            Divider()
            footer

            settingsToggle
        }
    }

    // MARK: Sign-in prompt

    private var signInPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("👋 No providers signed in")
                .font(.subheadline)
            ForEach(Provider.allCases) { provider in
                Text(provider.signInHint)
                    .font(.caption)
                    .foregroundColor(Color.secondaryText)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: Provider

    @ViewBuilder
    private func providerSection(_ provider: Provider) -> some View {
        let snapshot = store.snapshot(for: provider)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(provider.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if let plan = snapshot?.planLabel {
                    Text("· \(plan)")
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                }
                Spacer()
            }

            if let failure = store.failures[provider] {
                Text(failure)
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if let snapshot {
                ForEach(displayWindows(snapshot)) { window in
                    windowRow(window)
                }

                if let budget = store.budget(for: provider) {
                    budgetRow(provider: provider, budget: budget)
                } else if let balance = snapshot.creditBalanceMinor,
                          let unit = snapshot.creditUnit {
                    Text("\(Fmt.amount(balance, unit: unit)) available")
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                } else if snapshot.budgetReading != nil {
                    // Spend is reported but no cap exists to measure it against.
                    noBudgetHint(provider)
                }

                if !snapshot.unrecognized.isEmpty {
                    Label(
                        "Unrecognized from API: \(snapshot.unrecognized.joined(separator: ", "))",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else if store.failures[provider] == nil {
                Text("Loading…")
                    .font(.caption)
                    .foregroundColor(Color.secondaryText)
            }
        }
    }

    /// Model-scoped caps sitting at zero are noise; the account-wide meters always show.
    private func displayWindows(_ snapshot: ProviderSnapshot) -> [RateWindow] {
        snapshot.windows.filter { $0.isHeadline || $0.percent >= 1 }
    }

    private func windowRow(_ window: RateWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                    .font(.subheadline)
                Spacer()
                if let resetsAt = window.resetsAt {
                    Text("Resets \(Fmt.resetPhrase(resetsAt, includeDate: !window.isSessionLength))")
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                }
            }

            UsageBar(fraction: window.percent / 100,
                     color: UsageTier(percent: window.percent).color)

            Text("\(Int(window.percent.rounded()))% used")
                .font(.caption)
                .foregroundColor(Color.secondaryText)
        }
    }

    // MARK: Budget

    private func budgetRow(provider: Provider, budget: Budget) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(budgetTitle(budget))
                    .font(.subheadline)
                Spacer()
                Button("Manage →") { NSWorkspace.shared.open(provider.manageURL) }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
            }

            UsageBar(fraction: min(budget.fraction, 1.0),
                     color: UsageTier(percent: Double(budget.percent)).color)

            HStack(alignment: .top) {
                Text(budgetDetail(budget))
                    .font(.caption)
                    .foregroundColor(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let resetsAt = budget.resetsAt {
                    Text(Fmt.shortReset(resetsAt))
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                }
            }

            if let badge = budgetBadge(budget) {
                Label(badge, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if budget.isUserOverride {
                Text("Limit set by you in Settings, not reported by \(provider.displayName).")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
                    .opacity(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// An organization-wide cap counts everyone's spend, so it must not be labelled as
    /// the user's own.
    private func budgetTitle(_ budget: Budget) -> String {
        switch budget.unit {
        case .credits:
            return "Monthly credit limit"
        case .currency:
            return budget.isOrganizationWide ? "Monthly budget (whole org)" : "Monthly budget"
        }
    }

    private func budgetDetail(_ budget: Budget) -> String {
        let spent = Fmt.amount(budget.spentMinor, unit: budget.unit)
        let limit = Fmt.amount(budget.limitMinor, unit: budget.unit)
        if budget.isOver {
            let over = Fmt.amount(budget.overageMinor, unit: budget.unit)
            return "\(spent) of \(limit) · over by \(over)"
        }
        let left = Fmt.amount(budget.remainingMinor, unit: budget.unit)
        return "\(spent) of \(limit) · \(left) left · \(budget.percent)%"
    }

    private func budgetBadge(_ budget: Budget) -> String? {
        switch budget.state {
        case .active:
            return nil
        case .limitReached:
            return "Monthly spend limit reached"
        case .outOfCredits:
            // Distinct from hitting the cap: the pool is dry with headroom to spare.
            return "Prepaid credits exhausted"
        case .disabled(let reason):
            return reason
        }
    }

    private func noBudgetHint(_ provider: Provider) -> some View {
        Text("No monthly limit reported. Set one in Settings to see percent used.")
            .font(.caption2)
            .foregroundColor(Color.secondaryText)
            .opacity(0.8)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(statusManager.indicator.color)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusManager.indicator == .none
                         ? "All Claude services operational"
                         : statusManager.description)
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(statusManager.contextLine)
                        .font(.system(size: 10))
                        .foregroundColor(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if statusManager.hasIssue {
                    Button(action: { showingStatusDetails.toggle() }) {
                        HStack(spacing: 2) {
                            Text(showingStatusDetails ? "Hide" : "Details")
                            Image(systemName: showingStatusDetails ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8))
                        }
                        .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if statusManager.hasIssue && showingStatusDetails {
                statusDetails
            }
        }
    }

    private var statusDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(statusManager.filteredIncidents) { incident in
                VStack(alignment: .leading, spacing: 6) {
                    Text(incident.name)
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(incident.status.rawValue.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(incident.status.badgeColor)
                            .cornerRadius(3)
                        if let updatedAt = incident.updatedAt {
                            Text("Updated \(Fmt.relative(updatedAt))")
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                        }
                    }
                    if !incident.latestUpdate.isEmpty {
                        Text(incident.latestUpdate)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }

            if statusManager.filteredIncidents.isEmpty && !statusManager.affectedComponents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Affected services")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(Color.secondaryText)
                    ForEach(statusManager.affectedComponents) { component in
                        HStack(spacing: 6) {
                            Circle().fill(Color.orange).frame(width: 5, height: 5)
                            Text(component.name).font(.caption2)
                            Spacer()
                            Text(component.status.label)
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                        }
                    }
                }
            }

            Divider()

            HStack {
                if let lastUpdated = statusManager.lastUpdated {
                    Text("Checked \(Fmt.relative(lastUpdated))")
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
                }
                Spacer()
                Button("Open status page →") {
                    NSWorkspace.shared.open(URL(string: "https://status.claude.com")!)
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10))
        .cornerRadius(6)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let lastUpdated = store.lastUpdated {
                Text("Last updated: \(Fmt.timeOfDay.string(from: lastUpdated))")
                    .font(.caption)
                    .foregroundColor(Color.secondaryText)
            }
            Spacer()
            Button(store.isRefreshing ? "Refreshing…" : "Refresh") {
                Task {
                    await store.refresh()
                    await statusManager.fetch()
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(store.isRefreshing)
        }
    }

    // MARK: Settings

    private var settingsToggle: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(showingSettings ? "Hide Settings" : "Settings") {
                showingSettings.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingSettings {
                settingsPanel
                Color.clear.frame(height: 1).id("settings-anchor")
            }
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { settings.openAtLogin },
                set: { settings.applyLoginItem($0) }
            )) {
                settingLabel("Open at Login", "Launch automatically when you log in")
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $settings.statusNotificationsEnabled) {
                settingLabel("Claude Outage Notifications",
                             "Alert when a tracked Claude service goes down")
            }
            .toggleStyle(.checkbox)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $settings.shortcutEnabled) {
                    settingLabel("Keyboard Shortcut (⌘U)",
                                 "Toggle this popup from anywhere")
                }
                .toggleStyle(.switch)

                if settings.shortcutEnabled && store.shortcutConflict {
                    Text("⌘U is already in use by another app, so the shortcut is inactive.")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            budgetOverrideSettings

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Claude status alerts: services to track")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("Untracked services never color the dot or trigger an alert.")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(statusManager.components) { component in
                    Toggle(isOn: Binding(
                        get: { settings.trackedComponentIDs.contains(component.id) },
                        set: { _ in settings.toggleComponent(component.id) }
                    )) {
                        Text(component.name).font(.caption2)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Appearance").font(.caption)
                Picker("Appearance", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }

    /// Only offered for providers that are signed in but report no cap of their own;
    /// offering it where the API already answers would invite a stale figure to
    /// contradict billed truth.
    @ViewBuilder
    private var budgetOverrideSettings: some View {
        let candidates = store.visibleProviders.filter { provider in
            store.snapshot(for: provider)?.budgetReading?.limitMinor == nil
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Monthly budget")
                .font(.caption)
                .fontWeight(.semibold)
            if candidates.isEmpty {
                Text("Both providers report their own limits, so nothing to set here.")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(candidates) { provider in
                    BudgetOverrideField(provider: provider, settings: settings)
                }
            }
        }
    }

    private func settingLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            Text(detail)
                .font(.caption2)
                .foregroundColor(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Budget override field

/// Accepts whole and decimal amounts, stores minor units, and rejects anything that is
/// not a positive number rather than silently persisting a zero.
private struct BudgetOverrideField: View {
    let provider: Provider
    @ObservedObject var settings: Settings

    @State private var text: String = ""
    @State private var isInvalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(provider.displayName)
                    .font(.caption2)
                    .frame(width: 48, alignment: .leading)
                TextField("e.g. 1000", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)
                    .frame(width: 90)
                    .onSubmit(commit)
                Button("Set", action: commit)
                    .controlSize(.small)
                if settings.budgetOverrideMinor[provider] != nil {
                    Button("Clear") {
                        settings.budgetOverrideMinor[provider] = nil
                        text = ""
                        isInvalid = false
                    }
                    .controlSize(.small)
                }
            }
            if isInvalid {
                Text("Enter a positive amount.")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .onAppear {
            if let minor = settings.budgetOverrideMinor[provider] {
                text = String(format: "%.2f", Double(minor) / 100)
            }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            settings.budgetOverrideMinor[provider] = nil
            isInvalid = false
            return
        }
        guard let value = Double(trimmed), value > 0, value.isFinite else {
            isInvalid = true
            return
        }
        isInvalid = false
        settings.budgetOverrideMinor[provider] = Int((value * 100).rounded())
    }
}

// MARK: - Window helpers

extension RateWindow {
    /// A same-day window shows a time; a multi-day one needs the date too.
    var isSessionLength: Bool { id == WindowID.session }
}
