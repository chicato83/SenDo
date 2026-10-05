import Foundation
import IOKit
import IOKit.usb

// MARK: - Async Read Support

/// Heap buffer shared by every partial read of a single `readExact` call.
/// Kept alive by the pending `ReadRequest` so IOKit never writes into freed memory.
private final class SendoReadBuffer {
    let capacity: Int
    let pointer: UnsafeMutablePointer<UInt8>

    init(capacity: Int) {
        self.capacity = capacity
        self.pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        self.pointer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        pointer.deallocate()
    }
}

/// One in-flight `SenDo_ReadPipeAsync` operation.
/// Ownership: `readExact` holds a strong reference while it waits, and
/// `passRetained` gives one to the completion callback. The buffer is released
/// only when BOTH are gone, so a late callback after a timeout stays safe.
private final class SendoReadRequest {
    let semaphore = DispatchSemaphore(value: 0)
    var result: IOReturn = kIOReturnError
    var bytesRead = 0
    let buffer: SendoReadBuffer

    init(buffer: SendoReadBuffer) {
        self.buffer = buffer
    }
}

/// IOAsyncCallback1: `void (*)(void *refcon, IOReturn result, void *arg0)`.
/// `arg0` carries the byte count of the completed transfer.
private let sendoReadCallback: @convention(c) (UnsafeMutableRawPointer?, IOReturn, UnsafeMutableRawPointer?) -> Void = { refcon, result, arg0 in
    guard let refcon = refcon else { return }
    let request = Unmanaged<SendoReadRequest>.fromOpaque(refcon).takeRetainedValue()
    request.result = result
    request.bytesRead = arg0.map { Int(bitPattern: OpaquePointer($0)) } ?? 0
    request.semaphore.signal()
}

// MARK: - Async Completion Pump

/// Runs the USB interface's async event source on a dedicated thread.
///
/// IOKit does not spawn a thread to call us back: completions are posted to a
/// Mach port that must be wrapped in a CFRunLoopSource and serviced by a running
/// run loop. Without this, `SenDo_ReadPipeAsync` fails immediately with
/// `kIOUSBNoAsyncPortErr` (0xE000405F).
private final class SendoAsyncEventPump {
    private let thread: Thread
    /// Bounded wait so `stop()` does not return while the pump thread is alive.
    private let finished: DispatchSemaphore
    private var runLoop: CFRunLoop?
    private var running = false

    init(iface: UnsafeMutableRawPointer) {
        final class StartResult {
            let ready = DispatchSemaphore(value: 0)
            var result: IOReturn = kIOReturnError
            var runLoop: CFRunLoop?
        }

        let start = StartResult()
        let finished = DispatchSemaphore(value: 0)

        let thread = Thread {
            start.result = SenDo_AttachInterfaceAsyncEventSource(iface)
            start.runLoop = CFRunLoopGetCurrent()
            start.ready.signal()
            if start.result == KERN_SUCCESS {
                CFRunLoopRun()
            }
            finished.signal()
        }
        thread.name = "SenDo USB async pump"
        thread.qualityOfService = .userInitiated
        thread.start()
        start.ready.wait()

        self.thread = thread
        self.finished = finished
        self.runLoop = start.runLoop
        self.running = (start.result == KERN_SUCCESS)
    }

    var isRunning: Bool { running }

    func stop() {
        guard running, let runLoop = runLoop else { return }
        running = false
        SenDoLog.log("USBTransfer: stopping async event pump")
        CFRunLoopStop(runLoop)
        if finished.wait(timeout: .now() + 5) == .timedOut {
            SenDoLog.log("USBTransfer: WARNING — async event pump did not stop within 5s")
        }
    }

    deinit {
        stop()
    }
}

// MARK: - USB Transfer Manager

/// Handles bulk USB data transfer using IOKit IOUSBInterfaceInterface
/// Uses C helper functions for IOKit operations (avoids Swift C function pointer bridging crash)
final class USBTransfer {
    private var ifaceInterface: UnsafeMutableRawPointer?
    private var isOpen = false

