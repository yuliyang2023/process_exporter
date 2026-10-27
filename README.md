# process_exporter (macos)

Oversimplified Prometheus process exporter built for MacOS

**Motivation**: there is [process_exporter](https://github.com/ncabatoff/process-exporter) project but it [does not have MacOS support](https://github.com/ncabatoff/process-exporter/issues/63)

## Quick start

```bash
wget https://github.com/mac2000/process_exporter/releases/download/v1.0.1/process_exporter
chmod +x process_exporter
./process_exporter
open http://localhost:9256/metrics
```

To run in as a service create `~/Library/LaunchAgents/process_exporter`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <!-- Basic service information -->
    <key>Label</key>
    <string>process_exporter</string>

    <!-- Start after system -->
    <key>LimitLoadToSessionType</key>
    <array>
      <string>Aqua</string>
      <string>Background</string>
      <string>LoginWindow</string>
      <string>StandardIO</string>
      <string>System</string>
    </array>

    <!-- Command to execute and its arguments -->
    <key>Program</key>
    <string>/usr/local/bin/process_exporter</string> <!-- CHANGE ME -->

    <!-- Run configuration -->
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>

    <!-- Log files -->
    <key>StandardOutPath</key>
    <string>/path/to/stdout.log</string> <!-- CHANGE ME -->
    <key>StandardErrorPath</key>
    <string>/path/to/stderr.log</string> <!-- CHANGE ME -->
  </dict>
</plist>
```

and start it

```bash
launchctl load ~/Library/LaunchAgents/process_exporter
```

Prometheus may be configured like so

```yaml
global:
  scrape_interval: 30s
scrape_configs:
  - job_name: 'process'
    static_configs:
      - targets: ['localhost:9256']
```

and to apply changes run:

```bash
curl -X POST localhost:9090/-/reload -i
```

## Metrics

- `process_start_time_seconds` - timestamp of when service was started, useful for uptime widget
- `process_resident_memory_bytes` - memory bytes used by process
- `process_cpu_seconds_total` - user and system CPU seconds consumed by process

## Labels

- `pid` - process id
- `ppid` - parent process id
- `uid` - user id
- `guid` - group id
- `path` - executable path

## Query samples

**cpu usage**

```
sum(rate(process_cpu_seconds_total{path="/Applications/Plex Media Server.app/Contents/MacOS/Plex Media Server"}[2m])) by (mode)
```

**memory usage**

```
process_resident_memory_bytes{path="/Applications/Plex Media Server.app/Contents/MacOS/Plex Media Server"}
```

**uptime**

```
process_start_time_seconds{path="/opt/homebrew/Cellar/traefik/3.3.4/bin/traefik"}
```

## Build

To build it, you need XCode build tools

```bash
swiftc process_exporter/*.swift
```

## ps

You may ask, why not just use `ps` utility, and will be completelly correct, under the hood it does exactly the same

Closest possible output may be formed like so:

```bash
ps -eo pid,ppid,uid,gid,comm,rss,utime,stime,lstart
```

technically, you can even do something like:

```bash
#!/usr/bin/env bash

# ./process_exporter.sh 8080 - will start exporter on port 8080
# ./process_exporter.sh - will print metrics

function metrics() {
  lines=$(ps -o pid,ucomm,rss,time,ppid | tail -n +2)

  echo "# HELP process_rss_bytes The real memory (resident set) size of the process (in 1024 byte units)"
  echo "# TYPE process_rss_bytes gauge"
  echo "$lines" | awk '{print "process_rss_bytes{pid=\""$1"\",command=\""$2"\"}", $3}'
  echo ""
}

if [ -n "$1" ]
then
  while true
  do
    {
      echo "HTTP/1.1 200 OK"
      echo "Content-Type: text/plain; charset=utf-8"
      echo ""
      metrics
    } | nc -l $1
  done
else
  metrics
fi
```

but as you may guess, pretty quickly it becomes unusable, e.g. even if we do not care about the fact that metrics will be little bit behind, the real problem starts when we will try to convert the numbers like `12:04.23` to seconds

but at least, with this example we know little bit more about:

- `man ps` - what's inside, and what metrics available
- `nc -l 8080` - minimalistic http server

## C

Original [process_exporter](https://github.com/ncabatoff/process-exporter) can not work with MacOS because there is no `/proc`

But then where does `ps` takes data from?

There is `libproc` containing all the functions that are used under the hood

Here are few very small examples for `main.c`, each expected to be build and run as `gcc -o main main.c && ./main`

**retrieve process info**

```c
#include <stdio.h>
#include <libproc.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/sysctl.h>

int main() {
	pid_t pid = 44188;
	struct proc_taskallinfo info;
	if (proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, sizeof(info)) > 0) {
		printf("pti_total_user: %llu\n", info.ptinfo.pti_total_user); // note: that are ticks, not seconds, required processing
		printf("pti_total_system: %llu\n", info.ptinfo.pti_total_system);
		printf("pti_resident_size: %llu\n", info.ptinfo.pti_resident_size);
		printf("pbi_pid: %u\n", info.pbsd.pbi_pid);
		printf("pbi_ppid: %u\n", info.pbsd.pbi_ppid);
		printf("pbi_uid: %u\n", info.pbsd.pbi_uid);
		printf("pbi_gid: %u\n", info.pbsd.pbi_gid);
		printf("pbi_comm: %s\n", info.pbsd.pbi_comm);
		printf("pbi_name: %s\n", info.pbsd.pbi_name);
		printf("pbi_start_tvsec: %llu\n", info.pbsd.pbi_start_tvsec);

		// note: this one is slow
		int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    char args[ARG_MAX];
    size_t size = sizeof(args);

    if (sysctl(mib, 3, args, &size, NULL, 0) == -1) {
      return 1;
    }

		// first int contains number of arguments, then N arguments, rest are environment variables
		// take frist string after first int
		char *exe_path = args + sizeof(int);
    printf("Executable Path: %s\n", exe_path);
	}
}
```

**list processess**

```c
#include <stdio.h>
#include <libproc.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/sysctl.h>

int main() {
	pid_t pids[4096];
	int num_pids = proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof(pids)) / sizeof(pid_t);
	if (num_pids < 0) {
		return 1;
	}

	for (int i = 0; i < num_pids; i++) {
		if (pids[i] <= 0) continue;
		struct proc_taskallinfo info;
		int status = proc_pidinfo(pids[i], PROC_PIDTASKALLINFO, 0, &info, sizeof(info));
		if (status <= 0) continue;

		// much faster than sysctl
		char path[PATH_MAX];
		if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) {
			continue;
		}

		printf("pid: %d, comm: %s, path: %s\n", info.pbsd.pbi_pid, info.pbsd.pbi_comm, path);
	}
}
```

## Go

Whole exporter may be written in C, but, it becomes little bit clunky when it comes to Http server

There are some 3rd party libraries to make it easier, but at the very end - goal is to not have dependencies

Thankfully Go can run C code

Here is some example for better understanding how it looks and feels like

```go
package main

/*
#cgo LDFLAGS: -framework CoreFoundation
#include <libproc.h>
#include <stdlib.h>
#include <sys/sysctl.h>

int ps(struct proc_taskallinfo* list, int max_count) {
    pid_t pids[max_count];
    int num_pids = proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof(pids)) / sizeof(pid_t);

    if (num_pids < 0) {
        return 0;
    }

		int counter = 0;
    for (int i = 0; i < num_pids && counter < num_pids; i++) {
        if (pids[i] <= 0) continue;

        struct proc_taskallinfo info;
        int status = proc_pidinfo(pids[i], PROC_PIDTASKALLINFO, 0, &info, sizeof(info));
        if (status <= 0) continue;

				list[counter] = info;
        counter++;
    }

    return counter;
}
*/
import "C"

import (
	"fmt"
)

func main() {
	const maxPids = 4 * 1024
	var list [maxPids]C.struct_proc_taskallinfo
	n := C.ps(&list[0], C.int(maxPids))
	for i := range int(n) {
		info := list[i]

		pti_total_user := uint64(info.ptinfo.pti_total_user)
		// pti_total_system := uint64(info.ptinfo.pti_total_system)
		// pti_resident_size := uint64(info.ptinfo.pti_resident_size)
		pbi_pid := uint32(info.pbsd.pbi_pid)
		// pbi_ppid := uint32(info.pbsd.pbi_ppid)
		// pbi_uid := uint32(info.pbsd.pbi_uid)
		// pbi_start_tvsec := uint64(info.pbsd.pbi_start_tvsec)
		// pbi_gid := uint32(info.pbsd.pbi_gid)
		// pbi_comm := C.GoString(&info.pbsd.pbi_comm[0])
		pbi_name := C.GoString(&info.pbsd.pbi_comm[0])

		fmt.Printf("%5d %8s %5d\n", pbi_pid, pbi_name, pti_total_user)
	}
}
```

works quite nice and fast and we may proceed with that, but the question was "what if ..."

## Swift

Did you know that you may also call C code from Swift and somehow, some of parts, are even simpler than in Go (ok, exceptions are unsafe pointers, but the same is true for Go)

Here are few minimalistic examples, which are expected to be run like so: `swiftc main.swift && ./main`

```swift
import Foundation

print("Hello World")

// allocate memory for pids
let pids = UnsafeMutablePointer<pid_t>.allocate(capacity: 4096)
defer { pids.deallocate() } // do not forget to free the memory
let count = proc_listallpids(pids, Int32(4096) * Int32(MemoryLayout<pid_t>.size))

for i in 0..<Int(count) {
    let pid = pids[i]

    // get process name
    var nameChars = [CChar](repeating: 0, count: Int(PATH_MAX))
    let nameLength = proc_name(pid, &nameChars, UInt32(nameChars.count))
    let name = nameLength > 0 ? String(cString: nameChars) : ""

    // get process path
    var pathChars = [CChar](repeating: 0, count: Int(PATH_MAX))
    let pathLength = proc_pidpath(pid, &pathChars, UInt32(pathChars.count))
    let path = pathLength > 0 ? String(cString: pathChars) : ""

    print("PID: \(pid), Name: \(name), Path: \(path)")
}
```

## Http

Thankfully there was this article [https://ko9.org/posts/simple-swift-web-server/] without it my believing was that writing Http server in Swift will be the same as in C

So here is kind of Hello World web service in Swift

```swift
import Foundation
import Network

// https://ko9.org/posts/simple-swift-web-server/
let listener = try! NWListener(using: .tcp, on: 8080)
listener.newConnectionHandler = { connection in
    connection.stateUpdateHandler = { print("connection.state = \($0)") }
    connection.start(queue: .main)

    let body = "Hello World!\n"
    let response = """
        HTTP/1.1 200 OK
        Content-Length: \(body.count)

        \(body)
        """
    connection.send(content: response.data(using: .utf8), isComplete: true, completion: .contentProcessed({ error in
        connection.cancel()
    }))
}

print("open http://localhost:8080/")
listener.start(queue: .main)
RunLoop.current.run()
```

Technically this process exporter is an final result of all that experiments

At least is solves my goal - collect metrics for local processess running on MacOS

## CPU and per-process network metrics

The Intel workflow targets macOS 13 and later. `process_exporter_cpu_logical_count` and `process_exporter_cpu_physical_count` report host CPU core counts.

The exporter samples `/usr/bin/nettop` every 10 seconds on a background queue and exposes `process_network_receive_bytes_total` and `process_network_transmit_bytes_total` with the same PID and executable path labels as the CPU and memory metrics. Use `rate(...[1m])` to display bytes per second. These are macOS process traffic counters, not available link capacity; VPN/proxy traffic and shared networking services can be attributed to their owning processes. Processes without network records have no network series.

`process_network_collector_success` reports sample health; `process_network_collector_last_success_timestamp_seconds` allows detecting stale data. Network collection does not block HTTP scrapes and each sample has a five-second timeout.
