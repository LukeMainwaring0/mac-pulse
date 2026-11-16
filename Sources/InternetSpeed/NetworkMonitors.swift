import Foundation
import Network

/// The facts about the current connection that decide when to test.
struct NetworkPath: Equatable, Sendable {
    let signature: String
    let isOnline: Bool
    /// Hotspots and Low Data Mode, where automatic tests would cost real money.
    let isMetered: Bool
}

final class NetworkChangeMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.lukemainwaring.internetspeed.network-path")

    func start(onUpdate: @escaping @Sendable (NetworkPath) -> Void) {
        monitor.pathUpdateHandler = { path in
            let update = NetworkPath(
                signature: Self.signature(for: path),
                isOnline: path.status == .satisfied,
                isMetered: path.isExpensive || path.isConstrained
            )
            DispatchQueue.main.async {
                onUpdate(update)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    private static func signature(for path: NWPath) -> String {
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .requiresConnection: status = "requires-connection"
        case .unsatisfied: status = "unsatisfied"
        @unknown default: status = "unknown"
        }

        let interfaces = [
            path.usesInterfaceType(.wifi) ? "wifi" : nil,
            path.usesInterfaceType(.wiredEthernet) ? "ethernet" : nil,
            path.usesInterfaceType(.cellular) ? "cellular" : nil,
            path.usesInterfaceType(.other) ? "other" : nil
        ].compactMap { $0 }.joined(separator: ",")

        return [
            status,
            interfaces,
            path.isExpensive ? "expensive" : "unmetered",
            path.isConstrained ? "constrained" : "unconstrained",
            path.supportsIPv4 ? "ipv4" : "no-ipv4",
            path.supportsIPv6 ? "ipv6" : "no-ipv6"
        ].joined(separator: "|")
    }
}
