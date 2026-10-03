import Foundation
import Network
import CryptoKit

/// Native Swift HTTP/WebSocket server listening on port 8765 using Network.framework.
public final class DaylightHTTPServer: @unchecked Sendable {
    public let port: UInt16
    public let deviceId: String
    public let deviceName: String
    public var incomingDirectory: URL
    public let loopSuppression: LoopSuppressionEngine
    
    private var listener: NWListener?
    public private(set) var isRunning: Bool = false
    
    public var onDropReceived: ((_ transferId: String, _ filename: String, _ type: String, _ fileURL: URL, _ sha256: String) -> Void)?
    public var onTextReceived: ((TextPayload) -> Void)?
    public var onWebSocketMessage: ((String) -> Void)?
    
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var activeWsConnections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()
    private static let storageLock = NSLock()

    public static func sanitizeFilename(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*:|\"<>")
        let cleaned = base.components(separatedBy: invalidCharacters).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(255))
    }

    public static func resolveUniqueDestinationURL(directory: URL, desiredFilename: String) -> URL {
        storageLock.lock()
        defer { storageLock.unlock() }
        return internalResolveUniqueURL(directory: directory, desiredFilename: desiredFilename)
    }

    private static func internalResolveUniqueURL(directory: URL, desiredFilename: String) -> URL {
        let fm = FileManager.default
        let safeName = sanitizeFilename(desiredFilename)
        let ext = (safeName as NSString).pathExtension
        let baseName = (safeName as NSString).deletingPathExtension

        var target = directory.appendingPathComponent(safeName)
        var index = 1
        while fm.fileExists(atPath: target.path) {
            let nextName: String
            if ext.isEmpty {
                nextName = "\(baseName) (\(index))"
            } else {
                nextName = "\(baseName) (\(index)).\(ext)"
            }
            target = directory.appendingPathComponent(nextName)
            index += 1
        }
        return target
    }

    public static func commitInboundFile(tempURL: URL, directory: URL, desiredFilename: String) throws -> URL {
        storageLock.lock()
        defer { storageLock.unlock() }

        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let finalURL = internalResolveUniqueURL(directory: directory, desiredFilename: desiredFilename)
        try fm.moveItem(at: tempURL, to: finalURL)
        return finalURL
    }
    
    public init(
        port: UInt16 = ProtocolConstants.macPort,
        deviceId: String,
        deviceName: String = Host.current().localizedName ?? "Mac",
        incomingDirectory: URL? = nil,
        loopSuppression: LoopSuppressionEngine? = nil
    ) {
        self.port = port
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.loopSuppression = loopSuppression ?? LoopSuppressionEngine(localDeviceId: deviceId)
        
        if let dir = incomingDirectory {
            self.incomingDirectory = dir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.incomingDirectory = home.appendingPathComponent("DaylightDrop/incoming")
        }
    }
    
    public func start(queue: DispatchQueue = .global(qos: .userInitiated)) throws {
        stop()
        
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: incomingDirectory.path) {
            try? fileManager.createDirectory(at: incomingDirectory, withIntermediateDirectories: true)
        }
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "DaylightDrop", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        
        let nwListener = try NWListener(using: parameters, on: nwPort)
        self.listener = nwListener
        
        var txtRecord = NWTXTRecord()
        txtRecord["devId"] = deviceId
        txtRecord["devName"] = deviceName
        txtRecord["devModel"] = "Mac"
        txtRecord["role"] = ProtocolConstants.roleMac
        txtRecord["port"] = "\(port)"
        txtRecord["protoVer"] = ProtocolConstants.protocolVersion
        txtRecord["dropPath"] = ProtocolConstants.dropEndpoint
        txtRecord["wsPath"] = ProtocolConstants.webSocketEndpoint
        if let wifiIp = DaylightDropAdvertiser.getWifiIPv4Address() {
            txtRecord["ip"] = wifiIp
        }
        
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
        }
        
        nwListener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection, queue: queue)
        }
        
        nwListener.start(queue: queue)
    }
    
    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        
        lock.lock()
        let conns = Array(activeConnections.values)
        activeConnections.removeAll()
        activeWsConnections.removeAll()
        lock.unlock()
        
        for conn in conns {
            conn.cancel()
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection, queue: DispatchQueue) {
        let connId = ObjectIdentifier(connection)
        lock.lock()
        activeConnections[connId] = connection
        lock.unlock()
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.lock.lock()
                self?.activeConnections.removeValue(forKey: connId)
                self?.activeWsConnections.removeValue(forKey: connId)
                self?.lock.unlock()
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        let reader = HttpRequestReader(connection: connection) { [weak self] headerString, initialBody in
            self?.processParsedRequest(connection: connection, headerString: headerString, initialBody: initialBody)
        }
        reader.start()
    }
    
    private func processParsedRequest(connection: NWConnection, headerString: String, initialBody: Data) {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, statusCode: 400, body: "{\"status\":\"error\"}")
            return
        }
        
        let requestTokens = requestLine.split(separator: " ")
        guard requestTokens.count >= 2 else {
            sendResponse(connection: connection, statusCode: 400, body: "{\"status\":\"error\"}")
            return
        }
        
        let method = String(requestTokens[0]).uppercased()
        let path = String(requestTokens[1])
        
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIdx = line.firstIndex(of: ":") {
                let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        
        // Handle routes
        if method == "GET" && path == ProtocolConstants.healthEndpoint {
            handleHealth(connection: connection)
        } else if method == "GET" && path == ProtocolConstants.webSocketEndpoint {
            handleWebSocketUpgrade(connection: connection, headers: headers)
        } else if method == "POST" && path == ProtocolConstants.textEndpoint {
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            handleTextPost(connection: connection, headers: headers, initialBody: initialBody, contentLength: contentLength)
        } else if method == "POST" && path == ProtocolConstants.dropEndpoint {
            let contentLength = Int64(headers["content-length"] ?? "0") ?? 0
            handleDropPost(connection: connection, headers: headers, initialBody: initialBody, contentLength: contentLength)
        } else {
            sendResponse(connection: connection, statusCode: 404, body: "{\"status\":\"error\",\"message\":\"Not Found\"}")
        }
    }
    
    // MARK: - Handlers
    
    private func handleHealth(connection: NWConnection) {
        let resp = HealthResponse(status: "ok", device_id: deviceId, device_type: "macos", version: ProtocolConstants.protocolVersion)
        if let json = try? JSONEncoder().encode(resp), let str = String(data: json, encoding: .utf8) {
            sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: str)
        } else {
            sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"status\":\"ok\"}")
        }
    }
    
    private func handleTextPost(connection: NWConnection, headers: [String: String], initialBody: Data, contentLength: Int) {
        let session = TextBodySession(connection: connection, contentLength: contentLength, initialData: initialBody) { [weak self] bodyData in
            self?.processTextBody(connection: connection, bodyData: bodyData)
        }
        session.start()
    }
    
    private func processTextBody(connection: NWConnection, bodyData: Data) {
        guard let payload = try? JSONDecoder().decode(TextPayload.self, from: bodyData) else {
            sendResponse(connection: connection, statusCode: 400, body: "{\"status\":\"error\",\"error\":\"invalid_payload\",\"message\":\"Could not parse TextPayload JSON\"}")
            return
        }
        
        let hash = LoopSuppressionEngine.computeSha256(text: payload.text)
        
        // Loop suppression check
        if loopSuppression.shouldSuppressIncoming(origin: payload.origin, hash: hash) {
            sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"status\":\"ok\",\"received\":false,\"suppressed\":true}")
            return
        }
        
        // Record in cache
        loopSuppression.record(hash: hash)
        
        // Invoke listener
        onTextReceived?(payload)
        
        sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"status\":\"ok\",\"received\":true,\"id\":\"\(payload.id)\"}")
    }
    
    private func handleDropPost(connection: NWConnection, headers: [String: String], initialBody: Data, contentLength: Int64) {
        let transferId = headers[ProtocolConstants.headerDropId.lowercased()] ?? UUID().uuidString
        let dropType = headers[ProtocolConstants.headerDropType.lowercased()] ?? "file"
        let rawFilename = headers[ProtocolConstants.headerDropFilename.lowercased()] ?? "dropped_\(transferId).bin"
        let filename = (rawFilename as NSString).lastPathComponent
        let expectedSha256 = headers[ProtocolConstants.headerDropSha256.lowercased()]?.lowercased()
        let origin = headers[ProtocolConstants.headerDropOrigin.lowercased()] ?? ""
        
        if loopSuppression.isOriginSelf(origin) {
            sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"status\":\"ok\",\"received\":false,\"suppressed\":true}")
            return
        }
        
        let tempFilename = "\(ProtocolConstants.tempPrefix)\(transferId)_\(filename)\(ProtocolConstants.partSuffix)"
        let tempURL = incomingDirectory.appendingPathComponent(tempFilename)
        let fileManager = FileManager.default

        if contentLength == 0 {
            let emptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            if let expected = expectedSha256, !expected.isEmpty, expected != emptySha256 {
                let errResp = DropErrorResponse(status: "error", error: "checksum_mismatch", message: "Expected \(expected) but computed \(emptySha256)")
                if let errJson = try? JSONEncoder().encode(errResp), let errStr = String(data: errJson, encoding: .utf8) {
                    sendResponse(connection: connection, statusCode: 400, contentType: "application/json", body: errStr)
                } else {
                    sendResponse(connection: connection, statusCode: 400, body: "{\"status\":\"error\",\"error\":\"checksum_mismatch\"}")
                }
                return
            }
            
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
            fileManager.createFile(atPath: tempURL.path, contents: Data())
            
            let finalURL: URL
            do {
                finalURL = try DaylightHTTPServer.commitInboundFile(tempURL: tempURL, directory: incomingDirectory, desiredFilename: filename)
            } catch {
                sendResponse(connection: connection, statusCode: 500, body: "{\"status\":\"error\",\"message\":\"Failed to commit file: \(error.localizedDescription)\"}")
                return
            }
            
            let assignedFilename = finalURL.lastPathComponent
            loopSuppression.record(hash: emptySha256)
            onDropReceived?(transferId, assignedFilename, dropType, finalURL, emptySha256)
            let successResp = DropSuccessResponse(
                status: "ok",
                received: true,
                transfer_id: transferId,
                sha256: emptySha256,
                filename: assignedFilename,
                bytes: 0
            )
            if let sJson = try? JSONEncoder().encode(successResp), let sStr = String(data: sJson, encoding: .utf8) {
                sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: sStr)
            } else {
                sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"status\":\"ok\",\"received\":true}")
            }
            return
        }
        if fileManager.fileExists(atPath: tempURL.path) {
            try? fileManager.removeItem(at: tempURL)
        }
        fileManager.createFile(atPath: tempURL.path, contents: nil)
        
        guard let fileHandle = try? FileHandle(forWritingTo: tempURL) else {
            sendResponse(connection: connection, statusCode: 500, body: "{\"status\":\"error\",\"message\":\"Failed to create temp file\"}")
            return
        }
        
        let dropSession = DropStreamSession(
            connection: connection,
            transferId: transferId,
            filename: filename,
            dropType: dropType,
            expectedSha256: expectedSha256,
            contentLength: contentLength,
            tempURL: tempURL,
            incomingDirectory: incomingDirectory,
            fileHandle: fileHandle,
            initialBody: initialBody
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let hash, let bytesWritten, let committedURL):
                let assignedFilename = committedURL.lastPathComponent
                self.loopSuppression.record(hash: hash)
                self.onDropReceived?(transferId, assignedFilename, dropType, committedURL, hash)
                let successResp = DropSuccessResponse(
                    status: "ok",
                    received: true,
                    transfer_id: transferId,
                    sha256: hash,
                    filename: assignedFilename,
                    bytes: bytesWritten
                )
                if let sJson = try? JSONEncoder().encode(successResp), let sStr = String(data: sJson, encoding: .utf8) {
                    self.sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: sStr)
                } else {
                    self.sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"status\":\"ok\",\"received\":true}")
                }
            case .checksumMismatch(let expected, let actual):
                let errResp = DropErrorResponse(status: "error", error: "checksum_mismatch", message: "Expected \(expected) but computed \(actual)")
                if let errJson = try? JSONEncoder().encode(errResp), let errStr = String(data: errJson, encoding: .utf8) {
                    self.sendResponse(connection: connection, statusCode: 400, contentType: "application/json", body: errStr)
                } else {
                    self.sendResponse(connection: connection, statusCode: 400, body: "{\"status\":\"error\",\"error\":\"checksum_mismatch\"}")
                }
            case .failure(let error):
                self.sendResponse(connection: connection, statusCode: 500, body: "{\"status\":\"error\",\"message\":\"\(error)\"}")
            }
        }
        dropSession.start()
    }
    
    // MARK: - WebSocket Handshake & Framing
    
    private func handleWebSocketUpgrade(connection: NWConnection, headers: [String: String]) {
        guard let secKey = headers["sec-websocket-key"] else {
            sendResponse(connection: connection, statusCode: 400, body: "Missing Sec-WebSocket-Key")
            return
        }
        
        let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = secKey + magicGUID
        guard let combinedData = combined.data(using: .utf8) else {
            sendResponse(connection: connection, statusCode: 500, body: "Encoding error")
            return
        }
        
        let sha1 = Insecure.SHA1.hash(data: combinedData)
        let acceptKey = Data(sha1).base64EncodedString()
        
        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
                       "Upgrade: websocket\r\n" +
                       "Connection: Upgrade\r\n" +
                       "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
        
        guard let respData = response.data(using: .utf8) else { return }
        connection.send(content: respData, completion: .contentProcessed({ [weak self] error in
            guard let self = self, error == nil else { return }
            let connId = ObjectIdentifier(connection)
            self.lock.lock()
            self.activeWsConnections[connId] = connection
            self.lock.unlock()
            self.readWebSocketFrames(connection: connection)
        }))
    }
    
    private func readWebSocketFrames(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, error == nil, let data = data, data.count >= 2 else {
                return
            }
            
            let byte1 = data[0]
            let byte2 = data[1]
            let opcode = byte1 & 0x0F
            let isMasked = (byte2 & 0x80) != 0
            var payloadLen = Int(byte2 & 0x7F)
            var offset = 2
            
            if payloadLen == 126 {
                if data.count < offset + 2 { return }
                payloadLen = Int(data[offset]) << 8 | Int(data[offset + 1])
                offset += 2
            } else if payloadLen == 127 {
                if data.count < offset + 8 { return }
                offset += 8
            }
            
            var maskKey: [UInt8] = []
            if isMasked {
                if data.count < offset + 4 { return }
                maskKey = Array(data[offset..<offset + 4])
                offset += 4
            }
            
            if data.count >= offset + payloadLen {
                let rawPayload = data.subdata(in: offset..<offset + payloadLen)
                var unmasked = Data(count: payloadLen)
                if isMasked {
                    for i in 0..<payloadLen {
                        unmasked[i] = rawPayload[i] ^ maskKey[i % 4]
                    }
                } else {
                    unmasked = rawPayload
                }
                
                if opcode == 0x01 { // Text frame
                    if let text = String(data: unmasked, encoding: .utf8) {
                        self.onWebSocketMessage?(text)
                    }
                } else if opcode == 0x09 { // Ping
                    self.sendWebSocketPong(connection: connection, payload: unmasked)
                } else if opcode == 0x08 { // Close
                    connection.cancel()
                    return
                }
            }
            
            if !isComplete {
                self.readWebSocketFrames(connection: connection)
            }
        }
    }
    
    public func sendWebSocketMessage(_ text: String) {
        lock.lock()
        let conns = Array(activeWsConnections.values)
        lock.unlock()
        
        guard let textData = text.data(using: .utf8) else { return }
        let frame = makeWebSocketFrame(opcode: 0x01, payload: textData)
        for conn in conns {
            conn.send(content: frame, completion: .idempotent)
        }
    }
    
    private func sendWebSocketPong(connection: NWConnection, payload: Data) {
        let frame = makeWebSocketFrame(opcode: 0x0A, payload: payload)
        connection.send(content: frame, completion: .idempotent)
    }
    
    private func makeWebSocketFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | (opcode & 0x0F)) // FIN = 1
        
        let len = payload.count
        if len <= 125 {
            frame.append(UInt8(len))
        } else if len <= 65535 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for i in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> i) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }
    
    // MARK: - Response Helper
    
    private func sendResponse(
        connection: NWConnection,
        statusCode: Int,
        contentType: String = "application/json",
        body: String
    ) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "HTTP"
        }
        
        let bodyData = body.data(using: .utf8) ?? Data()
        let headers = "HTTP/1.1 \(statusCode) \(statusText)\r\n" +
                      "Content-Type: \(contentType)\r\n" +
                      "Content-Length: \(bodyData.count)\r\n" +
                      "Connection: close\r\n\r\n"
        
        var respData = headers.data(using: .utf8) ?? Data()
        respData.append(bodyData)
        
        connection.send(content: respData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed({ _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                connection.cancel()
            }
        }))
    }
}

