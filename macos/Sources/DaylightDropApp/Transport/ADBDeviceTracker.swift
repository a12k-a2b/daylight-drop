import Foundation
import Network

/// Real-time ADB device tracker over ADB daemon socket (127.0.0.1:5037).
/// Manages automatic reverse tunnel (DC1 -> Mac: tcp:8765 tcp:8765) and forward tunnel (Mac -> DC1: tcp:8766 tcp:8766).
public final class ADBDeviceTracker: @unchecked Sendable {
    public typealias CommandExecutor = ([String]) -> (code: Int32, output: String)
    
    private var connection: NWConnection?
    private let host: String
    private let port: UInt16
    private let adbExecutable: String
    private let commandExecutor: CommandExecutor
    
    public private(set) var isTracking: Bool = false
    public private(set) var connectedSerials: Set<String> = []
    public private(set) var activeTunnelSerials: Set<String> = []
    
    public var onDeviceAttached: ((String, String) -> Void)?
    public var onDeviceDetached: ((String) -> Void)?
    public var onTunnelEstablished: ((String) -> Void)?
    public var onTunnelTeardown: ((String) -> Void)?
    
    private let lock = NSLock()
    
    public static func resolveAdbPath() -> String {
        let fileManager = FileManager.default
        let env = ProcessInfo.processInfo.environment
        
        // 1. Check ANDROID_HOME / ANDROID_SDK_ROOT
        for envVar in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let dir = env[envVar], !dir.isEmpty {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent("platform-tools/adb").path
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        
        // 2. Check user's Library Android SDK path
        let homeDir = NSHomeDirectory()
        let libraryCandidate = "\(homeDir)/Library/Android/sdk/platform-tools/adb"
        if fileManager.isExecutableFile(atPath: libraryCandidate) {
            return libraryCandidate
        }
        
        // 3. Check standard package manager and system locations
        let standardPaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb"
        ]
        for path in standardPaths {
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        // 4. Check PATH environment variable
        if let pathEnv = env["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("adb").path
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        
        // 5. Query /usr/bin/which adb
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["adb"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        if (try? whichProcess.run()) != nil {
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !out.isEmpty, fileManager.isExecutableFile(atPath: out) {
                    return out
                }
            }
        }
        
        return libraryCandidate
    }
    
    public init(
        host: String = "127.0.0.1",
        port: UInt16 = ProtocolConstants.adbDaemonPort,
        adbExecutable: String? = nil,
        commandExecutor: CommandExecutor? = nil
    ) {
        self.host = host
        self.port = port
        let resolvedAdb = adbExecutable ?? ADBDeviceTracker.resolveAdbPath()
        self.adbExecutable = resolvedAdb
        self.commandExecutor = commandExecutor ?? { args in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: resolvedAdb)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                return (process.terminationStatus, out)
            } catch {
                return (-1, error.localizedDescription)
            }
        }
    }
    
