import Foundation

/// Periodic task scheduler — port of src/electron/backend/scheduler.ts.
/// Tasks have an interval, can be paused/resumed/triggered, and LOW_POWER tasks
/// are deferred (1s at a time) while CPU usage is at or above 75%.
/// Unlike the Electron version, a task never overlaps itself (`running` flag).
final class Scheduler {
    enum SystemState {
        case any
        case lowPower
    }

    private final class ScheduledTask {
        let id: String
        let interval: TimeInterval
        let requiredState: SystemState
        let action: () async -> Void
        var isPaused = false
        var nextRun: Date
        var running = false

        init(id: String, interval: TimeInterval, requiredState: SystemState, action: @escaping () async -> Void) {
            self.id = id
            self.interval = interval
            self.requiredState = requiredState
            self.action = action
            self.nextRun = Date().addingTimeInterval(interval)
        }
    }

    private var tasks: [String: ScheduledTask] = [:]
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "kaze.scheduler", qos: .utility)
    let cpu = CPUMonitor()

    func start() {
        cpu.start()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        cpu.stop()
    }

    func addTask(_ id: String, interval: TimeInterval, requiredState: SystemState = .any, action: @escaping () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        tasks[id] = ScheduledTask(id: id, interval: interval, requiredState: requiredState, action: action)
    }

    func pauseTask(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        tasks[id]?.isPaused = true
    }

    func resumeTask(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let task = tasks[id] else { return }
        task.isPaused = false
        task.nextRun = Date().addingTimeInterval(task.interval)
    }

    /// Run a task immediately (unless paused or already running).
    func triggerTask(_ id: String) {
        lock.lock()
        guard let task = tasks[id], !task.isPaused, !task.running else {
            lock.unlock()
            return
        }
        task.running = true
        task.nextRun = Date().addingTimeInterval(task.interval)
        lock.unlock()
        run(task)
    }

    private func tick() {
        let now = Date()
        var due: [ScheduledTask] = []

        lock.lock()
        for task in tasks.values {
            guard !task.isPaused, !task.running, now >= task.nextRun else { continue }
            if task.requiredState == .lowPower && !cpu.isLowPower {
                task.nextRun = now.addingTimeInterval(1.0) // defer 1s, same as Electron delayTask
                continue
            }
            task.running = true
            task.nextRun = now.addingTimeInterval(task.interval)
            due.append(task)
        }
        lock.unlock()

        for task in due { run(task) }
    }

    private func run(_ task: ScheduledTask) {
        Task.detached(priority: .utility) { [weak self] in
            await task.action()
            self?.markFinished(task)
        }
    }

    private func markFinished(_ task: ScheduledTask) {
        lock.lock()
        defer { lock.unlock() }
        task.running = false
    }
}
