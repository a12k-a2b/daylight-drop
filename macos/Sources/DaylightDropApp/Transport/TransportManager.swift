import Foundation

public enum ChannelType: String, Sendable {
    case usb = "USB (ADB Tunnel)"
    case wifi = "Wi-Fi (mDNS)"
}

/// Unified Transport Coordinator for macOS Daylight Drop.
public final class TransportManager: @unchecked Sendable {
    public static let shared = TransportManager()
    
    public let localDeviceId: String
    public let localDeviceName: String
    
    public let advertiser: DaylightDropAdvertiser
    public let browser: DaylightDropBrowser
    public let adbTracker: ADBDeviceTracker
    public let server: DaylightHTTPServer
    public let client: DaylightHTTPClient
    public let loopSuppression: LoopSuppressionEngine
    
    public private(set) var activeWifiPeer: DiscoveredPeer?
    public private(set) var isUsbTunnelHealthy: Bool = false
    public private(set) var activeUsbSerial: String?
    
    public var onChannelChanged: ((ChannelType?) -> Void)?
    public var onPeerDiscovered: ((DiscoveredPeer) -> Void)?
    public var onFileReceived: ((_ transferId: String, _ filename: String, _ type: String, _ fileURL: URL, _ sha256: String) -> Void)?
    public var onTextReceived: ((TextPayload) -> Void)?
    
    private let lock = NSLock()
    private var isRunning: Bool = false
    
    public var activeChannel: ChannelType? {
        lock.lock()
        defer { lock.unlock() }
        if isUsbTunnelHealthy {
            return .usb
        }
        if activeWifiPeer != nil {
            return .wifi
        }
        return nil
    }
    
    public init(
        deviceId: String = "mac-" + UUID().uuidString.prefix(8),
        deviceName: String = Host.current().localizedName ?? "MacBook Pro",
        serverPort: UInt16 = ProtocolConstants.macPort,
        incomingDirectory: URL? = nil
    ) {
        self.localDeviceId = deviceId
        self.localDeviceName = deviceName
        
        let loop = LoopSuppressionEngine(localDeviceId: deviceId)
        self.loopSuppression = loop
        
        self.advertiser = DaylightDropAdvertiser(
            port: serverPort,
            deviceId: deviceId,
            deviceName: deviceName
        )
        self.browser = DaylightDropBrowser()
        self.adbTracker = ADBDeviceTracker()
        self.server = DaylightHTTPServer(
            port: serverPort,
            deviceId: deviceId,
            incomingDirectory: incomingDirectory,
            loopSuppression: loop
        )
        self.client = DaylightHTTPClient(localDeviceId: deviceId)
        
        setupCallbacks()
    }
    
    private func setupCallbacks() {
        // Forward server callbacks
        server.onDropReceived = { [weak self] transferId, filename, type, fileURL, sha256 in
            self?.onFileReceived?(transferId, filename, type, fileURL, sha256)
        }
        
        server.onTextReceived = { [weak self] payload in
            self?.onTextReceived?(payload)
        }
        
        // Browser callbacks
        browser.onPeerDiscovered = { [weak self] peer in
            guard let self = self else { return }
            self.lock.lock()
            if peer.role == ProtocolConstants.roleAndroid || peer.deviceId.contains("JMBR") || peer.deviceName.contains("Daylight") {
                self.activeWifiPeer = peer
            }
            let currentChannel = self.isUsbTunnelHealthy ? ChannelType.usb : (self.activeWifiPeer != nil ? ChannelType.wifi : nil)
            self.lock.unlock()
            
            self.onPeerDiscovered?(peer)
            self.onChannelChanged?(currentChannel)
        }
        
        browser.onPeerLost = { [weak self] peerId in
            guard let self = self else { return }
            self.lock.lock()
            if self.activeWifiPeer?.deviceId == peerId {
                self.activeWifiPeer = nil
            }
            let currentChannel = self.isUsbTunnelHealthy ? ChannelType.usb : (self.activeWifiPeer != nil ? ChannelType.wifi : nil)
            self.lock.unlock()
            
            self.onChannelChanged?(currentChannel)
        }
        
        // ADB callbacks
        adbTracker.onDeviceAttached = { [weak self] serial, model in
            self?.lock.lock()
            self?.activeUsbSerial = serial
            self?.lock.unlock()
            self?.probeUsbTunnelHealth(serial: serial)
        }
        
        adbTracker.onTunnelEstablished = { [weak self] serial in
            self?.probeUsbTunnelHealth(serial: serial)
        }
        
        adbTracker.onDeviceDetached = { [weak self] serial in
            guard let self = self else { return }
            self.lock.lock()
            if self.activeUsbSerial == serial {
                self.activeUsbSerial = nil
                self.isUsbTunnelHealthy = false
            }
            let currentChannel = self.activeWifiPeer != nil ? ChannelType.wifi : nil
            self.lock.unlock()
            self.onChannelChanged?(currentChannel)
        }
    }
    
    public func start() throws {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()
        
        try server.start()
        browser.startBrowsing()
        adbTracker.startTracking()
    }
    
    public func stop() {
        lock.lock()
        isRunning = false
        isUsbTunnelHealthy = false
        activeWifiPeer = nil
        lock.unlock()
        
        server.stop()
        browser.stop()
        adbTracker.stopTracking()
        onChannelChanged?(nil)
    }
    
    private func updateUsbHealthState(isHealthy: Bool) {
        lock.lock()
        self.isUsbTunnelHealthy = isHealthy
        let currentChannel: ChannelType? = isHealthy ? .usb : (self.activeWifiPeer != nil ? .wifi : nil)
        lock.unlock()
        self.onChannelChanged?(currentChannel)
    }
    
    public func probeUsbTunnelHealth(serial: String) {
        Task {
            do {
                let health = try await client.checkHealth(host: "127.0.0.1", port: ProtocolConstants.androidPort, timeout: 1.5)
                self.updateUsbHealthState(isHealthy: health.status == "ok")
            } catch {
                self.updateUsbHealthState(isHealthy: false)
            }
        }
    }
    
    // MARK: - Outbound Transmission
    
    public func sendFile(fileURL: URL, type: String = "document") async throws -> DropSuccessResponse {
        guard let endpoint = resolveTargetEndpoint() else {
            throw HTTPClientError.noPeerAvailable
        }
        return try await client.sendDrop(
            fileURL: fileURL,
            type: type,
            origin: localDeviceId,
            targetHost: endpoint.host,
            targetPort: endpoint.port
        )
    }
    
    public func sendText(text: String, type: String = "prompt") async throws -> String {
        guard let endpoint = resolveTargetEndpoint() else {
            throw HTTPClientError.noPeerAvailable
        }
        
        let payload = TextPayload(
            type: type,
            text: text,
            origin: localDeviceId
        )
        
        // Record in loop suppression to avoid echoing
        loopSuppression.record(text: text)
        
        return try await client.sendText(
            payload: payload,
            targetHost: endpoint.host,
            targetPort: endpoint.port
        )
    }
    
    public func resolveTargetEndpoint() -> (host: String, port: UInt16)? {
        lock.lock()
        defer { lock.unlock() }
        
        // 1. Prefer USB tunnel (127.0.0.1:8766) if healthy
        if isUsbTunnelHealthy {
            return ("127.0.0.1", ProtocolConstants.androidPort)
        }
        
        // 2. Fall back to Wi-Fi peer
        if let peer = activeWifiPeer, !peer.ip.isEmpty {
            return (peer.ip, peer.port)
        }
        
        return nil
    }
}
