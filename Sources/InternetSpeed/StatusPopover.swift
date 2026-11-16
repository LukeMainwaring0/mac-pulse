import AppKit
import SwiftUI

enum MacPulseStatusTone: Equatable {
    case normal
    case attention
    case critical

    var color: Color {
        switch self {
        case .normal: return .green
        case .attention: return .orange
        case .critical: return .red
        }
    }

    /// Text only takes a status color when it needs attention.
    var textStyle: AnyShapeStyle {
        switch self {
        case .normal: return AnyShapeStyle(.secondary)
        case .attention: return AnyShapeStyle(Color.orange)
        case .critical: return AnyShapeStyle(Color.red)
        }
    }
}

struct MacPulseHealthMetric: Equatable, Identifiable {
    let id: String
    let label: String
    let detail: String
    let symbol: String
    let tone: MacPulseStatusTone
}

struct MacPulsePopoverSnapshot: Equatable {
    var download = "—"
    var memory = "—"
    var memoryDetail = ""
    var batteryPercentage = "—"
    var batteryTime = "—"
    var batteryTimeTone = MacPulseStatusTone.normal
    var batteryFlow = BatteryFlow.discharging
    /// Watts the Mac is using, and watts arriving from a charger.
    var powerUseWatts: Double?
    var powerInWatts: Double?
    var adapterWatts: Double?
    var temperature = "—"
    var temperatureIsWarning = false
    /// Current processor temperature, for the Temperature tile's status dot.
    var temperatureCelsius: Double?
    /// Timestamped readings; graphs place them by time so they can scroll.
    var downloadHistory: [MetricHistoryPoint] = []
    var memoryHistory: [MetricHistoryPoint] = []
    var temperatureHistory: [MetricHistoryPoint] = []

    var performance = "Checking…"
    var performanceDetail = "Collecting a system sample"
    var topMemory = "—"
    var performanceTone = MacPulseStatusTone.normal
    var performanceLevel = 0.25
    /// Per-core CPU use, grouped by tier. Nil until two samples exist.
    var cpu: CPUActivity?
    /// Smoothed total CPU history, 0–100.
    var cpuHistory: [MetricHistoryPoint] = []
    /// Smoothed GPU utilization, 0–1, and its core count.
    var gpuUsage: Double?
    var gpuCores: Int?
    /// CPU by app (credited to the responsible app) plus the hidden system share.
    var cpuBreakdown: CPUBreakdown?
    /// Histories for the full app's charts.
    var gpuHistory: [MetricHistoryPoint] = []
    var powerHistory: [MetricHistoryPoint] = []
    /// Speed-test data used today, and when the last test finished.
    var usageTodayBytes: Int64 = 0
    var lastMeasuredAt: Date?
    /// macOS memory pressure; the honest answer to "is memory a problem?".
    var memoryPressure: ResourcePressureLevel?
    /// Round-trip time measured by the latest speed test.
    var latencyMilliseconds: Double?
    /// Live detail for the full app; nil while only the panel is open.
    var commandCenter: CommandCenterSample?
    var batteryTemperatureCelsius: Double?
    var batteryVoltageMv: Double?
    var batteryAmperageMa: Double?
    /// Measured fan speeds only. Empty when the Mac does not report them.
    var fanRPMs: [Double] = []

    var macHealth = "Checking…"
    var macHealthDetail = "Checking battery, storage, heat and reliability"
    var macHealthTone = MacPulseStatusTone.normal
    var macHealthMetrics: [MacPulseHealthMetric] = []
    var panicSignature: String?
    var panicClassification: String?
    var panicTaskContext: String?

    var isTesting = false
    var isOffline = false
    var launchAtLogin = false
    var lidClosedOperation = false
    var lidClosedOperationAvailable = false
    var errorMessage: String?

    static func value(in titledValue: String, after label: String) -> String {
        let prefix = "\(label): "
        guard titledValue.hasPrefix(prefix) else { return titledValue }
        return String(titledValue.dropFirst(prefix.count))
    }
}

@MainActor
final class MacPulsePopoverModel: ObservableObject {
    struct Actions {
        var runFullTest: () -> Void = {}
        var toggleLaunchAtLogin: () -> Void = {}
        var toggleLidClosedOperation: () -> Void = {}
        var quit: () -> Void = {}
        var openApp: () -> Void = {}
        var openActivityMonitor: () -> Void = {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    @Published var snapshot = MacPulsePopoverSnapshot()
    /// True while the panel is on screen; graphs animate only then.
    @Published var isVisible = false
    var actions = Actions()
}

/// Layout constants shared by every section so spacing stays on one grid.
/// Everything sits on a 4 pt rhythm, and every corner is concentric with the
/// 24 pt glass panel: inner radius = panel radius − padding.
private enum PopoverMetrics {
    static let width: CGFloat = 340
    static let outerPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 8
    static let tileRadius: CGFloat = MenuBarPanel.cornerRadius - outerPadding
    static let tilePadding: CGFloat = 10
    static let rowPadding = EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
    static let iconWidth: CGFloat = 16
    static let graphHeight: CGFloat = 20
}

/// Subtle grouping inside the native menu; the menu owns the outer material.
private struct TileBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PopoverMetrics.tileRadius, style: .continuous)
        let dark = colorScheme == .dark
        content
            .background(Color.white.opacity(dark ? 0.075 : 0.42), in: shape)
            .overlay {
                shape.strokeBorder(Color.white.opacity(dark ? 0.12 : 0.6), lineWidth: 0.5)
            }
    }
}

private extension View {
    func tileBackground() -> some View { modifier(TileBackground()) }
}

/// Spring used for every value change; disabled when Reduce Motion is on.
struct MotionAnimation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: AnyHashable

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: value)
    }
}

extension View {
    func motion<V: Hashable>(_ value: V) -> some View { modifier(MotionAnimation(value: AnyHashable(value))) }
}

