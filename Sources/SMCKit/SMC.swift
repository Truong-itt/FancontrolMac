import Foundation
import IOKit

public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(key: String, code: kern_return_t)
    case smcResult(key: String, code: UInt8)
    case sizeMismatch(key: String, expected: Int, got: Int)

    public var description: String {
        switch self {
        case .serviceNotFound:
            return "AppleSMC service not found"
        case .openFailed(let kr):
            return "Could not open a connection to AppleSMC (0x\(String(UInt32(bitPattern: kr), radix: 16)))"
        case .callFailed(let key, let kr):
            let hex = String(UInt32(bitPattern: kr), radix: 16)
            // kIOReturnNotPrivileged: writing to the SMC needs root.
            return kr == kIOReturnNotPrivileged
                ? "\(key): not permitted (needs root)"
                : "\(key): SMC call failed (0x\(hex))"
        case .smcResult(let key, let code):
            switch code {
            case 0x84: return "\(key): key does not exist"
            case 0x85: return "\(key): key is not readable"
            case 0x86: return "\(key): key is not writable"
            default: return "\(key): SMC returned error 0x\(String(code, radix: 16))"
            }
        case .sizeMismatch(let key, let expected, let got):
            return "\(key): wrong data size (expected \(expected) bytes, got \(got))"
        }
    }
}

public struct SMCValue {
    public let key: String
    /// The SMC's 4-character data type, e.g. "flt ", "ui8 ".
    public let type: String
    public let bytes: [UInt8]

    /// Decodes to a number according to the data type; nil for types that are not a known numeric form.
    public var number: Double? {
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            // Apple Silicon stores floats little-endian.
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ", "ui16", "ui32", "flag":
            guard !bytes.isEmpty, bytes.count <= 4 else { return nil }
            return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "sp78":
            guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        default:
            return nil
        }
    }
}

/// Connection to AppleSMC through IOKit. Reading needs no privileges; writing needs root.
public final class SMC {
    // Layout of SMCKeyData_t (80 bytes) as the AppleSMC driver expects it.
    private enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let data32 = 44
        static let bytes = 48
    }
    private enum Command: UInt8 {
        case readBytes = 5
        case writeBytes = 6
        case keyFromIndex = 8
        case keyInfo = 9
    }
    private static let structSize = 80
    private static let maxDataSize = 32
    private static let selector: UInt32 = 2

    private var connection: io_connect_t = 0
    private var infoCache: [String: (size: Int, type: String)] = [:]
    private let lock = NSLock()

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - API

    public func read(_ key: String) throws -> SMCValue {
        lock.lock(); defer { lock.unlock() }
        let info = try keyInfo(key)
        var input = Self.blank(key: key, command: .readBytes)
        Self.put(UInt32(info.size), into: &input, at: Offset.dataSize)
        let output = try call(input, key: key)
        return SMCValue(key: key, type: info.type, bytes: Array(output[Offset.bytes..<(Offset.bytes + info.size)]))
    }

    public func readNumber(_ key: String) -> Double? {
        (try? read(key))?.number
    }

    public func write(_ key: String, bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let info = try keyInfo(key)
        guard bytes.count == info.size else {
            throw SMCError.sizeMismatch(key: key, expected: info.size, got: bytes.count)
        }
        var input = Self.blank(key: key, command: .writeBytes)
        Self.put(UInt32(info.size), into: &input, at: Offset.dataSize)
        input.replaceSubrange(Offset.bytes..<(Offset.bytes + bytes.count), with: bytes)
        _ = try call(input, key: key)
    }

    /// Writes a number, encoded for the key's data type.
    public func writeNumber(_ key: String, _ value: Double) throws {
        lock.lock()
        let info: (size: Int, type: String)
        do { info = try keyInfo(key) } catch { lock.unlock(); throw error }
        lock.unlock()

        let bytes: [UInt8]
        switch info.type {
        case "flt ":
            let bits = Float(value).bitPattern
            bytes = [UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits >> 16 & 0xff), UInt8(bits >> 24)]
        case "fpe2":
            let raw = UInt16(max(0, min(value * 4, Double(UInt16.max))))
            bytes = [UInt8(raw >> 8), UInt8(raw & 0xff)]
        default:
            let raw = UInt32(max(0, value))
            bytes = (0..<info.size).map { UInt8(raw >> (8 * UInt32(info.size - 1 - $0)) & 0xff) }
        }
        try write(key, bytes: bytes)
    }

    public func exists(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (try? keyInfo(key)) != nil
    }

    /// Lists every SMC key (several thousand; call once).
    public func allKeys() -> [String] {
        guard let count = readNumber("#KEY") else { return [] }
        lock.lock(); defer { lock.unlock() }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        for index in 0..<UInt32(count) {
            var input = [UInt8](repeating: 0, count: Self.structSize)
            input[Offset.command] = Command.keyFromIndex.rawValue
            Self.put(index, into: &input, at: Offset.data32)
            guard let output = try? call(input, key: "#\(index)") else { continue }
            keys.append(Self.string(fromFourCC: Self.get(output, at: Offset.key)))
        }
        return keys
    }

    // MARK: - Internals (call with the lock held)

    private func keyInfo(_ key: String) throws -> (size: Int, type: String) {
        if let cached = infoCache[key] { return cached }
        let output = try call(Self.blank(key: key, command: .keyInfo), key: key)
        let size = min(Int(Self.get(output, at: Offset.dataSize)), Self.maxDataSize)
        let info = (size: size, type: Self.string(fromFourCC: Self.get(output, at: Offset.dataType)))
        infoCache[key] = info
        return info
    }

    private func call(_ input: [UInt8], key: String) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let kr = IOConnectCallStructMethod(connection, Self.selector, input, Self.structSize, &output, &outputSize)
        guard kr == kIOReturnSuccess else { throw SMCError.callFailed(key: key, code: kr) }
        guard output[Offset.result] == 0 else { throw SMCError.smcResult(key: key, code: output[Offset.result]) }
        return output
    }

    private static func blank(key: String, command: Command) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: structSize)
        put(fourCC(key), into: &buffer, at: Offset.key)
        buffer[Offset.command] = command.rawValue
        return buffer
    }

    private static func put(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
        buffer.withUnsafeMutableBytes { $0.storeBytes(of: value, toByteOffset: offset, as: UInt32.self) }
    }

    private static func get(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private static func fourCC(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private static func string(fromFourCC value: UInt32) -> String {
        let bytes = [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