    /// Discovered pipe numbers (from endpoint discovery)
    private var outPipe: UInt8 = 0   // bulk OUT (Mac → Switch)
    private var inPipe: UInt8 = 0    // bulk IN  (Switch → Mac)

    /// Services the interface's async completion source. Required before any
    /// `SenDo_ReadPipeAsync` call — see `SendoAsyncEventPump`.
    private var asyncPump: SendoAsyncEventPump?

    init(device: USBDevice) {
        self.ifaceInterface = device.getRawIfaceInterface()
    }

    /// Configure: discover endpoints and store correct pipe numbers
    func configure() throws {
        guard let iface = ifaceInterface else {
            SenDoLog.log("USBTransfer: ifaceInterface is nil!")
            throw USBTransferError.deviceNotReady
        }

        SenDoLog.log("USBTransfer: ifaceInterface = \(iface)")

        // Get number of endpoints (skip SetAlternateInterface — Switch is already at alt 0)
        var numEndpoints: UInt8 = 0
        let numResult = SenDo_GetNumEndpoints(iface, &numEndpoints)
        SenDoLog.log("USBTransfer: GetNumEndpoints result: \(numResult), endpoints: \(numEndpoints)")
        guard numResult == KERN_SUCCESS else {
            throw USBTransferError.getNumEndpointsFailed(numResult)
        }
        SenDoLog.log("USB Endpoints found: \(numEndpoints)")

        // Discover and store pipe numbers
        var foundOUT = false
        var foundIN = false
        for i: UInt8 in 1...numEndpoints {
            var direction: UInt8 = 0
            var number: UInt8 = 0
            var transferType: UInt8 = 0
            var maxPacketSize: UInt16 = 0
            var interval: UInt8 = 0

            let propResult = SenDo_GetPipeProperties(iface, i, &direction, &number, &transferType, &maxPacketSize, &interval)
            if propResult == KERN_SUCCESS {
                // IOKit: kIOUSBEndpointDirectionOut = 0, kIOUSBEndpointDirectionIn = 1
                let dirStr = direction == 0 ? "OUT" : "IN"
                let typeStr: String
                switch transferType {
                case 0: typeStr = "Control"
                case 1: typeStr = "Isochronous"
                case 2: typeStr = "Bulk"
                case 3: typeStr = "Interrupt"
                default: typeStr = "Unknown"
                }
                SenDoLog.log("  Endpoint \(i): \(dirStr), \(typeStr), maxPacketSize: \(maxPacketSize)")

                if direction == 0 && !foundOUT && transferType == 2 {  // OUT + Bulk
                    outPipe = i
                    foundOUT = true
                    SenDoLog.log("  → Assigned as bulk OUT pipe: \(i)")
                } else if direction == 1 && !foundIN && transferType == 2 {  // IN + Bulk
                    inPipe = i
                    foundIN = true
                    SenDoLog.log("  → Assigned as bulk IN pipe: \(i)")
                }
            } else {
                SenDoLog.log("  Endpoint \(i): GetPipeProperties FAILED: \(propResult)")
            }
        }

        guard foundOUT && foundIN else {
            SenDoLog.log("USBTransfer: ERROR — missing endpoints! OUT=\(foundOUT) IN=\(foundIN)")
            throw USBTransferError.noMatchingInterface
        }
        SenDoLog.log("USBTransfer: Ready — OUT pipe=\(outPipe), IN pipe=\(inPipe)")

        // Start the async completion pump BEFORE the first ReadPipeAsync.
        if asyncPump == nil {
            let pump = SendoAsyncEventPump(iface: iface)
            guard pump.isRunning else {
                SenDoLog.log("USBTransfer: ERROR — async event pump failed to start (kIOUSBNoAsyncPortErr would follow)")
                throw USBTransferError.protocolError("failed to create USB interface async event source")
            }
            asyncPump = pump
            SenDoLog.log("USBTransfer: async event pump running")
        }

        isOpen = true
    }

