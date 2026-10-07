import Foundation

public struct Fan: Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let minRPM: Double
    public let maxRPM: Double
    public let actualRPM: Double
    public let targetRPM: Double
    /// True while the SMC is in forced mode (F?Md = 1), whoever set it.
    public let manual: Bool
}

extension SMC {
    public func fanCount() -> Int {
        Int(readNumber("FNum") ?? 0)
    }

    public func fans() -> [Fan] {
        let count = fanCount()
        return (0..<count).map { index in
            Fan(
                id: index,
                name: Self.fanName(index, of: count),
                minRPM: readNumber("F\(index)Mn") ?? 0,
                maxRPM: readNumber("F\(index)Mx") ?? 0,
                actualRPM: readNumber("F\(index)Ac") ?? 0,
                targetRPM: readNumber("F\(index)Tg") ?? 0,
                manual: readNumber("F\(index)Md") == 1
            )
        }
    }

    private static func fanName(_ index: Int, of count: Int) -> String {
        if count == 1 { return "Fan" }
        if count == 2 { return index == 0 ? "Left fan" : "Right fan" }
        return "Fan \(index + 1)"
    }
}

/// Writes fan speeds to the SMC. Only works when the process runs as root.
public final class FanWriter {
    private let smc: SMC
    // On recent Apple Silicon, thermalmonitord owns the fans;
    // the SMC only accepts F?Md = 1 after Ftst = 1 is set.
    private static let unlockKey = "Ftst"

    /// Thrown when `shouldContinue` turns false while waiting for the system to release a fan.
    public struct Cancelled: Error {}

    public init(smc: SMC) {
        self.smc = smc
    }

    /// Forces a fan to `rpm`. Taking over a fan can take several seconds; `shouldContinue` is polled
    /// during the wait so the caller can give up as soon as the request is no longer wanted.
    public func setManual(fan: Int, rpm: Double, shouldContinue: () -> Bool = { true }) throws {
        let modeKey = "F\(fan)Md"
        if smc.readNumber(modeKey) != 1 {
            if smc.exists(Self.unlockKey), smc.readNumber(Self.unlockKey) != 1 {
                try retry(attempts: 40, delay: 0.05, shouldContinue: shouldContinue) {
                    try self.smc.writeNumber(Self.unlockKey, 1)
                }
            }
            // After unlocking, the system takes a moment to release control.
            try retry(attempts: 100, delay: 0.1, shouldContinue: shouldContinue) {
                try self.smc.writeNumber(modeKey, 1)
                guard self.smc.readNumber(modeKey) == 1 else {
                    throw SMCError.smcResult(key: modeKey, code: 0x86)
                }
            }
        }
        try smc.writeNumber("F\(fan)Tg", rpm)
    }

    /// Returns one fan to the system while others stay forced. Returns false if the SMC refuses, which it
    /// does when it wants that fan stopped (cool machine): mode 0 means "automatic, running" and mode 3
    /// "automatic, stopped", and neither can be written then. `endUnlock()` always works as a fallback.
    public func setAuto(fan: Int) -> Bool {
        let modeKey = "F\(fan)Md"
        for mode in [0.0, 3.0] {
            if (try? retry(attempts: 3, delay: 0.05, { try self.smc.writeNumber(modeKey, mode) })) != nil {
                return true
            }
        }
        return false
    }

    /// Hands fan control back to the system. Call when no fan is forced any more.
    public func endUnlock() {
        guard smc.exists(Self.unlockKey) else { return }
        try? smc.writeNumber(Self.unlockKey, 0)
    }

    private func retry(attempts: Int, delay: TimeInterval, shouldContinue: () -> Bool = { true },
                       _ body: () throws -> Void) throws {
        var lastError: Error?
        for _ in 0..<attempts {
            guard shouldContinue() else { throw Cancelled() }
            do {
                try body()
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: delay)
            }
        }
        throw lastError!
    }
}