struct MacPulsePopoverView: View {
    @ObservedObject var model: MacPulsePopoverModel

    private var snapshot: MacPulsePopoverSnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverMetrics.sectionSpacing) {
            header
                .padding(.bottom, 2)
            if let errorMessage = snapshot.errorMessage {
                ErrorBanner(message: errorMessage)
            }
            metricGrid
            CPUTile(
                cpu: snapshot.cpu,
                gpuUsage: snapshot.gpuUsage,
                gpuCores: snapshot.gpuCores,
                history: snapshot.cpuHistory,
                level: snapshot.performanceLevel,
                hasSample: snapshot.performance != MacPulsePopoverSnapshot().performance,
                fanRPMs: snapshot.fanRPMs
            )
            MacHealthSection(
                status: snapshot.macHealth,
                tone: snapshot.macHealthTone,
                metrics: snapshot.macHealthMetrics,
                panicSignature: snapshot.panicSignature,
                panicClassification: snapshot.panicClassification,
                panicTaskContext: snapshot.panicTaskContext
            )
            settings
            footer
                .padding(.horizontal, -4)
        }
        .padding(PopoverMetrics.outerPadding)
        .frame(width: PopoverMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .motion(snapshot.errorMessage)
        .environment(\.graphsAreLive, model.isVisible)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Mac Pulse")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button {
                model.actions.openApp()
            } label: {
                HStack(spacing: 4) {
                    Text("Open")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .buttonStyle(OpenAppButtonStyle())
            .help("Open the full Mac Pulse app")
            .keyboardShortcut("o")
        }
        .padding(.leading, PopoverMetrics.rowPadding.leading)
        .padding(.trailing, 2)
    }

    private var metricGrid: some View {
        Grid(horizontalSpacing: PopoverMetrics.sectionSpacing, verticalSpacing: PopoverMetrics.sectionSpacing) {
            GridRow {
                MetricTile(
                    title: "Download",
                    symbol: "arrow.down.circle.fill",
                    tint: .blue,
                    value: snapshot.download,
                    detail: snapshot.isTesting ? "Testing…" : nil,
                    status: TileStatusRules.connection(latency: snapshot.latencyMilliseconds, isOffline: snapshot.isOffline),
                    help: snapshot.lastMeasuredAt.map { "Tested " + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) },
                    history: snapshot.downloadHistory,
                    window: LiveGraph.downloadWindow,
                    minimumGraphSpan: 10
                )
                MetricTile(
                    title: "Memory",
                    symbol: "memorychip.fill",
                    tint: .purple,
                    value: snapshot.memory,
                    detail: snapshot.memoryDetail.isEmpty ? nil : snapshot.memoryDetail,
                    status: snapshot.memoryPressure.flatMap(TileStatusRules.memory),
                    help: snapshot.topMemory == "—" ? nil : "Most memory: \(snapshot.topMemory)",
                    history: snapshot.memoryHistory,
                    window: LiveGraph.systemWindow,
                    minimumGraphSpan: 4
                )
            }
            GridRow {
                BatteryTile(
                    percentage: snapshot.batteryPercentage,
                    time: snapshot.batteryTime,
                    tone: snapshot.batteryTimeTone,
                    flow: snapshot.batteryFlow,
                    powerUse: snapshot.powerUseWatts,
                    powerIn: snapshot.powerInWatts,
                    adapterWatts: snapshot.adapterWatts
                )
                MetricTile(
                    title: "Temperature",
                    symbol: "thermometer.medium",
                    tint: snapshot.temperatureIsWarning ? .red : .orange,
                    value: snapshot.temperature,
                    detail: snapshot.temperatureIsWarning ? "High" : nil,
                    detailTone: snapshot.temperatureIsWarning ? .critical : .normal,
                    caption: heatToday,
                    status: snapshot.temperatureCelsius.map(TileStatusRules.temperature),
                    history: snapshot.temperatureHistory,
                    window: LiveGraph.systemWindow,
                    minimumGraphSpan: 5
                )
            }
        }
    }

    /// Today's average and peak, moved here from Mac Health so heat lives in
    /// one place. Turns orange when sustained heat is a health issue.
    private var heatToday: (text: String, tone: MacPulseStatusTone)? {
        guard let heat = snapshot.macHealthMetrics.first(where: { $0.id == "heat" }),
              heat.detail != "Checking…" else { return nil }
        return ("\(HealthRowFormatting.displayValue(for: heat)) today", heat.tone)
    }

    /// Control Center style: one round toggle per setting, with a short label.
    private var settings: some View {
        HStack(alignment: .top, spacing: 0) {
            ControlToggle(
                title: snapshot.isTesting ? "Testing…" : "Test now",
                symbol: "arrow.clockwise",
                isOn: snapshot.isTesting,
                onColor: .blue,
                help: "Measure your internet speed now"
            ) { model.actions.runFullTest() }
            ControlToggle(
                title: "At login",
                symbol: "power",
                isOn: snapshot.launchAtLogin,
                onColor: .blue,
                help: snapshot.launchAtLogin ? "Mac Pulse opens at login" : "Open Mac Pulse at login"
            ) { model.actions.toggleLaunchAtLogin() }
            ControlToggle(
                title: "Clamshell",
                symbol: "macpulse.clamshell",
                isOn: snapshot.lidClosedOperation,
                onColor: .blue,
                help: snapshot.lidClosedOperation
                    ? "Stays awake with the lid closed. Turning this off asks for an administrator password."
                    : "Stay awake with the lid closed while on power. Asks for an administrator password."
            ) { model.actions.toggleLidClosedOperation() }
            .disabled(!snapshot.lidClosedOperationAvailable)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .tileBackground()
    }

    private var footer: some View {
        HStack(spacing: 4) {
            FooterLink(title: "Activity Monitor…", symbol: "waveform.path.ecg.rectangle") {
                model.actions.openActivityMonitor()
            }
            Spacer()
            FooterLink(title: "Quit", symbol: "rectangle.portrait.and.arrow.right", shortcut: "⌘Q") { model.actions.quit() }
                .keyboardShortcut("q")
        }
    }
}

