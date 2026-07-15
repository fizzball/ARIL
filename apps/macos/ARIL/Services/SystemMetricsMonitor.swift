import Foundation
import Darwin
import Combine

/// Samples host CPU, memory, and disk usage for the title-bar metrics strip.
@MainActor
final class SystemMetricsMonitor: ObservableObject {
    @Published private(set) var cpuPercent: Double = 0
    @Published private(set) var memoryPercent: Double = 0
    @Published private(set) var diskPercent: Double = 0
    /// False until the first CPU delta is available (needs two samples).
    @Published private(set) var cpuReady: Bool = false

    private var timer: Timer?
    private var previousCPU: host_cpu_load_info?

    func start(interval: TimeInterval = 2.0) {
        stop()
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        updateCPU()
        updateMemory()
        updateDisk()
    }

    private func updateCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        if let previous = previousCPU {
            let user = Double(info.cpu_ticks.0 - previous.cpu_ticks.0)
            let system = Double(info.cpu_ticks.1 - previous.cpu_ticks.1)
            let idle = Double(info.cpu_ticks.2 - previous.cpu_ticks.2)
            let nice = Double(info.cpu_ticks.3 - previous.cpu_ticks.3)
            let total = user + system + idle + nice
            if total > 0 {
                cpuPercent = min(100, max(0, ((user + system + nice) / total) * 100))
                cpuReady = true
            }
        }
        previousCPU = info
    }

    private func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return }

        let page = Double(vm_kernel_page_size)
        // Approximate Activity Monitor “Memory Used”: active + wired + compressed.
        let usedPages = Double(stats.active_count)
            + Double(stats.wire_count)
            + Double(stats.compressor_page_count)
        memoryPercent = min(100, max(0, (usedPages * page / total) * 100))
    }

    private func updateDisk() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]),
            let total = values.volumeTotalCapacity.map(Double.init),
            total > 0
        else { return }

        let available = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let used = max(0, total - available)
        diskPercent = min(100, max(0, (used / total) * 100))
    }
}
