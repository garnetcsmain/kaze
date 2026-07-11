import Foundation

/// Samples total CPU usage (0.0–1.0) once per second via mach host statistics.
/// Used by the Scheduler to defer LOW_POWER tasks under load (parity with node-os-utils).
final class CPUMonitor {
    private(set) var usage: Double = 0
    private var previousTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "kaze.cpu", qos: .utility)

    var isLowPower: Bool { usage < K.cpuLowPowerThreshold }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &size)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let ticks = (
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        defer { previousTicks = ticks }
        guard let prev = previousTicks else { return }

        let user = ticks.user &- prev.user
        let system = ticks.system &- prev.system
        let idle = ticks.idle &- prev.idle
        let nice = ticks.nice &- prev.nice
        let total = user + system + idle + nice
        guard total > 0 else { return }
        usage = Double(user + system + nice) / Double(total)
    }
}
