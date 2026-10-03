import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

/// Advertises Daylight Drop service over Bonjour (mDNS) using Network.framework NWListener.
public final class DaylightDropAdvertiser: @unchecked Sendable {
    private var listener: NWListener?
    public let port: UInt16
    public let deviceId: String
    public let deviceName: String
    public let ipHint: String
    
    public private(set) var isRunning: Bool = false
    public var onStateChange: ((NWListener.State) -> Void)?
    
    public static func getWifiIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var en0Address: String? = nil
        var otherWifiAddress: String? = nil
        var fallbackAddress: String? = nil
        
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            guard let addr = interface.ifa_addr else {
                ptr = interface.ifa_next
                continue
            }
            let addrFamily = addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                let flags = Int32(interface.ifa_flags)
                let isUp = (flags & IFF_UP) != 0
                let isRunning = (flags & IFF_RUNNING) != 0
                let isLoopback = (flags & IFF_LOOPBACK) != 0
                
                if isUp && isRunning && !isLoopback {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let ip = hostname.withUnsafeBufferPointer { ptr in ptr.baseAddress.map { String(cString: $0) } } ?? ""
                        if name == "en0" {
                            en0Address = ip
                        } else if name.hasPrefix("en") && otherWifiAddress == nil {
                            otherWifiAddress = ip
                        } else if fallbackAddress == nil {
                            fallbackAddress = ip
                        }
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return en0Address ?? otherWifiAddress ?? fallbackAddress
    }
    
    public init(
        port: UInt16 = ProtocolConstants.macPort,
        deviceId: String,
        deviceName: String,
        ipHint: String? = nil
    ) {
        self.port = port
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.ipHint = ipHint ?? DaylightDropAdvertiser.getWifiIPv4Address() ?? "127.0.0.1"
    }
    
    public func start(on queue: DispatchQueue = .main) throws {
        stop()
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "DaylightDrop", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        
        let nwListener = try NWListener(using: parameters, on: nwPort)
        
        var resolvedIp = ipHint
        if resolvedIp == "127.0.0.1" || resolvedIp.isEmpty {
            if let activeIp = DaylightDropAdvertiser.getWifiIPv4Address() {
                resolvedIp = activeIp
            }
        }
        
        var txtRecord = NWTXTRecord()
        txtRecord["devId"] = deviceId
        txtRecord["devName"] = deviceName
        txtRecord["devModel"] = "Mac"
        txtRecord["role"] = ProtocolConstants.roleMac
        txtRecord["port"] = "\(port)"
        txtRecord["protoVer"] = ProtocolConstants.protocolVersion
        txtRecord["ip"] = resolvedIp
        txtRecord["wsPath"] = ProtocolConstants.webSocketEndpoint
        txtRecord["dropPath"] = ProtocolConstants.dropEndpoint
        
        nwListener.service = NWListener.Service(
            name: deviceName,
            type: ProtocolConstants.serviceType,
            domain: nil,
            txtRecord: txtRecord
        )
        
        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.isRunning = true
            case .failed, .cancelled:
                self.isRunning = false
            default:
                break
            }
            self.onStateChange?(state)
        }
        
        self.listener = nwListener
        nwListener.start(queue: queue)
    }
    
    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }
}

/// Discovers Daylight Drop peers across the local subnet using Network.framework NWBrowser.
public final class DaylightDropBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    public private(set) var isBrowsing: Bool = false
    
    public var onPeerDiscovered: ((DiscoveredPeer) -> Void)?
    public var onPeerLost: ((String) -> Void)?
    
    private var peers: [String: DiscoveredPeer] = [:]
    private let lock = NSLock()
    
    public init() {}
    
    public func startBrowsing(queue: DispatchQueue = .main) {
        stop()
        
        let descriptor = NWBrowser.Descriptor.bonjour(type: ProtocolConstants.serviceType, domain: nil)
        let parameters = NWParameters()
        let nwBrowser = NWBrowser(for: descriptor, using: parameters)
        self.browser = nwBrowser
        self.isBrowsing = true
        
        nwBrowser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            self.handleBrowseResults(results: results, changes: changes)
        }
        
        nwBrowser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.isBrowsing = false
            default:
                break
            }
        }
        
        nwBrowser.start(queue: queue)
    }
    
    public func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        lock.lock()
        peers.removeAll()
        lock.unlock()
    }
    
    public func getDiscoveredPeers() -> [DiscoveredPeer] {
        lock.lock()
        defer { lock.unlock() }
        return Array(peers.values)
    }
    
    private func handleBrowseResults(results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                parseAndAddResult(result)
            case .removed(let result):
                if case let .service(name, _, _, _) = result.endpoint {
                    removePeer(name: name)
                }
            case .changed(old: _, new: let newResult, flags: _):
                parseAndAddResult(newResult)
            default:
                break
            }
        }
    }
    
    private func parseAndAddResult(_ result: NWBrowser.Result) {
        guard case let .service(name, _, _, _) = result.endpoint else { return }
        
        var devId = name
        var devName = name
        var devModel = "Unknown"
        var role = "unknown"
        var port: UInt16 = ProtocolConstants.androidPort
        var protoVer = ProtocolConstants.protocolVersion
        var ip = ""
        
        if case let .bonjour(record) = result.metadata {
            if let id = record.dictionary["devId"] { devId = id }
            if let dn = record.dictionary["devName"] { devName = dn }
            if let dm = record.dictionary["devModel"] { devModel = dm }
            if let r = record.dictionary["role"] { role = r }
            if let pStr = record.dictionary["port"], let p = UInt16(pStr) { port = p }
            if let pv = record.dictionary["protoVer"] { protoVer = pv }
            if let ipHint = record.dictionary["ip"] {
                if ipHint != "127.0.0.1" && !ipHint.hasPrefix("127.") {
                    ip = ipHint
                }
            }
        }
        
        if ip.isEmpty {
            if let resolved = DaylightDropBrowser.resolveServiceHostname(name: name) {
                ip = resolved
            }
        }
        
        let peer = DiscoveredPeer(
            deviceId: devId,
            deviceName: devName,
            deviceModel: devModel,
            role: role,
            ip: ip,
            port: port,
            protoVer: protoVer,
            lastSeen: Date()
        )
        
        lock.lock()
        peers[devId] = peer
        lock.unlock()
        
        onPeerDiscovered?(peer)
    }
    
    public static func resolveServiceHostname(name: String) -> String? {
        let hostName = "\(name).local"
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(hostName, nil, &hints, &res) == 0, let first = res {
            defer { freeaddrinfo(res) }
            var ptr: UnsafeMutablePointer<addrinfo>? = first
            while let current = ptr {
                if let addr = current.pointee.ai_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                    var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    let sa = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var inAddr = sa.sin_addr
                    if inet_ntop(AF_INET, &inAddr, &ipBuffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let resolved = String(cString: ipBuffer)
                        if !resolved.isEmpty && resolved != "127.0.0.1" && !resolved.hasPrefix("127.") {
                            return resolved
                        }
                    }
                }
                ptr = current.pointee.ai_next
            }
        }
        return nil
    }
    
    private func removePeer(name: String) {
        lock.lock()
        var removedId: String? = nil
        for (id, peer) in peers {
            if peer.deviceName == name || id == name {
                removedId = id
                break
            }
        }
        if let id = removedId {
            peers.removeValue(forKey: id)
        }
        lock.unlock()
        
        if let id = removedId {
            onPeerLost?(id)
        }
    }
}
