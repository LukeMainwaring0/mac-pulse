import AppKit
import SwiftUI

// MARK: - Sections

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case overview, network, processors, memory, storage, power, temperature, processes, devices, health, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Command Center"
        case .network: return "Network"
        case .processors: return "CPU & GPU"
        case .memory: return "Memory"
        case .storage: return "Storage"
        case .power: return "Battery & Power"
        case .temperature: return "Temperature"
        case .processes: return "Apps"
        case .devices: return "Devices"
        case .health: return "Health"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "waveform.path.ecg"
        case .network: return "arrow.down.circle.fill"
        case .processors: return "cpu"
        case .memory: return "memorychip.fill"
        case .storage: return "internaldrive.fill"
        case .power: return "bolt.fill"
        case .temperature: return "thermometer.medium"
        case .processes: return "square.stack.3d.up.fill"
        case .devices: return "laptopcomputer"
        case .health: return "heart.text.square.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .overview: return .indigo
        case .network: return .blue
        case .processors: return .green
        case .memory: return .purple
        case .storage: return .teal
        case .power: return .green
        case .temperature: return .orange
        case .processes: return .cyan
        case .devices: return .gray
        case .health: return .red
        case .settings: return .gray
        }
    }

    /// The glyph inside the sidebar's colored badge, System Settings style.
    var badgeSymbol: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .network: return "arrow.down"
        case .processors: return "cpu.fill"
        case .memory: return "memorychip.fill"
        case .storage: return "internaldrive.fill"
        case .power: return "bolt.fill"
        case .temperature: return "thermometer.medium"
        case .processes: return "square.stack.3d.up.fill"
        case .devices: return "laptopcomputer"
        case .health: return "heart.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// Something that isn't green, with where to go to see more.
struct Concern: Hashable {
    let text: String
    let level: TileStatus.Level
    let section: AppSection
}

/// Status for each section, shared by the sidebar dots and the page headers.
struct SectionStatus {
    let snapshot: MacPulsePopoverSnapshot

    var hasLoadSample: Bool { snapshot.performance != MacPulsePopoverSnapshot().performance }
    var loadState: PerformanceMeterState { .current(for: snapshot.performanceLevel) }

    func status(for section: AppSection) -> TileStatus? {
        switch section {
        case .network: return TileStatusRules.connection(latency: snapshot.latencyMilliseconds, isOffline: snapshot.isOffline)
        case .processors: return hasLoadSample ? TileStatusRules.cpu(state: loadState, total: snapshot.cpu?.total) : nil
        case .memory: return snapshot.memoryPressure.flatMap(TileStatusRules.memory)
        case .temperature: return snapshot.temperatureCelsius.map(TileStatusRules.temperature)
        case .power:
            switch snapshot.batteryTimeTone {
            case .normal: return TileStatus(level: .good, explanation: "Battery is fine")
            case .attention: return TileStatus(level: .poor, explanation: "Battery is getting low")
            case .critical: return TileStatus(level: .bad, explanation: "Battery is very low")
            }
        case .health:
            switch snapshot.macHealthTone {
            case .normal: return TileStatus(level: .good, explanation: "Mac health is good")
            case .attention: return TileStatus(level: .poor, explanation: "Mac health needs attention")
            case .critical: return TileStatus(level: .bad, explanation: "Mac health needs attention now")
            }
        case .overview: return worst
        case .storage:
            guard let startup = snapshot.commandCenter?.volumes.first(where: \.isStartup) else {
                return snapshot.macHealthMetrics.first { $0.id == "storage" }.map {
                    TileStatus(level: $0.tone == .normal ? .good : .poor, explanation: HealthRowFormatting.displayValue(for: $0))
                }
            }
            let used = Int((startup.usedFraction * 100).rounded())
            switch startup.usedFraction {
            case ..<0.85: return TileStatus(level: .good, explanation: "Plenty of space · \(used)% used")
            case ..<0.95: return TileStatus(level: .poor, explanation: "Nearly full · \(used)% used")
            default: return TileStatus(level: .bad, explanation: "Almost out of space · \(used)% used")
            }
        case .devices:
            guard let low = snapshot.commandCenter?.accessories.min(by: { $0.percent < $1.percent }) else { return nil }
            return low.percent < 15
                ? TileStatus(level: .poor, explanation: "\(low.name) battery low · \(low.percent)%")
                : TileStatus(level: .good, explanation: "Accessories charged")
        case .processes, .settings: return nil
        }
    }

    var worst: TileStatus? {
        let all = [AppSection.network, .processors, .memory, .temperature, .power, .health].compactMap { status(for: $0) }
        return all.max { $0.level.rawValue < $1.level.rawValue }
    }

    /// Plain sentences about anything worth a look, worst first. Yellow
    /// readings are normal busyness, not concerns.
    var concerns: [Concern] {
        var items: [Concern] = []
        for metric in snapshot.macHealthMetrics where metric.tone != .normal {
            let title = metric.id == "reliability" ? "Stability" : metric.label
            items.append(Concern(text: "\(title): \(HealthRowFormatting.displayValue(for: metric))",
                                 level: metric.tone == .critical ? .bad : .poor, section: .health))
        }
        for section in [AppSection.processors, .memory, .temperature, .network, .power] {
            if let status = status(for: section), status.level.rawValue >= TileStatus.Level.poor.rawValue {
                items.append(Concern(text: status.explanation, level: status.level, section: section))
            }
        }
        return items.enumerated()
            .sorted { ($0.element.level.rawValue, -$0.offset) > ($1.element.level.rawValue, -$1.offset) }
            .map(\.element)
    }
}

extension TileStatus {
    /// The judgement alone, for pills under a page that already shows the number.
    func summary(for section: AppSection) -> String {
        let parts = explanation.components(separatedBy: " · ")
        guard parts.count == 2 else { return explanation }
        switch section {
        case .network: return parts[1] == "Calls may lag" ? parts[1] : "\(parts[1]) latency"
        case .temperature: return parts[1]
        default: return parts[0]
        }
    }
}

// MARK: - Root

struct MacPulseAppView: View {
    @ObservedObject var model: MacPulsePopoverModel
    @State private var selection: AppSection?

    init(model: MacPulsePopoverModel, initialSection: AppSection = .overview) {
        self.model = model
        _selection = State(initialValue: initialSection)
    }

    private var snapshot: MacPulsePopoverSnapshot { model.snapshot }
    private var statuses: SectionStatus { SectionStatus(snapshot: snapshot) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    sidebarRow(.overview)
                }
                Section("Vitals") {
                    ForEach([AppSection.network, .processors, .memory, .storage, .power, .temperature]) { sidebarRow($0) }
                }
                Section("System") {
                    ForEach([AppSection.processes, .devices, .health]) { sidebarRow($0) }
                }
                Section {
                    sidebarRow(.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail
                .navigationTitle(selection?.title ?? "Mac Pulse")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.actions.runFullTest()
                        } label: {
                            Label("Test Speed", systemImage: "gauge.with.needle")
                                .labelStyle(.iconOnly)
                        }
                        .help("Run a full speed test now")
                        .disabled(snapshot.isTesting)
                    }
                }
        }
        .environment(\.graphsAreLive, model.isVisible)
        .frame(minWidth: 980, minHeight: 660)
    }

    private func sidebarRow(_ section: AppSection) -> some View {
        Label {
            HStack {
                Text(section.title)
                Spacer()
                if let status = statuses.status(for: section) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 7, height: 7)
                        .shadow(color: status.color.opacity(0.5), radius: 2)
                        .help(status.explanation)
                        .motion(status.level.rawValue)
                }
            }
        } icon: {
            SidebarBadge(section: section)
        }
        .tag(section)
    }

    @ViewBuilder
    private var detail: some View {
        let current = selection ?? .overview
        ZStack {
            Group {
                if current == .settings {
                    // A native grouped form, like System Settings.
                    SettingsPage(snapshot: snapshot, actions: model.actions)
                } else if current == .processes {
                    // A native table that scrolls itself.
                    AppsPage(snapshot: snapshot)
                } else {
                    ScrollView {
                        page(current)
                            .padding(.horizontal, 32)
                            .padding(.top, 12)
                            .padding(.bottom, 32)
                            .frame(maxWidth: current == .overview ? 1600 : 1100, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .id(current)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 10)),
                removal: .opacity
            ))
        }
        .animation(.smooth(duration: 0.32), value: current)
        .background(alignment: .top) {
            // A soft wash of the section's color behind the page header.
            LinearGradient(
                colors: [current.tint.opacity(0.16), current.tint.opacity(0.04), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 420)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.5), value: current)
        }
    }

    @ViewBuilder
    private func page(_ section: AppSection) -> some View {
        switch section {
        case .overview: OverviewPage(snapshot: snapshot, statuses: statuses, select: { selection = $0 })
        case .network: NetworkPage(snapshot: snapshot, status: statuses.status(for: .network), runTest: model.actions.runFullTest)
        case .processors: ProcessorsPage(snapshot: snapshot, status: statuses.status(for: .processors))
        case .memory: MemoryPage(snapshot: snapshot, status: statuses.status(for: .memory))
        case .storage: StoragePage(snapshot: snapshot, status: statuses.status(for: .storage))
        case .power: PowerPage(snapshot: snapshot, status: statuses.status(for: .power))
        case .temperature: TemperaturePage(snapshot: snapshot, status: statuses.status(for: .temperature))
        case .devices: DevicesPage(snapshot: snapshot, status: statuses.status(for: .devices))
        case .health: HealthPage(snapshot: snapshot, status: statuses.status(for: .health))
        case .settings, .processes: EmptyView()
        }
    }
}

