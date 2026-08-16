import Darwin
import Foundation
import IOKit

struct SystemSnapshot {
    var cpuPercent: Double
    var memoryPercent: Double
    var diskPercent: Double
    var gpuPercent: Double
    var networkDownBytesPerSec: Double
    var networkUpBytesPerSec: Double
    var localIPv4: String
}

final class SystemStats {
    private var prevCpu: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var prevNetIn: UInt64 = 0
    private var prevNetOut: UInt64 = 0
    private var prevNetAt: TimeInterval = 0
    private var lastNetRate: (down: Double, up: Double) = (0, 0)

    func snapshot() -> SystemSnapshot {
        let mem = memoryUsage()
        let memPercent: Double = mem.total > 0 ? Double(mem.used) / Double(mem.total) * 100 : 0
        let net = networkRate()
        return SystemSnapshot(
            cpuPercent: cpuPercent(),
            memoryPercent: memPercent,
            diskPercent: diskPercent(),
            gpuPercent: gpuPercent(),
            networkDownBytesPerSec: net.down,
            networkUpBytesPerSec: net.up,
            localIPv4: localIPv4()
        )
    }

    private func cpuPercent() -> Double {
        guard let current = cpuTicks() else { return 0 }
        defer { prevCpu = current }
        guard let prev = prevCpu else { return 0 }
        let user = Double(current.user &- prev.user)
        let system = Double(current.system &- prev.system)
        let idle = Double(current.idle &- prev.idle)
        let nice = Double(current.nice &- prev.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return ((user + system + nice) / total) * 100
    }

    private func cpuTicks() -> (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3)
    }

