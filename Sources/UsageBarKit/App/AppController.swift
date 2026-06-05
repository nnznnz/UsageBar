import AppKit

/// Owns the menu-bar item and the refresh loop.
///
/// Concurrency model (kept deliberately simple so it's easy to reason about):
///   • All provider `fetch()` work runs on ONE serial queue (`workQueue`), so a
///     provider's internal throttle/cache state is never touched concurrently.
///   • All UI and the `results` dictionary are touched ONLY on the main thread.
///   • A refresh cycle computes into a local dictionary on the worker, then hops
///     to main once to publish results and rebuild the menu.
public final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {

    public override init() { super.init() }

    // Fixed probe/display order. Instances are created once and reused so their
    // per-provider throttle state survives across refreshes.
    private let providers: [Provider] = [
        ClaudeProvider(),
        CodexProvider(),
        CopilotProvider(),
        CursorProvider()
    ]

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let workQueue = DispatchQueue(label: "ai.usagebar.fetch")   // serial

    private var config = Config.load()
    private var client = HTTPClient(allowedHosts: [])
    private var currentAllowlist: Set<String> = []

    private var results: [String: ProbeResult] = [:]    // main-thread only
    private var lastRefresh: Date?
    private var isRefreshing = false
    private var timer: Timer?
    private var lastTimerInterval: TimeInterval = 0     // restart timer only when this changes
    private var lastEnabledIDs: Set<String> = []        // detect disable transitions to reset caches

    // MARK: Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Config.writeStarterIfMissing()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill",
                                   accessibilityDescription: "Usage")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = ""            // start clean: just the icon, no number
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        rebuildMenu()            // show a placeholder immediately
        reloadConfigAndClient()
        refresh()                // first fetch
        restartTimer()
    }

    // MARK: Config / client

    /// Reload config and, if the enabled-provider set changed, rebuild the HTTP
    /// client so its allowlist always equals exactly the hosts the currently
    /// enabled providers need — never more.
    private func reloadConfigAndClient() {
        config = Config.load()
        let hosts = enabledProviders().reduce(into: Set<String>()) { $0.formUnion($1.allowedHosts) }
        if hosts != currentAllowlist {
            client.invalidate()                       // release the old session/delegate
            client = HTTPClient(allowedHosts: hosts)
            currentAllowlist = hosts
            Log.info("HTTP allowlist: \(hosts.sorted().joined(separator: ", "))")
        }
    }

    private func enabledProviders() -> [Provider] {
        providers.filter { config.provider($0.id).enabled }
    }

    /// Restart the periodic timer ONLY when the interval actually changed, so a
    /// manual/menu refresh doesn't churn the schedule on every click.
    private func restartTimer() {
        let interval = TimeInterval(config.refreshMinutes * 60)
        guard interval != lastTimerInterval else { return }
        lastTimerInterval = interval
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Reset cache/throttle state for providers that were enabled last cycle but
    /// are now disabled, so re-enabling later starts clean. Runs on main while no
    /// fetch is in flight (the isRefreshing guard guarantees the prior worker
    /// finished), so it can't race provider state.
    private func resetDisabledProviders() {
        let enabledIDs = Set(enabledProviders().map { $0.id })
        for provider in providers where lastEnabledIDs.contains(provider.id) && !enabledIDs.contains(provider.id) {
            provider.reset()
            Log.info("reset cache for now-disabled provider: \(provider.id)")
        }
        lastEnabledIDs = enabledIDs
    }

    // MARK: Refresh

    @objc private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        reloadConfigAndClient()
        resetDisabledProviders()
        restartTimer()   // (no-op unless refreshMinutes changed)

        let toProbe = enabledProviders()
        let cfg = self.config          // Config is a struct → value copy, race-free
        let client = self.client

        // Strong `self` capture is intentional: AppController is the app-lifetime
        // NSApplication delegate, never deallocated. A weak capture could skip the
        // completion and leave `isRefreshing` stuck true forever. The closures are
        // transient (not stored on self), so there's no retain cycle.
        workQueue.async {
            var fresh: [String: ProbeResult] = [:]
            for provider in toProbe {
                fresh[provider.id] = provider.fetch(client: client, config: cfg.provider(provider.id))
            }
            DispatchQueue.main.async {
                self.results = fresh
                self.lastRefresh = Date()
                self.isRefreshing = false
                self.updateTitle()
                self.rebuildMenu()
            }
        }
    }

    // MARK: Menu-bar title

    private func updateTitle() {
        guard let button = statusItem.button else { return }

        // The menu bar stays clean: just the icon, no numbers. It only changes to
        // an alert icon when something actually needs attention — a provider has
        // hit its limit, the config is broken, or every enabled provider failed
        // with no data to fall back on. The per-provider percentages live in the
        // dropdown, not the bar.
        func showIcon(_ symbol: String, tint: NSColor?) {
            let image = NSImage(systemSymbolName: symbol,
                                accessibilityDescription: tint == nil ? "Usage" : "Usage alert")
            image?.isTemplate = true
            button.image = image
            button.contentTintColor = tint
            button.title = ""
        }

        // Bad config fails closed — surface it rather than show a healthy icon.
        if config.configError != nil {
            showIcon("exclamationmark.triangle.fill", tint: .systemOrange)
            return
        }

        var atLimit = false
        var anyFailure = false
        var anyData = false
        for provider in enabledProviders() {
            switch results[provider.id] {
            case .ok(let snap)?:
                if let h = snap.headlinePercent {
                    anyData = true
                    if h >= 100 { atLimit = true }      // a window is maxed out
                }
            case .failure?:
                anyFailure = true
            default:
                break
            }
        }

        if atLimit || (anyFailure && !anyData) {
            showIcon("exclamationmark.triangle.fill", tint: .systemRed)
        } else {
            showIcon("chart.bar.fill", tint: nil)       // all good: just the icon
        }
    }

    // MARK: Menu assembly

    private func rebuildMenu() {
        menu.removeAllItems()

        if let err = config.configError {
            menu.addItem(MenuRenderer.infoItem("⚠ \(err)", color: .systemOrange))
            menu.addItem(.separator())
        }

        let enabled = enabledProviders()
        if enabled.isEmpty && config.configError == nil {
            menu.addItem(MenuRenderer.infoItem("No providers enabled", color: .secondaryLabelColor))
            menu.addItem(MenuRenderer.infoItem("Edit config to enable one →", color: .secondaryLabelColor))
        }

        var first = true
        for provider in enabled {
            if !first { menu.addItem(.separator()) }
            first = false

            let result = results[provider.id]
            let plan: String? = {
                if case .ok(let snap)? = result { return snap.plan }
                return nil
            }()
            menu.addItem(MenuRenderer.headerItem(name: provider.displayName, plan: plan))

            if let result = result {
                for item in MenuRenderer.items(for: result) { menu.addItem(item) }
            } else {
                menu.addItem(MenuRenderer.infoItem("  Loading…", color: .secondaryLabelColor))
            }
        }

        menu.addItem(.separator())
        let updated: String = {
            guard let last = lastRefresh else { return "Updating…" }
            return "Updated \(Util.humanDuration(until: Date(), from: last)) ago"
                .replacingOccurrences(of: "now ago", with: "just now")
        }()
        menu.addItem(MenuRenderer.infoItem(updated, color: .secondaryLabelColor))

        addAction("Refresh now", #selector(refreshNow), key: "r")
        addAction("Open config…", #selector(openConfig), key: ",")
        menu.addItem(.separator())
        addAction("Quit UsageBar", #selector(quit), key: "q")
    }

    private func addAction(_ title: String, _ selector: Selector, key: String) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
    }

    // MARK: Menu delegate

    public func menuWillOpen(_ menu: NSMenu) {
        // Rebuild from current data instantly so it's never empty…
        rebuildMenu()
        // …and kick a background refresh if the data is getting stale. Providers
        // throttle their own network calls, so this is cheap when nothing's due.
        if lastRefresh == nil || Date().timeIntervalSince(lastRefresh!) > 60 {
            refresh()
        }
    }

    // MARK: Actions

    @objc private func refreshNow() { refresh() }

    @objc private func openConfig() {
        let url = Config.writeStarterIfMissing()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
