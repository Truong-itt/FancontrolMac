import Foundation

/// A point on a fan curve. `rpm` = 0 means the fan is off.
public struct CurvePoint: Codable, Equatable {
    public var temp: Double
    public var rpm: Double

    public init(temp: Double, rpm: Double) {
        self.temp = temp
        self.rpm = rpm
    }
}

/// RPM as a function of one sensor's temperature, linearly interpolated between points.
public struct FanCurve: Codable, Equatable {
    public var sensorID: String
    public var points: [CurvePoint]

    public init(sensorID: String, points: [CurvePoint]) {
        self.sensorID = sensorID
        self.points = points
    }

    public func rpm(at temp: Double) -> Double {
        let sorted = points.sorted { $0.temp < $1.temp }
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        if temp <= first.temp { return first.rpm }
        if temp >= last.temp { return last.rpm }
        for (lower, upper) in zip(sorted, sorted.dropFirst()) where temp <= upper.temp {
            guard upper.temp > lower.temp else { return upper.rpm }
            return lower.rpm + (upper.rpm - lower.rpm) * (temp - lower.temp) / (upper.temp - lower.temp)
        }
        return last.rpm
    }
}

/// How the helper controls a fan.
public enum FanControlMode: Codable, Equatable {
    /// Hand the fan back to the system.
    case auto
    /// Hold a fixed speed.
    case constant(rpm: Int)
    /// Linear interpolation from minimum RPM (at `minTemp`) to maximum (at `maxTemp`).
    case sensor(sensorID: String, minTemp: Double, maxTemp: Double)
    /// Follow temperature curves; the fan runs at the highest speed any curve asks for.
    case curve(curves: [FanCurve])
}

public struct HelperRequest: Codable {
    public enum Command: String, Codable {
        case status
        case set
    }

    public var command: Command
    public var fan: Int?
    public var mode: FanControlMode?

    public static let status = HelperRequest(command: .status, fan: nil, mode: nil)

    public static func set(fan: Int, mode: FanControlMode) -> HelperRequest {
        HelperRequest(command: .set, fan: fan, mode: mode)
    }
}

public struct HelperResponse: Codable {
    public var ok: Bool
    public var error: String?
    public var version: Int
    /// The mode set for each fan, by fan index.
    public var modes: [FanControlMode]
    /// The latest error applying each fan's mode (nil when fine).
    public var errors: [String?]

    public init(ok: Bool, error: String? = nil, modes: [FanControlMode] = [], errors: [String?] = []) {
        self.ok = ok
        self.error = error
        self.version = HelperSocket.protocolVersion
        self.modes = modes
        self.errors = errors
    }
}

public enum HelperClientError: Error, CustomStringConvertible {
    case notRunning
    case noResponse
    case rejected(String)

    public var description: String {
        switch self {
        case .notRunning: return "Helper is not running"
        case .noResponse: return "Helper did not respond"
        case .rejected(let message): return message
        }
    }
}

/// Unix socket between the app and the helper: each connection sends one JSON line and reads one back.
public enum HelperSocket {
    public static let path = "/var/run/fancontrol.sock"
    /// Bump whenever the protocol changes so the app can tell the installed helper is outdated.
    public static let protocolVersion = 3

    public static func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() where index < buffer.count - 1 {
                buffer[index] = byte
            }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    public static func setTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
    }

    public static func readLine(_ fd: Int32, limit: Int = 64 * 1024) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            if let newline = chunk[..<count].firstIndex(of: 0x0a) {
                data.append(contentsOf: chunk[..<newline])
                return data
            }
            data.append(contentsOf: chunk[..<count])
        }
        return data.isEmpty ? nil : data
    }

    public static func writeLine(_ fd: Int32, _ payload: Data) -> Bool {
        var bytes = [UInt8](payload)
        bytes.append(0x0a)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { return false }
            sent += count
        }
        return true
    }
}

public enum HelperClient {
    public static func send(_ request: HelperRequest) throws -> HelperResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperClientError.notRunning }
        defer { close(fd) }

        let connected = HelperSocket.withAddress { connect(fd, $0, $1) }
        guard connected == 0 else { throw HelperClientError.notRunning }
        HelperSocket.setTimeout(fd, seconds: 3)

        guard HelperSocket.writeLine(fd, try JSONEncoder().encode(request)),
              let line = HelperSocket.readLine(fd),
              let response = try? JSONDecoder().decode(HelperResponse.self, from: line)
        else { throw HelperClientError.noResponse }
        guard response.ok else { throw HelperClientError.rejected(response.error ?? "Helper rejected the request") }
        return response
    }
}
