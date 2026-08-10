import AppKit
import WebKit

/// Presents the embedded Pinterest login. The user logs into their OWN account
/// on the real pinterest.com (password goes straight to Pinterest; cookies
/// persist in WebKit's shared default store, so the harvester reuses them).
/// On "Continue" we scrape the logged-in feed once to confirm and seed the wall.
enum PinterestConnect {
    private static var controller: PinterestConnectWindowController?

    static func present(completion: @escaping (Bool) -> Void) {
        let c = PinterestConnectWindowController { connected in
            controller = nil
            completion(connected)
        }
        controller = c
        c.showWindow(nil)
        c.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Disconnects: clears Pinterest cookies/data, wipes the cached feed + boards,
    /// stops the refresh agent, and marks the app disconnected.
    static func logout(completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let pinterest = records.filter { $0.displayName.contains("pinterest") }
            store.removeData(ofTypes: types, for: pinterest) {
                PinStore.save([])
                BoardStore.save([])
                var s = WallSettings.load()
                s.connected = false
                s.source = FeedSource.feed
                s.save()
                Installer.removeHarvestAgent()
                completion()
            }
        }
    }
}

final class PinterestConnectWindowController: NSWindowController {
    private let onDone: (Bool) -> Void
    private var web: WKWebView!
    private var status: NSTextField!
    private var spinner: NSProgressIndicator!
    private var continueButton: NSButton!
    private var scraper: PinterestScraper?
    private var busy = false

    init(onDone: @escaping (Bool) -> Void) {
        self.onDone = onDone
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Connect your Pinterest"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        buildUI()
        loadLogin()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let cfg = WKWebViewConfiguration()   // default (persistent) data store
        web = WKWebView(frame: .zero, configuration: cfg)
        web.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(web)

        let bar = NSVisualEffectView()
        bar.material = .sidebar
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        status = NSTextField(labelWithString: "Log in to Pinterest, then click “I’m logged in”.")
        status.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .secondaryLabelColor
        bar.addSubview(status)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(spinner)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(cancel)

        continueButton = NSButton(title: "I’m logged in — Continue", target: self, action: #selector(continueTapped))
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(continueButton)

        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: content.topAnchor),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 56),

            status.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 10),
            spinner.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            continueButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            continueButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: continueButton.leadingAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    private func loadLogin() {
        web.load(URLRequest(url: URL(string: "https://www.pinterest.com/login/")!))
    }

    @objc private func cancel() {
        window?.close()
        onDone(false)
    }

    @objc private func continueTapped() {
        guard !busy else { return }
        busy = true
        continueButton.isEnabled = false
        spinner.startAnimation(nil)
        status.stringValue = "Fetching your feed…"

        let scraper = PinterestScraper(web: web)
        self.scraper = scraper
        Task { @MainActor in
            // load home + scrape; needsLoad navigates away from the login page
            let (pins, loggedIn) = await scraper.run(needsLoad: true)
            if loggedIn {
                PinStore.save(pins)
                status.stringValue = "Finding your boards…"
                let boards = await scraper.discoverBoards()
                BoardStore.save(boards)
                Installer.installHarvestAgent()
                spinner.stopAnimation(nil)
                status.stringValue = "Connected — \(pins.count) pins, \(boards.count) boards."
                window?.close()
                onDone(true)
            } else {
                spinner.stopAnimation(nil)
                status.stringValue = "Still looks logged out. Finish logging in, then try again."
                continueButton.isEnabled = true
                busy = false
                loadLogin()
            }
        }
    }
}