    private func memoryUsage() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        let used =
            (UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count))
            * page
        return (min(used, total), total)
    }

    private func networkRate() -> (down: Double, up: Double) {
        let bytes = interfaceBytes()
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            prevNetIn = bytes.in
            prevNetOut = bytes.out
            prevNetAt = now
        }
        guard prevNetAt > 0 else { return lastNetRate }
        let dt = now - prevNetAt
        guard dt >= 0.2 else { return lastNetRate }
        let deltaIn = bytes.in >= prevNetIn ? bytes.in - prevNetIn : 0
        let deltaOut = bytes.out >= prevNetOut ? bytes.out - prevNetOut : 0
        let cap = 1_250_000_000.0
        let down = min(Double(deltaIn) / dt, cap)
        let up = min(Double(deltaOut) / dt, cap)
        lastNetRate = (down, up)
        return lastNetRate
    }

    private func interfaceBytes() -> (in: UInt64, out: UInt64) {
        let listed = interfaceBytesFromRouteTable()
        if listed.in > 0 || listed.out > 0 { return listed }
        return interfaceBytesFromGetIfAddrs()
    }

    private func interfaceBytesFromRouteTable() -> (in: UInt64, out: UInt64) {
        var needed: size_t = 0
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else {
            return (0, 0)
        }
        var buffer = [UInt8](repeating: 0, count: Int(needed))
        let ok = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &needed, nil, 0) == 0
        }
        guard ok else { return (0, 0) }

        var enIn: UInt64 = 0
        var enOut: UInt64 = 0
        var tunIn: UInt64 = 0
        var tunOut: UInt64 = 0

        buffer.withUnsafeBytes { raw in
            guard var ptr = raw.baseAddress else { return }
            let end = ptr.advanced(by: Int(needed))
            while ptr.distance(to: end) >= MemoryLayout<if_msghdr>.size {
                let hdr = ptr.assumingMemoryBound(to: if_msghdr.self).pointee
                let length = Int(hdr.ifm_msglen)
                guard length > 0, ptr.distance(to: end) >= length else { break }
                if hdr.ifm_type == UInt8(RTM_IFINFO2),
                   length >= MemoryLayout<if_msghdr2>.size
                {
                    let msg = ptr.assumingMemoryBound(to: if_msghdr2.self).pointee
                    let flags = Int32(msg.ifm_flags)
                    if (flags & IFF_LOOPBACK) != IFF_LOOPBACK {
                        let sdlPtr = ptr.advanced(by: MemoryLayout<if_msghdr2>.stride)
                        let name = linkName(sdlPtr)
                        let ibytes = msg.ifm_data.ifi_ibytes
                        let obytes = msg.ifm_data.ifi_obytes
                        if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                            enIn &+= ibytes
                            enOut &+= obytes
                        } else if name.hasPrefix("utun") || name.hasPrefix("ipsec") {
                            tunIn &+= ibytes
                            tunOut &+= obytes
                        }
                    }
                }
                ptr = ptr.advanced(by: length)
            }
        }

        if enIn > 0 || enOut > 0 {
            return (enIn, enOut)
        }
        return (tunIn, tunOut)
    }

    private func linkName(_ sdlPtr: UnsafeRawPointer) -> String {
        let nlen = Int(sdlPtr.load(fromByteOffset: 5, as: UInt8.self))
        guard nlen > 0, nlen < 32 else { return "" }
        let bytes = UnsafeRawBufferPointer(start: sdlPtr.advanced(by: 8), count: nlen)
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private func interfaceBytesFromGetIfAddrs() -> (in: UInt64, out: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var input: UInt64 = 0
        var output: UInt64 = 0
        var cursor = ifaddr
        while let ptr = cursor {
            let iface = ptr.pointee
            cursor = iface.ifa_next
            let flags = Int32(bitPattern: iface.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) != IFF_LOOPBACK else {
                continue
            }
            let name = String(cString: iface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") || name.hasPrefix("utun") else {
                continue
            }
            guard let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else {
                continue
            }
            guard let raw = iface.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            input += UInt64(data.ifi_ibytes)
            output += UInt64(data.ifi_obytes)
        }
        return (input, output)
    }

    func localIPv4() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return "—" }
        defer { freeifaddrs(ifaddr) }

        var preferred: String?
        var fallback: String?
        var cursor = ifaddr
        while let ptr = cursor {
            let iface = ptr.pointee
            cursor = iface.ifa_next
            let flags = Int32(bitPattern: iface.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) != IFF_LOOPBACK else {
                continue
            }
            guard let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard ok == 0 else { continue }
            let ip = String(cString: hostname)
            let name = String(cString: iface.ifa_name)
            if name.hasPrefix("en") {
                preferred = ip
                break
            }
            if fallback == nil { fallback = ip }
        }
        return preferred ?? fallback ?? "—"
    }

    private func diskPercent() -> Double {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = attrs[.systemSize] as? NSNumber,
              let free = attrs[.systemFreeSize] as? NSNumber
        else { return 0 }
        let t = total.doubleValue
        guard t > 0 else { return 0 }
        return min(100, max(0, (t - free.doubleValue) / t * 100))
    }

    private func gpuPercent() -> Double {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator") else { return 0 }
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        var total = 0.0
        var samples = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0)
                == KERN_SUCCESS,
                let props = propsRef?.takeRetainedValue() as? [String: Any]
            else { continue }
            let stats = props["PerformanceStatistics"] as? [String: Any] ?? [:]
            let keys = [
                "Device Utilization %",
                "GPU Busy",
                "gpu-busy",
                "Renderer Utilization %",
                "Tiler Utilization %",
            ]
            for key in keys {
                if let value = numberValue(stats[key]) {
                    var pct = value
                    if pct <= 1.0 { pct *= 100 }
                    total += min(100, max(0, pct))
                    samples += 1
                    break
                }
            }
        }
        guard samples > 0 else { return 0 }
        return min(100, total / Double(samples))
    }

    private func numberValue(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber:
            return n.doubleValue
        case let d as Double:
            return d
        case let i as Int:
            return Double(i)
        default:
            return nil
        }
    }
}
