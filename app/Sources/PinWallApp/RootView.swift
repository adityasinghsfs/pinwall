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
    @StateObject private var updater = Updater.shared

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WallWebView(gallery: browseMode, settings: settings,
                        reloadToken: reloadToken, replayToken: replayToken)
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider().overlay(Color.white.opacity(0.12))
                connectionSection
                Divider().overlay(Color.white.opacity(0.12))
                motionSection
                Divider().overlay(Color.white.opacity(0.12))
                effectsSection
                Divider().overlay(Color.white.opacity(0.12))
                behaviourSection
                Divider().overlay(Color.white.opacity(0.12))
                installSection
                footer
            }
            .padding(20)
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
        guard url.contains("pinterest.") else { sourceStatus = "That's not a Pinterest URL"; return }
        if !url.hasSuffix("/") { url += "/" }
        let slug = URL(string: url)?.pathComponents.filter { $0 != "/" }.last ?? "Board"
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

    private var motionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("MOTION")
            slider("Speed", value: $settings.speed, range: 10...120, unit: "")
            slider("Fade", value: $settings.fade, range: 0...1200, unit: "ms")
            slider("Rise", value: $settings.rise, range: 0...120, unit: "px")
            slider("Stagger", value: $settings.stagger, range: 0...1500, unit: "ms")
            slider("Columns", value: $settings.columns, range: 3...10, unit: "", step: 1)
            Button {
                Installer.startScreenSaver()
            } label: {
                Label("Preview", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(tint: .pink))
            .help("Start the screensaver full-screen (install & select PinWall first)")
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

    private var fontBinding: Binding<String> {
        Binding(get: { settings.clockFont }, set: { settings.clockFont = $0; settings.save() })
    }
    private var clockColorBinding: Binding<Color> {
        Binding(get: { Color(hexString: settings.clockColor) },
                set: { settings.clockColor = $0.hexString; settings.save() })
    }

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("CLOCK")
            toggleRow("Clock & date overlay", "Show the time over the wall", isOn: $settings.clock)
                .onChange(of: settings.clock) { _ in settings.save() }
            if settings.clock {
                pickerRow("Position", selection: clockPosBinding) {
                    ForEach(clockPositions, id: \.0) { Text($0.1).tag($0.0) }
                }
                slider("Size", value: $settings.clockSize, range: 60...160, unit: "%")
                pickerRow("Font", selection: fontBinding) {
                    Text("System").tag("system")
                    Text("Rounded").tag("rounded")
                    Text("Serif").tag("serif")
                    Text("Mono").tag("mono")
                }
                slider("Weight", value: $settings.clockWeight, range: 100...900, unit: "", step: 100)
                HStack {
                    Text("Colour").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    Spacer()
                    ColorPicker("", selection: clockColorBinding, supportsOpacity: false).labelsHidden()
                }
                toggleRow("Glass panel", "Frosted background behind the clock", isOn: $settings.clockGlass)
                    .onChange(of: settings.clockGlass) { _ in settings.save() }
                toggleRow("Show date", "", isOn: $settings.clockDate)
                    .onChange(of: settings.clockDate) { _ in settings.save() }
            }
        }
    }

    // A labelled menu-picker row (label left, dropdown flush right).
    private func pickerRow<T: Hashable, C: View>(_ label: String, selection: Binding<T>,
                                                 @ViewBuilder content: () -> C) -> some View {
        HStack {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            Spacer()
            Picker("", selection: selection, content: content)
                .labelsHidden().pickerStyle(.menu).tint(.white).fixedSize()
        }
    }

    private var refreshBinding: Binding<Double> {
        Binding(get: { settings.refreshMins },
                set: { settings.refreshMins = $0; settings.save()
                       if settings.connected { Installer.installHarvestAgent() } })
    }

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("FEED REFRESH")
            pickerRow("Refresh every", selection: refreshBinding) {
                Text("30 min").tag(30.0)
                Text("1 hour").tag(60.0)
                Text("3 hours").tag(180.0)
                Text("6 hours").tag(360.0)
                Text("Once a day").tag(1440.0)
            }
            slider("Pins per refresh", value: $settings.pinTarget, range: 100...300, unit: "", step: 20)
            toggleRow("Refresh only on charger", "Skip refreshing your feed while on battery",
                      isOn: $settings.chargerOnly)
                .onChange(of: settings.chargerOnly) { _ in settings.save() }
            Button {
                refreshSource()
            } label: {
                Label(refreshing ? "Refreshing…" : "Refresh feed now",
                      systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.16)))
            .disabled(refreshing || !settings.connected)
        }
    }

    // A settings row with the switch flush to the right edge.
    private func toggleRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(.pink)
        }
    }

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("SCREEN SAVER")
            Button {
                installStatus = Installer.installSaver()
            } label: {
                Label("Set up PinWall screensaver", systemImage: "menubar.dock.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.16)))
            if let s = installStatus {
                Text(s).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Color.white.opacity(0.1))

            Button {
                settings.resetTuning()
                settings.save()
                reloadToken += 1
            } label: {
                Label("Reset to defaults", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.12)))

            if settings.connected {
                Button(role: .destructive) {
                    logout()
                } label: {
                    Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.10)))
            }

            HStack {
                Text("v\(appVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button(updater.statusText) { updater.checkNow() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.top, 4)
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
