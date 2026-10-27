import Foundation
import MonitorBackend
import Observation

struct CoreSample: Identifiable {
    let id: Int
    let type: Character // "P", "E" or "?"
    let cluster: Int    // -1 when unknown
    var busy: Double?
    var user: Double?
    var system: Double?
}

struct ProcessSample: Identifiable {
    let id: Int // pid
    let name: String
    let cpu: Double? // one full core = 100%
    let memory: UInt64 // resident bytes
}

struct GpuSample {
    let name: String
    let utilization: Double?
    let usedBytes: Double?
    let cores: Int?
}

struct MemorySample {
    var total: UInt64 = 0, used: UInt64 = 0, app: UInt64 = 0, wired: UInt64 = 0
    var compressed: UInt64 = 0, cached: UInt64 = 0, swapUsed: UInt64 = 0, swapTotal: UInt64 = 0
    var usedPercent: Double { total == 0 ? 0 : 100 * Double(used) / Double(total) }
}

struct DiskSample {
    var total: UInt64 = 0, used: UInt64 = 0
    var usedPercent: Double? { total == 0 ? nil : 100 * Double(used) / Double(total) }
}

struct HistoryPoint: Identifiable {
    let id: Int
    let cpu: Double
    let memory: Double
    let gpu: Double?
}

/// Raw counters from one backend pass; diffed against the previous pass to get rates.
private struct RawSample: Sendable {
    var cores: [rv_core]
    var processes: [rv_process]
    var gpus: [rv_gpu]
    var memory: rv_memory?
    var disk: DiskSample?
    var time: ContinuousClock.Instant
}

private func readSample() -> RawSample {
    func list<T>(_ fill: (UnsafeMutablePointer<T>?, Int) -> Int, initial: Int, empty: T) -> [T] {
        var capacity = initial
        while true {
            var items = [T](repeating: empty, count: capacity)
            let count = items.withUnsafeMutableBufferPointer { fill($0.baseAddress, capacity) }
            if count <= capacity { return Array(items.prefix(count)) }
            capacity = count + 64 // the list grew between calls
        }
    }
    let cores = list({ rv_cpu_cores($0, $1) }, initial: 64, empty: rv_core())
    let processes = list({ rv_processes($0, $1) }, initial: 1024, empty: rv_process())
    let gpus = list({ rv_gpus($0, $1) }, initial: 4, empty: rv_gpu())
    var memory = rv_memory()
    let hasMemory = rv_memory_stats(&memory)
    return RawSample(cores: cores, processes: processes, gpus: gpus,
                     memory: hasMemory ? memory : nil, disk: readDisk(), time: .now)
}

/// Startup volume usage. Purgeable space counts as free, matching Finder.
private func readDisk() -> DiskSample? {
    let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey,
                                     .volumeAvailableCapacityForImportantUsageKey]
    guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
          let total = values.volumeTotalCapacity, total > 0,
          let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
    let free = UInt64(clamping: max(0, min(available, Int64(total))))
    return DiskSample(total: UInt64(total), used: UInt64(total) - free)
}

private func string<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

private func optional(_ value: Double) -> Double? { value.isNaN ? nil : value }

@MainActor @Observable
final class Monitor {
    static let historyLength = 120

    private(set) var cores: [CoreSample] = []
    private(set) var processes: [ProcessSample] = []
    private(set) var gpus: [GpuSample] = []
    private(set) var memory = MemorySample()
    private(set) var disk = DiskSample()
    private(set) var history: [HistoryPoint] = []
    private(set) var cpuAverage: Double?

    var interval: Double {
        didSet { UserDefaults.standard.set(interval, forKey: "interval") }
    }

    var gpuUtilization: Double? { gpus.compactMap(\.utilization).max() }

    private var previous: RawSample?
    private var historyCounter = 0
    private var task: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.double(forKey: "interval")
        interval = (0.25...10).contains(saved) ? saved : 1
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let raw = await Task.detached(priority: .utility) { readSample() }.value
                guard let self else { return }
                self.apply(raw)
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    private func apply(_ raw: RawSample) {
        let before = previous
        previous = raw

        var oldCores: [UInt32: rv_core] = [:]
        for core in before?.cores ?? [] { oldCores[core.id] = core }
        cores = raw.cores.map { core in
            var sample = CoreSample(id: Int(core.id),
                                    type: Character(UnicodeScalar(UInt8(bitPattern: core.type))),
                                    cluster: Int(core.cluster))
            guard let old = oldCores[core.id] else { return sample }
            // Wrapping subtraction matches the 32-bit kernel tick counters.
            let user = Double(core.user &- old.user), system = Double(core.system &- old.system)
            let nice = Double(core.nice &- old.nice), idle = Double(core.idle &- old.idle)
            let total = user + system + nice + idle
            guard total > 0 else { return sample }
            sample.busy = 100 * (user + system + nice) / total
            sample.user = 100 * (user + nice) / total
            sample.system = 100 * system / total
            return sample
        }
        let busy = cores.compactMap(\.busy)
        cpuAverage = busy.isEmpty ? nil : busy.reduce(0, +) / Double(busy.count)

        if let m = raw.memory {
            memory = MemorySample(total: m.total, used: m.used, app: m.app, wired: m.wired,
                                  compressed: m.compressed, cached: m.cached,
                                  swapUsed: m.swap_used, swapTotal: m.swap_total)
        }

        if let d = raw.disk { disk = d }

        var oldProcesses: [Int32: rv_process] = [:]
        for process in before?.processes ?? [] { oldProcesses[process.pid] = process }
        let elapsed = before.map { $0.time.duration(to: raw.time) / .seconds(1) } ?? 0
        processes = raw.processes.map { p in
            var cpu: Double?
            // A reused pid has a different start time, so it is treated as a new process.
            if let old = oldProcesses[p.pid], old.start_id == p.start_id, p.cpu_ns >= old.cpu_ns,
               elapsed > 0 {
                cpu = Double(p.cpu_ns - old.cpu_ns) / (elapsed * 1e9) * 100
            }
            return ProcessSample(id: Int(p.pid), name: string(p.name), cpu: cpu,
                                 memory: p.resident_bytes)
        }

        gpus = raw.gpus.map { g in
            GpuSample(name: string(g.name), utilization: optional(g.utilization),
                      usedBytes: optional(g.used_bytes),
                      cores: optional(g.core_count).map { Int($0) })
        }

        if let cpuAverage {
            historyCounter += 1
            history.append(HistoryPoint(id: historyCounter, cpu: cpuAverage,
                                        memory: memory.usedPercent, gpu: gpuUtilization))
            if history.count > Self.historyLength { history.removeFirst() }
        }
    }
}