// MARK: - Helper Session Classes

private final class HttpRequestReader: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()
    private let onHeadersParsed: (String, Data) -> Void
    
    init(connection: NWConnection, onHeadersParsed: @escaping (String, Data) -> Void) {
        self.connection = connection
        self.onHeadersParsed = onHeadersParsed
    }
    
    func start() {
        readNext()
    }
    
    private func readNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if error != nil {
                self.connection.cancel()
                return
            }
            if let data = data {
                self.buffer.append(data)
            }
            
            let headerSeparator = Data([0x0D, 0x0A, 0x0D, 0x0A])
            if let sepRange = self.buffer.range(of: headerSeparator) {
                let headerData = self.buffer.subdata(in: 0..<sepRange.lowerBound)
                let bodyPrefix = self.buffer.subdata(in: sepRange.upperBound..<self.buffer.count)
                if let headerStr = String(data: headerData, encoding: .utf8) {
                    self.onHeadersParsed(headerStr, bodyPrefix)
                } else {
                    self.connection.cancel()
                }
            } else if !isComplete {
                self.readNext()
            } else {
                self.connection.cancel()
            }
        }
    }
}

private final class TextBodySession: @unchecked Sendable {
    private let connection: NWConnection
    private let contentLength: Int
    private var buffer: Data
    private let onComplete: (Data) -> Void
    
