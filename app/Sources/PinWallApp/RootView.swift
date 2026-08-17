import SwiftUI
import AppKit

struct RootView: View {
    @State private var settings = WallSettings.load()
    @State private var showPanel = true
    @State private var reloadToken = 0
    @State private var replayToken = 0
    @State private var browseMode = false
    @State private var keyMonitor: Any?
    @State private var installStatus: String?
    @State private var boards: [Board] = BoardStore.load()
    @State private var sourceStatus: String?
    @State private var refreshing = false
    @State private var showAddBoard = false
    @State private var newBoardURL = ""
    @State private var providerTab = WallSettings.load().provider
    @State private var drainToken = 0
    @State private var icloudLink = ""
    @State private var icloudStatus: String?
    @State private var icloudLoading = false
    @StateObject private var updater = Updater.shared

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WallWebView(gallery: browseMode, settings: settings,
                        reloadToken: reloadToken, replayToken: replayToken,
                        drainToken: drainToken)
                .ignoresSafeArea()

            // slim glass top bar: grab anywhere on it to move the window
            // (the wall's webview eats drags, so the window was un-draggable)
            dragBar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()

            // subtle right-edge darkening so the glass panel always reads
            if showPanel && !browseMode {
                LinearGradient(colors: [.clear, .black.opacity(0.45)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 420)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if showPanel && !browseMode {
                settingsPanel
                    .frame(width: 320)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 20)
                    .padding(.top, 44)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if !browseMode {
                // buttons slide left out of the panel's way when it's open
                floatingButtons
                    .padding(.trailing, showPanel ? 356 : 20)
                    .padding(.bottom, 20)
            }

            if browseMode {
                browseBanner
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 26)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showPanel)
        .animation(.easeInOut(duration: 0.25), value: browseMode)
        .frame(minWidth: 940, minHeight: 620)
        .onChange(of: browseMode) { isOn in
            if isOn {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == 53 { exitBrowseMode(); return nil }   // 53 = Esc
                    return event
                }
            } else if let m = keyMonitor {
                NSEvent.removeMonitor(m); keyMonitor = nil
            }
        }
        .onDisappear {   // don't leak the Esc monitor if the window closes mid-browse
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
    }

    // MARK: - browse mode

    private func enterBrowseMode() {
        browseMode = true
        reloadToken += 1     // reload the wall into gallery (hand-scroll) mode
    }
    private func exitBrowseMode() {
        browseMode = false
        reloadToken += 1     // reload back to the live, animated wall
    }

