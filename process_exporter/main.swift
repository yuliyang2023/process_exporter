import Foundation
import Network

struct ProcessInfo {
    let pid: Int32
    let path: String
    let pti_total_user: UInt64
    let pti_total_system: UInt64
    let pti_resident_size: UInt64
    let pbi_ppid: UInt32
    let pbi_uid: UInt32
    let pbi_gid: UInt32
    let pbi_start_tvsec: UInt64
}

func getExecutablePath(for pid: Int32) -> String? {
    var path = [CChar](repeating: 0, count: Int(PATH_MAX))
    let result = proc_pidpath(pid, &path, UInt32(PATH_MAX))
    return result > 0 ? String(cString: path) : nil
}

func getProcessInfo(for pid: Int32, number: UInt64, denom: UInt64) -> ProcessInfo? {
    var info = proc_taskallinfo()
    let size = MemoryLayout.size(ofValue: info)
    
    let result = withUnsafeMutablePointer(to: &info) { ptr in
        return proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, ptr, Int32(size))
    }
    if (result < 0) {
        return nil
    }
    if (info.pbsd.pbi_ppid == 0) {
        return nil
    }
    let path = getExecutablePath(for: pid)
    if path == nil || path == "" {
        return nil
    }
    
    return ProcessInfo(
        pid: pid,
        path: path!,
        pti_total_user: (info.ptinfo.pti_total_user * number / denom) / 1_000_000_000,
        pti_total_system: (info.ptinfo.pti_total_system * number / denom) / 1_000_000_000,
        pti_resident_size: info.ptinfo.pti_resident_size,
        pbi_ppid: info.pbsd.pbi_ppid,
        pbi_uid: info.pbsd.pbi_uid,
        pbi_gid: info.pbsd.pbi_gid,
        pbi_start_tvsec: info.pbsd.pbi_start_tvsec
    )
}

func getPids() -> [Int32] {
    let pids = UnsafeMutablePointer<pid_t>.allocate(capacity: 4096)
    defer { pids.deallocate() }
    let count = proc_listallpids(pids, Int32(4096) * Int32(MemoryLayout<pid_t>.size))
    var arr = [Int32]()
    for i in 0..<Int(count) {
        arr.append(pids[i])
    }
    return arr
}

func getProcesses() -> [ProcessInfo] {
    var timebaseInfo = mach_timebase_info_data_t()
    mach_timebase_info(&timebaseInfo)
    let number = UInt64(timebaseInfo.numer)
    let denom = UInt64(timebaseInfo.denom)
    let pids = getPids()
    var result = [ProcessInfo]()

    for pid in pids {
        if let info = getProcessInfo(for: pid, number: number, denom: denom) {
            if info.pid == 0 { continue }
            if info.pbi_ppid == 0 { continue }
            if info.path == "" { continue }
            result.append(info)
        }
    }

    return result
}

func getPrometheusMetrics() -> String {
    var metrics = [String]()
    
    // Add metric descriptions (HELP and TYPE)
    metrics.append("# HELP process_start_time_seconds Start time of the process since unix epoch in seconds")
    metrics.append("# TYPE process_start_time_seconds gauge")
    
    metrics.append("# HELP process_cpu_seconds_total Total user and system CPU time spent in seconds")
    metrics.append("# TYPE process_cpu_seconds_total counter")
    
    metrics.append("# HELP process_resident_memory_bytes Resident memory size in bytes")
    metrics.append("# TYPE process_resident_memory_bytes gauge")
    
    // Collect metrics for each process
    for info in getProcesses() {
        let labels = "pid=\"\(info.pid)\",ppid=\"\(info.pbi_ppid)\",uid=\"\(info.pbi_uid)\",gid=\"\(info.pbi_gid)\",path=\"\(info.path)\""
        
        // Start time
        metrics.append("process_start_time_seconds{\(labels)} \(info.pbi_start_tvsec)")
        
        // CPU times
        metrics.append("process_cpu_seconds_total{\(labels),mode=\"user\"} \(info.pti_total_user)")
        metrics.append("process_cpu_seconds_total{\(labels),mode=\"system\"} \(info.pti_total_system)")
        
        // Memory
        metrics.append("process_resident_memory_bytes{\(labels)} \(info.pti_resident_size)")
    }
    
    return metrics.joined(separator: "\n")
}

// https://ko9.org/posts/simple-swift-web-server/
let listener = try! NWListener(using: .tcp, on: 9256)
listener.newConnectionHandler = { connection in
    connection.start(queue: .main)
    // Read the HTTP request before sending the response. Cancelling a connection
    // with unread request bytes can reset it and truncate a large metrics body.
    func receiveRequest(_ buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var request = buffered
            if let data = data { request.append(data) }
            if request.range(of: Data([13, 10, 13, 10])) != nil {
                let metrics = getPrometheusMetrics() + "\n"
                let headers = "HTTP/1.1 200 OK\r\n"
                    + "Content-Length: \(metrics.utf8.count)\r\n"
                    + "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n"
                    + "Connection: close\r\n\r\n"
                connection.send(content: (headers + metrics).data(using: .utf8),
                                contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in })
            } else if complete || error != nil || request.count >= 65536 {
                connection.cancel()
            } else {
                receiveRequest(request)
            }
        }
    }
    receiveRequest(Data())
}

print("open http://localhost:9256/metrics")
listener.start(queue: .main)
RunLoop.current.run()