// MARK: - Building blocks

/// A white glyph on a rounded square of the section's color, like the
/// icons in System Settings.
private struct SidebarBadge: View {
    let section: AppSection
    var symbolOverride: String?
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbolOverride ?? section.badgeSymbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(section.tint.gradient)
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
            )
    }
}

/// Cards side by side that share the height of the tallest one.
private struct EqualRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PageHeader: View {
    let section: AppSection
    let value: String?
    var subtitle: String?
    var status: TileStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The toolbar already names the section; the pill says how it's doing.
            if let status {
                StatusPill(status: status, text: status.summary(for: section))
            }
            if let value {
                BigValue(value: value, size: 60)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .motion(subtitle)
            }
        }
        .padding(.bottom, 10)
    }
}

private struct StatusPill: View {
    let status: TileStatus
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 7, height: 7)
                .shadow(color: status.color.opacity(0.6), radius: 2)
            Text(text)
                .contentTransition(.opacity)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(status.color.opacity(0.16)))
        .overlay(Capsule().strokeBorder(status.color.opacity(0.22), lineWidth: 0.5))
        .help(status.explanation)
        .motion(text)
    }
}

/// A number in large type with its unit small beside it.
private struct BigValue: View {
    let value: String
    var size: CGFloat = 34
    /// Color for word values such as "Normal"; numbers stay primary.
    var wordStyle: AnyShapeStyle = AnyShapeStyle(.primary)

    var body: some View {
        switch HeroValueParts(value) {
        case let .measured(number, unit):
            HStack(alignment: .firstTextBaseline, spacing: unit.hasPrefix("°") || unit == "%" ? 0 : 5) {
                Text(number)
                    .font(.system(size: size, weight: .semibold))
                    .kerning(size > 40 ? -1 : -0.3)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .motion(number)
                Text(unit)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        case let .text(text):
            Text(text)
                .font(.system(size: size * 0.72, weight: .semibold))
                .foregroundStyle(wordStyle)
                .contentTransition(.opacity)
                .motion(text)
        }
    }
}

private struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    var tint: Color = .secondary
    var status: TileStatus?
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 7) {
                    if let symbol {
                        Image(systemName: symbol).foregroundStyle(tint).symbolRenderingMode(.hierarchical)
                    }
                    Text(title).foregroundStyle(.secondary)
                    Spacer()
                    if let status {
                        Circle().fill(status.color).frame(width: 8, height: 8)
                            .shadow(color: status.color.opacity(0.55), radius: 2)
                            .help(status.explanation)
                            .motion(status.level.rawValue)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CardSurface())
    }
}

/// The shared card surface: a quiet fill with a light-catching top edge, so
/// cards read as layered glass without competing with the content.
private struct CardSurface: View {
    var highlighted = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let dark = colorScheme == .dark
        shape
            // Dark: a faint lift off the window. Light: near-white panels on
            // the tinted page, the way grouped content sits in macOS.
            .fill(dark ? Color.white.opacity(highlighted ? 0.085 : 0.055)
                       : Color.white.opacity(highlighted ? 0.95 : 0.78))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(dark ? 0.12 : 0.9),
                                            Color.black.opacity(dark ? 0.1 : 0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.6
                )
            )
            .shadow(color: .black.opacity(dark ? 0.2 : 0.07), radius: highlighted ? 16 : 10, y: highlighted ? 7 : 3)
    }
}

/// Clickable cards brighten and lift slightly on hover, and press in.
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLift(pressed: configuration.isPressed) { configuration.label }
    }

    private struct HoverLift<Label: View>: View {
        let pressed: Bool
        @ViewBuilder let label: Label
        @State private var hovering = false

        var body: some View {
            label
                .background(CardSurface(highlighted: hovering).opacity(hovering ? 1 : 0))
                .scaleEffect(pressed ? 0.985 : (hovering ? 1.008 : 1))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
                .animation(.spring(response: 0.2, dampingFraction: 0.9), value: pressed)
                .onHover { hovering = $0 }
        }
    }
}

/// A live chart with quiet reference labels on the right.
private struct ChartView: View {
    let points: [MetricHistoryPoint]
    let tint: Color
    var range: ClosedRange<Double>?
    var minimumSpan: Double = 1
    var zoneGradient = false
    var window: TimeInterval = RecentMetricHistory.retention
    var labels: [String] = []
    var height: CGFloat = 160

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LiveGraph(
                points: points, window: window, tint: tint, minimumSpan: minimumSpan,
                valueGradient: zoneGradient ? (PerformanceMeterState.meterGradient, 0...100) : nil,
                fixedRange: range,
                fadesLeadingEdge: false
            )
            .background {
                VStack {
                    ForEach(0..<3) { index in
                        if index > 0 { Spacer() }
                        Rectangle().fill(Color.primary.opacity(index == 2 ? 0.1 : 0.05)).frame(height: 0.5)
                    }
                }
            }
            if !labels.isEmpty {
                VStack(alignment: .trailing) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        if index > 0 { Spacer() }
                        Text(label)
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            }
        }
        .frame(height: height)
        .overlay(alignment: .bottomLeading) {
            Text(window >= 7_200 ? "Last \(Int(window / 3_600)) hours"
                 : window >= 120 ? "Last \(Int(window / 60)) minutes" : "Last \(Int(window)) seconds")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .offset(y: 16)
        }
        .padding(.bottom, 16)
    }
}

/// A ring that fills toward its value, with the number in the middle.
private struct Ring: View {
    let title: String
    let value: Double?
    let display: String
    var gradient: Gradient = PerformanceMeterState.meterGradient
    var solid: Color?

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: min(1, max(0, value ?? 0)))
                    .stroke(
                        solid.map { AnyShapeStyle($0) } ?? AnyShapeStyle(AngularGradient(
                            gradient: gradient, center: .center,
                            startAngle: .degrees(0), endAngle: .degrees(360)
                        )),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: (solid ?? .green).opacity(0.35), radius: 6)
                    .motion(Int(((value ?? 0) * 200).rounded()))
                BigValue(value: display, size: 26)
            }
            .frame(width: 112, height: 112)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(display)
    }
}

/// Color for a load fraction on the green–red zone scale.
private func zoneColor(_ value: Double) -> Color {
    let stops: [(Double, NSColor)] = [(0, .systemGreen), (0.35, .systemYellow), (0.55, .systemOrange), (0.82, .systemRed), (1, .systemRed)]
    let v = min(1, max(0, value))
    for index in 1..<stops.count where v <= stops[index].0 {
        let (lowerAt, lower) = stops[index - 1]
        let (upperAt, upper) = stops[index]
        let fraction = (v - lowerAt) / max(upperAt - lowerAt, 0.0001)
        return Color(nsColor: lower.blended(withFraction: fraction, of: upper) ?? lower)
    }
    return Color(nsColor: .systemRed)
}

private func bytes(_ value: UInt64) -> String {
    compactSize(Double(value), base: 1024)
}

private func fileSize(_ value: Int64) -> String {
    compactSize(Double(max(0, value)), base: 1000)
}

private func memorySize(_ value: Int64) -> String {
    compactSize(Double(max(0, value)), base: 1024)
}

/// Sizes with three significant figures at most: "255 GB", "17.2 GB",
/// "9.78 GB", "405 MB". Long decimals make a dashboard look noisy.
private func compactSize(_ value: Double, base: Double) -> String {
    let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
    var amount = value
    var index = 0
    while amount >= 1000, index < units.count - 1 {
        amount /= base
        index += 1
    }
    if index == 0 { return "\(Int(amount)) bytes" }
    let format = amount >= 99.95 ? "%.0f" : (amount >= 9.995 ? "%.1f" : "%.2f")
    var text = String(format: format, amount)
    if text.contains(".") {
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
    }
    return "\(text) \(units[index])"
}

private func percent(_ value: Double?) -> String {
    value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
}

private func numericValue(_ text: String) -> Double? {
    if case let .measured(number, _) = HeroValueParts(text) { return Double(number.replacingOccurrences(of: ",", with: "")) }
    return nil
}

// MARK: - Overview

private struct OverviewPage: View {
    let snapshot: MacPulsePopoverSnapshot
    let statuses: SectionStatus
    let select: (AppSection) -> Void

    private var live: CommandCenterSample? { snapshot.commandCenter }
    private let identity = SystemIdentity.current