/// A small capsule like the "Open" buttons in macOS widgets: tinted with the
/// accent color, brighter on hover, pressed in when clicked.
private struct OpenAppButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.accentColor)
            .background(
                Capsule().fill(Color.accentColor.opacity(configuration.isPressed ? 0.28 : (isHovering ? 0.22 : 0.15)))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A round toggle like the ones in Control Center: the circle fills with
/// color when on, the icon turns white, and it presses in when clicked.
private struct ControlToggle: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let onColor: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ControlCircle(symbol: symbol, isOn: isOn, onColor: onColor)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlPressStyle())
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .motion(isOn)
        .motion(title)
    }
}

private struct ControlCircle: View {
    let symbol: String
    let isOn: Bool
    let onColor: Color
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder private var controlIcon: some View {
        if symbol == "macpulse.clamshell" {
            ClamshellIcon()
                .fill(style: FillStyle(eoFill: true))
                .frame(width: 23, height: 21)
                .accessibilityHidden(true)
        } else {
            Image(systemName: symbol)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn ? AnyShapeStyle(onColor.gradient) : AnyShapeStyle(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)))
            Circle()
                .fill(Color.white.opacity(isHovering && isEnabled ? 0.12 : 0))
            Circle()
                .strokeBorder(Color.white.opacity(isOn ? 0.25 : (colorScheme == .dark ? 0.08 : 0.5)), lineWidth: 0.5)
            controlIcon
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .modifier(SymbolReplaceTransition())
        }
        .frame(width: 40, height: 40)
        
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct ControlPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Morphs one symbol into the next on macOS 14 and later.
private struct SymbolReplaceTransition: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content
        }
    }
}

/// A quiet footer action that highlights as a pill on hover.
private struct FooterLink: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                if let shortcut {
                    Text(shortcut).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(isHovering ? 0.08 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - Building blocks

/// Splits "452 Mbps" into a large number and a small unit, the way Apple's
/// widgets set measurements. Text without a leading number is shown whole.
enum HeroValueParts: Equatable {
    case measured(number: String, unit: String)
    case text(String)

    init(_ value: String) {
        let numeric = value.prefix { "0123456789.,−-".contains($0) }
        guard !numeric.isEmpty, numeric.contains(where: \.isNumber) else {
            self = .text(value)
            return
        }
        let unit = value.dropFirst(numeric.count).trimmingCharacters(in: .whitespaces)
        self = .measured(number: String(numeric), unit: unit)
    }
}

private struct HeroValue: View {
    let value: String

    var body: some View {
        switch HeroValueParts(value) {
        case let .measured(number, unit):
            HStack(alignment: .firstTextBaseline, spacing: unit.hasPrefix("°") || unit == "%" ? 0 : 3) {
                Text(number)
                    .font(.system(size: 24, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .motion(number)
                Text(unit)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        case let .text(text):
            Text(text)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(height: 29, alignment: .bottomLeading)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

private struct TileHeader: View {
    let title: String
    let symbol: String
    let tint: Color
    /// A status dot in the top-right corner: green is good, then yellow,
    /// orange and red. Hovering explains it.
    var status: TileStatus?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if let status {
                Spacer(minLength: 4)
                StatusDot(status: status)
            }
        }
        .frame(height: 14)
    }
}

struct TileStatus: Equatable {
    enum Level: Int, Equatable { case good, fair, poor, bad }
    let level: Level
    let explanation: String

    var color: Color {
        switch level {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .orange
        case .bad: return .red
        }
    }
}

private struct StatusDot: View {
    let status: TileStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
            .shadow(color: status.color.opacity(0.5), radius: 2)
            .padding(4) // a comfortable hover target
            .contentShape(Rectangle())
            .help(status.explanation)
            .motion(status.level.rawValue)
            .accessibilityLabel(status.explanation)
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider()
            .opacity(0.6)
            .padding(.leading, PopoverMetrics.rowPadding.leading)
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Color.orange.opacity(0.12),
            in: RoundedRectangle(cornerRadius: PopoverMetrics.tileRadius, style: .continuous)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .combine)
    }
}

private struct HoverCircleButtonStyle: ButtonStyle {
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .frame(width: 26, height: 26)
            .background(
                Circle().fill(Color.primary.opacity(
                    configuration.isPressed ? 0.14 : (isHovering && isEnabled ? 0.08 : 0)
                ))
            )
            .contentShape(Circle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// A full-width action row like the items at the bottom of macOS 26 menu bar
/// extras: highlights on hover with a radius concentric with the panel.
private struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(MenuRowStyle())
    }
}

private struct MenuRowStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, PopoverMetrics.rowPadding.leading + 6)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PopoverMetrics.tileRadius - 4, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (isHovering ? 0.08 : 0)))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

// MARK: - Tiles

private struct MetricTile: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    var detail: String?
    var detailTone: MacPulseStatusTone = .normal
    /// A short explanatory line under the value, colored only when it matters.
    var caption: (text: String, tone: MacPulseStatusTone)?
    var status: TileStatus?
    var help: String?
    let history: [MetricHistoryPoint]
    let window: TimeInterval
    let minimumGraphSpan: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TileHeader(title: title, symbol: symbol, tint: tint, status: status)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                HeroValue(value: value)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(detailTone.textStyle)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            .padding(.top, 4)
            if let caption {
                Text(caption.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(caption.tone.textStyle)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .motion(caption.text)
                    .padding(.top, 1)
            }
            // The graph takes any extra height so neighboring tiles stay balanced.
            LiveGraph(points: history, window: window, tint: tint, minimumSpan: minimumGraphSpan)
                .frame(minHeight: PopoverMetrics.graphHeight, maxHeight: .infinity)
                .padding(.top, 6)
        }
        .padding(PopoverMetrics.tilePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tileBackground()
        .accessibilityElement(children: .ignore)
        .help(help ?? "")
        .accessibilityLabel(title)
        .accessibilityValue([value, detail, caption?.text].compactMap { $0 }.joined(separator: ", "))
    }
}

