import Foundation

public enum ProtocolConstants {
    public static let protocolVersion = "1.0"
    
    // Ports
    public static let macPort: UInt16 = 8765
    public static let androidPort: UInt16 = 8766
    public static let adbDaemonPort: UInt16 = 5037
    
    // Service Discovery
    public static let serviceType = "_daylightdrop._tcp"
    public static let serviceTypeWithDot = "_daylightdrop._tcp."
    public static let legacyServiceType = "_daylight-drop._tcp"
    public static let domain = "local."
    
    // Endpoints
    public static let healthEndpoint = "/api/health"
    public static let dropEndpoint = "/api/drop"
    public static let textEndpoint = "/api/text"
    public static let webSocketEndpoint = "/api/ws"
    
    // Headers
    public static let headerDropId = "X-Daylight-Drop-Id"
    public static let headerDropType = "X-Daylight-Drop-Type"
    public static let headerDropFilename = "X-Daylight-Drop-Filename"
    public static let headerDropSha256 = "X-Daylight-Drop-Sha256"
    public static let headerDropOrigin = "X-Daylight-Drop-Origin"
    
    // Loop suppression tags
    public static let originPasteboardType = "com.daylight.drop.origin"
    public static let transferIdPasteboardType = "com.daylight.drop.transferId"
    public static let defaultLruCapacity = 256
    public static let defaultTtlSeconds: TimeInterval = 60.0
    
    // Roles
    public static let roleMac = "mac_desktop"
    public static let roleAndroid = "dc1_tablet"
    
    // Staging
    public static let defaultIncomingDirectory = "~/DaylightDrop/incoming"
    public static let defaultOutgoingDirectory = "~/DaylightDrop/outgoing"
    public static let tempPrefix = ".tmp_"
    public static let partSuffix = ".part"
}

public struct HealthResponse: Codable, Sendable, Equatable {
    public let status: String
    public let device_id: String
    public let device_type: String
    public let version: String
    
    public init(status: String = "ok", device_id: String, device_type: String = "macos", version: String = ProtocolConstants.protocolVersion) {
        self.status = status
        self.device_id = device_id
        self.device_type = device_type
        self.version = version
    }
}

public struct TextPayload: Codable, Sendable, Equatable {
    public let id: String
    public let type: String // "prompt" | "clipboard"
    public let text: String
    public let origin: String
    public let timestamp: Int64
    
    public init(id: String = UUID().uuidString, type: String = "prompt", text: String, origin: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.id = id
        self.type = type
        self.text = text
        self.origin = origin
        self.timestamp = timestamp
    }
}

public struct DropSuccessResponse: Codable, Sendable, Equatable {
    public let status: String
    public let received: Bool
    public let transfer_id: String
    public let sha256: String
    public let filename: String
    public let bytes: Int64
    
    public init(status: String = "ok", received: Bool = true, transfer_id: String, sha256: String, filename: String, bytes: Int64) {
        self.status = status
        self.received = received
        self.transfer_id = transfer_id
        self.sha256 = sha256
        self.filename = filename
        self.bytes = bytes
    }
}

public struct DropErrorResponse: Codable, Sendable, Equatable {
    public let status: String
    public let error: String
    public let message: String
    
    public init(status: String = "error", error: String, message: String) {
        self.status = status
        self.error = error
        self.message = message
    }
}

public struct DiscoveredPeer: Hashable, Sendable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public let deviceName: String
    public let deviceModel: String
    public let role: String
    public let ip: String
    public let port: UInt16
    public let protoVer: String
    public let lastSeen: Date
    
    public init(
        deviceId: String,
        deviceName: String,
        deviceModel: String = "Unknown",
        role: String = "unknown",
        ip: String,
        port: UInt16 = ProtocolConstants.androidPort,
        protoVer: String = ProtocolConstants.protocolVersion,
        lastSeen: Date = Date()
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.role = role
        self.ip = ip
        self.port = port
        self.protoVer = protoVer
        self.lastSeen = lastSeen
    }
}
