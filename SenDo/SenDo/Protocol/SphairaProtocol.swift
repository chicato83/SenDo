import Foundation

// MARK: - Protocol Constants

/// Sphaira USB protocol constants.
/// Verified against sphaira/include/usb/usb_api.hpp and tools/usb_common.py.
enum SPHProtocol {
    /// Packet magic, ASCII "SPH0".
    static let MAGIC: UInt32 = 0x53504830

    /// Wire size of every packet: 6 x UInt32, little-endian.
    static let PACKET_SIZE = 24

    /// Number of leading bytes covered by the packet CRC32C (fields 0..<5).
    static let CRC_SIZE = 20

    // Commands (SendPacket.arg2)
    static let CMD_QUIT: UInt32 = 0
    static let CMD_OPEN: UInt32 = 1
    /// Shares its wire value with `CMD_OPEN`: the session-opening packet decides
    /// which one it is (`arg2 == 0` -> install, `arg2 == 1` -> export).
    static let CMD_EXPORT: UInt32 = 1

    // Results (ResultPacket.arg2)
    static let RESULT_OK: UInt32 = 0
    static let RESULT_ERROR: UInt32 = 1

    // Flags, packed into ResultPacket.arg3 bits 16...31
    static let FLAG_NONE: UInt32 = 0
    static let FLAG_STREAM: UInt32 = 1
}

// MARK: - Packet

/// 24-byte wire packet: 6 x UInt32, little-endian.
///
/// Field semantics depend on the packet role:
/// - `SendPacket`     (Switch -> Mac): `arg2 = cmd`, `arg3`, `arg4`
/// - `ResultPacket`   (Mac -> Switch): `arg2 = result`, `arg3`, `arg4`
/// - `SendDataPacket` (Switch -> Mac): `arg2 = offset >> 32`, `arg3 = offset & 0xFFFFFFFF`,
///   `arg4 = size`, `arg5 = crc32c` (0 in requests)
///
/// `crc32c` is CRC-32C (Castagnoli) over the first 20 bytes (fields `magic` ... `arg5`).
struct SPHPacket {
    /// Expected wire size. Kept as a static so callers can assert it.
    static let expectedSize = SPHProtocol.PACKET_SIZE

    var magic: UInt32 = SPHProtocol.MAGIC
    var arg2: UInt32 = 0
    var arg3: UInt32 = 0
    var arg4: UInt32 = 0
    var arg5: UInt32 = 0
    var crc32c: UInt32 = 0

    /// Explicit memberwise initializer (Swift suppresses the implicit one
    /// because this type declares its own initializers).
    init(
        magic: UInt32 = SPHProtocol.MAGIC,
        arg2: UInt32 = 0,
        arg3: UInt32 = 0,
        arg4: UInt32 = 0,
        arg5: UInt32 = 0,
        crc32c: UInt32 = 0
    ) {
        self.magic = magic
        self.arg2 = arg2
        self.arg3 = arg3
        self.arg4 = arg4
        self.arg5 = arg5
        self.crc32c = crc32c
    }

    // MARK: Builders

    /// Switch -> Mac command packet.
    static func send(cmd: UInt32, arg3: UInt32 = 0, arg4: UInt32 = 0) -> SPHPacket {
        var packet = SPHPacket(magic: SPHProtocol.MAGIC, arg2: cmd, arg3: arg3, arg4: arg4, arg5: 0, crc32c: 0)
        packet.regenerateCRC32C()
        return packet
    }

    /// Mac -> Switch result packet.
    static func result(_ result: UInt32, arg3: UInt32 = 0, arg4: UInt32 = 0) -> SPHPacket {
        var packet = SPHPacket(magic: SPHProtocol.MAGIC, arg2: result, arg3: arg3, arg4: arg4, arg5: 0, crc32c: 0)
        packet.regenerateCRC32C()
        return packet
    }

    /// Switch -> Mac data-request packet.
    static func sendData(offset: UInt64, size: UInt32, crc: UInt32) -> SPHPacket {
        var packet = SPHPacket(
            magic: SPHProtocol.MAGIC,
            arg2: UInt32(truncatingIfNeeded: offset >> 32),
            arg3: UInt32(truncatingIfNeeded: offset & 0xFFFF_FFFF),
            arg4: size,
            arg5: crc,
            crc32c: 0
        )
        packet.regenerateCRC32C()
        return packet
    }

