import Foundation
import CryptoKit

public enum HTTPClientError: Error, LocalizedError {
    case noPeerAvailable
    case invalidURL(String)
    case transferFailed(statusCode: Int, body: String)
    case checksumMismatch
    case decodingError(Error)
    
    public var errorDescription: String? {
        switch self {
        case .noPeerAvailable:
            return "No Daylight peer reachable via USB or Wi-Fi"
        case .invalidURL(let url):
            return "Invalid target URL: \(url)"
        case .transferFailed(let code, let body):
            return "Transfer failed with HTTP status \(code): \(body)"
        case .checksumMismatch:
            return "Server reported checksum mismatch"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        }
    }
}

/// Outbound HTTP/WebSocket client communicating with Daylight DC1 (port 8766).
public final class DaylightHTTPClient: Sendable {
    public let localDeviceId: String
    private let session: URLSession
    
    public init(localDeviceId: String, session: URLSession = .shared) {
        self.localDeviceId = localDeviceId
        self.session = session
    }
    
    // MARK: - Health Check
    
    public func checkHealth(host: String = "127.0.0.1", port: UInt16 = ProtocolConstants.androidPort, timeout: TimeInterval = 2.0) async throws -> HealthResponse {
        guard let url = URL(string: "http://\(host):\(port)\(ProtocolConstants.healthEndpoint)") else {
            throw HTTPClientError.invalidURL("http://\(host):\(port)\(ProtocolConstants.healthEndpoint)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw HTTPClientError.transferFailed(statusCode: status, body: body)
        }
        
        do {
            return try JSONDecoder().decode(HealthResponse.self, from: data)
        } catch {
            throw HTTPClientError.decodingError(error)
        }
    }
    
    // MARK: - File Drop
    
    public func sendDrop(
        fileURL: URL,
        type: String = "document",
        origin: String? = nil,
        transferId: String = UUID().uuidString,
        targetHost: String = "127.0.0.1",
        targetPort: UInt16 = ProtocolConstants.androidPort
    ) async throws -> DropSuccessResponse {
        let fileData = try Data(contentsOf: fileURL)
        let sha256 = LoopSuppressionEngine.computeSha256(data: fileData)
        let filename = fileURL.lastPathComponent
        let originId = origin ?? localDeviceId
        
        guard let url = URL(string: "http://\(targetHost):\(targetPort)\(ProtocolConstants.dropEndpoint)") else {
            throw HTTPClientError.invalidURL("http://\(targetHost):\(targetPort)\(ProtocolConstants.dropEndpoint)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(transferId, forHTTPHeaderField: ProtocolConstants.headerDropId)
        request.setValue(type, forHTTPHeaderField: ProtocolConstants.headerDropType)
        request.setValue(filename, forHTTPHeaderField: ProtocolConstants.headerDropFilename)
        request.setValue(sha256, forHTTPHeaderField: ProtocolConstants.headerDropSha256)
        request.setValue(originId, forHTTPHeaderField: ProtocolConstants.headerDropOrigin)
        request.setValue("\(fileData.count)", forHTTPHeaderField: "Content-Length")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.upload(for: request, from: fileData)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.transferFailed(statusCode: -1, body: "No HTTP response")
        }
        
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("checksum_mismatch") {
                throw HTTPClientError.checksumMismatch
            }
            throw HTTPClientError.transferFailed(statusCode: http.statusCode, body: body)
        }
        
        do {
            return try JSONDecoder().decode(DropSuccessResponse.self, from: data)
        } catch {
            return DropSuccessResponse(status: "ok", received: true, transfer_id: transferId, sha256: sha256, filename: filename, bytes: Int64(fileData.count))
        }
    }
    
    // MARK: - Text / Prompt
    
    public func sendText(
        payload: TextPayload,
        targetHost: String = "127.0.0.1",
        targetPort: UInt16 = ProtocolConstants.androidPort
    ) async throws -> String {
        guard let url = URL(string: "http://\(targetHost):\(targetPort)\(ProtocolConstants.textEndpoint)") else {
            throw HTTPClientError.invalidURL("http://\(targetHost):\(targetPort)\(ProtocolConstants.textEndpoint)")
        }
        
        let bodyData = try JSONEncoder().encode(payload)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")
        request.setValue(payload.origin, forHTTPHeaderField: ProtocolConstants.headerDropOrigin)
        request.httpBody = bodyData
        
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw HTTPClientError.transferFailed(statusCode: status, body: body)
        }
        
        return String(data: data, encoding: .utf8) ?? ""
    }
}
