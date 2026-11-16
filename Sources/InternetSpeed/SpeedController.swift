import AppKit
import Foundation
import OSLog
import SwiftUI

enum PopoverRefreshPolicy {
    static func shouldRebuild(isShown: Bool) -> Bool {
        isShown
    }
}

enum StatusItemRefreshPolicy {
    static func shouldApply(previousFingerprint: String?, nextFingerprint: String) -> Bool {
        previousFingerprint != nextFingerprint
    }
}

enum StatusItemIconLayout {
    /// Matches the optical size of Apple's own menu bar icons.
    static let canvasSize = NSSize(width: 20, height: 16)
    static let symbolPointSize: CGFloat = 15
    static let metricGapPointSize: CGFloat = 3
    /// Space between the four status symbols, in points of kerning.
    static let symbolSpacing: CGFloat = 11

    static func baselineOffset(for font: NSFont) -> CGFloat {
        ((font.capHeight - canvasSize.height) / 2).rounded(.toNearestOrAwayFromZero)
    }

    static func fittedRect(for source: NSSize, in target: NSSize = canvasSize) -> NSRect {
        guard source.width > 0, source.height > 0 else {
            return NSRect(origin: .zero, size: target)
        }
        let scale = min(target.width / source.width, target.height / source.height)
        let size = NSSize(width: source.width * scale, height: source.height * scale)
        return NSRect(
            x: (target.width - size.width) / 2,
            y: (target.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class SpeedController: NSObject {
    private let logger = Logger(subsystem: "com.lukemainwaring.internetspeed", category: "MenuBar")
    private let statusNotifications = StatusNotifications()
    private var commandCenterSampledAt: Date?
    private let speedTest: SpeedTesting
    private let connectionCheck: ConnectionChecking
    private let settings: AppSettings
    private let networkMonitor: NetworkChangeMonitor
    private let systemStatsProvider: SystemStatsProviding
    private let healthRefresh: MacHealthRefresh
    private let resourceMonitor: ResourceMonitor
    private let fanSpeedProvider: FanSpeedProviding
    private let cpuSampler = CPUActivitySampler()
    private var cpuActivity: CPUActivity?
    private var cpuSampledAt: Date?
    /// Power readings averaged over a few seconds so the watts read steadily.
    private var powerUseWatts: Double?
    private var powerInWatts: Double?
    private var powerSampledAt: Date?
    private let topCPUSampler = TopCPUSampler()
    private var cpuBreakdown: CPUBreakdown?
    private var isSamplingTopApp = false
    private var topAppSampledAt: Date?
    private let commandCenterSampler = CommandCenterSampler()
    private var commandCenter: CommandCenterSample?
    private var isSamplingCommandCenter = false
    private var gpuUsage: Double?
    private var gpuSampledAt: Date?
    private let gpuCores = GPUActivityReader.coreCount()
    private let lidClosedModeProvider: LidClosedModeProviding
    private let appUpdater: AppUpdating
    private let statusItem: NSStatusItem
    private let popoverModel = MacPulsePopoverModel()
    private lazy var panel = MenuBarPanel(rootView: MacPulsePopoverView(model: popoverModel))
    private lazy var appWindow = AppWindowController(model: popoverModel)

    private var connectionTimer: Timer?
    private var systemStatsTimer: Timer?
    private var resourceTimer: Timer?
    private var popoverLiveTimer: Timer?
    private var metricHistory = RecentMetricHistory()
    private var measurement: SpeedResult?
    private var systemSnapshot: SystemSnapshot?
    private var healthSnapshot: MacHealthSnapshot?
    private var resourceSnapshot: ResourceSnapshot?
    private var immediateResourceAlert: ResourceAlert?
    private var isResourceSampling = false
    private var lastError: Error?
    private var isTesting = false
    private var lastSpeedAttemptAt: Date?
    /// A network change or Test now that arrived mid-test runs right after it.
    private var testAgainAfterCurrent = false
    private var network: NetworkPath?
    /// Response time from the last connection check; nil until one succeeds.
    private var connectionLatency: Double?
    private var connectionFailures = 0
    private var isCheckingConnection = false
    private var isOffline: Bool { connectionFailures >= 2 || network?.isOnline == false }
    private var wakeObserver: NSObjectProtocol?
    private var lidClosedModeError: String?
    private var lastStatusLayoutFingerprint: String?
    /// The menu's four status dots, in the order the menu shows them.
    private var menuBarStatuses: [(section: AppSection, status: TileStatus?)] = []

    private var displayedBattery: BatterySnapshot? {
        guard let battery = systemSnapshot?.battery,
              battery.shouldShowInStatus
        else { return nil }
        return battery
    }

    init(
        speedTest: SpeedTesting = AppleSpeedTest(),
        connectionCheck: ConnectionChecking = ConnectionCheck(),
        settings: AppSettings = AppSettings(),
        networkMonitor: NetworkChangeMonitor = NetworkChangeMonitor(),
        systemStatsProvider: SystemStatsProviding = SystemStatsProvider(),
        healthMonitor: MacHealthMonitor = MacHealthMonitor(),
        resourceMonitor: ResourceMonitor = ResourceMonitor(),
        fanSpeedProvider: FanSpeedProviding = AppleSMCFanSpeedProvider(),
        lidClosedModeProvider: LidClosedModeProviding = LidClosedModeProvider(),
        appUpdater: AppUpdating? = nil
    ) {
        self.speedTest = speedTest
        self.connectionCheck = connectionCheck
        self.settings = settings
        self.networkMonitor = networkMonitor
        self.systemStatsProvider = systemStatsProvider
        self.healthRefresh = MacHealthRefresh(monitor: healthMonitor)
        self.resourceMonitor = resourceMonitor
        self.fanSpeedProvider = fanSpeedProvider
        self.lidClosedModeProvider = lidClosedModeProvider
        self.appUpdater = appUpdater ?? SparkleAppUpdater()
        let autosaveName = "InternetSpeed"
        let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            // Keep this wide status item on the visible side of the MacBook
            // notch while still allowing a user-dragged position to persist.
            UserDefaults.standard.set(250, forKey: positionKey)
        }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = autosaveName
        self.statusItem = statusItem
        super.init()

        configureStatusLabel()
        configurePopover()
        updateStatusTitle()
        statusItem.button?.toolTip = "Internet speed, memory, and battery time"
        statusItem.menu = panel.menu
        logStatusItem("created")
    }

    private func configurePopover() {
        panel.onPrepare = { [weak self] in
            self?.refreshSystemStats()
            self?.rebuildMenu(publish: true)
        }
        panel.onShow = { [weak self] in
            self?.logger.info("Menu shown")
            self?.viewersChanged()
        }
        panel.onClose = { [weak self] in
            self?.logger.info("Menu closed")
            self?.viewersChanged()
        }
        appWindow.onVisibilityChange = { [weak self] in
            self?.viewersChanged()
        }
        popoverModel.actions = MacPulsePopoverModel.Actions(
            runFullTest: { [weak self] in self?.requestSpeedTest(.manual) },
            toggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
            toggleLidClosedOperation: { [weak self] in self?.toggleLidClosedOperation() },
            quit: { [weak self] in self?.quit() },
            openApp: { [weak self] in self?.openApp() }
        )
        rebuildMenu()
    }

    /// Live updates run while anything is on screen: the panel or the app.
    private func viewersChanged() {
        let visible = panel.isShown || appWindow.isOpen
        guard visible != popoverModel.isVisible else { return }
        popoverModel.isVisible = visible
        if visible {
            startPopoverLiveUpdates()
        } else {
            stopPopoverLiveUpdates()
        }
    }

    private func openApp() {
        panel.close()
        rebuildMenu(publish: true)
        appWindow.show()
    }

    private func startPopoverLiveUpdates(now: Date = Date()) {
        stopPopoverLiveUpdates()
        refreshSystemStats()

        requestSpeedTest(.menuOpened, now: now)

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemStats() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        popoverLiveTimer = timer
    }

    private func stopPopoverLiveUpdates() {
        popoverLiveTimer?.invalidate()
        popoverLiveTimer = nil
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if !panel.isShown { rebuildMenu(publish: true) }
        panel.toggle(below: button)
    }

    func start() {
        statusNotifications.openApp = { [weak self] in self?.openApp() }
        statusNotifications.onRedChange = { [weak self] in self?.updateStatusTitle() }
        statusNotifications.start()
        appUpdater.start()
        settings.enableLaunchAtLoginIfInstalled()
        resourceMonitor.setImmediatePressureHandler { [weak self] alert in
            Task { @MainActor in
                guard let self else { return }
                self.immediateResourceAlert = alert
                self.updateStatusTitle()
                self.rebuildMenuIfVisible()
            }
        }
        refreshSystemStats()
        scheduleSystemStatsTimer()
        sampleResources()
        scheduleResourceTimer()
        networkMonitor.start { [weak self] path in
            Task { @MainActor in self?.handleNetworkPath(path) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Give Wi‑Fi a moment to rejoin before measuring.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.checkConnection()
                self?.requestSpeedTest(.wake)
            }
        }
        scheduleConnectionTimer()
        checkConnection()
        requestSpeedTest(.launch)
        // Visual QA hook: `open -n "Mac Pulse.app" --args --show-popover`.
        if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.togglePopover()
            }
        }
        if CommandLine.arguments.contains("--show-app") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.openApp()
            }
        }
    }

    /// Every minute: a tiny connection check, and the hourly backup test.
    private func scheduleConnectionTimer() {
        connectionTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkConnection()
                self?.requestSpeedTest(.hourly)
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        connectionTimer = timer
    }

    private func scheduleSystemStatsTimer() {
        systemStatsTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemStats() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        systemStatsTimer = timer
    }

    private func scheduleResourceTimer() {
        resourceTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleResources() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        resourceTimer = timer
    }

    private func sampleResources() {
        guard !isResourceSampling else { return }
        isResourceSampling = true
        let monitor = resourceMonitor
        Task { [weak self, monitor] in
            let snapshot = await Task.detached(priority: .utility) {
                monitor.sample()
            }.value
            guard let self else { return }
            self.resourceSnapshot = snapshot
            self.isResourceSampling = false
            self.updateStatusTitle()
            self.rebuildMenuIfVisible()
        }
    }

    private func refreshSystemStats() {
        let snapshot = systemStatsProvider.currentSnapshot()
        systemSnapshot = snapshot
        if let activity = cpuSampler.sample() {
            let now = snapshot.capturedAt
            let elapsed = cpuSampledAt.map { now.timeIntervalSince($0) } ?? 0
            cpuActivity = cpuActivity?.smoothed(toward: activity, elapsed: elapsed) ?? activity
            cpuSampledAt = now
            metricHistory.recordCPU(percent: (cpuActivity?.total ?? 0) * 100, at: now)
        }
        smoothPower(from: snapshot.battery, at: snapshot.capturedAt)
        smoothGPU(at: snapshot.capturedAt)
        sampleTopAppIfNeeded(at: snapshot.capturedAt)
        sampleCommandCenterIfNeeded()
        if let gpuUsage { metricHistory.recordGPU(percent: gpuUsage * 100, at: snapshot.capturedAt) }
        if let powerUseWatts { metricHistory.recordPower(watts: powerUseWatts, at: snapshot.capturedAt) }
        metricHistory.recordSystem(
            memoryUsedBytes: snapshot.memory?.usedBytes,
            temperatureCelsius: snapshot.thermal.processorTemperatureCelsius,
            at: snapshot.capturedAt
        )
        healthRefresh.refresh(
            thermal: snapshot.thermal,
            at: snapshot.capturedAt
        ) { [weak self] health in
            guard let self else { return }
            self.healthSnapshot = health
            self.updateStatusTitle()
            self.rebuildMenuIfVisible()
        }
        updateStatusTitle()
        rebuildMenuIfVisible()
    }

    private func requestSpeedTest(_ reason: SpeedTestReason, now: Date = Date()) {
        if isTesting {
            if reason == .manual || reason == .networkChange { testAgainAfterCurrent = true }
            return
        }
        guard SpeedTestSchedule.shouldTest(
            reason,
            lastResultAt: measurement?.measuredAt,
            lastAttemptAt: lastSpeedAttemptAt,
            isMeteredNetwork: network?.isMetered ?? false,
            isOffline: isOffline,
            now: now
        ) else { return }

        isTesting = true
        lastSpeedAttemptAt = now
        lastError = nil
        logger.info("speed test started; reason=\(reason.rawValue, privacy: .public)")
        updateStatusTitle()
        rebuildMenuIfVisible()

        Task {
            do {
                let result = try await speedTest.run()
                measurement = result
                metricHistory.recordDownload(megabitsPerSecond: result.downloadMbps, at: result.measuredAt)
                settings.addUsage(result.bytesTransferred)
                logger.info("speed test finished; mbps=\(result.downloadMbps); bytes=\(result.bytesTransferred)")
            } catch {
                lastError = error
                logger.error("speed test failed; \(error.localizedDescription, privacy: .public)")
            }
            isTesting = false
            updateStatusTitle()
            rebuildMenuIfVisible()

            if testAgainAfterCurrent {
                testAgainAfterCurrent = false
                requestSpeedTest(.manual)
            }
        }
    }

    private func checkConnection() {
        guard !isCheckingConnection else { return }
        isCheckingConnection = true
        let check = connectionCheck
        Task {
            let latency = await check.responseTime()
            isCheckingConnection = false
            let wasOffline = isOffline
            let previousLevel = connectionLatency.map { TileStatusRules.latency($0).level }
            if let latency {
                connectionFailures = 0
                connectionLatency = latency
            } else {
                connectionFailures += 1
            }
            if wasOffline, !isOffline {
                requestSpeedTest(.networkChange)
            } else if let latency,
                      TileStatusRules.latency(latency).level.rawValue >= TileStatus.Level.poor.rawValue,
                      (previousLevel?.rawValue ?? 0) < TileStatus.Level.poor.rawValue {
                requestSpeedTest(.connectionWorse)
            }
            updateStatusTitle()
            rebuildMenuIfVisible()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try settings.setLaunchAtLogin(!settings.launchAtLoginEnabled)
        } catch {
            lastError = error
        }
        rebuildMenu()
    }

    @objc private func toggleLidClosedOperation() {
        guard let status = lidClosedModeProvider.currentStatus() else {
            lidClosedModeError = LidClosedModeError.unavailable.localizedDescription
            rebuildMenu()
            return
        }

        let shouldEnable = !status.isEnabled
        if !shouldEnable, status.isLidClosed {
            // The alert would otherwise open behind the menu bar panel.
            panel.close()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Let Your Mac Sleep with the Lid Closed?"
            alert.informativeText = "The lid is closed right now, so your Mac may go to sleep as soon as you turn this off."
            alert.addButton(withTitle: "Turn Off")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        do {
            try lidClosedModeProvider.setEnabled(shouldEnable)
            guard lidClosedModeProvider.currentStatus()?.isEnabled == shouldEnable else {
                throw LidClosedModeError.changeDidNotApply
            }
            lidClosedModeError = nil
        } catch LidClosedModeError.cancelled {
            lidClosedModeError = nil
        } catch {
            lidClosedModeError = "Couldn’t change the lid setting. \(error.localizedDescription)"
        }
        rebuildMenu()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func handleNetworkPath(_ path: NetworkPath) {
        let previous = network
        network = path
        guard let previous, previous != path else { return }
        // A hotspot result says nothing about the line you were on before.
        if path.isMetered, !previous.isMetered { measurement = nil }
        if path.isOnline {
            connectionFailures = 0
            checkConnection()
            requestSpeedTest(.networkChange)
        }
        updateStatusTitle()
        rebuildMenuIfVisible()
    }

    /// The menu bar shows the menu's four status dots as filled, colored
    /// symbols, then the battery only when it is worth the space.
    private func updateStatusTitle() {
        let battery = displayedBattery
        let batteryIsRed = statusNotifications.redIDs.contains("power")
        let fingerprint = ([menuBarIsLight ? "light-bar" : "dark-bar"] + menuBarStatuses.map { "\($0.section.rawValue)=\($0.status.map { String($0.level.rawValue) } ?? "-")" }
            + [battery.map { "\(batteryBucket(for: $0.percentage))|\($0.flow.rawValue)|\(SystemStatsFormatting.compactDuration($0.timeRemainingMinutes))" } ?? "",
               batteryIsRed ? "battery-red" : ""])
            .joined(separator: "\u{1F}")
        guard StatusItemRefreshPolicy.shouldApply(
            previousFingerprint: lastStatusLayoutFingerprint,
            nextFingerprint: fingerprint
        ) else { return }
        lastStatusLayoutFingerprint = fingerprint

        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString()
        let isLightBar = menuBarIsLight
        logger.info("menu bar symbols redrawn; bar=\(isLightBar ? "light" : "dark", privacy: .public)")

        func append(_ image: NSImage, spacingAfter: CGFloat = 0) {
            let attachment = NSTextAttachment()
            // The attachment cell keeps template images adaptive in the menu bar.
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
            let icon = NSMutableAttributedString(attachment: attachment)
            let range = NSRange(location: 0, length: icon.length)
            icon.addAttribute(.baselineOffset, value: StatusItemIconLayout.baselineOffset(for: font), range: range)
            title.append(icon)
            // The status bar ignores kerning on attachments, so space is an
            // empty image of the exact width.
            if spacingAfter > 0 {
                let spacer = NSTextAttachment()
                spacer.attachmentCell = NSTextAttachmentCell(imageCell: NSImage(size: NSSize(width: spacingAfter, height: 1)))
                title.append(NSAttributedString(attachment: spacer))
            }
        }

        let items = menuBarStatuses.isEmpty
            ? Self.menuBarSections.map { (section: $0, status: TileStatus?.none) }
            : menuBarStatuses
        for (index, item) in items.enumerated() {
            let spacing = index < items.count - 1 ? StatusItemIconLayout.symbolSpacing : 0
            if let image = statusSymbol(
                named: Self.menuBarSymbol(for: item.section),
                accessibilityDescription: item.section.title,
                font: font,
                tintColor: item.status.map { Self.menuBarColor(for: $0.level, onLightBar: isLightBar) },
                weight: isLightBar ? .medium : .regular,
                opacity: item.status == nil ? 0.35 : 1
            ) {
                append(image, spacingAfter: spacing)
            }
        }

        if let battery {
            append(NSImage(size: NSSize(width: StatusItemIconLayout.symbolSpacing, height: 1)))
            append(Self.separatorImage(), spacingAfter: StatusItemIconLayout.symbolSpacing)
            let symbolName: String
            switch battery.flow {
            case .charging: symbolName = "bolt.fill"
            case .pluggedIn: symbolName = "powerplug.fill"
            case .charged: symbolName = "battery.100percent"
            case .discharging: symbolName = "battery.\(batteryBucket(for: battery.percentage))percent"
            }
            if let image = statusSymbol(
                named: symbolName,
                accessibilityDescription: battery.flow == .charging ? "Battery charging" : "Battery",
                font: font,
                tintColor: batteryIsRed ? .systemRed : nil
            ) {
                append(image)
            }
            if battery.flow != .pluggedIn {
                title.append(NSAttributedString(
                    string: SystemStatsFormatting.compactDuration(battery.timeRemainingMinutes),
                    attributes: [.font: font, .foregroundColor: batteryIsRed ? NSColor.systemRed : NSColor.labelColor]
                ))
            }
        }

        statusItem.button?.attributedTitle = title
        statusItem.length = NSStatusItem.variableLength

        let lines = items.map { item in
            "\(item.section.title): \(item.status?.explanation ?? "Checking…")"
        }
        statusItem.button?.toolTip = lines.joined(separator: "\n")
        statusItem.button?.setAccessibilityLabel("Mac Pulse. " + lines.joined(separator: ". "))
    }

    private static let menuBarSections: [AppSection] = [.network, .memory, .temperature, .processors]

    private static func menuBarSymbol(for section: AppSection) -> String {
        switch section {
        case .network: return "arrow.down.circle"
        case .memory: return "memorychip"
        case .temperature: return "thermometer.medium"
        default: return "cpu"
        }
    }

    /// Full-strength system colors look heavy beside white menu bar icons,
    /// so a bar with white text gets them lightened 30% toward white. A bar
    /// with black text uses the bright dark-mode system colors.
    private static func menuBarColor(for level: TileStatus.Level, onLightBar: Bool) -> NSColor {
        let (red, green, blue): (CGFloat, CGFloat, CGFloat)
        switch level {
        case .good: (red, green, blue) = (48, 209, 88)
        case .fair: (red, green, blue) = (255, 214, 10)
        case .poor: (red, green, blue) = (255, 159, 10)
        case .bad: (red, green, blue) = (255, 69, 58)
        }
        let lift: CGFloat = onLightBar ? 0 : 0.3
        func channel(_ value: CGFloat) -> CGFloat { (value + (255 - value) * lift) / 255 }
        return NSColor(srgbRed: channel(red), green: channel(green), blue: channel(blue), alpha: 1)
    }

    /// The menu bar picks light or dark text from the wallpaper; the
    /// status item's appearance says which one it is using now.
    private var menuBarIsLight: Bool {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
        return match == .aqua || match == .vibrantLight
    }

    /// A thin divider drawn as a template so it follows the menu bar's color.
    private static func separatorImage() -> NSImage {
        let size = NSSize(width: 1, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 0.5, yRadius: 0.5).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Divider"
        return image
    }

    private func statusSymbol(
        named name: String,
        accessibilityDescription: String,
        font: NSFont,
        tintColor: NSColor? = nil,
        weight: NSFont.Weight = .regular,
        opacity: CGFloat = 1
    ) -> NSImage? {
        let source: NSImage
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription) {
            source = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: StatusItemIconLayout.symbolPointSize, weight: weight)
            ) ?? symbol
        } else {
            return nil
        }
        return normalizedStatusSymbol(
            source,
            accessibilityDescription: accessibilityDescription,
            tintColor: tintColor,
            opacity: opacity
        )
    }

    /// Fits a symbol on the shared canvas. Status symbols take their dot's
    /// color; anything without a color stays a template that follows the bar.
    private func normalizedStatusSymbol(
        _ source: NSImage,
        accessibilityDescription: String,
        tintColor: NSColor? = nil,
        opacity: CGFloat = 1
    ) -> NSImage {
        let size = StatusItemIconLayout.canvasSize
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: StatusItemIconLayout.fittedRect(for: source.size, in: size),
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: opacity
        )
        if let tintColor {
            tintColor.set()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        }
        image.unlockFocus()
        image.isTemplate = tintColor == nil
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private func batteryBucket(for percentage: Int) -> Int {
        switch percentage {
        case ..<13: return 0
        case ..<38: return 25
        case ..<63: return 50
        case ..<88: return 75
        default: return 100
        }
    }

    private func configureStatusLabel() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
    }

    private func logStatusItem(_ event: String) {
        let title = statusItem.button?.attributedTitle.string ?? ""
        let frame = statusItem.button?.window?.frame.debugDescription ?? "nil"
        let visible = statusItem.button?.window?.isVisible ?? false
        logger.info("\(event, privacy: .public); title=\(title, privacy: .public); visible=\(visible); frame=\(frame, privacy: .public)")
    }


    /// Always evaluates alerts; only pushes the snapshot into SwiftUI when a
    /// view is on screen (or about to be), so hidden views cost nothing.
    private func rebuildMenu(publish: Bool = false) {
        var snapshot = MacPulsePopoverSnapshot()
        if isOffline {
            snapshot.download = "Offline"
        } else if let measurement {
            snapshot.download = SpeedFormatting.rate(measurement.downloadMbps)
        } else if isTesting {
            snapshot.download = "Measuring…"
        } else if network?.isMetered == true {
            snapshot.download = "Hotspot"
        }
        snapshot.latencyMilliseconds = isOffline ? nil : connectionLatency
        snapshot.isOffline = isOffline

        if let memory = systemSnapshot?.memory {
            snapshot.memory = SystemStatsFormatting.memoryValue(memory.usedBytes)
            snapshot.memoryDetail = "of " + SystemStatsFormatting.memoryValue(memory.totalBytes)
        }
        if let battery = systemSnapshot?.battery {
            let detail = SystemStatsFormatting.batteryDetail(battery)
            snapshot.batteryPercentage = "\(battery.percentage)%"
            if let separator = detail.range(of: " · ") {
                snapshot.batteryTime = String(detail[separator.upperBound...])
            } else {
                snapshot.batteryTime = ""
            }
            snapshot.batteryTimeTone = batteryTimeTone(for: battery)
            snapshot.batteryFlow = battery.flow
            snapshot.powerUseWatts = powerUseWatts
            snapshot.powerInWatts = powerInWatts
            snapshot.adapterWatts = battery.adapterWatts
        }
        if let thermal = systemSnapshot?.thermal {
            snapshot.temperature = MacPulsePopoverSnapshot.value(
                in: thermal.detail,
                after: "Temperature"
            )
            snapshot.temperatureIsWarning = thermal.shouldShowWarning
            snapshot.temperatureCelsius = thermal.processorTemperatureCelsius
        }

        if let resource = resourceSnapshot {
            let currentResourceAlert = immediateResourceAlert ?? resource.statusAlert
            snapshot.performance = MacPulsePopoverSnapshot.value(
                in: resource.performanceTitle,
                after: "Performance"
            )
            snapshot.performanceDetail = currentResourceAlert?.cause
                ?? MacPulsePopoverSnapshot.value(in: resource.swapDetail, after: "Swap")
            snapshot.topMemory = MacPulsePopoverSnapshot.value(
                in: resource.topMemoryDetail,
                after: "Top Memory"
            )
            if let alert = currentResourceAlert {
                snapshot.performanceTone = alert.severity == .critical ? .critical : .attention
            }
            snapshot.performanceLevel = performanceLevel(for: resource)
        }
        // Show fans only when the Mac reports real speeds.
        snapshot.fanRPMs = fanSpeedProvider.currentFanSpeeds()
        snapshot.cpu = cpuActivity
        snapshot.gpuHistory = metricHistory.gpu
        snapshot.powerHistory = metricHistory.power
        snapshot.usageTodayBytes = settings.usageToday()
        snapshot.lastMeasuredAt = measurement?.measuredAt
        snapshot.gpuUsage = gpuUsage
        snapshot.gpuCores = gpuCores
        snapshot.cpuBreakdown = cpuBreakdown
        snapshot.memoryPressure = resourceSnapshot?.sample.pressure
        snapshot.commandCenter = commandCenter
        snapshot.batteryTemperatureCelsius = systemSnapshot?.battery?.temperatureCelsius
        snapshot.batteryVoltageMv = systemSnapshot?.battery?.voltageMv
        snapshot.batteryAmperageMa = systemSnapshot?.battery?.amperageMa

        if let health = healthSnapshot {
            snapshot.macHealth = health.level.rawValue
            snapshot.macHealthDetail = health.issues.first
                ?? "Battery, storage, heat and reliability look good"
            snapshot.macHealthTone = health.level == .good ? .normal : .attention
            snapshot.macHealthMetrics = healthMetrics(from: health)
            snapshot.panicSignature = health.panic?.signature
            snapshot.panicClassification = health.panic?.classification
            snapshot.panicTaskContext = health.panic?.taskContext
        }

        if let lidClosedStatus = lidClosedModeProvider.currentStatus() {
            snapshot.lidClosedOperation = lidClosedStatus.isEnabled
            snapshot.lidClosedOperationAvailable = true
        }

        snapshot.isTesting = isTesting
        snapshot.launchAtLogin = settings.launchAtLoginEnabled
        snapshot.downloadHistory = metricHistory.download
        snapshot.memoryHistory = metricHistory.memory
        snapshot.temperatureHistory = metricHistory.temperature
        snapshot.cpuHistory = metricHistory.cpu
        if let lidClosedModeError {
            snapshot.errorMessage = lidClosedModeError
        } else if let lastError {
            snapshot.errorMessage = "Couldn’t complete the speed test. \(lastError.localizedDescription)"
        }
        statusNotifications.update(snapshot)
        let rules = SectionStatus(snapshot: snapshot)
        menuBarStatuses = Self.menuBarSections.map { (section: $0, status: rules.status(for: $0)) }
        updateStatusTitle()
        if publish || panel.isShown || appWindow.isOpen {
            popoverModel.snapshot = snapshot
        }
    }

    private func rebuildMenuIfVisible() {
        rebuildMenu()
    }

    private func batteryTimeTone(for battery: BatterySnapshot) -> MacPulseStatusTone {
        guard battery.flow == .discharging else { return .normal }
        if battery.percentage < 20 { return .critical }
        if battery.percentage < 40 { return .attention }
        return .normal
    }

    private func healthMetrics(from health: MacHealthSnapshot) -> [MacPulseHealthMetric] {
        [
            MacPulseHealthMetric(
                id: "battery",
                label: "Battery",
                detail: healthMetricValue(health.batteryDetail, removing: "Battery Health: "),
                symbol: "battery.100percent",
                tone: healthMetricTone(health, matching: ["battery"])
            ),
            MacPulseHealthMetric(
                id: "storage",
                label: "Storage",
                detail: healthMetricValue(health.storageDetail, removing: "Storage: "),
                symbol: "internaldrive",
                tone: healthMetricTone(health, matching: ["storage"])
            ),
            MacPulseHealthMetric(
                id: "heat",
                label: "Heat",
                detail: healthMetricValue(health.heatDetail, removing: "Heat Today: "),
                symbol: "thermometer.medium",
                tone: healthMetricTone(health, matching: ["temperature", "thermal"])
            ),
            MacPulseHealthMetric(
                id: "reliability",
                label: "Reliability",
                detail: healthMetricValue(health.reliabilityDetail, removing: "Reliability: "),
                symbol: "checkmark.shield",
                tone: healthMetricTone(health, matching: ["panic"])
            )
        ]
    }

    private func healthMetricValue(_ detail: String, removing prefix: String) -> String {
        guard detail.hasPrefix(prefix) else { return detail }
        return String(detail.dropFirst(prefix.count))
    }

    private func healthMetricTone(
        _ health: MacHealthSnapshot,
        matching terms: [String]
    ) -> MacPulseStatusTone {
        health.issues.contains { issue in
            terms.contains { issue.localizedCaseInsensitiveContains($0) }
        } ? .attention : .normal
    }

    private func performanceLevel(for resource: ResourceSnapshot) -> Double {
        // Prefer the live per-core reading so the label matches the CPU bars;
        // the resource sample is only taken once a minute.
        let cpuLevel = min(1, max(0, cpuActivity?.total ?? resource.sample.cpuPercent / 100))
        let pressureLevel: Double
        switch resource.sample.pressure {
        case .normal: pressureLevel = 0.22
        case .elevated: pressureLevel = 0.62
        case .critical: pressureLevel = 0.95
        case .unavailable: pressureLevel = 0.18
        }
        let thermalLevel: Double
        switch resource.sample.thermalState {
        case .nominal: thermalLevel = 0
        case .fair: thermalLevel = 0.35
        case .serious: thermalLevel = 0.7
        case .critical: thermalLevel = 1
        }
        return min(1, max(0.05, max(cpuLevel, max(pressureLevel, thermalLevel))))
    }

    private func relativeAge(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds) seconds ago" }
        return "\(seconds / 60) minute\(seconds / 60 == 1 ? "" : "s") ago"
    }

    private func smoothGPU(at now: Date) {
        guard let latest = GPUActivityReader.utilization() else { gpuUsage = nil; return }
        let elapsed = gpuSampledAt.map { now.timeIntervalSince($0) } ?? 0
        gpuSampledAt = now
        guard let previous = gpuUsage, elapsed > 0 else { gpuUsage = latest; return }
        gpuUsage = previous + (latest - previous) * (1 - exp(-elapsed / CPUActivity.smoothingTimeConstant))
    }

    /// Scanning every process costs a few milliseconds, so it runs in the
    /// background, every two seconds, and only while the full app is open.
    private func sampleTopAppIfNeeded(at now: Date) {
        guard appWindow.isOpen, !isSamplingTopApp else { return }
        if let last = topAppSampledAt, now.timeIntervalSince(last) < 2 { return }
        isSamplingTopApp = true
        topAppSampledAt = now
        let sampler = topCPUSampler
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { sampler.sample() }.value
            guard let self else { return }
            self.isSamplingTopApp = false
            if let result { self.cpuBreakdown = result }
            self.rebuildMenuIfVisible()
        }
    }

    /// Network, disk, memory and device detail for the command center, read
    /// in the background once a second while the full app is open.
    private func sampleCommandCenterIfNeeded() {
        guard !isSamplingCommandCenter else { return }
        let now = Date()
        guard appWindow.isOpen || commandCenterSampledAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true else { return }
        commandCenterSampledAt = now
        isSamplingCommandCenter = true
        let sampler = commandCenterSampler
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { sampler.sample() }.value
            guard let self else { return }
            self.isSamplingCommandCenter = false
            self.commandCenter = result
            self.rebuildMenuIfVisible()
        }
    }

    /// Averages charger and system power over a few seconds.
    private func smoothPower(from battery: BatterySnapshot?, at now: Date) {
        let elapsed = powerSampledAt.map { now.timeIntervalSince($0) } ?? 0
        powerSampledAt = now
        let blend = 1 - exp(-max(0, elapsed) / CPUActivity.smoothingTimeConstant)
        func smooth(_ previous: Double?, _ latest: Double?) -> Double? {
            guard let latest else { return nil }
            guard let previous, elapsed > 0 else { return latest }
            return previous + (latest - previous) * blend
        }
        powerUseWatts = smooth(powerUseWatts, battery?.systemLoadMw.map { $0 / 1_000 })
        // Below half a watt is sensor noise, not a connected charger.
        let input = battery?.systemPowerInMw.map { $0 / 1_000 }.flatMap { $0 >= 0.5 ? $0 : nil }
        powerInWatts = smooth(powerInWatts, input)
    }

}
