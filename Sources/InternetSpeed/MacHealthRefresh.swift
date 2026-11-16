import Foundation

/// Owns the monitor's mutable history on one background executor.
private actor MacHealthWorker {
    private let monitor: MacHealthMonitor

    init(monitor: MacHealthMonitor) {
        self.monitor = monitor
    }

    func update(thermal: ThermalSnapshot, at date: Date) -> MacHealthSnapshot {
        monitor.update(thermal: thermal, at: date)
    }
}

@MainActor
final class MacHealthRefresh {
    private let worker: MacHealthWorker
    private var isRefreshing = false

    /// Ownership of the monitor transfers to this worker; do not use it elsewhere.
    init(monitor: MacHealthMonitor = MacHealthMonitor()) {
        worker = MacHealthWorker(monitor: monitor)
    }

    func refresh(
        thermal: ThermalSnapshot,
        at date: Date,
        completion: @escaping @MainActor (MacHealthSnapshot) -> Void
    ) {
        // Keep the last snapshot visible and drop timer ticks while a scan runs.
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let snapshot = await worker.update(thermal: thermal, at: date)
            isRefreshing = false
            completion(snapshot)
        }
    }
}