    private var heat: MacPulseHealthMetric? { snapshot.macHealthMetrics.first { $0.id == "heat" } }
    private var batteryHealth: MacPulseHealthMetric? { snapshot.macHealthMetrics.first { $0.id == "battery" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            IdentityBar(identity: identity, status: statuses.worst, concerns: statuses.concerns, select: select)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 520), spacing: 14)], spacing: 14) {
                cpuTile
                gpuTile
                memoryTile
                temperatureTile
                trafficTile
                speedTile
                wifiTile
                diskTile
                powerTile
                batteryTile
                systemTile
                devicesTile
            }

            EqualRow {
                Card(title: "Top apps", symbol: "square.stack.3d.up.fill", tint: .cyan) {
                    AppsList(apps: snapshot.cpuBreakdown?.apps ?? [], sortByMemory: false, limit: 6, showsFootnote: false)
                    Button("Show all apps") { select(.processes) }
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .medium))
                }
                Card(title: "Health", symbol: "heart.text.square.fill", tint: .red, status: statuses.status(for: .health)) {
                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.macHealthMetrics.enumerated()), id: \.element.id) { index, metric in
                            if index > 0 { Divider().opacity(0.4) }
                            HStack(spacing: 10) {
                                Image(systemName: metric.symbol)
                                    .foregroundStyle(metric.tone == .normal ? AnyShapeStyle(.secondary) : AnyShapeStyle(metric.tone.color))
                                    .frame(width: 20)
                                Text(metric.id == "reliability" ? "Stability" : metric.label)
                                Spacer()
                                Text(HealthRowFormatting.displayValue(for: metric))
                                    .foregroundStyle(metric.tone == .normal ? AnyShapeStyle(.secondary) : metric.tone.textStyle)
                            }
                            .font(.system(size: 13))
                            .padding(.vertical, 8)
                        }
                    }
                    Button("Open Health") { select(.health) }
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
    }

    // MARK: Tiles
    //
    // Every tile shares one anatomy so the grid reads as a single instrument
    // panel: header, hero value, one caption line, and a visual band of the
    // same height pinned to the bottom edge.

    private var cpuTile: some View {
        let status = statuses.status(for: .processors)
        return Tile(section: .processors, title: "CPU", status: status,
                    caption: status?.summary(for: .processors) ?? "Measuring…", select: select) {
            BigValue(value: percent(snapshot.cpu?.total), size: 32)
        } visual: {
            VStack(spacing: 8) {
                LiveGraph(points: snapshot.cpuHistory, window: CommandCenterSample.historyWindow, tint: .green, minimumSpan: 10,
                          valueGradient: (PerformanceMeterState.meterGradient, 0...100), fixedRange: 0...100)
                    .frame(height: 22)
                HStack(spacing: 3) {
                    ForEach(Array((snapshot.cpu?.groups ?? []).flatMap(\.usages).enumerated()), id: \.offset) { _, usage in
                        CoreMeter(usage: usage)
                    }
                }
                .frame(height: 32)
            }
        }
    }

    private var gpuTile: some View {
        Tile(section: .processors, title: "GPU", symbolOverride: "square.stack.3d.up.fill", status: nil,
             caption: snapshot.gpuCores.map { "\($0) graphics cores" }, select: select) {
            BigValue(value: percent(snapshot.gpuUsage), size: 32)
        } visual: {
            LiveGraph(points: snapshot.gpuHistory, window: CommandCenterSample.historyWindow, tint: .green, minimumSpan: 10,
                      valueGradient: (PerformanceMeterState.meterGradient, 0...100), fixedRange: 0...100)
        }
    }

    private var memoryTile: some View {
        let status = statuses.status(for: .memory)
        return Tile(section: .memory, status: status,
                    caption: [snapshot.memoryDetail, snapshot.memoryPressure.map { "\($0.displayName.lowercased()) pressure" }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    select: select) {
            BigValue(value: snapshot.memory, size: 32)
        } visual: {
            if let memory = live?.memory {
                VStack(alignment: .leading, spacing: 12) {
                    MemoryBar(memory: memory).frame(height: 10)
                    MemoryLegend(memory: memory, compact: true)
                }
            } else {
                LiveGraph(points: snapshot.memoryHistory, window: CommandCenterSample.historyWindow, tint: .purple, minimumSpan: 4)
            }
        }
    }

    private var temperatureTile: some View {
        Tile(section: .temperature, status: statuses.status(for: .temperature),
             caption: heat.map { HealthRowFormatting.displayValue(for: $0) + " today" }, select: select) {
            BigValue(value: snapshot.temperature, size: 32)
        } visual: {
            VStack(spacing: 10) {
                TemperatureScale(current: snapshot.temperatureCelsius, average: nil, peak: nil, compact: true)
                LiveGraph(points: snapshot.temperatureHistory, window: CommandCenterSample.historyWindow,
                          tint: snapshot.temperatureIsWarning ? .red : .orange, minimumSpan: 4)
            }
        }
    }

    private var trafficTile: some View {
        Tile(section: .network, title: "Traffic", symbolOverride: "arrow.up.arrow.down", status: nil,
             caption: "Download and upload across every app", select: select) {
            HStack(spacing: 18) {
                RateLabel(symbol: "arrow.down", color: .blue, text: CommandCenterFormatting.bitRate(live?.downloadBytesPerSecond ?? 0))
                RateLabel(symbol: "arrow.up", color: .pink, text: CommandCenterFormatting.bitRate(live?.uploadBytesPerSecond ?? 0))
            }
        } visual: {
            DualGraph(first: live?.downloadHistory ?? [], second: live?.uploadHistory ?? [],
                      firstTint: .blue, secondTint: .pink, floor: 125_000)
        }
    }

    private var speedTile: some View {
        Tile(section: .network, title: "Internet speed", symbolOverride: "speedometer", status: statuses.status(for: .network),
             caption: [snapshot.latencyMilliseconds.map { "\(Int($0.rounded())) ms latency" },
                       snapshot.lastMeasuredAt.map { "tested " + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }]
                .compactMap { $0 }.joined(separator: " · "),
             select: select) {
            BigValue(value: snapshot.download, size: 32)
        } visual: {
            LiveGraph(points: snapshot.downloadHistory, window: LiveGraph.downloadWindow, tint: .blue, minimumSpan: 20)
        }
    }

    private var wifiTile: some View {
        let wifi = live?.wifi
        let status = wifi.map { TileStatus(level: $0.bars >= 3 ? .good : ($0.bars == 2 ? .fair : .poor),
                                           explanation: "Wi‑Fi signal \($0.quality.lowercased()) · \($0.rssi) dBm") }
        let caption = wifi?.networkName
            ?? [live?.interfaceName, live?.localAddress].compactMap { $0 }.joined(separator: " · ")
        return Tile(section: .network, title: "Wi‑Fi", symbolOverride: "wifi", status: status,
                    caption: caption.isEmpty ? nil : caption, select: select) {
            HStack(alignment: .bottom, spacing: 10) {
                SignalBars(bars: wifi?.bars ?? 0, color: status?.color ?? .secondary).frame(width: 30, height: 26)
                Text(wifi?.quality ?? (live?.interfaceName != nil ? "Wired" : "Off"))
                    .font(.system(size: 28, weight: .semibold))
                    .kerning(-0.3)
                    .contentTransition(.opacity)
            }
        } visual: {
            if let wifi {
                MiniStats(items: [
                    ("Signal", "\(wifi.rssi) dBm"),
                    ("Link", "\(Int(wifi.transmitRateMbps)) Mbps"),
                    ("Band", [wifi.band, wifi.channel.map { "ch \($0)" }].compactMap { $0 }.joined(separator: " · "))
                ])
                .frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                Color.clear
            }
        }
    }

    private var diskTile: some View {
        let startup = live?.volumes.first(where: \.isStartup)
        return Tile(section: .storage, title: "Disk", status: statuses.status(for: .storage),
                    caption: startup.map { "\($0.name) · \(fileSize($0.availableBytes)) free" }, select: select) {
            HStack(spacing: 18) {
                RateLabel(symbol: "arrow.down.doc", color: .teal, text: CommandCenterFormatting.byteRate(live?.diskReadBytesPerSecond ?? 0))
                RateLabel(symbol: "square.and.pencil", color: .orange, text: CommandCenterFormatting.byteRate(live?.diskWriteBytesPerSecond ?? 0))
            }
        } visual: {
            VStack(spacing: 10) {
                DualGraph(first: live?.diskReadHistory ?? [], second: live?.diskWriteHistory ?? [],
                          firstTint: .teal, secondTint: .orange, floor: 1_000_000)
                UsageBar(fraction: startup?.usedFraction ?? 0).frame(height: 6)
            }
        }
    }

    private var powerTile: some View {
        Tile(section: .power, title: "Power", status: nil,
             caption: snapshot.adapterWatts.map { "Drawing from a \(Int($0.rounded())) W charger" } ?? "Running on battery",
             select: select) {
            BigValue(value: snapshot.powerUseWatts.map(PowerFormatting.watts) ?? "—", size: 32)
        } visual: {
            LiveGraph(points: snapshot.powerHistory, window: CommandCenterSample.historyWindow, tint: .green, minimumSpan: 10,
                      fixedRange: 0...max(snapshot.adapterWatts ?? 0, (snapshot.powerHistory.map(\.value).max() ?? 0) * 1.2, 20))
        }
    }

    private var batteryTile: some View {
        Tile(section: .power, title: "Battery", symbolOverride: "battery.100percent", status: statuses.status(for: .power),
             caption: snapshot.batteryTime == "—" ? nil : snapshot.batteryTime, select: select) {
            BigValue(value: snapshot.batteryPercentage, size: 32)
        } visual: {
            VStack(alignment: .leading, spacing: 12) {
                UsageBar(fraction: numericValue(snapshot.batteryPercentage).map { $0 / 100 } ?? 0, tint: .green).frame(height: 6)
                MiniStats(items: [
                    ("Health", batteryHealth.map { HealthRowFormatting.displayValue(for: $0) } ?? "—"),
                    ("Temperature", snapshot.batteryTemperatureCelsius.map { "\(Int($0.rounded())) °C" } ?? "—")
                ])
            }
        }
    }

    private var systemTile: some View {
        let thermal = CommandCenterFormatting.thermal(live?.thermalState ?? .nominal)
        let cores = snapshot.cpu?.groups.reduce(0) { $0 + $1.usages.count } ?? 0
        let load = live?.loadAverages.first
        return Tile(section: .devices, title: "System", symbolOverride: "gauge.with.dots.needle.33percent", status: nil,
                    caption: load.map { $0 < Double(max(cores, 1)) ? "Load average · nothing is waiting" : "Load average · tasks are queuing" },
                    select: select) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                BigValue(value: load.map { String(format: "%.1f", $0) } ?? "—", size: 32)
                if let loads = live?.loadAverages, loads.count == 3 {
                    Text(String(format: "%.1f · %.1f", loads[1], loads[2]))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } visual: {
            HStack(alignment: .bottom, spacing: 16) {
                MiniStat(label: "Processes", value: live.map { $0.processCount.formatted() } ?? "—")
                MiniStat(label: "Uptime", value: CommandCenterFormatting.uptime(since: identity.bootedAt))
                MiniStat(label: "Thermal", value: thermal.text, dot: TileStatus(level: thermal.level, explanation: "").color)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var devicesTile: some View {
        let accessories = live?.accessories ?? []
        let displays = NSScreen.screens.count
        return Tile(section: .devices, title: "Devices", status: statuses.status(for: .devices),
                    caption: "\(displays) display\(displays == 1 ? "" : "s") connected", select: select) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                BigValue(value: "\(accessories.count)", size: 32)
                Text(accessories.count == 1 ? "accessory" : "accessories")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
        } visual: {
            VStack(spacing: 8) {
                ForEach(accessories.prefix(2)) { accessory in
                    HStack(spacing: 8) {
                        Image(systemName: accessory.symbol).font(.system(size: 12)).frame(width: 18).foregroundStyle(.secondary)
                        Text(accessory.name).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 8)
                        UsageBar(fraction: Double(accessory.percent) / 100, tint: accessory.percent < 15 ? .orange : .green)
                            .frame(width: 44, height: 5)
                        Text("\(accessory.percent)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

}

// MARK: - Command center pieces

/// The command center's masthead: which Mac this is, how it's doing, and a
/// live heartbeat in the color of its worst concern.
private struct IdentityBar: View {
    let identity: SystemIdentity
    let status: TileStatus?
    let concerns: [Concern]
    let select: (AppSection) -> Void

    private var color: Color {
        concerns.first.map { TileStatus(level: $0.level, explanation: "").color } ?? .green
    }

    private var headline: String {
        switch concerns.first?.level {
        case .bad: return "Needs attention"
        case .poor: return concerns.count == 1 ? "1 thing to look at" : "\(concerns.count) things to look at"
        default: return "All systems normal"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(identity.computerName)
                    .font(.system(size: 30, weight: .bold))
                    .kerning(-0.5)
                    .lineLimit(1)
                Text([identity.modelName, identity.chip,
                      memorySize(Int64(identity.memoryBytes)),
                      identity.osVersion].joined(separator: "  ·  "))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Show as many concern chips as fit on one line; the count
                // chip always tells the whole story.
                ViewThatFits(in: .horizontal) {
                    chipRow(concernLimit: 3)
                    chipRow(concernLimit: 2)
                    chipRow(concernLimit: 1)
                    chipRow(concernLimit: 0)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Heartbeat(color: color)
                .frame(width: 260, height: 70)
        }
        .padding(.bottom, 4)
    }

    private func chipRow(concernLimit: Int) -> some View {
        HStack(spacing: 6) {
            Chip(dot: color, text: headline)
            Chip(symbol: "clock", text: "Up " + CommandCenterFormatting.uptime(since: identity.bootedAt))
            ForEach(concerns.prefix(concernLimit), id: \.self) { concern in
                ConcernRow(concern: concern) { select(concern.section) }
            }
        }
        .fixedSize()
    }
}

private struct Chip: View {
    var dot: Color?
    var symbol: String?
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                Circle().fill(dot).frame(width: 7, height: 7).shadow(color: dot.opacity(0.6), radius: 2)
            }
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            Text(text).contentTransition(.opacity).motion(text)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill((dot ?? .primary).opacity(dot == nil ? 0.07 : 0.16)))
        .overlay(Capsule().strokeBorder((dot ?? .primary).opacity(0.18), lineWidth: 0.5))
    }
}

/// An ECG trace that scrolls left; one beat per cycle.
private struct Heartbeat: View {
    let color: Color
    @Environment(\.graphsAreLive) private var isLive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isLive || reduceMotion)) { context in
            Canvas { graphics, size in
                let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                graphics.stroke(Self.path(in: size, phase: phase), with: .color(color),
                                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                                     .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .shadow(color: color.opacity(0.5), radius: 8)
        .animation(.easeInOut(duration: 0.6), value: color)
        .accessibilityHidden(true)
    }

    static func path(in size: CGSize, phase: Double) -> Path {
        var path = Path()
        let mid = size.height / 2
        let beatWidth = size.width / 2
        var x: CGFloat = -CGFloat(phase) * beatWidth
        var first = true
        let shape: [(CGFloat, CGFloat)] = [
            (0, 0), (0.30, 0), (0.36, -0.08), (0.40, 0), (0.46, 0.12),
            (0.50, -0.85), (0.54, 0.45), (0.58, 0), (0.70, -0.14), (0.78, 0), (1, 0)
        ]
        while x < size.width + beatWidth {
            for (fx, fy) in shape {
                let point = CGPoint(x: x + fx * beatWidth, y: mid + fy * size.height * 0.48)
                if first { path.move(to: point); first = false } else { path.addLine(to: point) }
            }
            x += beatWidth
        }
        return path
    }
}

/// A compact, clickable dashboard tile. Fixed proportions keep every tile in
/// the grid aligned: the hero values share a baseline row and the visual
/// bands share a bottom edge.
private struct Tile<Hero: View, Visual: View>: View {
    let section: AppSection
    var title: String?
    var symbolOverride: String?
    let status: TileStatus?
    var caption: String?
    let select: (AppSection) -> Void
    @ViewBuilder let hero: Hero
    @ViewBuilder let visual: Visual

    var body: some View {
        Button { select(section) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    SidebarBadge(section: section, symbolOverride: symbolOverride, size: 20)
                    Text(title ?? section.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let status {
                        Circle().fill(status.color).frame(width: 8, height: 8)
                            .shadow(color: status.color.opacity(0.55), radius: 2)
                            .help(status.explanation)
                            .motion(status.level.rawValue)
                    }
                }
                hero
                    .frame(height: 40, alignment: .leading)
                    .padding(.top, 12)
                Text(caption ?? " ")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .motion(caption ?? "")
                Spacer(minLength: 12)
                visual
                    .frame(maxWidth: .infinity)
                    .frame(height: 62, alignment: .bottom)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 214, maxHeight: 214, alignment: .topLeading)
            .background(CardSurface())
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(CardButtonStyle())
        .help("Show \(section.title)")
    }
}


private struct RateLabel: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(color)
            Text(text)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .motion(text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// Two live series on one shared scale, such as download and upload.
private struct DualGraph: View {
    let first: [MetricHistoryPoint]
    let second: [MetricHistoryPoint]
    let firstTint: Color
    let secondTint: Color
    /// The smallest top of the scale, so idle traffic doesn't look busy.
    let floor: Double
    var window: TimeInterval = CommandCenterSample.historyWindow

    var body: some View {
        let top = max(floor, ((first + second).map(\.value).max() ?? 0) * 1.2)
        ZStack {
            LiveGraph(points: first, window: window, tint: firstTint, minimumSpan: 1, fixedRange: 0...top)
            LiveGraph(points: second, window: window, tint: secondTint, minimumSpan: 1, fixedRange: 0...top)
        }
    }
}

private struct SignalBars: View {
    let bars: Int
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index <= bars ? AnyShapeStyle(color.gradient) : AnyShapeStyle(Color.primary.opacity(0.12)))
                    .frame(height: CGFloat(index) / 4 * 28)
            }
        }
        .animation(.smooth, value: bars)
        .accessibilityLabel("\(bars) of 4 bars")
    }
}

private struct UsageBar: View {
    let fraction: Double
    var tint: Color?

    var body: some View {
        ZStack {
            Capsule().fill(Color.primary.opacity(0.08))
            BarFill(fraction: min(1, max(0, fraction)))
                .fill((tint ?? (fraction >= 0.95 ? .red : fraction >= 0.85 ? .orange : .teal)).gradient)
        }
        .clipShape(Capsule())
        .animation(.smooth(duration: 0.8), value: fraction)
    }
}

private struct BarFill: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = max(rect.height, rect.width * CGFloat(fraction))
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                    cornerRadius: rect.height / 2, style: .continuous)
    }
}