    init(connection: NWConnection, contentLength: Int, initialData: Data, onComplete: @escaping (Data) -> Void) {
        self.connection = connection
        self.contentLength = contentLength
        self.buffer = initialData
        self.onComplete = onComplete
    }
    
    func start() {
        if buffer.count >= contentLength {
            onComplete(buffer.prefix(contentLength))
        } else {
            readMore()
        }
    }
    
    private func readMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { chunk, _, _, error in
            if error != nil {
                self.connection.cancel()
                return
            }
            if let chunk = chunk {
                self.buffer.append(chunk)
            }
            if self.buffer.count >= self.contentLength {
                self.onComplete(self.buffer.prefix(self.contentLength))
            } else {
                self.readMore()
            }
        }
    }
}

private enum DropStreamResult: Sendable {
    case success(hash: String, bytesWritten: Int64, finalURL: URL)
    case checksumMismatch(expected: String, actual: String)
    case failure(String)
}

private final class DropStreamSession: @unchecked Sendable {
    private let connection: NWConnection
    private let transferId: String
    private let filename: String
    private let dropType: String
    private let expectedSha256: String?
    private let contentLength: Int64
    private let tempURL: URL
    private let incomingDirectory: URL
    private let fileHandle: FileHandle
    private var hasher = SHA256()
    private var totalBytesWritten: Int64 = 0
    private let onComplete: (DropStreamResult) -> Void
    
