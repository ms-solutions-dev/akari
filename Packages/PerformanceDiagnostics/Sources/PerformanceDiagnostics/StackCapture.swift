import Darwin
import Foundation

/// **The call stack of the main thread while it hangs**
///
/// Averages from stack samples hide a single 600 ms hang in eight seconds of measurement —
/// seen with the webtoon. So the hang watchdog stops the main thread at the moment it crosses
/// the threshold, reads program counter and frame chain and lets it run on: the approach of
/// PLCrashReporter, without a signal.
///
/// **What is read** is only the stack of the stopped thread — memory of its own that does
/// not move while the thread stands. Resolving happens afterwards with `dladdr`:
/// debug builds show names there, release builds show image and offset, which become names
/// on a workstation with the build's dSYM (`atos -o … -l <load address> <address>`).
enum StackCapture {

    /// The main thread as a Mach port — read once on the main thread itself.
    nonisolated(unsafe) static var mainThread: thread_t = 0

    /// Remembers the main thread. Call on the main thread.
    static func rememberMainThread() {
        mainThread = mach_thread_self()
    }

    /// At most this many frames.
    static let depth = 48

    /// Stops the main thread, reads its return addresses and lets it run on.
    static func capture() -> [UInt] {
        #if arch(arm64)
            let thread = mainThread
            guard thread != 0, thread_suspend(thread) == KERN_SUCCESS else { return [] }
            defer { thread_resume(thread) }
            var phase = arm_thread_state64_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &phase) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                    thread_get_state(thread, ARM_THREAD_STATE64, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return [] }
            // Strip pointer authentication: the upper bits are not part of the address.
            func strip(_ a: UInt64) -> UInt { UInt(a & 0x0000_000F_FFFF_FFFF) }
            var addresses: [UInt] = [strip(phase.__pc), strip(phase.__lr)]
            var frames = strip(phase.__fp)
            // The frame chain: [fp] = previous fp, [fp+8] = return address.
            while addresses.count < depth, frames != 0, frames % 8 == 0 {
                var pair: (UInt64, UInt64) = (0, 0)
                var read: vm_size_t = 0
                let ok = withUnsafeMutableBytes(of: &pair) { buffer in
                    vm_read_overwrite(
                        mach_task_self_, vm_address_t(frames), vm_size_t(16),
                        vm_address_t(UInt(bitPattern: buffer.baseAddress)), &read)
                }
                guard ok == KERN_SUCCESS, read == 16 else { break }
                let ret = strip(pair.1)
                if ret == 0 { break }
                addresses.append(ret)
                let next = strip(pair.0)
                guard next > frames else { break }
                frames = next
            }
            return addresses
        #else
            return []
        #endif
    }

    /// Turns addresses into readable lines: "Akari.debug.dylib  Shelf.genres(_:) +428" or,
    /// without a symbol, "Akari  0x1a2b3c (Ladeadresse 0x100000000)".
    static func resolve(_ addresses: [UInt]) -> [String] {
        addresses.map { address in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
                return String(format: "?  0x%lx", address)
            }
            let image =
                info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
            let base = UInt(bitPattern: info.dli_fbase)
            if let name = info.dli_sname {
                let offset = address - UInt(bitPattern: info.dli_saddr)
                return "\(image)  \(demangle(String(cString: name))) +\(offset)"
            }
            return String(format: "%@  0x%lx (load address 0x%lx)", image, address, base)
        }
    }

    /// Makes Swift names readable — via the runtime, if it offers it.
    private static func demangle(_ name: String) -> String {
        typealias Demangler =
            @convention(c) (
                UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
            ) -> UnsafeMutablePointer<CChar>?
        guard let handle = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else {
            return name
        }
        let demangle = unsafeBitCast(handle, to: Demangler.self)
        guard let result = name.withCString({ demangle($0, strlen($0), nil, nil, 0) }) else { return name }
        defer { free(result) }
        return String(cString: result)
    }
}