    // MARK: - Sphaira Protocol I/O

    /// Read exactly `count` bytes from the IN pipe, with timeout.
    ///
    /// Uses `SenDo_ReadPipeAsync` — never the synchronous `SenDo_ReadPipe`, which
    /// blocks forever when the Switch sends nothing. Bulk IN reads may return
    /// fewer bytes than requested, so this loops until `count` is satisfied or
    /// the deadline passes. On timeout the pipe is aborted and
    /// `USBTransferError.timeout` is thrown.
    func readExact(_ count: Int, timeout: TimeInterval) throws -> Data {
        guard isOpen, let iface = ifaceInterface else {
            throw USBTransferError.notConfigured
        }
        guard count > 0 else { return Data() }

        let buffer = SendoReadBuffer(capacity: count)
        var totalRead = 0
        let deadline = Date().addingTimeInterval(timeout)

        while totalRead < count {
            let remaining = count - totalRead
            let request = SendoReadRequest(buffer: buffer)
            let refcon = Unmanaged.passRetained(request).toOpaque()

            let startOffset = Date()
            let kr = SenDo_ReadPipeAsync(
                iface,
                inPipe,
                buffer.pointer.advanced(by: totalRead),
                UInt32(remaining),
                sendoReadCallback,
                refcon
            )

            guard kr == KERN_SUCCESS else {
                // No completion will be delivered, so release the retained request here.
                Unmanaged<SendoReadRequest>.fromOpaque(refcon).release()
                SenDoLog.log("USBTransfer: ReadPipeAsync(remaining=\(remaining)) failed: \(kr) (0x\(String(UInt32(bitPattern: kr), radix: 16, uppercase: true)))")
                throw USBTransferError.readFailed(kr)
            }

            let remainingTime = deadline.timeIntervalSinceNow
            if remainingTime <= 0 || request.semaphore.wait(timeout: .now() + max(remainingTime, 0)) == .timedOut {
                SenDoLog.log("USBTransfer: readExact timed out after \(String(format: "%.3f", Date().timeIntervalSince(startOffset)))s (have \(totalRead)/\(count)) — aborting pipe \(inPipe)")
                let abortResult = SenDo_AbortPipe(iface, inPipe)
                SenDoLog.log("USBTransfer: AbortPipe(\(inPipe)) result: \(abortResult)")
                // Give the completion a moment to fire so the pipe is idle again.
                // The request stays alive either way (the callback owns a reference).
                _ = request.semaphore.wait(timeout: .now() + 2)
                SenDoLog.log("USBTransfer: readExact gave up after timeout (total \(totalRead)/\(count) bytes)")
                throw USBTransferError.timeout(timeout)
            }

            guard request.result == KERN_SUCCESS else {
                SenDoLog.log("USBTransfer: async read completed with error: \(request.result)")
                throw USBTransferError.readFailed(request.result)
            }

            if request.bytesRead <= 0 {
                SenDoLog.log("USBTransfer: async read returned \(request.bytesRead) bytes (requested \(remaining)) — aborting")
                _ = SenDo_AbortPipe(iface, inPipe)
                throw USBTransferError.zeroLengthRead
            }

            totalRead += request.bytesRead
            // No per-partial-read log: a single `readExact` can complete
            // hundreds of small transfers, and logging each one floods
            // /tmp/sendo.log (W4). The `readExact done` line below is the
            // single per-call record.
        }

        SenDoLog.log("USBTransfer: readExact done — \(count) bytes")
        return Data(bytes: buffer.pointer, count: count)
    }