    init(
        connection: NWConnection,
        transferId: String,
        filename: String,
        dropType: String,
        expectedSha256: String?,
        contentLength: Int64,
        tempURL: URL,
        incomingDirectory: URL,
        fileHandle: FileHandle,
        initialBody: Data,
        onComplete: @escaping (DropStreamResult) -> Void
    ) {
        self.connection = connection
        self.transferId = transferId
        self.filename = filename
        self.dropType = dropType
        self.expectedSha256 = expectedSha256
        self.contentLength = contentLength
        self.tempURL = tempURL
        self.incomingDirectory = incomingDirectory
        self.fileHandle = fileHandle
        self.onComplete = onComplete
        
        if !initialBody.isEmpty {
            fileHandle.write(initialBody)
            hasher.update(data: initialBody)
            totalBytesWritten += Int64(initialBody.count)
        }
    }
    
    func start() {
        if contentLength == 0 || (totalBytesWritten >= contentLength && contentLength > 0) {
            finish()
        } else {
            readNext()
        }
    }
    
    private func readNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { chunk, _, isComplete, error in
            if let error = error {
                try? self.fileHandle.close()
                try? FileManager.default.removeItem(at: self.tempURL)
                self.onComplete(.failure(error.localizedDescription))
                return
            }
            if let chunk = chunk, !chunk.isEmpty {
                self.fileHandle.write(chunk)
                self.hasher.update(data: chunk)
                self.totalBytesWritten += Int64(chunk.count)
            }
            if (self.contentLength == 0) || (self.contentLength > 0 && self.totalBytesWritten >= self.contentLength) || isComplete {
                self.finish()
            } else {
                self.readNext()
            }
        }
    }
    
    private func finish() {
        try? fileHandle.close()
        let computedHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        
        if let expected = expectedSha256, !expected.isEmpty, computedHash.lowercased() != expected.lowercased() {
            try? fm.removeItem(at: tempURL)
            onComplete(.checksumMismatch(expected: expected, actual: computedHash))
            return
        }
        
        do {
            let finalURL = try DaylightHTTPServer.commitInboundFile(tempURL: tempURL, directory: incomingDirectory, desiredFilename: filename)
            onComplete(.success(hash: computedHash, bytesWritten: totalBytesWritten, finalURL: finalURL))
        } catch {
            try? fm.removeItem(at: tempURL)
            onComplete(.failure("Failed to rename file: \(error.localizedDescription)"))
        }
    }
}
