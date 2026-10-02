import Foundation
import DaylightDropTransport

let args = CommandLine.arguments
let port: UInt16 = args.count > 1 ? (UInt16(args[1]) ?? ProtocolConstants.macPort) : ProtocolConstants.macPort
let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("daylight_challenger_\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

let server = DaylightHTTPServer(port: port, deviceId: "mac-challenger-m1", incomingDirectory: tempDir)
server.onDropReceived = { transferId, filename, type, fileURL, sha256 in
    let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int64 ?? 0
    print("[SERVER_EVENT] DROP_RECEIVED id=\(transferId) file=\(filename) sha=\(sha256) size=\(size)")
    fflush(stdout)
}
server.onTextReceived = { payload in
    print("[SERVER_EVENT] TEXT_RECEIVED id=\(payload.id) text=\(payload.text)")
    fflush(stdout)
}

do {
    try server.start()
    print("[SERVER_READY] port=\(port) tempDir=\(tempDir.path)")
    fflush(stdout)
    
    // Read lines until EOF or STOP
    while let line = readLine() {
        if line.trimmingCharacters(in: .whitespacesAndNewlines) == "STOP" {
            break
        }
    }
    server.stop()
    try? FileManager.default.removeItem(at: tempDir)
    print("[SERVER_STOPPED]")
    fflush(stdout)
} catch {
    print("[SERVER_ERROR] \(error)")
    fflush(stdout)
    exit(1)
}