    public func startTracking(queue: DispatchQueue = .global(qos: .userInitiated)) {
        stopTracking()
        
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.connection = conn
        self.isTracking = true
        
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.sendTrackCommand()
            case .failed, .cancelled:
                self.isTracking = false
            default:
                break
            }
        }
        
        conn.start(queue: queue)
    }
    
    public func stopTracking() {
        connection?.cancel()
        connection = nil
        isTracking = false
        
        lock.lock()
        let active = Array(activeTunnelSerials)
        lock.unlock()
        
        for serial in active {
            teardownTunnel(serial: serial)
        }
    }
    
    private func sendTrackCommand() {
        guard let conn = connection else { return }
        let cmd = "host:track-devices"
        let msg = String(format: "%04x%@", cmd.count, cmd)
        guard let data = msg.data(using: .utf8) else { return }
        
        conn.send(content: data, completion: .contentProcessed({ [weak self] error in
            if error == nil {
                self?.receiveInitialStatus()
            }
        }))
    }
    
    private func receiveInitialStatus() {
        guard let conn = connection else { return }
        // Read 4-byte response: "OKAY" or "FAIL"
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let data = data, let str = String(data: data, encoding: .utf8), str == "OKAY" else {
                return
            }
            self?.readNextPayload()
        }
    }
    
    private func readNextPayload() {
        guard let conn = connection else { return }
        // Read 4-hex-digit length
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] lenData, _, _, error in
            guard let self = self, let lenData = lenData,
                  let lenStr = String(data: lenData, encoding: .utf8),
                  let payloadLen = Int(lenStr, radix: 16) else {
                return
            }
            
            if payloadLen == 0 {
                // Empty payload means 0 devices connected
                self.handleDeviceListUpdate("")
                self.readNextPayload()
                return
            }
            
            conn.receive(minimumIncompleteLength: payloadLen, maximumLength: payloadLen) { [weak self] pData, _, _, _ in
                if let pData = pData, let text = String(data: pData, encoding: .utf8) {
                    self?.handleDeviceListUpdate(text)
                }
                self?.readNextPayload()
            }
        }
    }
    
    /// Parses ADB track-devices output payload into a map of serial -> state.
    public static func parseDeviceEntries(_ text: String) -> [(serial: String, state: String)] {
        var results: [(serial: String, state: String)] = []
        let lines = text.split(whereSeparator: \.isNewline)
        for line in lines {
            let parts = line.split(separator: "\t")
            if parts.count >= 2 {
                let serial = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let state = String(parts[1]).trimmingCharacters(in: .whitespaces)
                results.append((serial, state))
            }
        }
        return results
    }
    
    public func handleDeviceListUpdate(_ text: String) {
        let entries = Self.parseDeviceEntries(text)
        var currentOnline: Set<String> = []
        
        for entry in entries {
            if entry.state == "device" {
                currentOnline.insert(entry.serial)
            }
        }
        
        lock.lock()
        let previousSerials = connectedSerials
        connectedSerials = currentOnline
        
        let newlyAttached = currentOnline.subtracting(previousSerials)
        let newlyDetached = previousSerials.subtracting(currentOnline)
        lock.unlock()
        
        for serial in newlyAttached {
            setupTunnel(serial: serial)
            onDeviceAttached?(serial, "DC_1")
        }
        
        for serial in newlyDetached {
            teardownTunnel(serial: serial)
            onDeviceDetached?(serial)
        }
    }
    
    public func setupTunnel(serial: String) {
        // 0. Remove stale tunnels first
        _ = commandExecutor(["-s", serial, "forward", "--remove", "tcp:\(ProtocolConstants.androidPort)"])
        _ = commandExecutor(["-s", serial, "reverse", "--remove", "tcp:\(ProtocolConstants.macPort)"])
        
        // 1. adb -s <serial> reverse tcp:8765 tcp:8765
        let revResult = commandExecutor(["-s", serial, "reverse", "tcp:\(ProtocolConstants.macPort)", "tcp:\(ProtocolConstants.macPort)"])
        // 2. adb -s <serial> forward tcp:8766 tcp:8766
        let fwdResult = commandExecutor(["-s", serial, "forward", "tcp:\(ProtocolConstants.androidPort)", "tcp:\(ProtocolConstants.androidPort)"])
        
        if revResult.code == 0 && fwdResult.code == 0 {
            lock.lock()
            activeTunnelSerials.insert(serial)
            lock.unlock()
            
            onTunnelEstablished?(serial)
        } else {
            NSLog("[ADBDeviceTracker] Tunnel setup partial failure for %@: rev=%d fwd=%d", serial, revResult.code, fwdResult.code)
        }
    }
    
    public func teardownTunnel(serial: String) {
        // adb -s <serial> forward --remove tcp:8766
        _ = commandExecutor(["-s", serial, "forward", "--remove", "tcp:\(ProtocolConstants.androidPort)"])
        // adb -s <serial> reverse --remove tcp:8765
        _ = commandExecutor(["-s", serial, "reverse", "--remove", "tcp:\(ProtocolConstants.macPort)"])
        
        lock.lock()
        activeTunnelSerials.remove(serial)
        lock.unlock()
        
        onTunnelTeardown?(serial)
    }
}