    /// Write all bytes to the OUT pipe.
    func write(_ data: Data) throws {
        guard isOpen, let iface = ifaceInterface else {
            throw USBTransferError.notConfigured
        }
        guard !data.isEmpty else {
            SenDoLog.log("USBTransfer: write skipped — 0 bytes")
            return
        }

        SenDoLog.log("USBTransfer: writing \(data.count) bytes to OUT pipe \(outPipe)")
        let result = data.withUnsafeBytes { rawBufferPointer -> IOReturn in
            guard let baseAddress = rawBufferPointer.baseAddress else { return kIOReturnBadArgument }
            return SenDo_WritePipe(iface, outPipe, baseAddress, UInt32(data.count))
        }
        guard result == KERN_SUCCESS else {
            SenDoLog.log("USBTransfer: WritePipe failed: \(result)")
            throw USBTransferError.writeFailed(result)
        }
        SenDoLog.log("USBTransfer: wrote \(data.count) bytes to OUT pipe \(outPipe)")
    }

    /// Read + verify a 24-byte SPHPacket (checks magic + CRC32C).
    func readPacket(timeout: TimeInterval) throws -> SPHPacket {
        let raw = try readExact(SPHPacket.expectedSize, timeout: timeout)
        let packet = try SPHPacket(wireBytes: raw)
        try packet.verified()
        SenDoLog.log(
            String(
                format: "USBTransfer: recv packet magic=0x%08X arg2=0x%08X(%u) arg3=0x%08X(%u) arg4=0x%08X(%u) arg5=0x%08X crc=0x%08X",
                packet.magic,
                packet.arg2, packet.arg2,
                packet.arg3, packet.arg3,
                packet.arg4, packet.arg4,
                packet.arg5,
                packet.crc32c
            )
        )
        return packet
    }

    /// Write an already-built SPHPacket.
    func send(_ packet: SPHPacket) throws {
        try write(packet.wireBytes)
    }

    /// Build and write a ResultPacket.
    func sendResult(_ result: UInt32, arg3: UInt32 = 0, arg4: UInt32 = 0) throws {
        let packet = SPHPacket.result(result, arg3: arg3, arg4: arg4)
        SenDoLog.log(
            String(
                format: "USBTransfer: send ResultPacket result=%u arg3=0x%08X(%u) arg4=0x%08X(%u) crc=0x%08X",
                result,
                arg3, arg3,
                arg4, arg4,
                packet.crc32c
            )
        )
        try write(packet.wireBytes)
    }

    func close() {
        isOpen = false
        asyncPump?.stop()
        asyncPump = nil
    }
}

// MARK: - USB Transfer Error

enum USBTransferError: LocalizedError {
    case deviceNotReady
    case notConfigured
    case configurationFailed(kern_return_t)
    case interfaceIteratorFailed(kern_return_t)
    case noMatchingInterface
    case interfaceCreationFailed(kern_return_t)
    case setAlternateInterfaceFailed(kern_return_t)
    case getNumEndpointsFailed(kern_return_t)
    case writeFailed(kern_return_t)
    case readFailed(kern_return_t)
    case timeout(TimeInterval)
    case zeroLengthRead
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotReady:
            return "USB device not ready"
        case .notConfigured:
            return "USB transfer not configured"
        case .configurationFailed(let code):
            return "Failed to set USB configuration: \(code)"
        case .interfaceIteratorFailed(let code):
            return "Failed to create interface iterator: \(code)"
        case .noMatchingInterface:
            return "No matching USB interface found"
        case .interfaceCreationFailed(let code):
            return "Failed to create USB interface: \(code)"
        case .setAlternateInterfaceFailed(let code):
            return "Failed to set alternate interface: \(code)"
        case .getNumEndpointsFailed(let code):
            return "Failed to get number of endpoints: \(code)"
        case .writeFailed(let code):
            return "USB write failed: \(code)"
        case .readFailed(let code):
            return "USB read failed: \(code)"
        case .timeout(let seconds):
            return "USB read timed out after \(seconds)s"
        case .zeroLengthRead:
            return "USB read returned zero bytes"
        case .protocolError(let message):
            return "USB protocol error: \(message)"
        }
    }
}
