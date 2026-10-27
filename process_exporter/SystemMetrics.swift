import Foundation
import Darwin

struct NetworkBytes {
    let received: UInt64
    let transmitted: UInt64
}

// Collect outside the HTTP queue so nettop startup cannot delay scrapes.
final class NetworkCollector {
    private let queue = DispatchQueue(label: "process-exporter.network", qos: .utility)
    private let lock = NSLock()
    private var values: [Int32: NetworkBytes] = [:]
    private var success = false
    private var updated: TimeInterval = 0

    func snapshot() -> ([Int32: NetworkBytes], Bool, TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (values, success, updated)
    }

    func start() {
        queue.async { self.collect() }
    }

    private func collect() {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var result: [Int32: NetworkBytes] = [:]
        var ok = false
        do {
            try process.run()
            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            if process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    var columns = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    if columns.last == "" { columns.removeLast() }
                    guard columns.count >= 3,
                          let sent = UInt64(columns.removeLast()),
                          let received = UInt64(columns.removeLast()) else { continue }
                    // Process names may contain dots or commas; PID is the final suffix.
                    let name = columns.joined(separator: ",")
                    guard let suffix = name.split(separator: ".").last,
                          let pid = Int32(suffix) else { continue }
                    result[pid] = NetworkBytes(received: received, transmitted: sent)
                }
                ok = !result.isEmpty
            }
        } catch {
            // Report failure separately; preserve the last good sample and its age.
        }
        output.fileHandleForReading.closeFile()
        lock.lock()
        success = ok
        if ok {
            values = result
            updated = Date().timeIntervalSince1970
        }
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 10) { self.collect() }
    }
}

func cpuCount(_ key: String) -> Int32 {
    var count: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(key, &count, &size, nil, 0) == 0 else { return 0 }
    return count
}

func escapeLabel(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

let networkCollector = NetworkCollector()