/// When each tile's status dot is green, yellow, orange or red.
enum TileStatusRules {
    /// The network dot follows the minute-by-minute connection check.
    static func connection(latency: Double?, isOffline: Bool) -> TileStatus? {
        if isOffline { return TileStatus(level: .bad, explanation: "No internet connection") }
        return latency.map(Self.latency)
    }

    static func latency(_ milliseconds: Double) -> TileStatus {
        let ms = Int(milliseconds.rounded())
        switch milliseconds {
        case ..<50: return TileStatus(level: .good, explanation: "Latency \(ms) ms · Excellent")
        case ..<100: return TileStatus(level: .fair, explanation: "Latency \(ms) ms · Fair")
        case ..<250: return TileStatus(level: .poor, explanation: "Latency \(ms) ms · Calls may lag")
        default: return TileStatus(level: .bad, explanation: "Latency \(ms) ms · Poor")
        }
    }

    static func memory(_ pressure: ResourcePressureLevel) -> TileStatus? {
        switch pressure {
        case .normal: return TileStatus(level: .good, explanation: "Memory pressure is normal")
        case .elevated: return TileStatus(level: .poor, explanation: "Memory pressure is elevated")
        case .critical: return TileStatus(level: .bad, explanation: "Memory pressure is critical")
        case .unavailable: return nil
        }
    }

    /// Apple Silicon is designed to run warm; 90 °C is where macOS starts to
    /// care, so the dot stays green through ordinary work.
    static func temperature(_ celsius: Double) -> TileStatus {
        let degrees = Int(celsius.rounded())
        switch celsius {
        case ..<75: return TileStatus(level: .good, explanation: "\(degrees) °C · Normal")
        case ..<85: return TileStatus(level: .fair, explanation: "\(degrees) °C · Warm")
        case ..<90: return TileStatus(level: .poor, explanation: "\(degrees) °C · Hot")
        default: return TileStatus(level: .bad, explanation: "\(degrees) °C · Very hot")
        }
    }

    static func cpu(state: PerformanceMeterState, total: Double?) -> TileStatus {
        let percent = total.map { " · \(Int(($0 * 100).rounded()))% CPU" } ?? ""
        switch state {
        case .normal: return TileStatus(level: .good, explanation: "Light load" + percent)
        case .caution: return TileStatus(level: .fair, explanation: "Moderate load" + percent)
        case .elevated: return TileStatus(level: .poor, explanation: "Heavy load" + percent)
        case .critical: return TileStatus(level: .bad, explanation: "Very heavy load" + percent)
        }
    }
}

/// Plain-language readings for the small caption lines.
enum InsightFormatting {
    /// Under 100 ms feels instant for calls and browsing; above 250 ms is laggy.
    static func latency(_ milliseconds: Double) -> (text: String, tone: MacPulseStatusTone) {
        let value = Int(milliseconds.rounded())
        let tone: MacPulseStatusTone = milliseconds > 250 ? .critical : (milliseconds > 100 ? .attention : .normal)
        return ("Latency \(value) ms", tone)
    }

    static func pressure(_ level: ResourcePressureLevel) -> (text: String, tone: MacPulseStatusTone)? {
        switch level {
        case .normal: return ("Normal pressure", .normal)
        case .elevated: return ("Elevated pressure", .attention)
        case .critical: return ("Critical pressure", .critical)
        case .unavailable: return nil
        }
    }

    static func topApp(_ app: TopCPUApp) -> String {
        "\(app.name) \(Int((app.share * 100).rounded()))%"
    }

    static func breakdown(_ parts: [TopCPUApp]) -> String {
        parts.map(topApp).joined(separator: " · ")
    }
}

private struct BatteryTile: View {
    let percentage: String
    let time: String
    let tone: MacPulseStatusTone
    let flow: BatteryFlow
    var powerUse: Double?
    var powerIn: Double?
    var adapterWatts: Double?

    private var level: Double? {
        Double(percentage.filter(\.isNumber)).map { min(1, max(0, $0 / 100)) }
    }

    private var symbol: String {
        switch flow {
        case .charging: return "battery.100percent.bolt"
        case .pluggedIn, .charged: return "powerplug.fill"
        case .discharging:
            guard let level else { return "battery.75percent" }
            switch level {
            case ..<0.13: return "battery.0percent"
            case ..<0.38: return "battery.25percent"
            case ..<0.63: return "battery.50percent"
            case ..<0.88: return "battery.75percent"
            default: return "battery.100percent"
            }
        }
    }

    /// Follows Apple's battery widgets: green when healthy, orange or red when low.
    private var color: Color {
        switch tone {
        case .critical: return .red
        case .attention: return .orange
        case .normal: return .green
        }
    }

    private var status: String {
        guard level != nil else { return "" }
        if !time.isEmpty, time != "—" { return time }
        switch flow {
        case .charging: return "Charging"
        case .charged: return "Fully charged"
        case .pluggedIn: return "On power adapter"
        case .discharging: return "On battery"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TileHeader(title: "Battery", symbol: symbol, tint: level == nil ? .secondary : color)
            HeroValue(value: percentage)
                .padding(.top, 4)
            Text(status)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tone.textStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 1)
            Spacer(minLength: 6)
            if let level {
                BatteryBar(level: level, color: color)
                    .frame(height: 6)
                    .padding(.bottom, powerUse == nil && powerIn == nil ? 2 : 0)
                PowerRows(
                    using: powerUse,
                    // Supply shows only while a charger is actually connected.
                    supply: powerIn == nil ? nil : adapterWatts,
                    charging: PowerRows.chargingWatts(flow: flow, receiving: powerIn, using: powerUse)
                )
                    .padding(.top, 8)
            } else {
                LiveGraph(points: [], window: LiveGraph.systemWindow, tint: .secondary, minimumSpan: 1)
                    .frame(height: PopoverMetrics.graphHeight)
            }
        }
        .padding(PopoverMetrics.tilePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tileBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(status.isEmpty ? percentage : "\(percentage), \(status)")
    }
}

