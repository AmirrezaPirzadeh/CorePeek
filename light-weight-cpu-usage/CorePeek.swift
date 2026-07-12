import SwiftUI
import Combine
import ServiceManagement
import UserNotifications

// MARK: - Display mode

enum MenuBarStyle: String, CaseIterable {
    case percentage = "Percentage"
    case icon = "Icon Only"
    case graph = "Mini Graph"
}

// MARK: - CPU + Memory sampling

final class CPUMonitor: ObservableObject {
    @Published var usage: Double = 0
    @Published var perCoreUsage: [Double] = []
    @Published var memoryUsedGB: Double = 0
    @Published var memoryTotalGB: Double = 0
    @Published var history: [Double] = []

    private let historyLimit = 30
    private var prevInfo: [UInt32] = []
    private var timer: Timer?
    private let notifier: NotificationManager

    var refreshInterval: TimeInterval = 2.0 {
        didSet { restartTimer() }
    }

    var alertThreshold: Double = 90 // 0 disables

    init(notifier: NotificationManager) {
        self.notifier = notifier
        _ = sampleCPUDetailed()
        memoryTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 0.5
    }

    private func tick() {
        let (total, perCore) = sampleCPUDetailed()
        usage = total
        perCoreUsage = perCore
        memoryUsedGB = sampleMemoryUsedGB()

        history.append(total)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }

        if alertThreshold > 0 && total >= alertThreshold {
            notifier.notifyHighUsage(usage: total)
        }
    }

    private func sampleCPUDetailed() -> (total: Double, perCore: [Double]) {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t!
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &infoArray,
            &infoCount
        )
        guard result == KERN_SUCCESS else { return (0, []) }

        let cpuLoadInfo = infoArray.withMemoryRebound(
            to: integer_t.self,
            capacity: Int(infoCount)
        ) { $0 }

        var current: [UInt32] = []
        let fieldsPerCPU = Int(CPU_STATE_MAX)
        for i in 0..<Int(cpuCount) {
            for j in 0..<fieldsPerCPU {
                current.append(UInt32(cpuLoadInfo[i * fieldsPerCPU + j]))
            }
        }

        let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray), size)

        defer { prevInfo = current }
        guard prevInfo.count == current.count else { return (0, []) }

        var totalUsed: UInt64 = 0
        var totalTicks: UInt64 = 0
        var perCore: [Double] = []

        for i in stride(from: 0, to: current.count, by: fieldsPerCPU) {
            let user = UInt64(current[i] &- prevInfo[i])
            let system = UInt64(current[i + 1] &- prevInfo[i + 1])
            let idle = UInt64(current[i + 2] &- prevInfo[i + 2])
            let nice = UInt64(current[i + 3] &- prevInfo[i + 3])
            let used = user + system + nice
            let ticks = used + idle
            perCore.append(ticks > 0 ? (Double(used) / Double(ticks)) * 100 : 0)
            totalUsed += used
            totalTicks += ticks
        }

        let total = totalTicks > 0 ? (Double(totalUsed) / Double(totalTicks)) * 100 : 0
        return (total, perCore)
    }

    private func sampleMemoryUsedGB() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let pageSize = Double(vm_kernel_page_size)
        let usedPages = Double(stats.active_count + stats.inactive_count + stats.wire_count + stats.compressor_page_count)
        return (usedPages * pageSize) / 1_073_741_824
    }
}

// MARK: - Disk sampling

final class DiskMonitor: ObservableObject {
    @Published var usedGB: Double = 0
    @Published var totalGB: Double = 0

    init() { refresh() }

    func refresh() {
        guard let path = URL(string: NSHomeDirectory()),
              let values = try? path.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity else { return }

        totalGB = Double(total) / 1_073_741_824
        usedGB = totalGB - Double(available) / 1_073_741_824
    }
}

// MARK: - Network throughput sampling

final class NetworkMonitor: ObservableObject {
    @Published var downloadKBs: Double = 0
    @Published var uploadKBs: Double = 0

    private var prevIn: UInt64 = 0
    private var prevOut: UInt64 = 0
    private var timer: Timer?

    init() {
        (prevIn, prevOut) = Self.sampleCounters()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let (curIn, curOut) = Self.sampleCounters()
        downloadKBs = Double(curIn &- prevIn) / 1024 / 2.0
        uploadKBs = Double(curOut &- prevOut) / 1024 / 2.0
        prevIn = curIn
        prevOut = curOut
    }

    private static func sampleCounters() -> (UInt64, UInt64) {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return (0, 0) }
        defer { freeifaddrs(ifaddrPtr) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let name = String(cString: current.pointee.ifa_name)
            if (flags & IFF_UP) != 0 && !name.hasPrefix("lo"),
               let data = current.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                totalIn += UInt64(data.pointee.ifi_ibytes)
                totalOut += UInt64(data.pointee.ifi_obytes)
            }
            ptr = current.pointee.ifa_next
        }
        return (totalIn, totalOut)
    }
}

// MARK: - Top processes

struct ProcessInfoItem: Identifiable {
    let id = UUID()
    let name: String
    let cpu: Double
}

final class ProcessMonitor: ObservableObject {
    @Published var topProcesses: [ProcessInfoItem] = []
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Aceo", "pcpu,comm", "-r"]

        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
        } catch {
            return
        }
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        let lines = output.split(separator: "\n").dropFirst().prefix(5)
        topProcesses = lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { return nil }
            let cpuStr = trimmed[trimmed.startIndex..<spaceIdx]
            let name = trimmed[trimmed.index(after: spaceIdx)...].trimmingCharacters(in: .whitespaces)
            guard let cpu = Double(cpuStr) else { return nil }
            return ProcessInfoItem(name: name, cpu: cpu)
        }
    }
}

