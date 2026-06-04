import AppKit

/// Owns the menu-bar item and the refresh loop.
///
/// Concurrency model (kept deliberately simple so it's easy to reason about):
///   • All provider `fetch()` work runs on ONE serial queue (`workQueue`), so a
///     provider's internal throttle/cache state is never touched concurrently.
///   • All UI and the `results` dictionary are touched ONLY on the main thread.
///   • A refresh cycle computes into a local dictionary on the worker, then hops
///     to main once to publish results and rebuild the menu.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {

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

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.writeStarterIfMissing()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill",
                                   accessibilityDescription: "Usage")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = " …"
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

    private func restartTimer() {
        timer?.invalidate()
        let interval = TimeInterval(config.refreshMinutes * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Refresh

    @objc private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        reloadConfigAndClient()
        restartTimer()   // pick up any refreshMinutes change

        let toProbe = enabledProviders()
        let cfg = self.config          // Config is a struct → value copy, race-free
        let client = self.client

        workQueue.async { [weak self] in
            guard let self = self else { return }
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
        var worst: Double?
        for provider in enabledProviders() {
            if case .ok(let snap)? = results[provider.id], let h = snap.headlinePercent {
                worst = max(worst ?? 0, h)
            }
        }
        if let worst = worst {
            button.title = " \(Int(worst.rounded()))%"
            button.contentTintColor = worst >= 90 ? .systemRed : (worst >= 75 ? .systemOrange : nil)
        } else {
            button.title = ""
            button.contentTintColor = nil
        }
    }

    // MARK: Menu assembly

    private func rebuildMenu() {
        menu.removeAllItems()

        let enabled = enabledProviders()
        if enabled.isEmpty {
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

    func menuWillOpen(_ menu: NSMenu) {
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