/// Power in plain words: what the Mac is using, the most the connected
/// charger can supply, and, only while the battery is charging, how much is
/// going into it.
struct PowerRows: View {
    let using: Double?
    let supply: Double?
    let charging: Double?

    /// The charging row appears only while the battery takes a meaningful
    /// amount of power, so it never flickers in at a fraction of a watt.
    static func chargingWatts(flow: BatteryFlow, receiving: Double?, using: Double?) -> Double? {
        guard flow == .charging, let receiving, let using else { return nil }
        let intoBattery = receiving - using
        return intoBattery >= 1 ? intoBattery : nil
    }

    var body: some View {
        VStack(spacing: 3) {
            if let using {
                row("Using", watts: using)
                    .help("Power this Mac is using right now")
            }
            if let supply {
                row("Supply", watts: supply)
                    .help("The most the connected charger can supply")
            }
            if let charging {
                row("Charging", watts: charging)
                    .help("Power going into the battery")
            }
        }
    }

    private func row(_ title: String, watts: Double) -> some View {
        let text = PowerFormatting.watts(watts)
        return HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(text)
                .monospacedDigit()
                .contentTransition(.numericText())
                .motion(text)
        }
        .font(.system(size: 11, weight: .medium))
        .accessibilityElement(children: .combine)
    }
}

enum PowerFormatting {
    /// Whole watts above 10 W, one decimal below, the way macOS shows power.
    static func watts(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f W", value) : "\(Int(value.rounded())) W"
    }
}

private struct BatteryBar: View {
    let level: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: max(proxy.size.height, proxy.size.width * level))
            }
        }
        .motion(level)
        .accessibilityHidden(true)
    }
}

private struct GraphsAreLiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var graphsAreLive: Bool {
        get { self[GraphsAreLiveKey.self] }
        set { self[GraphsAreLiveKey.self] = newValue }
    }
}

/// Eases the vertical range toward its target so a new high or low never
/// makes the whole graph jump. A class so the renderer can update it per frame.
private final class GraphScale {
    var lower: Double?
    var upper: Double?
    var lastFrame: Date?

    func update(lower targetLower: Double, upper targetUpper: Double, at now: Date, animated: Bool) -> (Double, Double) {
        guard animated, let lower, let upper, let lastFrame else {
            self.lower = targetLower; self.upper = targetUpper; self.lastFrame = now
            return (targetLower, targetUpper)
        }
        let elapsed = max(0, min(0.25, now.timeIntervalSince(lastFrame)))
        let blend = 1 - exp(-elapsed / 0.45)
        let newLower = lower + (targetLower - lower) * blend
        let newUpper = upper + (targetUpper - upper) * blend
        self.lower = newLower; self.upper = newUpper; self.lastFrame = now
        return (newLower, newUpper)
    }
}

/// A live graph in the style of Activity Monitor: readings are placed by time,
/// the line scrolls left continuously, the newest value glides in, and the
/// dot at the right edge always shows the value right now.
struct LiveGraph: View {
    /// Speed tests run every 15 to 60 minutes, so download shows six hours.
    static let downloadWindow: TimeInterval = 6 * 60 * 60
    /// Memory and temperature are sampled every second while open.
    static let systemWindow: TimeInterval = 2 * 60
    /// How long a new reading takes to glide into place.
    static let settleDuration: TimeInterval = 0.45
    /// The shortest span a graph shows while history is still building up.
    static let minimumWindow: TimeInterval = 20

    /// Grows with the available history so a fresh graph fills its tile,
    /// then holds at the full window and scrolls.
    static func visibleWindow(for points: [MetricHistoryPoint], maximum: TimeInterval, at now: Date) -> TimeInterval {
        guard let oldest = points.first else { return maximum }
        return min(maximum, max(minimumWindow, now.timeIntervalSince(oldest.capturedAt)))
    }

    let points: [MetricHistoryPoint]
    let window: TimeInterval
    let tint: Color
    let minimumSpan: Double
    /// When set, the line is colored by value: each stretch takes the color of
    /// the zone it is in, blending smoothly between zones.
    var valueGradient: (gradient: Gradient, values: ClosedRange<Double>)?
    /// A fixed vertical scale, such as 0–100%, so height always means the same.
    var fixedRange: ClosedRange<Double>?
    /// Small graphs fade old readings out at the left; large charts with a
    /// time label keep a crisp edge.
    var fadesLeadingEdge = true

    @Environment(\.graphsAreLive) private var isLive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale = GraphScale()

