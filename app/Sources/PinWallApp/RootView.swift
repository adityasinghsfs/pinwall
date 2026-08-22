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
    // Panel docking: drag it across the central axis to snap to the other side.
    @State private var panelOnRight: Bool = {
        let d = UserDefaults(suiteName: PinWall.suiteName)
        return d?.object(forKey: "panelOnRight") == nil ? true : d!.bool(forKey: "panelOnRight")
    }()
    // Auto-resets even if the gesture is CANCELLED. The resetTransaction is the
    // key bit: without it the end-of-gesture reset to 0 is un-animated, so the
    // panel teleported back to its old edge on release instead of gliding.
    @GestureState(initialValue: CGFloat(0),
                  resetTransaction: Transaction(animation: .spring(response: 0.35,
                                                                   dampingFraction: 0.8)))
    private var panelDragX: CGFloat
    @State private var panelShadowOn = true              // fades during the drag
    @State private var shadowRestore: DispatchWorkItem?  // cancellable, so a new drag can't be re-lit
    @State private var saverSetupDone = UserDefaults(suiteName: PinWall.suiteName)?.bool(forKey: "saverSetupDone") ?? false
    @State private var icloudLink = ""
    @State private var icloudStatus: String?
    @State private var icloudLoading = false
    @StateObject private var updater = Updater.shared

    var body: some View {
        GeometryReader { geo in
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

            // subtle edge darkening (mirrors the panel's side) so the glass reads;
            // fades with the shadow while the panel is in flight
            if showPanel && !browseMode {
                LinearGradient(colors: panelOnRight ? [.clear, .black.opacity(0.45)]
                                                    : [.black.opacity(0.45), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: min(420, geo.size.width))
                    .frame(maxWidth: .infinity, alignment: panelOnRight ? .trailing : .leading)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    // fades with the shadow so the edge darkening doesn't sit at
                    // the OLD edge while the panel is mid-flight
                    .opacity(panelShadowOn ? 1 : 0)
                    .transition(.opacity)
            }

            if showPanel && !browseMode {
                settingsPanel
                    .frame(width: 320)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: panelOnRight ? .trailing : .leading)
                    .padding(panelOnRight ? .trailing : .leading, 12)
                    .offset(x: panelDragX)
                    .onChange(of: panelDragX) { v in
                        if v != 0 {
                            // in flight: kill any pending restore so a stale timer
                            // can't re-light the shadow mid-drag
                            shadowRestore?.cancel(); shadowRestore = nil
                            if panelShadowOn {
                                withAnimation(.easeOut(duration: 0.12)) { panelShadowOn = false }
                            }
                        } else if !panelShadowOn {
                            // landed (or cancelled) → shadow returns at the new edge
                            shadowRestore?.cancel()
                            let work = DispatchWorkItem {
                                withAnimation(.easeIn(duration: 0.3)) { panelShadowOn = true }
                            }
                            shadowRestore = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
                        }
                    }
                    .transition(.move(edge: panelOnRight ? .trailing : .leading).combined(with: .opacity))
                    .gesture(
                        // Drag the panel; on release it snaps to whichever side
                        // of the screen's central axis it landed on.
                        DragGesture(minimumDistance: 12, coordinateSpace: .global)
                            .updating($panelDragX) { g, state, _ in state = g.translation.width }
                            .onEnded { g in
                                let centreX = (panelOnRight ? geo.size.width - 12 - 160 : 12 + 160)
                                              + g.translation.width
                                let toRight = centreX > geo.size.width / 2
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    panelOnRight = toRight
                                }
                                UserDefaults(suiteName: PinWall.suiteName)?
                                    .set(toRight, forKey: "panelOnRight")
                            }
                    )
            }

            if !browseMode {
                // buttons dodge the panel only when it's docked on their side
                floatingButtons
                    .padding(.trailing, (showPanel && panelOnRight) ? 336 : 20)
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
        }
        // the whole stage spans the raw window — geo.size is the true window
        // size and children lay out from its actual edges (no titlebar inset).
        // NO layout minWidth here: an oversized layout gets CENTERED by SwiftUI
        // in a smaller window and overhangs BOTH edges — that was the panel-
        // off-the-edge bug. The usable minimum lives on the NSWindow instead.
        .ignoresSafeArea()
        .background(WindowConfigurator())
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
            // window controls live in the panel (Apple TV style)
            trafficDots
                .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 2)
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
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ScrollView(.vertical, showsIndicators: false) {
                // HOT ZONE flat on the panel; everything set-once lives in ADVANCED.
                VStack(alignment: .leading, spacing: 0) {
                    sourceSection
                        .padding(.top, 10)
                    Divider().overlay(Dial.stroke).padding(.top, 12)
                    dialsSection
                        .padding(.vertical, 10)
                    Divider().overlay(Dial.stroke)
                    quickRows
                        .padding(.vertical, 8)
                    Divider().overlay(Dial.stroke)
                    if !saverSetupDone {
                        // first-run: keep the one-time setup front and centre
                        // until it's been clicked, then it lives in ADVANCED.
                        Button { runSaverSetup() } label: {
                            Label("Set up PinWall screensaver", systemImage: "menubar.dock.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(DialButtonStyle(accent: true))
                        .padding(.vertical, 10)
                        if let s = installStatus {
                            Text(s).font(.system(size: 11)).foregroundStyle(Dial.textSection)
                                .padding(.bottom, 8)
                        }
                        Divider().overlay(Dial.stroke)
                    }
                    advancedFolder
                    slimFooter
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .background {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.42))   // darker glass
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        // fades out while the panel is being dragged, back in once it lands
        .shadow(color: .black.opacity(panelShadowOn ? 0.5 : 0), radius: 24, x: 0, y: 12)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Dial.accent)
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

    // MARK: - traffic dots (window controls inside the panel)

    private var trafficDots: some View {
        HStack(spacing: 8) {
            trafficDot(Color(red: 1.0, green: 0.37, blue: 0.34)) { NSApp.keyWindow?.close() }
            trafficDot(Color(red: 1.0, green: 0.74, blue: 0.18)) { NSApp.keyWindow?.miniaturize(nil) }
            trafficDot(Color(red: 0.16, green: 0.78, blue: 0.25)) { NSApp.keyWindow?.zoom(nil) }
            Spacer()
        }
    }
    private func trafficDot(_ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(color)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
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

    // Flat source strip (no folder chrome) — the most-touched control.
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            if providerTab == "icloud" { icloudConnBody } else { pinterestConnBody }
        }
        .id(providerTab)   // rebuild when the tab flips
    }

    // Small square icon button in the DialKit chip style.
    private func connIcon(_ system: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Dial.textMuted)
                .frame(width: 26, height: 26)
                .background(Dial.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Dial.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain).help(help)
    }

    @ViewBuilder private var pinterestConnBody: some View {
        if settings.connected && PinWall.harvestLoggedOut {
            Button { connect() } label: {
                Label("Sign-in expired — reconnect", systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(DialButtonStyle(accent: true))
        }

        if settings.connected {
            // One tidy row: Source dropdown + compact add/refresh chips.
            DialRow(label: "Source") {
                HStack(spacing: 6) {
                    Picker("", selection: sourceBinding) {
                        Text("Feed").tag(FeedSource.feed)
                        if !boards.isEmpty {
                            Divider()
                            ForEach(boards, id: \.url) { b in Text(b.name).tag(b.url) }
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).tint(.white)
                    connIcon("plus", "Add a board by URL") {
                        withAnimation(.easeInOut(duration: 0.2)) { showAddBoard.toggle() }
                    }
                }
            }
            if showAddBoard {
                HStack(spacing: 7) {
                    TextField("Board URL or pin.it link", text: $newBoardURL)
                        .textFieldStyle(DialFieldStyle())
                        .onSubmit { addBoard() }
                    Button("Add") { addBoard() }
                        .buttonStyle(DialButtonStyle(compact: true))
                }
            }
            if let s = sourceStatus {
                Text(s).font(.system(size: 11)).foregroundStyle(Dial.textSection)
            }
        } else {
            Text("Connect your Pinterest to fill the wall with your own feed.")
                .font(.system(size: 12)).foregroundStyle(Dial.textSection)
                .fixedSize(horizontal: false, vertical: true)
            Button { connect() } label: { Text("Connect Pinterest") }
                .buttonStyle(DialButtonStyle(accent: true))
        }
    }

    @ViewBuilder private var icloudConnBody: some View {
        if settings.icloudURL.isEmpty {
            Text("Paste a public iCloud Shared Album link. In Photos: album → People → turn on Public Website → Copy Link.")
                .font(.system(size: 11)).foregroundStyle(Dial.textSection)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                TextField("icloud.com/sharedalbum/#B0…", text: $icloudLink)
                    .textFieldStyle(DialFieldStyle())
                    .onSubmit { linkICloud() }
                Button("Load") { linkICloud() }
                    .buttonStyle(DialButtonStyle(accent: true, compact: true))
                    .disabled(icloudLoading)
            }
        } else {
            // One compact row: album identity + refresh / unlink chips.
            DialRow(label: "Album") {
                HStack(spacing: 6) {
                    Text(settings.icloudURL)
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Dial.textSection)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 120, alignment: .trailing)
                    connIcon("arrow.clockwise", "Refresh album now") { refreshICloud() }
                        .disabled(icloudLoading)
                    connIcon("xmark", "Unlink album") {
                        // Unlink: clear the link + cached photos, then play the wall
                        // OUT (tiles scroll off, red skeleton) instead of cutting.
                        settings.icloudURL = ""; settings.save(); icloudStatus = nil
                        PinStore.clearCache(for: "icloud")
                        if settings.provider == "icloud" {
                            PinStore.save([])          // saver mirror → skeleton too
                            drainToken += 1            // in-app: graceful play-out
                        }
                    }
                    if icloudLoading { ProgressView().controlSize(.small) }
                }
            }
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
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Dial.accent)
                    Button("Refresh") { refreshBoards() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Dial.accent)
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
                .buttonStyle(GlassButtonStyle(tint: Dial.accent))
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
            if count == -1 {
                flashStatus("Another refresh is already running — try again in a moment")
            } else if count > 0 {
                flashStatus("Showing \(count) pins")
                reloadToken += 1
            } else {
                flashStatus("Couldn’t load that source")
            }
        }
    }

    /// Show a status line, then clear it after a few seconds (unless replaced).
    private func flashStatus(_ text: String) {
        sourceStatus = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if sourceStatus == text { sourceStatus = nil }
        }
    }

    private func refreshBoards() {
        refreshing = true
        sourceStatus = "Finding your boards…"
        AppHarvest.refreshBoards { found in
            refreshing = false
            boards = found
            flashStatus(found.isEmpty ? "No boards found — add one by URL instead" : "Found \(found.count) boards")
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

    // HOT ZONE — the dials people actually play with, flat on the panel.
    private var dialsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Shown 0–100 (step 1); mapped to the real 5–60 px/s scroll speed.
            DialSlider(label: "Scroll speed", value: speedDisplayBinding, range: 0...100,
                       step: 1, onCommit: { settings.save() })
            DialSlider(label: "Columns", value: $settings.columns, range: 3...10,
                       step: 1, onCommit: { settings.save() })
            // Centred at 0 = straight; ±30° tilts the scrolling axis left/right.
            DialSlider(label: "Tilt", value: $settings.feedAngle, range: -30...30,
                       step: 1, unit: "°", onCommit: { settings.save() })
            pickerRow("Intro", selection: introStyleBinding) {
                Text("Bloom").tag("bloom")
                Text("Radial").tag("radial")
                Text("Radial dots").tag("radialDots")
            }
            DialSlider(label: "Duration", value: $settings.introMs, range: 1000...4000,
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
                Label("Preview", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(DialButtonStyle(accent: true))
            .padding(.top, 6)
            .help("Full-screen preview of the wall — press Esc to exit. Doesn’t lock your screen.")
        }
    }

    // Quick rows: the two hot non-dial controls.
    private var quickRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            toggleRow("Clock overlay", "Styling lives under Advanced", isOn: $settings.clock)
            HStack {
                Text(lastRefreshedText)
                    .font(.system(size: 11)).foregroundStyle(Dial.textSection)
                Spacer()
                Button {
                    if providerTab == "icloud" { refreshICloud() } else { refreshSource() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                        Text(refreshing || icloudLoading ? "Refreshing…" : "Refresh now")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Dial.accent)
                }
                .buttonStyle(.plain)
                .disabled(refreshing || icloudLoading ||
                          (providerTab == "icloud" ? settings.icloudURL.isEmpty : !settings.connected))
            }
            .frame(minHeight: 26)
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
    // Scroll speed shown as 0–100, stored as 5–60 px/s.
    private static let speedMin = 5.0, speedMax = 60.0
    private var speedDisplayBinding: Binding<Double> {
        Binding(
            get: { ((settings.speed - Self.speedMin) / (Self.speedMax - Self.speedMin) * 100).rounded() },
            set: { settings.speed = Self.speedMin + max(0, min(100, $0)) / 100 * (Self.speedMax - Self.speedMin) }
        )
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

    // ---- ADVANCED drawer: everything set-once / boring, grouped by tiny labels.

    private func advLabel(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 9.5, weight: .bold)).tracking(1.3)
            .foregroundStyle(Dial.textSection)
            .padding(.top, 6)
    }

    @ViewBuilder private var advClockBlock: some View {
        advLabel("CLOCK STYLE")
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

    @ViewBuilder private var advRefreshBlock: some View {
        advLabel("REFRESH")
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
        Button { refreshBoards() } label: {
            Text(refreshing ? "Finding boards…" : "Find my boards").frame(maxWidth: .infinity)
        }
        .buttonStyle(DialButtonStyle(ghost: true))
        .disabled(refreshing || !settings.connected)
    }

    // A settings row with a DialKit Off/On segmented toggle flush right.
    private func toggleRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        DialRow(label: title, sub: subtitle) {
            DialSegToggle(isOn: isOn, onChange: { settings.save() })
        }
    }

    private func runSaverSetup() {
        installStatus = Installer.installSaver()
        saverSetupDone = true
        UserDefaults(suiteName: PinWall.suiteName)?.set(true, forKey: "saverSetupDone")
    }

    @ViewBuilder private var advSaverBlock: some View {
        advLabel("SCREEN SAVER")
        Button { runSaverSetup() } label: {
            Label("Set up PinWall screensaver", systemImage: "menubar.dock.rectangle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(DialButtonStyle())
        if let s = installStatus {
            Text(s).font(.system(size: 11)).foregroundStyle(Dial.textSection)
        }
    }

    @ViewBuilder private var advMaintenanceBlock: some View {
        advLabel("MAINTENANCE")
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
        Button { confirmUninstall() } label: { Text("Uninstall PinWall…") }
            .buttonStyle(DialButtonStyle(ghost: true))
    }

    // One drawer for every set-once control.
    private var advancedFolder: some View {
        DialFolder("ADVANCED", icon: "slider.horizontal.3", startCollapsed: true) {
            advRefreshBlock
            if settings.clock { advClockBlock }
            advSaverBlock
            advMaintenanceBlock
        }
    }

    private var slimFooter: some View {
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
        .padding(.top, 8)
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

    // Invisible strip along the top: still drags the window, draws nothing —
    // the wall runs edge-to-edge (window controls live in the panel).
    private var dragBar: some View {
        WindowDragArea()
            .frame(height: 30)
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
            .tint(Dial.accent)
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

/// Hides the system title bar + traffic lights so the wall fills the window
/// edge-to-edge; the panel draws its own traffic dots (Apple TV style).
/// Also enforces the window's minimum size CONTINUOUSLY — with the titlebar
/// hidden, SwiftUI stops enforcing it, which is what previously let the window
/// shrink under the layout and pushed the panel off the edges.
struct WindowConfigurator: NSViewRepresentable {
    final class ConfigView: NSView {
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            guard let w = window else { return }
            apply(w)
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = [
                NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                       object: w, queue: .main) { [weak self] _ in self?.enforce() },
                NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification,
                                                       object: w, queue: .main) { [weak self] _ in self?.enforce() },
            ]
            DispatchQueue.main.async { [weak self] in self?.enforce() }
        }
        private func apply(_ w: NSWindow) {
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.standardWindowButton(.closeButton)?.isHidden = true
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
        }
        private func enforce() {
            guard let w = window else { return }
            apply(w)   // SwiftUI can re-show buttons on focus changes — reassert
            // Layout adapts to ANY size now; this is just a usability floor
            // (panel 320 + margins + some wall).
            w.contentMinSize = NSSize(width: 560, height: 480)
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ view: NSView, context: Context) {}
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