    // MARK: CRC32C

    /// CRC32C over the first 20 bytes of the wire encoding.
    var calculatedCRC32C: UInt32 {
        SphairaCRC32C.checksum(wireBytes.prefix(SPHProtocol.CRC_SIZE))
    }

    mutating func regenerateCRC32C() {
        crc32c = calculatedCRC32C
    }

    /// Verifies magic and CRC32C. Throws `SphairaProtocolError` on mismatch.
    func verified() throws {
        guard magic == SPHProtocol.MAGIC else {
            throw SphairaProtocolError.badMagic(magic)
        }
        let expected = calculatedCRC32C
        guard crc32c == expected else {
            throw SphairaProtocolError.badCRC(received: crc32c, expected: expected)
        }
    }

    // MARK: Wire encoding

    /// Little-endian encoding of all six fields (24 bytes).
    var wireBytes: Data {
        var data = Data(capacity: Self.expectedSize)
        appendLittleEndian(magic, to: &data)
        appendLittleEndian(arg2, to: &data)
        appendLittleEndian(arg3, to: &data)
        appendLittleEndian(arg4, to: &data)
        appendLittleEndian(arg5, to: &data)
        appendLittleEndian(crc32c, to: &data)
        return data
    }

    /// Decodes a packet from raw little-endian bytes. Requires at least 24 bytes.
    init(wireBytes data: Data) throws {
        guard data.count >= Self.expectedSize else {
            throw SphairaProtocolError.shortPacket(data.count)
        }
        var values = [UInt32](repeating: 0, count: 6)
        let base = data.startIndex
        for field in 0..<6 {
            let offset = base + field * 4
            values[field] =
                UInt32(data[offset]) |
                (UInt32(data[offset + 1]) << 8) |
                (UInt32(data[offset + 2]) << 16) |
                (UInt32(data[offset + 3]) << 24)
        }
        self.init(
            magic: values[0],
            arg2: values[1],
            arg3: values[2],
            arg4: values[3],
            arg5: values[4],
            crc32c: values[5]
        )
    }

    private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    // MARK: Debug self-test

    /// Logs pass/fail for the required CRC32C test vector and the packet layout.
    /// Returns true when everything passes.
    @discardableResult
    static func runSelfTest(file: String = #file, line: Int = #line) -> Bool {
        let layoutOK = MemoryLayout<SPHPacket>.size == expectedSize
        SenDoLog.log(
            "SphairaProtocol self-test: MemoryLayout<SPHPacket>.size = \(MemoryLayout<SPHPacket>.size), expected \(expectedSize) — \(layoutOK ? "PASS" : "FAIL")",
            file: file,
            line: line
        )

        let crcOK = SphairaCRC32C.runSelfTest(file: file, line: line)

        // Round-trip a packet through the wire encoding.
        let original = SPHPacket.send(cmd: SPHProtocol.CMD_OPEN, arg3: 7, arg4: 4242)
        var roundTripOK = false
        do {
            let decoded = try SPHPacket(wireBytes: original.wireBytes)
            try decoded.verified()
            roundTripOK = decoded.magic == original.magic
                && decoded.arg2 == original.arg2
                && decoded.arg3 == original.arg3
                && decoded.arg4 == original.arg4
        } catch {
            roundTripOK = false
        }
        SenDoLog.log(
            "SphairaProtocol self-test: packet round-trip — \(roundTripOK ? "PASS" : "FAIL")",
            file: file,
            line: line
        )

        // Mode latch: the session-opening packet carries 0 for install and 1 for
        // export, and CMD_OPEN/CMD_EXPORT deliberately share the value 1 — so the
        // mode must be decided by the FIRST packet of a session.
        let modeLatchOK = SPHProtocol.CMD_QUIT == 0
            && SPHProtocol.CMD_EXPORT == 1
            && SPHProtocol.CMD_EXPORT == SPHProtocol.CMD_OPEN
        SenDoLog.log(
            "SphairaProtocol self-test: mode latch (install=0, export=\(SPHProtocol.CMD_EXPORT)) — \(modeLatchOK ? "PASS" : "FAIL")",
            file: file,
            line: line
        )

        // Export chunk headers carry a 64-bit offset split across arg2/arg3.
        let exportOffset: UInt64 = 0x0000_0001_2345_6789
        let dataPacket = SPHPacket.sendData(offset: exportOffset, size: 0x0010_0000, crc: 0xDEAD_BEEF)
        var exportPacketOK = false
        do {
            let decoded = try SPHPacket(wireBytes: dataPacket.wireBytes)
            try decoded.verified()
            let rebuilt = (UInt64(decoded.arg2) << 32) | UInt64(decoded.arg3)
            exportPacketOK = rebuilt == exportOffset
                && decoded.arg4 == 0x0010_0000
                && decoded.arg5 == 0xDEAD_BEEF
        } catch {
            exportPacketOK = false
        }
        SenDoLog.log(
            "SphairaProtocol self-test: export SendDataPacket offset round-trip — \(exportPacketOK ? "PASS" : "FAIL")",
            file: file,
            line: line
        )

        return layoutOK && crcOK && roundTripOK && modeLatchOK && exportPacketOK
    }
}