    var body: some View {
        // 30 fps keeps a 1 pt/s scroll and the value glide smooth at a fraction
        // of the energy of 60 fps.
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0, paused: !isLive)) { context in
            Canvas(rendersAsynchronously: false) { graphics, size in
                draw(in: &graphics, size: size, now: context.date)
            }
        }
        .mask {
            // Old readings fade out at the left edge instead of being cut off.
            LinearGradient(
                stops: [.init(color: fadesLeadingEdge ? .clear : .black, location: 0), .init(color: .black, location: 0.14)],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .accessibilityHidden(true)
    }

    /// The value shown at "now": eases from the previous reading to the newest.
    static func currentValue(of points: [MetricHistoryPoint], at now: Date, animated: Bool) -> Double? {
        guard let last = points.last else { return nil }
        guard animated, points.count > 1 else { return last.value }
        let previous = points[points.count - 2].value
        let progress = min(1, max(0, now.timeIntervalSince(last.capturedAt) / settleDuration))
        let eased = 1 - pow(1 - progress, 3)
        return previous + (last.value - previous) * eased
    }

    private func draw(in graphics: inout GraphicsContext, size: CGSize, now: Date) {
        let dotRadius: CGFloat = 2.5
        let plotWidth = size.width - dotRadius - 1
        let top = dotRadius + 1
        let bottom = size.height - dotRadius - 1
        let window = Self.visibleWindow(for: points, maximum: self.window, at: now)
        let start = now.addingTimeInterval(-window)
        let animated = isLive && !reduceMotion

        guard let current = Self.currentValue(of: points, at: now, animated: animated) else {
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 1))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 1))
            graphics.stroke(baseline, with: .color(.secondary.opacity(0.35)),
                            style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 3]))
            return
        }

        // Keep one reading before the window so the line enters from the edge.
        let firstVisible = points.firstIndex { $0.capturedAt >= start } ?? (points.count - 1)
        var visible = Array(points[max(0, firstVisible - 1)...])
        visible[visible.count - 1] = MetricHistoryPoint(capturedAt: visible[visible.count - 1].capturedAt, value: current)

        let values = visible.map(\.value)
        let minimum = values.min() ?? current
        let maximum = values.max() ?? current
        // Keep the same value-per-point at any height, so a taller graph gets
        // more room instead of exaggerated swings.
        let heightScale = max(1, size.height / PopoverMetrics.graphHeight)
        let span = max(minimumSpan * heightScale, (maximum - minimum) * 1.15)
        let center = (minimum + maximum) / 2
        let target = fixedRange ?? ((center - span / 2)...(center + span / 2))
        let (lower, upper) = scale.update(lower: target.lowerBound, upper: target.upperBound,
                                          at: now, animated: animated)
        let range = max(upper - lower, .ulpOfOne)

        func y(for value: Double) -> CGFloat {
            top + (bottom - top) * (1 - CGFloat((value - lower) / range))
        }

        func position(_ point: MetricHistoryPoint) -> CGPoint {
            let x = CGFloat(point.capturedAt.timeIntervalSince(start) / window) * plotWidth
            let normalized = CGFloat(min(1, max(0, (point.value - lower) / range)))
            return CGPoint(x: min(x, plotWidth), y: top + (bottom - top) * (1 - normalized))
        }

        var path = visible.map(position)
        let nowPoint = CGPoint(x: plotWidth, y: path.last!.y)
        if path.last!.x < plotWidth - 0.5 { path.append(nowPoint) }
        if path.count == 1 { path.insert(CGPoint(x: 0, y: nowPoint.y), at: 0) }

        let line = Self.smoothPath(through: path)
        var area = line
        area.addLine(to: CGPoint(x: path.last!.x, y: size.height))
        area.addLine(to: CGPoint(x: path.first!.x, y: size.height))
        area.closeSubpath()
        let end = path.last!
        let halo = Path(ellipseIn: CGRect(x: end.x - 5, y: end.y - 5, width: 10, height: 10))
        let dot = Path(ellipseIn: CGRect(x: end.x - dotRadius, y: end.y - dotRadius,
                                         width: dotRadius * 2, height: dotRadius * 2))

        // Shading pinned to real values, so a reading has the same color at
        // any scale; otherwise the single tint.
        let shading: GraphicsContext.Shading
        if let valueGradient {
            shading = .linearGradient(
                valueGradient.gradient,
                startPoint: CGPoint(x: 0, y: y(for: valueGradient.values.lowerBound)),
                endPoint: CGPoint(x: 0, y: y(for: valueGradient.values.upperBound))
            )
        } else {
            shading = .color(tint)
        }

        graphics.drawLayer { layer in
            layer.opacity = 0.24
            layer.fill(area, with: shading)
            // Fade the fill toward the bottom edge.
            layer.blendMode = .destinationOut
            layer.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [.clear, .black]),
                    startPoint: CGPoint(x: 0, y: top),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }
        graphics.stroke(line, with: shading,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        graphics.drawLayer { layer in
            layer.opacity = 0.18
            layer.fill(halo, with: shading)
        }
        graphics.fill(dot, with: shading)
    }

    /// Monotone cubic interpolation: smooth, and it never overshoots the data.
    static func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        let n = points.count
        var slopes = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            slopes[i] = dx <= 0 ? 0 : (points[i + 1].y - points[i].y) / dx
        }
        var tangents = [CGFloat](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) {
            tangents[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2
        }
        for i in 0..<(n - 1) {
            let p0 = points[i], p1 = points[i + 1]
            let third = (p1.x - p0.x) / 3
            path.addCurve(
                to: p1,
                control1: CGPoint(x: p0.x + third, y: p0.y + tangents[i] * third),
                control2: CGPoint(x: p1.x - third, y: p1.y - tangents[i + 1] * third)
            )
        }
        return path
    }
}

/// CPU at a glance: a smoothed total, its two-minute trend in the same style as
/// the other graphs, and one calm meter per core tier. Readings are averaged
/// over a few seconds so the tile drifts instead of flickering.
private struct CPUTile: View {
    let cpu: CPUActivity?
    let gpuUsage: Double?
    let gpuCores: Int?
    let history: [MetricHistoryPoint]
    let level: Double
    let hasSample: Bool
    let fanRPMs: [Double]

    /// Tiers share the load color, brightest for the fastest tier, so the
    /// shade itself says which cores are faster.
    static let tierOpacities: [Double] = [1, 0.55, 0.35]