    private var browseBanner: some View {
        VStack(spacing: 3) {
            Text("Press Esc to exit browse mode")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("scroll or drag to explore · click a pin to open it on Pinterest")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 18)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Settings panel (glass)

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            dialTitlebar
                .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 9)
            DialTabs(tab: $providerTab) { id in
                guard id != settings.provider else { return }
                // Caches are written ONLY by harvests (and the launch-time seed),
                // so switching just activates the new provider's cache and
                // replays the intro. Empty cache → skeleton wall.
                settings.provider = id
                settings.save()
                PinStore.activate(provider: id)
                reloadToken += 1
            }
            .padding(.horizontal, 12).padding(.bottom, 4)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    connectionFolder
                    Divider().overlay(Dial.stroke)
                    wallSection
                    Divider().overlay(Dial.stroke)
                    introSection
                    Divider().overlay(Dial.stroke)
                    effectsSection
                    Divider().overlay(Dial.stroke)
                    behaviourSection
                    Divider().overlay(Dial.stroke)
                    installSection
                    footer
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.pink)
                Text("PinWall")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
            }
            Text(lastRefreshedText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { t in
                    clockTick = t   // re-render so "X minutes ago" stays current
                }
        }
    }

    @State private var clockTick = Date()

    private var lastRefreshedText: String {
        _ = clockTick
        guard let last = PinStore.lastRefresh else { return "Feed not refreshed yet" }
        let mins = Int(Date().timeIntervalSince(last) / 60)
        if mins < 1 { return "Last refreshed just now" }
        if mins < 60 { return "Last refreshed \(mins) min ago" }
        let h = mins / 60
        return h < 24 ? "Last refreshed \(h)h \(mins % 60)m ago"
                      : "Last refreshed \(h / 24)d ago"
    }

    // MARK: - DialKit titlebar + connection folder

    private var dialTitlebar: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 21, height: 21)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("PinWall").font(.system(size: 13, weight: .bold)).foregroundStyle(Dial.textRoot)
            Spacer()
            Text(appVersion).font(.system(size: 11, design: .monospaced)).foregroundStyle(Dial.textSection)
        }
    }

    private var connectionFolder: some View {
        DialFolder(providerTab == "icloud" ? "ICLOUD" : "PINTEREST",
                   meta: providerTab == "icloud"
                       ? (settings.icloudURL.isEmpty ? "not linked" : "linked")
                       : (settings.connected ? "connected" : "not connected")) {
            if providerTab == "icloud" { icloudConnBody } else { pinterestConnBody }
        }
        .id(providerTab)   // rebuild (and un-collapse) when the tab flips
    }

    @ViewBuilder private var pinterestConnBody: some View {
        HStack(spacing: 8) {
            Circle().fill(settings.connected ? Dial.good : Color.orange)
                .frame(width: 8, height: 8)
                .shadow(color: settings.connected ? Dial.good.opacity(0.6) : .clear, radius: 4)
            Text(settings.connected ? "Connected" : "Not connected")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Dial.textRoot)
            Spacer()
            if refreshing { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 3)

        if settings.connected && PinWall.harvestLoggedOut {
            Button { connect() } label: {
                Label("Sign-in expired — reconnect", systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(DialButtonStyle(accent: true))
        }

        if settings.connected {
            DialRow(label: "Source") {
                Picker("", selection: sourceBinding) {
                    Text("Feed").tag(FeedSource.feed)
                    if !boards.isEmpty {
                        Divider()
                        ForEach(boards, id: \.url) { b in Text(b.name).tag(b.url) }
                    }
                }
                .labelsHidden().pickerStyle(.menu).tint(.white).fixedSize()
            }
            HStack(spacing: 12) {
                Text(boards.isEmpty ? "No boards found" : "\(boards.count) boards")
                    .font(.system(size: 11)).foregroundStyle(Dial.textSection)
                Spacer()
                Button("Add URL") { showAddBoard.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Dial.accent)
                Button("Refresh") { refreshBoards() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Dial.accent)
                    .disabled(refreshing)
            }
            if showAddBoard {
                HStack(spacing: 7) {
                    TextField("Board URL or pin.it link", text: $newBoardURL)
                        .textFieldStyle(DialFieldStyle())
                        .onSubmit { addBoard() }
                    Button("Add") { addBoard() }
                        .buttonStyle(DialButtonStyle()).fixedSize()
                }
                .padding(.top, 2)
            }
            if let s = sourceStatus {
                Text(s).font(.system(size: 11)).foregroundStyle(Dial.textSection)
            }
        } else {
            Button { connect() } label: { Text("Connect your Pinterest") }
                .buttonStyle(DialButtonStyle(accent: true))
        }
    }

    @ViewBuilder private var icloudConnBody: some View {
        HStack(spacing: 8) {
            Circle().fill(settings.icloudURL.isEmpty ? Dial.textSection : Dial.good)
                .frame(width: 8, height: 8)
                .shadow(color: settings.icloudURL.isEmpty ? .clear : Dial.good.opacity(0.6), radius: 4)
            Text(settings.icloudURL.isEmpty ? "Not linked" : "Linked")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Dial.textRoot)
            Spacer()
            if icloudLoading { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 3)

        if settings.icloudURL.isEmpty {
            Text("Paste a public iCloud Shared Album link. In Photos: album → People → turn on Public Website → Copy Link.")
                .font(.system(size: 11)).foregroundStyle(Dial.textSection)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                TextField("icloud.com/sharedalbum/#B0…", text: $icloudLink)
                    .textFieldStyle(DialFieldStyle())
                    .onSubmit { linkICloud() }
                Button("Load") { linkICloud() }
                    .buttonStyle(DialButtonStyle(accent: true)).fixedSize()
                    .disabled(icloudLoading)
            }
            .padding(.top, 2)
        } else {
            Text(settings.icloudURL)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Dial.textSection)
                .lineLimit(1).truncationMode(.middle)
            Button { refreshICloud() } label: { Text("Refresh album now") }
                .buttonStyle(DialButtonStyle())
                .disabled(icloudLoading)
            Button {
                // Unlink: clear the link + cached photos, then play the wall OUT
                // (tiles scroll off, red skeleton takes over) instead of cutting.
                settings.icloudURL = ""; settings.save(); icloudStatus = nil
                PinStore.clearCache(for: "icloud")
                if settings.provider == "icloud" {
                    PinStore.save([])          // saver mirror → skeleton too
                    drainToken += 1            // in-app: graceful play-out
                }
            } label: { Text("Unlink album") }
                .buttonStyle(DialButtonStyle(ghost: true))
        }
        if let s = icloudStatus {
            Text(s).font(.system(size: 11)).foregroundStyle(Dial.textSection)
        }
    }

    private func linkICloud() {
        let link = icloudLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        guard ICloudAlbum.token(from: link) != nil else {
            icloudStatus = "That doesn't look like an iCloud Shared Album link"; return
        }
        icloudLoading = true; icloudStatus = "Loading album…"
        AppHarvest.runICloud(link: link) { count, err in
            icloudLoading = false
            if let err { icloudStatus = err; return }
            settings.icloudURL = link
            settings.provider = "icloud"
            settings.save()
            icloudLink = ""
            icloudStatus = "Loaded \(count) photos"
            reloadToken += 1
        }
    }

    private func refreshICloud() {
        icloudLoading = true; icloudStatus = "Refreshing…"
        AppHarvest.runICloud(link: settings.icloudURL) { count, err in
            icloudLoading = false
            icloudStatus = err ?? "Loaded \(count) photos"
            if err == nil { reloadToken += 1 }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("PINTEREST")
            HStack(spacing: 8) {
                Circle()
                    .fill(settings.connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(settings.connected ? "Connected" : "Not connected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                if refreshing { ProgressView().controlSize(.small) }
            }

            if settings.connected && PinWall.harvestLoggedOut {
                Button { connect() } label: {
                    Label("Pinterest sign-in expired — reconnect", systemImage: "exclamationmark.triangle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(tint: .orange.opacity(0.30)))
            }

            if settings.connected {
                // Source dropdown: Feed (top) + the user's boards.
                Picker("", selection: sourceBinding) {
                    Text("Feed").tag(FeedSource.feed)
                    if !boards.isEmpty {
                        Divider()
                        ForEach(boards, id: \.url) { b in Text(b.name).tag(b.url) }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.white)
                HStack(spacing: 12) {
                    Text(boards.isEmpty ? "No boards found" : "\(boards.count) boards")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button("Add URL") { showAddBoard.toggle() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.pink)
                    Button("Refresh") { refreshBoards() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.pink)
                        .disabled(refreshing)
                }
                if showAddBoard {
                    HStack(spacing: 6) {
                        TextField("pinterest.com/you/board/", text: $newBoardURL)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11))
                            .onSubmit { addBoard() }
                        Button("Add") { addBoard() }
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                if let s = sourceStatus {
                    Text(s).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
            } else {
                Button {
                    connect()
                } label: {
                    Text("Connect your Pinterest").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(tint: .pink))
            }
        }
    }

    // Picker binding that harvests the newly-chosen source on change.
    private var sourceBinding: Binding<String> {
        Binding(
            get: { settings.source },
            set: { newValue in
                guard newValue != settings.source else { return }
                settings.source = newValue
                settings.save()
                refreshSource()
            }
        )
    }

    private func connect() {
        PinterestConnect.present { connected in
            var s = WallSettings.load()
            s.connected = connected
            s.save()
            settings = s
            boards = BoardStore.load()
            reloadToken += 1
        }
    }

    private func refreshSource() {
        refreshing = true
        sourceStatus = "Loading pins…"
        AppHarvest.run(source: settings.source) { count in
            refreshing = false
            sourceStatus = count > 0 ? "Showing \(count) pins" : "Couldn’t load that source"
            reloadToken += 1
        }
    }

    private func refreshBoards() {
        refreshing = true
        sourceStatus = "Finding your boards…"
        AppHarvest.refreshBoards { found in
            refreshing = false
            boards = found
            sourceStatus = found.isEmpty ? "No boards found — add one by URL instead" : "Found \(found.count) boards"
        }
    }

    private func addBoard() {
        var url = newBoardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        if !url.hasPrefix("http") { url = "https://" + url }
        guard let host = URL(string: url)?.host?.lowercased() else {
            sourceStatus = "That's not a valid URL"; return
        }
        // pin.it share links are short redirects — follow them to the canonical
        // pinterest.com board URL before saving (the scraper can't harvest a
        // board off the short link itself).
        if host.contains("pin.it") {
            sourceStatus = "Resolving link…"
            Task { @MainActor in
                if let resolved = await Self.resolveShortLink(url) {
                    finishAddBoard(resolved)
                } else {
                    sourceStatus = "Couldn't resolve that pin.it link"
                }
            }
            return
        }
        guard host.contains("pinterest.") else { sourceStatus = "That's not a Pinterest URL"; return }
        finishAddBoard(url)
    }

    /// Commits a resolved pinterest.com URL as the active board source. Rejects
    /// single-pin links (`/pin/…`) since a board source needs a board.
    private func finishAddBoard(_ input: String) {
        var url = input
        // drop tracking query/fragment that pin.it appends on resolve
        if var comps = URLComponents(string: url) {
            comps.query = nil; comps.fragment = nil
            url = comps.url?.absoluteString ?? url
        }
        let parts = URL(string: url)?.pathComponents.filter { $0 != "/" } ?? []
        if parts.first?.lowercased() == "pin" {
            sourceStatus = "That's a single pin, not a board"; return
        }
        if !url.hasSuffix("/") { url += "/" }
        let slug = parts.last ?? "Board"
        let name = slug.replacingOccurrences(of: "-", with: " ").capitalized
        var list = boards
        if !list.contains(where: { $0.url == url }) { list.append(Board(name: name, url: url)) }
        BoardStore.save(list)
        boards = list
        newBoardURL = ""
        showAddBoard = false
        settings.source = url
        settings.save()
        refreshSource()
    }

    /// Follows a pin.it (or any) short link to its final pinterest.com URL.
    private static func resolveShortLink(_ url: String) async -> String? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let final = resp.url, (final.host?.lowercased().contains("pinterest.") ?? false)
        else { return nil }
        return final.absoluteString
    }

    // The always-on scrolling wall: how fast it drifts and how many columns.
    private var wallSection: some View {
        DialFolder("WALL", icon: "square.grid.2x2") {
            DialSlider(label: "Scroll speed", value: $settings.speed, range: 10...120,
                       step: 10, onCommit: { settings.save() })
            DialSlider(label: "Columns", value: $settings.columns, range: 3...10,
                       step: 1, onCommit: { settings.save() })
        }
    }

    private var introStyleName: String {
        switch settings.introStyle {
        case "radial": return "radial"
        case "radialDots": return "radial dots"
        default: return "bloom"
        }
    }

    // The entrance animation, played once when the screensaver starts.
    private var introSection: some View {
        DialFolder("INTRO", icon: "sparkles", meta: introStyleName) {
            pickerRow("Style", selection: introStyleBinding) {
                Text("Bloom").tag("bloom")
                Text("Radial").tag("radial")
                Text("Radial dots").tag("radialDots")
            }
            DialSlider(label: "Duration", value: $settings.introMs, range: 1000...3000,
                       step: 100, unit: "ms", onCommit: { settings.save() })
            if settings.introStyle == "radial" || settings.introStyle == "radialDots" {
                pickerRow("Reveal from", selection: introOriginBinding) {
                    Text("Bottom center").tag("bc")
                    Text("Bottom left").tag("bl")
                    Text("Bottom right").tag("br")
                }
            }
            Button {
                PreviewController.shared.show()
            } label: {
                Label("Preview intro", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(DialButtonStyle(accent: true))
            .help("Full-screen preview of the wall — press Esc to exit. Doesn’t lock your screen.")
        }
    }

    private let clockPositions: [(String, String)] = [
        ("tl", "Top left"), ("tc", "Top"), ("tr", "Top right"),
        ("cl", "Left"), ("cc", "Center"), ("cr", "Right"),
        ("bl", "Bottom left"), ("bc", "Bottom"), ("br", "Bottom right")
    ]
    private var clockPosBinding: Binding<String> {
        Binding(get: { settings.clockPos },
                set: { settings.clockPos = $0; settings.save() })
    }
    private var introStyleBinding: Binding<String> {
        Binding(get: { settings.introStyle },
                set: { settings.introStyle = $0; settings.save(); replayToken += 1 })
    }
    private var introOriginBinding: Binding<String> {
        Binding(get: { settings.introOrigin },
                set: { settings.introOrigin = $0; settings.save(); replayToken += 1 })
    }

    private var fontBinding: Binding<String> {
        Binding(get: { settings.clockFont }, set: { settings.clockFont = $0; settings.save() })
    }
    private var clockColorBinding: Binding<Color> {
        Binding(get: { Color(hexString: settings.clockColor) },
                set: { settings.clockColor = $0.hexString; settings.save() })
    }

    private var effectsSection: some View {
        DialFolder("CLOCK", icon: "clock", meta: settings.clock ? "on" : "off",
                   startCollapsed: !settings.clock) {
            toggleRow("Clock & date overlay", "Show the time over the wall", isOn: $settings.clock)
            if settings.clock {
                pickerRow("Position", selection: clockPosBinding) {
                    ForEach(clockPositions, id: \.0) { Text($0.1).tag($0.0) }
                }
                DialSlider(label: "Size", value: $settings.clockSize, range: 60...160,
                           step: 10, unit: "%", onCommit: { settings.save() })
                pickerRow("Font", selection: fontBinding) {
                    Text("System").tag("system")
                    Text("Rounded").tag("rounded")
                    Text("Serif").tag("serif")
                    Text("Mono").tag("mono")
                }
                DialSlider(label: "Weight", value: $settings.clockWeight, range: 100...900,
                           step: 100, onCommit: { settings.save() })
                DialRow(label: "Colour") {
                    ColorPicker("", selection: clockColorBinding, supportsOpacity: false).labelsHidden()
                }
                toggleRow("Glass font", "Frosted background behind the clock", isOn: $settings.clockGlass)
                toggleRow("Show date", "", isOn: $settings.clockDate)
            }
        }
    }

    // A labelled menu-picker row (label left, dropdown flush right).
    private func pickerRow<T: Hashable, C: View>(_ label: String, selection: Binding<T>,
                                                 @ViewBuilder content: @escaping () -> C) -> some View {
        DialRow(label: label) {
            Picker("", selection: selection, content: content)
                .labelsHidden().pickerStyle(.menu).tint(.white).fixedSize()
        }
    }

    private var refreshBinding: Binding<Double> {
        Binding(get: { settings.refreshMins },
                set: { settings.refreshMins = $0; settings.save()
                       if settings.connected { Installer.installHarvestAgent() } })
    }

    private var refreshMeta: String {
        let m = Int(settings.refreshMins)
        if m >= 1440 { return "daily" }
        if m >= 60 { return "\(m / 60)h" }
        return "\(m)m"
    }

    private var behaviourSection: some View {
        DialFolder("FEED REFRESH", icon: "arrow.clockwise", meta: refreshMeta) {
            pickerRow("Refresh every", selection: refreshBinding) {
                Text("30 min").tag(30.0)
                Text("1 hour").tag(60.0)
                Text("3 hours").tag(180.0)
                Text("6 hours").tag(360.0)
                Text("Once a day").tag(1440.0)
            }
            DialSlider(label: "Pins per refresh", value: $settings.pinTarget, range: 100...300,
                       step: 20, onCommit: { settings.save() })
            toggleRow("Only on charger", "Skip refreshing your feed while on battery",
                      isOn: $settings.chargerOnly)
            Button {
                refreshSource()
            } label: {
                Label(refreshing ? "Refreshing…" : "Refresh feed now",
                      systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DialButtonStyle())
            .disabled(refreshing || !(settings.connected || !settings.icloudURL.isEmpty))
            Text(lastRefreshedText)
                .font(.system(size: 11)).foregroundStyle(Dial.textSection)
        }
    }

    // A settings row with a DialKit Off/On segmented toggle flush right.
    private func toggleRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        DialRow(label: title, sub: subtitle) {
            DialSegToggle(isOn: isOn, onChange: { settings.save() })
        }
    }

    private var installSection: some View {
        DialFolder("SCREEN SAVER", icon: "display", startCollapsed: true) {
            Button {
                installStatus = Installer.installSaver()
            } label: {
                Label("Set up PinWall screensaver", systemImage: "menubar.dock.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DialButtonStyle())
            if let s = installStatus {
                Text(s).font(.system(size: 11)).foregroundStyle(Dial.textSection)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Dial.stroke)

            HStack(spacing: 8) {
                Button {
                    settings.resetTuning()
                    settings.save()
                    reloadToken += 1
                } label: { Text("Reset") }
                    .buttonStyle(DialButtonStyle(ghost: true))
                if settings.connected {
                    Button { logout() } label: { Text("Log out") }
                        .buttonStyle(DialButtonStyle(ghost: true))
                }
            }
            .padding(.top, 8)

            Button { confirmUninstall() } label: { Text("Uninstall PinWall…") }
                .buttonStyle(DialButtonStyle(ghost: true))

            HStack {
                Text("v\(appVersion)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Dial.textSection)
                Spacer()
                Button(updater.statusText) { updater.checkNow() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Dial.textMuted)
            }
            .padding(.top, 4)
        }
    }

    private func confirmUninstall() {
        let a = NSAlert()
        a.messageText = "Uninstall PinWall?"
        a.informativeText = "This removes the screensaver, stops the background refresh, and deletes "
            + "your cached feed + settings. Afterwards, drag PinWall to the Trash. This can't be undone."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn {
            Installer.uninstall()
            NSApp.terminate(nil)
        }
    }

    private func logout() {
        PinterestConnect.logout {
            settings = WallSettings.load()
            boards = []
            sourceStatus = nil
            reloadToken += 1
        }
    }

    // MARK: - Top drag bar

    private var dragBar: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 7) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.pink)
                Text("PinWall")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .allowsHitTesting(false)   // let drags fall through to the drag area
        }
        .frame(height: 38)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().frame(height: 1).foregroundStyle(.white.opacity(0.08))
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Floating buttons (bottom-right)

    private var floatingButtons: some View {
        HStack(spacing: 12) {
            circleButton(system: "photo.on.rectangle.angled", help: "Browse mode") {
                enterBrowseMode()
            }
            circleButton(system: showPanel ? "gearshape.fill" : "gearshape",
                         help: "Settings") {
                showPanel.toggle()
            }
        }
    }

    // MARK: - Small building blocks

    private func sectionLabel(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.4))
    }

    private func slider(_ name: String, value: Binding<Double>,
                        range: ClosedRange<Double>, unit: String, step: Double = 10) -> some View {
        // Snap to `step` via a wrapper binding so we DON'T pass `step:` to Slider
        // (that's what draws the tick marks). No ticks, still snaps.
        let snapped = Binding<Double>(
            get: { value.wrappedValue },
            set: { newVal in
                let v = step > 0 ? (range.lowerBound + (round((newVal - range.lowerBound) / step) * step)) : newVal
                value.wrappedValue = min(max(v, range.lowerBound), range.upperBound)
            }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Spacer()
                Text("\(Int(value.wrappedValue))\(unit.isEmpty ? "" : " \(unit)")")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Slider(value: snapped, in: range) { editing in
                if !editing { settings.save() }
            }
            .tint(.pink)
        }
    }

    private func circleButton(system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .help(help)
        .environment(\.colorScheme, .dark)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}

/// Transparent AppKit view that turns any mouse-down into a window drag —
/// needed because the WKWebView underneath swallows SwiftUI drag gestures.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension Color {
    init(hexString: String) {
        var s = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self = Color(.sRGB,
                     red: Double((v & 0xFF0000) >> 16) / 255,
                     green: Double((v & 0x00FF00) >> 8) / 255,
                     blue: Double(v & 0x0000FF) / 255)
    }
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }
}

// A soft, tinted glass button used across the panel.
struct GlassButtonStyle: ButtonStyle {
    var tint: Color = .white.opacity(0.16)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