// MARK: - CRC-32C (Castagnoli)

/// Table-based CRC-32C.
///
/// Reflected polynomial 0x82F63B78 (non-reflected 0x1EDC6F41),
/// init 0xFFFFFFFF, reflected input/output, final XOR 0xFFFFFFFF.
enum SphairaCRC32C {
    /// Required test vector: CRC32C("123456789") == 0xE3069283.
    static let expectedTestVector: UInt32 = 0xE3069283

    private static let table: [UInt32] = {
        var result = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                if value & 1 != 0 {
                    value = 0x82F63B78 ^ (value >> 1)
                } else {
                    value = value >> 1
                }
            }
            result[index] = value
        }
        return result
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                let tableIndex = Int((crc ^ UInt32(bytes[index])) & 0xFF)
                crc = table[tableIndex] ^ (crc >> 8)
                index += 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Logs pass/fail for the required test vector. Returns true on success.
    @discardableResult
    static func runSelfTest(file: String = #file, line: Int = #line) -> Bool {
        let actual = checksum(Data("123456789".utf8))
        let passed = actual == expectedTestVector
        SenDoLog.log(
            "SphairaCRC32C self-test: CRC32C(\"123456789\") = 0x\(String(actual, radix: 16, uppercase: true)), expected 0x\(String(expectedTestVector, radix: 16, uppercase: true)) — \(passed ? "PASS" : "FAIL")",
            file: file,
            line: line
        )
        return passed
    }
}

// MARK: - Protocol Errors

enum SphairaProtocolError: LocalizedError {
    case shortPacket(Int)
    case badMagic(UInt32)
    case badCRC(received: UInt32, expected: UInt32)
    case unknownCommand(UInt32)
    case invalidFileIndex(Int)
    case fileOpenFailed(String)
    case invalidExportPath(String)
    case unexpectedEndOfFile(expected: Int, got: Int)
    /// The Switch never sent the session-opening packet within the handshake
    /// timeout. This is the normal idle state between two sessions, so it is
    /// tracked separately: the UI must not report it as a failure.
    case sessionIdle
    /// The export session closed cleanly but at least one file lost chunks
    /// (CRC mismatch or write error), so what landed on disk is incomplete.
    case exportInterrupted

    var errorDescription: String? {
        switch self {
        case .shortPacket(let count):
            return "Sphaira packet too short: \(count) bytes"
        case .badMagic(let magic):
            return String(format: "Sphaira packet bad magic: 0x%08X", magic)
        case .badCRC(let received, let expected):
            return String(format: "Sphaira packet CRC mismatch: got 0x%08X, expected 0x%08X", received, expected)
        case .unknownCommand(let cmd):
            return String(format: "Unknown Sphaira command: 0x%08X", cmd)
        case .invalidFileIndex(let index):
            return "Invalid file index requested by Switch: \(index)"
        case .fileOpenFailed(let path):
            return "Failed to open file: \(path)"
        case .invalidExportPath(let path):
            return "Rejected export path from Switch: \(path)"
        case .unexpectedEndOfFile(let expected, let got):
            return "Unexpected end of file: wanted \(expected) bytes, got \(got)"
        case .sessionIdle:
            return "No session-opening packet from the Switch (idle session)"
        case .exportInterrupted:
            return "Export interrupted — one or more exported files are incomplete"
        }
    }
}