// MARK: - Notifications

final class NotificationManager {
    private var lastNotified: Date?
    private let cooldown: TimeInterval = 120

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyHighUsage(usage: Double) {
        if let last = lastNotified, Date().timeIntervalSince(last) < cooldown { return }
        lastNotified = Date()

        let content = UNMutableNotificationContent()
        content.title = "High CPU Usage"
        content.body = String(format: "CPU usage is at %.0f%%", usage)
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Launch at login

final class LaunchAtLogin: ObservableObject {
    @Published var isEnabled: Bool = SMAppService.mainApp.status == .enabled {
        didSet { apply() }
    }

    private func apply() {
        do {
            if isEnabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            print("LaunchAtLogin error: \(error)")
        }
    }
}

// MARK: - Sparkline view

struct SparklineView: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1 else { return }
                let maxVal = max(values.max() ?? 1, 1)
                let stepX = geo.size.width / CGFloat(values.count - 1)
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = geo.size.height - (CGFloat(v / maxVal) * geo.size.height)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
    }
}

// MARK: - Menu content

struct MenuContent: View {
    @ObservedObject var monitor: CPUMonitor
    @ObservedObject var diskMonitor: DiskMonitor
    @ObservedObject var networkMonitor: NetworkMonitor
    @ObservedObject var processMonitor: ProcessMonitor
    @ObservedObject var launchAtLogin: LaunchAtLogin

    @AppStorage("refreshInterval") private var refreshInterval: Double = 2.0
    @AppStorage("menuBarStyle") private var menuBarStyle: String = MenuBarStyle.percentage.rawValue
    @AppStorage("alertThreshold") private var alertThreshold: Double = 90
    @AppStorage("showTopProcesses") private var showTopProcesses: Bool = true

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear {
                monitor.refreshInterval = refreshInterval
                monitor.alertThreshold = alertThreshold
            }

        Text(String(format: "Total: %.0f%%", monitor.usage))

        if !monitor.perCoreUsage.isEmpty {
            Divider()
            ForEach(Array(monitor.perCoreUsage.enumerated()), id: \.offset) { index, value in
                Text(String(format: "Core %d: %.0f%%", index, value))
            }
        }

        Divider()
        Text(String(format: "Memory: %.1f / %.1f GB", monitor.memoryUsedGB, monitor.memoryTotalGB))
        Text(String(format: "Disk: %.0f / %.0f GB", diskMonitor.usedGB, diskMonitor.totalGB))
        Text(String(format: "Net: ↓%.0f KB/s  ↑%.0f KB/s", networkMonitor.downloadKBs, networkMonitor.uploadKBs))

        if showTopProcesses && !processMonitor.topProcesses.isEmpty {
            Divider()
            Text("Top Processes")
            ForEach(processMonitor.topProcesses) { proc in
                Text(String(format: "%.0f%%  %@", proc.cpu, proc.name))
            }
        }

        Divider()
        Menu("Refresh Interval") {
            ForEach([1.0, 2.0, 5.0, 10.0], id: \.self) { interval in
                Button("\(Int(interval))s") {
                    refreshInterval = interval
                    monitor.refreshInterval = interval
                }
            }
        }

        Menu("Menu Bar Style") {
            ForEach(MenuBarStyle.allCases, id: \.self) { style in
                Button(style.rawValue) { menuBarStyle = style.rawValue }
            }
        }

        Menu("Alert Threshold") {
            ForEach([0.0, 70.0, 80.0, 90.0, 95.0], id: \.self) { threshold in
                Button(threshold == 0 ? "Off" : "\(Int(threshold))%") {
                    alertThreshold = threshold
                    monitor.alertThreshold = threshold
                }
            }
        }

        Toggle("Show Top Processes", isOn: $showTopProcesses)
        Toggle("Launch at Login", isOn: $launchAtLogin.isEnabled)

        Divider()
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

// MARK: - Menu bar label

struct MenuBarLabel: View {
    @ObservedObject var monitor: CPUMonitor
    @AppStorage("menuBarStyle") private var menuBarStyle: String = MenuBarStyle.percentage.rawValue

    var body: some View {
        switch MenuBarStyle(rawValue: menuBarStyle) ?? .percentage {
        case .percentage:
            Text(String(format: "%.0f%%", monitor.usage))
                .monospacedDigit()
                .foregroundStyle(labelColor)
        case .icon:
            Image(systemName: "cpu")
                .foregroundStyle(labelColor)
        case .graph:
            SparklineView(values: monitor.history)
                .frame(width: 40, height: 16)
        }
    }

    private var labelColor: Color {
        switch monitor.usage {
        case ..<50: return .primary
        case 50..<80: return .orange
        default: return .red
        }
    }
}

// MARK: - App

@main
struct light_weight_cpu_usageApp: App {
    private let notifier: NotificationManager
    @StateObject private var monitor: CPUMonitor
    @StateObject private var diskMonitor = DiskMonitor()
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var processMonitor = ProcessMonitor()
    @StateObject private var launchAtLogin = LaunchAtLogin()

    init() {
        let n = NotificationManager()
        notifier = n
        _monitor = StateObject(wrappedValue: CPUMonitor(notifier: n))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                monitor: monitor,
                diskMonitor: diskMonitor,
                networkMonitor: networkMonitor,
                processMonitor: processMonitor,
                launchAtLogin: launchAtLogin
            )
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.menu)
    }
}