    private var state: PerformanceMeterState { .current(for: min(1, max(0, level))) }
    private var loadTitle: String { hasSample ? "\(state.title) load" : "Checking…" }
    /// The whole tile takes the color of the current load: green, yellow,
    /// orange or red, matching the load label.
    private var accent: Color { hasSample ? state.color : .secondary }

    private var fanSummary: String? {
        guard !fanRPMs.isEmpty else { return nil }
        let speeds = fanRPMs.filter { $0 > 0 }
        guard !speeds.isEmpty else { return "Fans off" }
        return speeds.map { Int($0.rounded()).formatted() }.joined(separator: " · ") + " rpm"
    }

    /// One row per CPU tier, fastest first, then the GPU.
    private var meterRows: [ProcessorMeterRow] {
        var rows = (cpu?.groups ?? []).enumerated().map { index, group in
            ProcessorMeterRow(
                name: group.name, cores: group.usages.count, usage: group.average,
                opacity: CPUTile.tierOpacities[min(index, CPUTile.tierOpacities.count - 1)]
            )
        }
        if rows.count == 1 { rows[0] = ProcessorMeterRow(name: "CPU", cores: rows[0].cores, usage: rows[0].usage, opacity: 1) }
        if let gpuUsage {
            rows.append(ProcessorMeterRow(name: "GPU", cores: gpuCores, usage: gpuUsage, opacity: 1))
        }
        return rows
    }

    private var totalText: String {
        cpu.map { "\(Int(($0.total * 100).rounded()))%" } ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TileHeader(title: "CPU", symbol: "cpu", tint: accent,
                       status: hasSample ? TileStatusRules.cpu(state: state, total: cpu?.total) : nil)

            HeroValue(value: totalText)
                .padding(.top, 4)

            LiveGraph(
                points: history, window: LiveGraph.systemWindow, tint: accent, minimumSpan: 20,
                valueGradient: (PerformanceMeterState.meterGradient, 0...100)
            )
                .frame(height: PopoverMetrics.graphHeight)
                .padding(.top, 6)

            ProcessorMeters(rows: meterRows)
                .padding(.top, 10)

            if fanSummary != nil {
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    if let fanSummary {
                        Label(fanSummary, systemImage: "fan")
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .labelStyle(CompactLabelStyle())
                .padding(.top, 8)
            }
        }
        .padding(PopoverMetrics.tilePadding)
        .tileBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [totalText == "—" ? "Measuring" : "\(totalText) in use", loadTitle]
        for group in cpu?.groups ?? [] {
            parts.append("\(group.name) cores \(Int((group.average * 100).rounded())) percent")
        }
        if let gpuUsage { parts.append("GPU \(Int((gpuUsage * 100).rounded())) percent") }
        if let fanSummary { parts.append(fanSummary) }
        return parts.joined(separator: ", ")
    }
}

struct ProcessorMeterRow: Equatable {
    let name: String
    let cores: Int?
    let usage: Double
    let opacity: Double
}

/// One line per processor: name and core count, a slim bar that reveals the
/// load-zone gradient up to its value, and the percentage. Rows share columns
/// so the bars line up.
private struct ProcessorMeters: View {
    let rows: [ProcessorMeterRow]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(rows, id: \.name) { row in
                let percent = Int((min(1, max(0, row.usage)) * 100).rounded())
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Text(row.name).foregroundStyle(.secondary)
                        if let cores = row.cores {
                            Text("· \(cores)").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 104, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            LinearGradient(gradient: PerformanceMeterState.meterGradient,
                                           startPoint: .leading, endPoint: .trailing)
                                .opacity(row.opacity)
                                .mask(alignment: .leading) {
                                    Capsule().frame(width: max(proxy.size.height, proxy.size.width * min(1, row.usage)))
                                }
                        }
                    }
                    .frame(height: 4)
                    .motion(percent)
                    Text("\(percent)%")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .motion(percent)
                        .frame(width: 34, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .help(row.cores.map { "\($0) \(row.name) cores, \(percent)% busy on average" } ?? "\(row.name) \(percent)% busy")
            }
        }
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10))
            configuration.title
        }
    }
}

private struct LoadBar: View {
    let level: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: level > 0 ? max(proxy.size.height, proxy.size.width * level) : 0)
            }
        }
        .motion(level)
        .accessibilityHidden(true)
    }
}

// MARK: - Mac Health

private struct MacHealthSection: View {
    let status: String
    let tone: MacPulseStatusTone
    let metrics: [MacPulseHealthMetric]
    let panicSignature: String?
    let panicClassification: String?
    let panicTaskContext: String?

    private var isChecking: Bool { status == "Checking…" }

    private var statusText: String {
        status == "Attention" ? "Needs attention" : status
    }

    private var statusSymbol: String {
        switch tone {
        case .normal: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("Mac Health")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 4) {
                    if !isChecking {
                        Image(systemName: statusSymbol)
                            .foregroundStyle(tone.color)
                            .font(.system(size: 11))
                    }
                    Text(statusText)
                        .foregroundStyle(tone == .normal ? AnyShapeStyle(.secondary) : tone.textStyle)
                }
                .font(.system(size: 11, weight: .medium))
                .motion(statusText)
            }
            .padding(.horizontal, PopoverMetrics.rowPadding.leading)
            .padding(.top, 8)
            .padding(.bottom, 6)