private struct MiniStat: View {
    let label: String
    let value: String
    var dot: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                    .motion(value)
            }
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct MiniStats: View {
    let items: [(String, String)]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                MiniStat(label: item.0, value: item.1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Memory split the way Activity Monitor splits it.
private struct MemoryBar: View {
    let memory: MemoryBreakdown

    static func segments(_ memory: MemoryBreakdown) -> [(String, UInt64, Color)] {
        [("App", memory.appBytes, .purple), ("Wired", memory.wiredBytes, .pink),
         ("Compressed", memory.compressedBytes, .yellow), ("Cached", memory.cachedBytes, .teal)]
    }

    var body: some View {
        GeometryReader { proxy in
            let total = Double(max(memory.totalBytes, 1))
            HStack(spacing: 2) {
                ForEach(Self.segments(memory), id: \.0) { segment in
                    Rectangle()
                        .fill(segment.2.gradient)
                        .frame(width: max(2, (proxy.size.width - 8) * Double(segment.1) / total))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .animation(.smooth(duration: 0.8), value: memory)
    }
}

private struct MemoryLegend: View {
    let memory: MemoryBreakdown
    var compact = false

    var body: some View {
        let items = MemoryBar.segments(memory) + (compact ? [] : [("Free", memory.freeBytes, Color.primary.opacity(0.25))])
        HStack(alignment: .top, spacing: compact ? 12 : 22) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(item.2).frame(width: 7, height: 7)
                        Text(item.0).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text(bytes(item.1))
                        .font(.system(size: compact ? 12 : 15, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Connected displays, read live from AppKit.
private struct DisplaysSummary: View {
    var compact = false

    var body: some View {
        let screens = NSScreen.screens
        if compact {
            Label("\(screens.count) display\(screens.count == 1 ? "" : "s")", systemImage: "display")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(screens.enumerated()), id: \.offset) { _, screen in
                    HStack(spacing: 8) {
                        Image(systemName: "display").frame(width: 18).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(screen.localizedName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(DisplayFormatting.summary(screen)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

enum DisplayFormatting {
    @MainActor
    static func summary(_ screen: NSScreen) -> String {
        let scale = screen.backingScaleFactor
        let width = Int(screen.frame.width * scale), height = Int(screen.frame.height * scale)
        let hz = screen.maximumFramesPerSecond
        return "\(width) × \(height)" + (hz > 0 ? " · \(hz) Hz" : "")
    }
}

/// One concern: a colored dot and a sentence; clicking opens its page.
private struct ConcernRow: View {
    let concern: Concern
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let color = TileStatus(level: concern.level, explanation: "").color
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(concern.text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0.45)
                    .offset(x: hovering ? 1.5 : 0)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(hovering ? 0.22 : 0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Show \(concern.section.title)")
    }
}

// MARK: - Network

private struct NetworkPage: View {
    let snapshot: MacPulsePopoverSnapshot
    let status: TileStatus?
    let runTest: () -> Void

    private var live: CommandCenterSample? { snapshot.commandCenter }
    private var wifiStatus: TileStatus? {
        live?.wifi.map { TileStatus(level: $0.bars >= 3 ? .good : ($0.bars == 2 ? .fair : .poor),
                                    explanation: "Wi‑Fi signal \($0.quality.lowercased()) · \($0.rssi) dBm") }
    }

    private var lastTest: String {
        guard let date = snapshot.lastMeasuredAt else { return "No test yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last test " + formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom) {
                PageHeader(section: .network, value: snapshot.download,
                           subtitle: lastTest, status: status)
                Spacer()
                Button(action: runTest) {
                    Label(snapshot.isTesting ? "Testing…" : "Test Now", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 6)
                }
                .modifier(ProminentButton())
                .controlSize(.large)
                .disabled(snapshot.isTesting)
                .padding(.bottom, 12)
            }
            Card(title: "Download speed", symbol: "chart.xyaxis.line", tint: .blue) {
                ChartView(points: snapshot.downloadHistory, tint: .blue, minimumSpan: 20,
                          window: RecentMetricHistory.downloadRetention)
            }
            Card(title: "Live traffic", symbol: "arrow.up.arrow.down", tint: .blue) {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 2) {
                        RateLabel(symbol: "arrow.down", color: .blue, text: CommandCenterFormatting.bitRate(live?.downloadBytesPerSecond ?? 0))
                        Text("Downloading").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        RateLabel(symbol: "arrow.up", color: .pink, text: CommandCenterFormatting.bitRate(live?.uploadBytesPerSecond ?? 0))
                        Text("Uploading").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    MiniStat(label: "Received since connecting",
                             value: fileSize(Int64(clamping: live?.receivedSinceBootBytes ?? 0)))
                    MiniStat(label: "Sent since connecting",
                             value: fileSize(Int64(clamping: live?.sentSinceBootBytes ?? 0)))
                }
                DualGraph(first: live?.downloadHistory ?? [], second: live?.uploadHistory ?? [],
                          firstTint: .blue, secondTint: .pink, floor: 250_000)
                    .frame(height: 130)
                Text("Last 2 minutes · every app on this Mac").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            }
            EqualRow {
                Card(title: "Wi‑Fi", symbol: "wifi", tint: .blue, status: wifiStatus) {
                    if let wifi = live?.wifi {
                        HStack(spacing: 14) {
                            SignalBars(bars: wifi.bars, color: wifiStatus?.color ?? .green).frame(width: 38, height: 30)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(wifi.quality).font(.system(size: 24, weight: .semibold))
                                if let name = wifi.networkName {
                                    Text(name).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        MiniStats(items: [("Signal", "\(wifi.rssi) dBm"), ("Noise", "\(wifi.noise) dBm"),
                                          ("Signal to noise", "\(wifi.signalToNoise) dB")])
                        MiniStats(items: [("Link rate", "\(Int(wifi.transmitRateMbps)) Mbps"),
                                          ("Channel", wifi.channel.map(String.init) ?? "—"), ("Band", wifi.band ?? "—")])
                    } else {
                        BigValue(value: live?.interfaceName != nil ? "Wired" : "Off")
                        Text("Wi‑Fi isn't connected.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Card(title: "Connection", symbol: "network", tint: .blue) {
                    VStack(alignment: .leading, spacing: 14) {
                        MiniStat(label: "Local address", value: live?.localAddress ?? "—")
                        MiniStat(label: "Interface", value: live?.interfaceName.map { $0 == "en0" ? "\($0) · Wi‑Fi" : $0 } ?? "—")
                        MiniStat(label: "Latency", value: snapshot.latencyMilliseconds.map { "\(Int($0.rounded())) ms" } ?? "—")
                    }
                }
            }
            EqualRow {
                Card(title: "Latency", symbol: "timer", tint: .blue, status: status) {
                    BigValue(value: snapshot.latencyMilliseconds.map { "\(Int($0.rounded())) ms" } ?? "—")
                    Text(status?.explanation.components(separatedBy: " · ").last ?? "Checked every minute")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Card(title: "Data used today", symbol: "arrow.down.doc", tint: .blue) {
                    BigValue(value: fileSize(snapshot.usageTodayBytes))
                    Text("By Mac Pulse speed tests").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Card(title: "Test schedule", symbol: "clock", tint: .blue) {
                    BigValue(value: "Hourly")
                    Text("And when you open the menu, wake your Mac or change networks. Never on hotspots.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ProminentButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - CPU & GPU

private struct ProcessorsPage: View {
    let snapshot: MacPulsePopoverSnapshot
    let status: TileStatus?
    @State private var sortByMemory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(section: .processors, value: percent(snapshot.cpu?.total),
                       subtitle: "Across all \(snapshot.cpu?.groups.reduce(0) { $0 + $1.usages.count } ?? 0) CPU cores", status: status)
            Card(title: "CPU", symbol: "cpu", tint: .green) {
                ChartView(points: snapshot.cpuHistory, tint: .green, range: 0...100, zoneGradient: true,
                          labels: ["100%", "50%", "0%"])
            }
            HStack(alignment: .top, spacing: 16) {
                Card(title: "Cores", symbol: "square.grid.3x3.fill", tint: .green) {
                    CoreMap(groups: snapshot.cpu?.groups ?? [])
                }
                Card(title: "GPU", symbol: "square.stack.3d.up.fill", tint: .green) {
                    HStack(alignment: .firstTextBaseline) {
                        BigValue(value: percent(snapshot.gpuUsage))
                        if let cores = snapshot.gpuCores {
                            Text("\(cores) cores").foregroundStyle(.secondary)
                        }
                    }
                    ChartView(points: snapshot.gpuHistory, tint: .green, range: 0...100, zoneGradient: true,
                              labels: ["100%", "50%", "0%"], height: 110)
                }
            }
            if let live = snapshot.commandCenter {
                Card(title: "System load", symbol: "gauge.with.dots.needle.33percent", tint: .green) {
                    let thermal = CommandCenterFormatting.thermal(live.thermalState)
                    HStack(alignment: .top, spacing: 36) {
                        ForEach(Array(zip(["1 minute", "5 minutes", "15 minutes"], live.loadAverages)), id: \.0) { label, value in
                            VStack(alignment: .leading, spacing: 2) {
                                BigValue(value: String(format: "%.2f", value), size: 26)
                                Text("Load · \(label)").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Divider().frame(height: 40)
                        MiniStat(label: "Processes", value: "\(live.processCount)")
                        MiniStat(label: "Thermal state", value: thermal.text, dot: TileStatus(level: thermal.level, explanation: "").color)
                        Spacer(minLength: 0)
                    }
                    Text("Load is how many tasks are running or waiting. Below \(snapshot.cpu?.groups.reduce(0) { $0 + $1.usages.count } ?? 18), one per core, nothing is waiting.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Card(title: "Apps", symbol: "app.badge", tint: .green) {
                Picker("Sort by", selection: $sortByMemory) {
                    Text("CPU").tag(false)
                    Text("Memory").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                AppsList(apps: snapshot.cpuBreakdown?.apps ?? [], sortByMemory: sortByMemory)
            }
        }
    }
}

/// Every core as a slim level meter, grouped by tier. The color is pinned
/// to the scale — green at the bottom, red at the top — so a tall meter is
/// visibly hotter. Readings are smoothed, so the meters breathe gently.
private struct CoreMap: View {
    let groups: [CPUCoreGroup]

    var body: some View {
        if groups.isEmpty {
            Text("Measuring…").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.name).font(.system(size: 13, weight: .semibold))
                            Text("\(group.usages.count) cores").font(.system(size: 12)).foregroundStyle(.tertiary)
                            Spacer()
                            Text(percent(group.average))
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .motion(Int((group.average * 100).rounded()))
                        }
                        HStack(spacing: 6) {
                            ForEach(Array(group.usages.enumerated()), id: \.offset) { index, usage in
                                CoreMeter(usage: usage)
                                    .help("\(group.name) core \(index + 1): \(percent(usage))")
                            }
                        }
                        .frame(height: 64)
                    }
                }
            }
        }
    }
}

private struct CoreMeter: View {
    let usage: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One animatable shape inside its track: the level glides, but the
        // fill can never drift out of the capsule.
        ZStack {
            Capsule().fill(Color.primary.opacity(0.07))
            MeterFill(level: min(1, max(0.06, usage)))
                .fill(LinearGradient(gradient: PerformanceMeterState.meterGradient, startPoint: .bottom, endPoint: .top))
        }
        .clipShape(Capsule())
        .animation(reduceMotion ? nil : .smooth(duration: 0.9), value: usage)
        .frame(maxWidth: 22)
        .frame(maxWidth: .infinity)
    }
}

private struct MeterFill: Shape {
    var level: Double

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let height = rect.height * CGFloat(level)
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height),
                    cornerRadius: rect.width / 2, style: .continuous)
    }
}

/// An app's own icon, or a quiet symbol for processes without one.
private struct AppIconView: View {
    let bundlePath: String?
    var size: CGFloat = 20

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        if let bundlePath {
            Image(nsImage: Self.icon(for: bundlePath))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size * 0.86, height: size * 0.86)
                .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color.primary.opacity(0.08)))
                .frame(width: size, height: size)
        }
    }

    private static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

private struct AppsList: View {
    let apps: [TopCPUApp]
    let sortByMemory: Bool
    var limit = 8
    var showsFootnote = true

    private var rows: [TopCPUApp] {
        Array((sortByMemory ? apps.sorted { $0.memoryBytes > $1.memoryBytes } : apps).prefix(limit))
    }

    var body: some View {
        if apps.isEmpty {
            Text("Measuring…").foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { Divider().opacity(0.5) }
                    HStack(spacing: 12) {
                        AppIconView(bundlePath: app.bundlePath)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Capsule().fill(Color.primary.opacity(0.08)).frame(width: 140, height: 6)
                            .overlay(alignment: .leading) {
                                Capsule().fill(sortByMemory ? Color.purple : zoneColor(app.share * 3))
                                    .frame(width: max(6, 140 * min(1, sortByMemory
                                        ? Double(app.memoryBytes) / Double(max(rows.first?.memoryBytes ?? 1, 1))
                                        : app.share / max(rows.first?.share ?? 0.01, 0.01))), height: 6)
                                    .animation(.smooth(duration: 0.8), value: sortByMemory ? Double(app.memoryBytes) : app.share)
                            }
                        Text(percent(app.share)).frame(width: 48, alignment: .trailing).monospacedDigit()
                            .foregroundStyle(sortByMemory ? .secondary : .primary)
                            .contentTransition(.numericText())
                        Text(bytes(app.memoryBytes)).frame(width: 80, alignment: .trailing).monospacedDigit()
                            .foregroundStyle(sortByMemory ? .primary : .secondary)
                    }
                    .font(.system(size: 13))
                    .padding(.vertical, 7)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: rows.map(\.id))
                }
            }
            if showsFootnote {
                Text("Each app includes the processes it launched. Shares are of the whole processor.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Memory

private struct MemoryPage: View {
    let snapshot: MacPulsePopoverSnapshot
    let status: TileStatus?

    private var total: Double? { numericValue(snapshot.memoryDetail.replacingOccurrences(of: "of ", with: "")) }

    /// "Swap: 4.7 GB allocated · inactive …" → ("4.7 GB", false)
    private var swap: (amount: String, active: Bool)? {
        let detail = snapshot.performanceDetail.replacingOccurrences(of: "Swap: ", with: "")
        let parts = detail.components(separatedBy: " · ")
        guard parts.count >= 2, parts[0].hasSuffix(" allocated") else { return nil }
        return (parts[0].replacingOccurrences(of: " allocated", with: ""), !parts[1].hasPrefix("inactive"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(section: .memory, value: snapshot.memory,
                       subtitle: snapshot.memoryDetail.isEmpty ? nil : "In use \(snapshot.memoryDetail)", status: status)
            Card(title: "Memory in use", symbol: "chart.xyaxis.line", tint: .purple) {
                ChartView(points: snapshot.memoryHistory, tint: .purple, range: total.map { 0...$0 },
                          minimumSpan: 4, labels: total.map { ["\(Int($0)) GB", "\(Int($0 / 2)) GB", "0 GB"] } ?? [])
            }
            if let memory = snapshot.commandCenter?.memory {
                Card(title: "Where it's going", symbol: "chart.bar.xaxis", tint: .purple) {
                    MemoryBar(memory: memory).frame(height: 14)
                    MemoryLegend(memory: memory)
                    Text("App memory belongs to running apps. Wired memory is reserved by macOS. Compressed memory is squeezed to make room. Cached files are kept for speed and freed instantly when needed.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            EqualRow {
                Card(title: "Pressure", symbol: "gauge.with.dots.needle.67percent", tint: .purple, status: status) {
                    BigValue(value: snapshot.memoryPressure?.displayName ?? "—",
                             wordStyle: AnyShapeStyle(status?.color ?? .secondary))
                    Text("Pressure, not the amount in use, shows whether your Mac is short of memory. macOS keeps spare memory busy as a cache.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Card(title: "Swap", symbol: "arrow.left.arrow.right", tint: .purple) {
                    if let swap {
                        BigValue(value: swap.amount)
                        Text(swap.active ? "Moving memory to and from disk right now" : "Set aside on disk, not in use right now")
                            .font(.system(size: 12)).foregroundStyle(swap.active ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    } else {
                        Text(snapshot.performanceDetail)
                            .font(.system(size: 15, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Swap is memory moved to disk when RAM runs short.")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
            Card(title: "Apps by memory", symbol: "app.badge", tint: .purple) {
                AppsList(apps: snapshot.cpuBreakdown?.apps ?? [], sortByMemory: true)
            }
        }
    }
}

// MARK: - Battery & Power

private struct PowerPage: View {
    let snapshot: MacPulsePopoverSnapshot
    let status: TileStatus?

    private var level: Double? { numericValue(snapshot.batteryPercentage).map { $0 / 100 } }
    private var batteryMetric: MacPulseHealthMetric? { snapshot.macHealthMetrics.first { $0.id == "battery" } }
    private var charging: Double? {
        PowerRows.chargingWatts(flow: snapshot.batteryFlow, receiving: snapshot.powerInWatts, using: snapshot.powerUseWatts)
    }

    private var chargeState: (value: String, detail: String) {
        if let charging { return (PowerFormatting.watts(charging), "Going into the battery") }
        switch snapshot.batteryFlow {
        case .charged: return ("Full", "Running on charger power")
        case .pluggedIn: return ("On hold", "macOS is pausing charging to protect the battery")
        case .charging: return ("Charging", "Going into the battery")
        case .discharging: return ("On battery", "Plug in to charge")
        }
    }

    /// "100% · 6 cycles" → (100, "6 cycles")
    private var capacity: (percent: Double?, cycles: String?) {
        guard let metric = batteryMetric else { return (nil, nil) }
        let parts = HealthRowFormatting.displayValue(for: metric).components(separatedBy: " · ")
        return (parts.first.flatMap(numericValue), parts.count > 1 ? parts[1] : nil)
    }

    private var batteryWatts: Double? {
        guard let volts = snapshot.batteryVoltageMv, let amps = snapshot.batteryAmperageMa else { return nil }
        return volts / 1000 * amps / 1000
    }

    private func reading(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            BigValue(value: value ?? "—", size: 24)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(section: .power, value: snapshot.batteryPercentage,
                       subtitle: snapshot.batteryTime == "—" ? nil : snapshot.batteryTime, status: status)
            EqualRow {
                Card(title: "Using", symbol: "bolt.fill", tint: .green) {
                    BigValue(value: snapshot.powerUseWatts.map(PowerFormatting.watts) ?? "—")
                    Text("Power your Mac is drawing").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Card(title: "Supply", symbol: "powerplug.fill", tint: .green) {
                    BigValue(value: snapshot.powerInWatts != nil ? snapshot.adapterWatts.map(PowerFormatting.watts) ?? "—" : "—")
                    Text(snapshot.powerInWatts != nil ? "Most the charger can give" : "No charger connected")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Card(title: "Charging", symbol: "battery.100percent.bolt", tint: .green) {
                    BigValue(value: chargeState.value)
                    Text(chargeState.detail)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Card(title: "Power use", symbol: "chart.xyaxis.line", tint: .green) {
                let top = max(snapshot.adapterWatts ?? 0, (snapshot.powerHistory.map(\.value).max() ?? 0) * 1.2, 20)
                ChartView(points: snapshot.powerHistory, tint: .green, range: 0...top,
                          labels: ["\(Int(top)) W", "\(Int(top / 2)) W", "0 W"])
            }
            Card(title: "Inside the battery", symbol: "battery.100percent", tint: .green) {
                HStack(alignment: .top, spacing: 40) {
                    reading("Temperature", snapshot.batteryTemperatureCelsius.map { String(format: "%.1f °C", $0) })
                    reading("Voltage", snapshot.batteryVoltageMv.map { String(format: "%.2f V", $0 / 1000) })
                    reading("Current", snapshot.batteryAmperageMa.map { "\(Int($0.rounded())) mA" })
                    reading("Battery power", batteryWatts.map { String(format: "%+.1f W", $0) })
                    Spacer(minLength: 0)
                }
                Text("Positive current and power mean the battery is charging; negative means it's powering the Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Card(title: "Battery health", symbol: "heart.fill", tint: .green) {
                HStack(alignment: .firstTextBaseline, spacing: 40) {
                    VStack(alignment: .leading, spacing: 2) {
                        BigValue(value: capacity.percent.map { "\(Int($0))%" } ?? "—")
                        Text("Maximum capacity").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if let cycles = capacity.cycles {
                        VStack(alignment: .leading, spacing: 2) {
                            BigValue(value: cycles)
                            Text("Charge cycles").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                CapacityBar(capacity: (capacity.percent ?? 0) / 100)
                    .padding(.top, 4)
            }
        }
    }
}

/// Battery capacity against Apple's 80% service mark.
private struct CapacityBar: View {
    let capacity: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule()
                        .fill(LinearGradient(colors: [capacity >= 0.8 ? .green.opacity(0.7) : .orange.opacity(0.7),
                                                      capacity >= 0.8 ? .green : .orange],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, width * min(1, capacity)))
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 1.5, height: 16)
                        .offset(x: width * 0.8 - 0.75)
                }
            }
            .frame(height: 8)
            GeometryReader { proxy in
                Text("Service recommended below 80%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .frame(width: proxy.size.width * 0.8, alignment: .trailing)
            }
            .frame(height: 14)
        }
    }
}

// MARK: - Temperature

private struct TemperaturePage: View {
    let snapshot: MacPulsePopoverSnapshot
    let status: TileStatus?

    private var heat: MacPulseHealthMetric? { snapshot.macHealthMetrics.first { $0.id == "heat" } }

    private func today(_ pattern: String) -> Double? {
        guard let detail = heat?.detail,
              let match = detail.range(of: pattern, options: .regularExpression) else { return nil }
        return Double(detail[match].prefix { $0.isNumber })
    }
    private var average: Double? { today("[0-9]+° avg") }
    private var peak: Double? { today("[0-9]+° peak") }
    private var hotMinutes: Double? { today("[0-9]+m ≥90°") }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(section: .temperature, value: snapshot.temperature,
                       subtitle: heat.map { HealthRowFormatting.displayValue(for: $0) + " today" }, status: status)
            Card(title: "Processor temperature", symbol: "chart.xyaxis.line", tint: .orange) {
                ChartView(points: snapshot.temperatureHistory, tint: snapshot.temperatureIsWarning ? .red : .orange,
                          range: 30...105, labels: ["105°", "68°", "30°"])
            }
            Card(title: "Where it sits", symbol: "thermometer.variable", tint: .orange) {
                TemperatureScale(current: snapshot.temperatureCelsius, average: average, peak: peak)
                Text("Apple silicon is designed to run warm. macOS only slows things down to cool off from about 90 °C.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            EqualRow {
                Card(title: "Today", symbol: "calendar", tint: .orange) {
                    HStack(alignment: .firstTextBaseline, spacing: 36) {
                        stat(average.map { "\(Int($0)) °C" } ?? "—", "Average")
                        stat(peak.map { "\(Int($0)) °C" } ?? "—", "Peak")
                        stat(hotMinutes.map { $0 == 0 ? "None" : "\(Int($0)) min" } ?? "—", "Above 90 °C")
                        Spacer(minLength: 0)
                    }
                }
                if !snapshot.fanRPMs.isEmpty {
                    Card(title: "Fans", symbol: "fan.fill", tint: .orange) {
                        BigValue(value: snapshot.fanRPMs.map { Int($0.rounded()).formatted() }.joined(separator: " · ") + " rpm")
                    }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            BigValue(value: value, size: 28)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// A thermometer laid on its side: relaxed, working hard and cooling-down
/// zones, with today's average and peak marked and the current reading
/// as a glowing marker.
private struct TemperatureScale: View {
    let current: Double?
    let average: Double?
    let peak: Double?
    /// A slim version for dashboard tiles: just the bar and the marker.
    var compact = false
    private let range = 30.0...105.0

    private func x(_ value: Double, _ width: CGFloat) -> CGFloat {
        width * CGFloat((min(range.upperBound, max(range.lowerBound, value)) - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(stops: [
                            .init(color: .green, location: 0),
                            .init(color: .green, location: x(68, 1)),
                            .init(color: .yellow, location: x(80, 1)),
                            .init(color: .orange, location: x(88, 1)),
                            .init(color: .red, location: x(93, 1)),
                            .init(color: .red, location: 1)
                        ], startPoint: .leading, endPoint: .trailing))
                        .opacity(0.32)
                        .frame(height: compact ? 8 : 10)
                    if let average { tick(at: x(average, width), label: "avg") }
                    if let peak { tick(at: x(peak, width), label: "peak") }
                    if let current {
                        Circle()
                            .fill(.white)
                            .frame(width: compact ? 14 : 18, height: compact ? 14 : 18)
                            .overlay(Circle().fill(zoneColor(max(0, (current - 40) / 60))).padding(compact ? 3 : 4))
                            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                            .offset(x: x(current, width) - (compact ? 7 : 9))
                            .animation(.smooth(duration: 0.8), value: current)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: compact ? 16 : 34)
            .padding(.top, compact ? 0 : 12)
            if !compact {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .topLeading) {
                        zoneLabel("Relaxed", from: 30, to: 75, width: width)
                        zoneLabel("Working hard", from: 75, to: 90, width: width)
                        zoneLabel("Cooling down", from: 90, to: 105, width: width)
                    }
                }
                .frame(height: 14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Temperature")
        .accessibilityValue(current.map { "\(Int($0.rounded())) degrees" } ?? "Unknown")
    }

    private func tick(at position: CGFloat, label: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).fixedSize()
            Capsule().fill(Color.primary.opacity(0.45)).frame(width: 2, height: 16)
        }
        .frame(width: 40)
        .offset(x: position - 20, y: -9)
    }

    private func zoneLabel(_ text: String, from: Double, to: Double, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: x(to, width) - x(from, width))
            .offset(x: x(from, width))
    }
}

// MARK: - Health

// MARK: - Storage

private struct StoragePage: View {
    let snapshot: MacPulsePopoverSnapshot
    let status: TileStatus?

    private var live: CommandCenterSample? { snapshot.commandCenter }
    private var startup: VolumeDetails? { live?.volumes.first(where: \.isStartup) }
    private var ssd: MacPulseHealthMetric? { snapshot.macHealthMetrics.first { $0.id == "storage" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(section: .storage,
                       value: startup.map { fileSize($0.availableBytes) } ?? "—",
                       subtitle: startup.map { "Free of \(fileSize($0.totalBytes)) on \($0.name)" },
                       status: status)
            Card(title: "Disk activity", symbol: "chart.xyaxis.line", tint: .teal) {
                HStack(spacing: 28) {
                    VStack(alignment: .leading, spacing: 2) {
                        RateLabel(symbol: "arrow.down.doc", color: .teal, text: CommandCenterFormatting.byteRate(live?.diskReadBytesPerSecond ?? 0))
                        Text("Reading").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        RateLabel(symbol: "square.and.pencil", color: .orange, text: CommandCenterFormatting.byteRate(live?.diskWriteBytesPerSecond ?? 0))
                        Text("Writing").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                DualGraph(first: live?.diskReadHistory ?? [], second: live?.diskWriteHistory ?? [],
                          firstTint: .teal, secondTint: .orange, floor: 5_000_000)
                    .frame(height: 150)
                Text("Last 2 minutes").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            }
            Card(title: "Volumes", symbol: "externaldrive.fill", tint: .teal) {
                if let volumes = live?.volumes, !volumes.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(volumes.enumerated()), id: \.element.id) { index, volume in
                            if index > 0 { Divider().opacity(0.4) }
                            HStack(spacing: 14) {
                                Image(systemName: volume.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.teal.gradient)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(volume.name).font(.system(size: 14, weight: .semibold))
                                        if volume.isStartup {
                                            Text("Startup").font(.system(size: 10, weight: .semibold))
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                        }
                                        Spacer()
                                        Text("\(fileSize(volume.availableBytes)) free of \(fileSize(volume.totalBytes))")
                                            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    UsageBar(fraction: volume.usedFraction).frame(height: 8)
                                }
                            }
                            .padding(.vertical, 10)
                        }
                    }
                } else {
                    Text("Measuring…").foregroundStyle(.secondary)
                }
            }
            if let ssd {
                Card(title: "SSD health", symbol: "checkmark.seal.fill", tint: .teal) {
                    Text(ssd.detail.replacingOccurrences(of: "Storage: ", with: ""))
                        .font(.system(size: 14, weight: .medium))
                    Text("From the drive's own SMART report. “Verified” means it reports no errors.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Apps

private struct AppsPage: View {
    let snapshot: MacPulsePopoverSnapshot
    @State private var sortOrder = [KeyPathComparator(\TopCPUApp.share, order: .reverse)]
    @State private var search = ""
    @State private var selection: TopCPUApp.ID?

    private var apps: [TopCPUApp] { snapshot.cpuBreakdown?.apps ?? [] }
    private var rows: [TopCPUApp] {
        let filtered = search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Chip(symbol: "square.stack.3d.up", text: "\(apps.count) apps")
                Chip(symbol: "gearshape.2", text: "\(snapshot.commandCenter?.processCount ?? 0) processes")
                Chip(symbol: "cpu", text: "CPU \(percent(snapshot.cpu?.total))")
                Chip(symbol: "memorychip", text: "Memory \(snapshot.memory)")
                Spacer()
                Text("Each app includes the processes it launched.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("App", value: \.name) { app in
                    HStack(spacing: 10) {
                        AppIconView(bundlePath: app.bundlePath, size: 20)
                        Text(app.name).lineLimit(1)
                    }
                }
                TableColumn("CPU", value: \.share) { app in
                    HStack(spacing: 10) {
                        UsageBar(fraction: app.share / max(apps.first?.share ?? 0.01, 0.01), tint: zoneColor(app.share * 3))
                            .frame(height: 5)
                        Text(String(format: "%.1f%%", app.share * 100))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                .width(min: 160, ideal: 220)
                TableColumn("Memory", value: \.memoryBytes) { app in
                    Text(bytes(app.memoryBytes)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 90, ideal: 110)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: TopCPUApp.ID.self) { ids in
                if let id = ids.first, let app = apps.first(where: { $0.id == id }), let path = app.bundlePath {
                    Button("Quit \(app.name)") { AppActions.quit(bundlePath: path) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
            }
            .overlay {
                if apps.isEmpty { ProgressView("Measuring…") }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
    }
}

enum AppActions {
    /// Asks the app to quit normally, so it can save its work.
    @MainActor
    static func quit(bundlePath: String) {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleURL?.path == bundlePath }
            .forEach { $0.terminate() }
    }
}

// MARK: - Devices

private struct DevicesPage: View {
    let snapshot: MacPulsePopoverSnapshot
    let status: TileStatus?
    private let identity = SystemIdentity.current

    private var cores: String {
        let groups = snapshot.cpu?.groups ?? []
        guard !groups.isEmpty else { return "—" }
        return groups.reversed().map { "\($0.usages.count) \($0.name)" }.joined(separator: " + ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 24) {
                // The Mac's own artwork, as in About This Mac.
                Image(nsImage: NSImage(named: NSImage.computerName) ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                PageHeader(section: .devices, value: identity.computerName, subtitle: identity.modelName, status: status)
            }
            Card(title: "This Mac", symbol: "laptopcomputer", tint: .gray) {
                Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 14) {
                    GridRow {
                        spec("Chip", identity.chip)
                        spec("Memory", memorySize(Int64(identity.memoryBytes)))
                        spec("macOS", identity.osVersion)
                    }
                    GridRow {
                        spec("CPU cores", cores)
                        spec("GPU cores", snapshot.gpuCores.map(String.init) ?? "—")
                        spec("Uptime", CommandCenterFormatting.uptime(since: identity.bootedAt))
                    }
                    GridRow {
                        spec("Startup disk", snapshot.commandCenter?.volumes.first(where: \.isStartup)
                            .map { "\($0.name) · \(fileSize($0.totalBytes))" } ?? "—")
                        spec("Model identifier", CommandCenterReaders.sysctlString("hw.model") ?? "—")
                        spec("Last started", identity.bootedAt.map {
                            $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        } ?? "—")
                    }
                }
            }
            EqualRow {
                Card(title: "Displays", symbol: "display", tint: .gray) {
                    DisplaysSummary()
                }
                Card(title: "Accessories", symbol: "keyboard.fill", tint: .gray, status: status) {
                    let accessories = snapshot.commandCenter?.accessories ?? []
                    if accessories.isEmpty {
                        Text("No Bluetooth accessories are reporting a battery level.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(accessories) { accessory in
                                HStack(spacing: 10) {
                                    Image(systemName: accessory.symbol).frame(width: 22).foregroundStyle(.secondary)
                                    Text(accessory.name).font(.system(size: 13))
                                    Spacer()
                                    UsageBar(fraction: Double(accessory.percent) / 100, tint: accessory.percent < 15 ? .orange : .green)
                                        .frame(width: 90, height: 6)
                                    Text("\(accessory.percent)%").font(.system(size: 13, weight: .medium)).monospacedDigit()
                                        .frame(width: 40, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func spec(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
        }
    }
}

private struct HealthPage: View {
    let snapshot: MacPulsePopoverSnapshot
    let status: TileStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(section: .health,
                       value: headline,
                       subtitle: snapshot.macHealthDetail, status: status)
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.macHealthMetrics.enumerated()), id: \.element.id) { index, metric in
                        if index > 0 { Divider().opacity(0.5) }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: metric.symbol)
                                .foregroundStyle(metric.tone == .normal ? AnyShapeStyle(.secondary) : AnyShapeStyle(metric.tone.color))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(metric.id == "reliability" ? "Stability" : metric.label)
                                    .font(.system(size: 14, weight: .semibold))
                                if let detail = friendlyDetail(metric) {
                                    Text(detail)
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(HealthRowFormatting.displayValue(for: metric))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(metric.tone == .normal ? AnyShapeStyle(.secondary) : metric.tone.textStyle)
                        }
                        .padding(.vertical, 12)
                    }
                }
            }
            if let signature = snapshot.panicSignature {
                Card(title: "Latest kernel panic", symbol: "exclamationmark.triangle.fill", tint: .orange) {
                    Text(signature).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
                    if let classification = snapshot.panicClassification {
                        Text(classification).foregroundStyle(.secondary)
                    }
                    if let context = snapshot.panicTaskContext {
                        Text(context).font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// The pill already says how things are; the headline says how many need a look.
    private var headline: String {
        let concerns = snapshot.macHealthMetrics.filter { $0.tone != .normal }.count
        switch concerns {
        case 0: return "All good"
        case 1: return "1 to look at"
        default: return "\(concerns) to look at"
        }
    }

    /// The detail line in plain words, or nil when it only repeats the value.
    private func friendlyDetail(_ metric: MacPulseHealthMetric) -> String? {
        var detail = metric.detail
        detail = detail.replacingOccurrences(of: " · 0m ≥90°", with: " · never above 90°")
        detail = detail.replacingOccurrences(of: "([0-9]+)m ≥90°", with: "$1 min above 90°", options: .regularExpression)
        detail = detail.replacingOccurrences(of: "([0-9]+)m thermal pressure", with: "$1 min slowed to cool", options: .regularExpression)
        return detail == HealthRowFormatting.displayValue(for: metric) ? nil : detail
    }
}

// MARK: - Settings

private struct SettingsPage: View {
    let snapshot: MacPulsePopoverSnapshot
    let actions: MacPulsePopoverModel.Actions

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { snapshot.launchAtLogin }, set: { _ in actions.toggleLaunchAtLogin() })) {
                    settingLabel("Open at login", "Start Mac Pulse in the menu bar when you log in.")
                }
                Toggle(isOn: Binding(get: { snapshot.lidClosedOperation }, set: { _ in actions.toggleLidClosedOperation() })) {
                    settingLabel("Clamshell",
                                 "Keeps your Mac running with the lid closed while it's on power. Asks for an administrator password.")
                }
                .disabled(!snapshot.lidClosedOperationAvailable)
            } header: {
                SettingsHeader(title: "This Mac", section: .power)
            }

            Section {
                LabeledContent {
                    Button("Open…") { actions.openActivityMonitor() }
                } label: {
                    settingLabel("Activity Monitor", "See every process running on your Mac.")
                }
                LabeledContent {
                    Button("Quit", role: .destructive) { actions.quit() }
                } label: {
                    settingLabel("Quit Mac Pulse", "Removes Mac Pulse from the menu bar until you open it again.")
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private func settingLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct SettingsHeader: View {
    let title: String
    let section: AppSection

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