            ForEach(displayMetrics.filter { $0.id != "heat" }) { metric in
                RowDivider()
                HealthRow(metric: metric, help: help(for: metric))
            }
        }
        .padding(.bottom, 2)
        .tileBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mac Health, \(statusText)")
    }

    /// Diagnostic detail lives in the hover tip so the list stays calm.
    private func help(for metric: MacPulseHealthMetric) -> String {
        guard metric.id == "reliability", let panicSignature else { return metric.detail }
        let latest = [panicSignature, panicClassification].compactMap { $0 }.joined(separator: " · ")
        return ["Latest panic: \(latest)", panicTaskContext].compactMap { $0 }.joined(separator: "\n")
    }

    private var displayMetrics: [MacPulseHealthMetric] {
        if metrics.isEmpty {
            return [
                MacPulseHealthMetric(id: "battery", label: "Battery", detail: "Checking…", symbol: "battery.100percent", tone: .normal),
                MacPulseHealthMetric(id: "storage", label: "Storage", detail: "Checking…", symbol: "internaldrive", tone: .normal),
                MacPulseHealthMetric(id: "heat", label: "Heat", detail: "Checking…", symbol: "thermometer.medium", tone: .normal),
                MacPulseHealthMetric(id: "reliability", label: "Reliability", detail: "Checking…", symbol: "checkmark.shield", tone: .normal)
            ]
        }
        return metrics
    }
}

private struct HealthRow: View {
    let metric: MacPulseHealthMetric
    var help: String?

    private var title: String {
        metric.id == "reliability" ? "Stability" : metric.label
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: metric.symbol)
                .font(.system(size: 11))
                .foregroundStyle(metric.tone == .normal ? AnyShapeStyle(.secondary) : AnyShapeStyle(metric.tone.color))
                .frame(width: PopoverMetrics.iconWidth)
            Text(title)
            Spacer(minLength: 12)
            Text(HealthRowFormatting.displayValue(for: metric))
                .foregroundStyle(metric.tone == .normal ? AnyShapeStyle(.secondary) : metric.tone.textStyle)
                .fontWeight(metric.tone == .normal ? .regular : .medium)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 13))
        .padding(PopoverMetrics.rowPadding)
        .help(help ?? metric.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(metric.detail)
    }
}

enum HealthRowFormatting {
    /// Picks the part of each detail that explains the row's state.
    static func displayValue(for metric: MacPulseHealthMetric) -> String {
        let parts = metric.detail.components(separatedBy: " · ")
        switch metric.id {
        case "storage":
            guard parts.count >= 2 else { return metric.detail }
            let smart = parts[0]
            let used = parts[1]
            return smart == "Verified" || smart == "Unknown" ? used : "\(smart) · \(used)"
        case "heat":
            return parts.prefix(2).joined(separator: " · ")
        case "reliability":
            if metric.detail.localizedCaseInsensitiveContains("No panics") { return "No panics in 30 days" }
            return parts.first ?? metric.detail
        default:
            return parts.prefix(2).joined(separator: " · ")
        }
    }
}

// MARK: - Settings

private struct SettingRow<Control: View>: View {
    let title: String
    var help: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            control
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .font(.system(size: 13))
        .padding(PopoverMetrics.rowPadding)
        .frame(minHeight: 30)
        .help(help ?? "")
    }
}

enum PerformanceMeterState: Equatable {
    case normal
    case caution
    case elevated
    case critical

    static let cautionThreshold = 0.35
    static let elevatedThreshold = 0.55
    static let criticalThreshold = 0.82

    static func current(for level: Double) -> Self {
        switch min(1, max(0, level)) {
        case ..<cautionThreshold: return .normal
        case ..<elevatedThreshold: return .caution
        case ..<criticalThreshold: return .elevated
        default: return .critical
        }
    }

    static var meterGradient: Gradient {
        Gradient(stops: [
            .init(color: .green, location: 0),
            .init(color: .yellow, location: CGFloat(cautionThreshold)),
            .init(color: .orange, location: CGFloat(elevatedThreshold)),
            .init(color: .red, location: CGFloat(criticalThreshold)),
            .init(color: .red, location: 1)
        ])
    }

    var color: Color {
        switch self {
        case .normal: return .green
        case .caution: return .yellow
        case .elevated: return .orange
        case .critical: return .red
        }
    }

    var title: String {
        switch self {
        case .normal: return "Light"
        case .caution: return "Moderate"
        case .elevated: return "Heavy"
        case .critical: return "Very heavy"
        }
    }
}


/// A compact shell silhouette with three inset ribs, legible at control size.
private struct ClamshellIcon: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 24 * rect.width,
                    y: rect.minY + y / 24 * rect.height)
        }
        var path = Path()
        path.move(to: p(8.5, 21))
        path.addCurve(to: p(1, 10), control1: p(6, 18), control2: p(1, 15))
        path.addCurve(to: p(5, 5), control1: p(0, 6.5), control2: p(2.5, 4))
        path.addCurve(to: p(9, 2.5), control1: p(5, 2), control2: p(7, 1))
        path.addCurve(to: p(15, 2.5), control1: p(10.5, 0.5), control2: p(13.5, 0.5))
        path.addCurve(to: p(19, 5), control1: p(17, 1), control2: p(19, 2))
        path.addCurve(to: p(23, 10), control1: p(21.5, 4), control2: p(24, 6.5))
        path.addCurve(to: p(15.5, 21), control1: p(23, 15), control2: p(18, 18))
        path.addQuadCurve(to: p(8.5, 21), control: p(12, 23))
        path.closeSubpath()

        // The grooves taper toward the hinge instead of crowding into one point.
        path.move(to: p(11.3, 5))
        path.addQuadCurve(to: p(12.7, 5), control: p(12, 3.8))
        path.addLine(to: p(12.4, 18.5))
        path.addQuadCurve(to: p(11.6, 18.5), control: p(12, 19.3))
        path.closeSubpath()
        for side: CGFloat in [-1, 1] {
            func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { p(12 + side * x, y) }
            path.move(to: q(5, 7))
            path.addQuadCurve(to: q(6.3, 7.5), control: q(6.1, 6.5))
            path.addQuadCurve(to: q(2.6, 18.5), control: q(5.3, 13.5))
            path.addQuadCurve(to: q(2, 18), control: q(1.9, 19))
            path.addQuadCurve(to: q(5, 7), control: q(4.1, 12.5))
            path.closeSubpath()
        }
        return path
    }
}
